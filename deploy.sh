#
# deploy.sh — 최신 ECR 이미지를 받아 moly-backend를 EC2에서 (재)기동한다.
#
# 시크릿은 런타임에 SSM Parameter Store에서 읽어 .env 파일(chmod 600, git 제외)로
# 생성한다. 시크릿 값은 절대 출력/로그에 노출하지 않는다.
# 배치 워커용 systemd 유닛(moly-worker.service/.timer)도 여기서 설치/갱신한다.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. 변수 정의
# ---------------------------------------------------------------------------
REGION="ap-northeast-2"
ACCOUNT_ID="676972757138"
ECR_REGISTRY="676972757138.dkr.ecr.ap-northeast-2.amazonaws.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# 환경 판별 — /etc/moly-env 마커 파일(개발서버 전용). 마커가 없으면 prod이므로
# 기존 prod 호스트는 이 변경 전과 동일하게 동작한다(마커 생성 전까지 무영향).
# dev 인스턴스는 셋업 시 1회: echo dev | sudo tee /etc/moly-env
# "호스트가 자기 역할을 안다"는 점은 워커 마커(/etc/moly-worker-host)와 같은 패턴이라
# 배포 호출부(GH Actions)는 환경을 몰라도 된다. 단, 워커 마커(존재만 확인)와 달리
# 이 마커는 **내용(prod|dev)이 필요하다** — sudo touch로 만들면 빈 값으로 즉시 실패한다.
# 값은 화이트리스트로 검증 — 오타가 "빈 SSM 경로 → 필수 키 누락"으로 늦게 터지는 대신
# 원인(마커 값)을 그대로 보고하며 즉시 실패한다(CRLF 등 제어문자는 %q로 가시화).
if [ -e /etc/moly-env ]; then
  # 존재하는 마커는 반드시 읽혀야 한다 — 읽기 실패(권한/디렉터리/PATH 붕괴)를 조용한
  # prod 폴백으로 접지 않고 set -e로 즉시 중단한다. "없음 = prod"와 "있는데 못 읽음 =
  # 사고"의 구분: dev 호스트에서 조용히 prod 시크릿을 읽는 경로를 스크립트 단에서 차단.
  ENV_NAME="$(cat /etc/moly-env)"
else
  ENV_NAME="prod"
fi
case "$ENV_NAME" in
  prod) APP_ENV="production";  IMAGE_REPO="moly-backend" ;;
  dev)  APP_ENV="development"; IMAGE_REPO="moly-backend-dev" ;;
  *) printf "ERROR: /etc/moly-env 값이 prod|dev 가 아닙니다: %q\n" "$ENV_NAME" >&2; exit 1 ;;
esac
SSM_PATH="/moly/${ENV_NAME}/"
SECRETS_DIR="$SCRIPT_DIR/secrets"
FCM_FILE="$SECRETS_DIR/fcm-service-account.json"
STATE_DIR="$SCRIPT_DIR/.deploy-state"
NEXT_COMPOSE_ENV_FILE="$STATE_DIR/compose.env.next"
NEXT_BACKEND_ENV_FILE="$STATE_DIR/backend.env.next"

# 배포할 이미지 태그(불변 git-sha). GH Actions가 인자로 넘긴다. 인자 없이 실행(수동 재배포)하면
# 마지막으로 배포된 태그를 재사용한다 — 수동 실행이 임의의 :latest로 되돌리는 사고 방지.
# compose가 이 .env를 읽는다(:latest 고정 소비 중단 — 2대가 다른 시점에 pull해도 같은 빌드 보장).
IMAGE_TAG="${1:-}"
COMPOSE_ENV_FILE="$SCRIPT_DIR/.env"
if [ -z "$IMAGE_TAG" ] && [ -f "$COMPOSE_ENV_FILE" ]; then
  IMAGE_TAG="$(sed -n 's/^IMAGE_TAG=//p' "$COMPOSE_ENV_FILE")"
fi
IMAGE_TAG="${IMAGE_TAG:-latest}"
# 주의: .env 파일 쓰기는 ECR 로그인 뒤로 미룬다(§2 직후) — 워커 타이머(moly-worker.service)가
# 틱 시작 시점에 .env를 읽으므로, "새 sha는 적혔는데 ECR 자격이 만료된" 창을 없애기 위함.
echo "==> 배포 태그: IMAGE_TAG=$IMAGE_TAG"

echo "==> moly-backend 배포 시작 (region=$REGION, account=$ACCOUNT_ID, env=$ENV_NAME)"

# 의존성 확인
for bin in docker aws jq curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: 필수 명령어 '$bin' 를 PATH에서 찾을 수 없습니다" >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' (v2) 를 사용할 수 없습니다" >&2
  exit 1
fi

# 디스크 여유 확인 — sha 태그 고정 후엔 이미지가 태그를 달고 쌓이므로(§8에서 정리)
# 80% 초과 상태로 pull을 시작하면 100%에서 컨테이너 기동 불가로 발견된다. 여기서 미리 실패.
disk_usage="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "$disk_usage" -gt 80 ]; then
  echo "ERROR: 루트 디스크 사용률 ${disk_usage}% (>80%) — 정리 후 재배포하세요" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. ECR 로그인 (인스턴스 역할 사용 — 키 불필요)
# ---------------------------------------------------------------------------
echo "==> ECR 로그인"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# 새 compose env는 DB preflight 전까지 live .env와 분리한다. preflight가 실패했는데 live .env만
# 새 sha를 가리키면 systemd worker가 API보다 먼저 새 코드·플래그로 뜰 수 있다.
# IMAGE_REPO도 함께 기록 — compose가 환경별 ECR 레포를 고른다(prod=moly-backend,
# dev=moly-backend-dev). compose 쪽 기본값이 moly-backend라 prod는 이 줄이 없어도 동일.
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf 'IMAGE_TAG=%s\nIMAGE_REPO=%s\n' "$IMAGE_TAG" "$IMAGE_REPO" > "$NEXT_COMPOSE_ENV_FILE"

# ---------------------------------------------------------------------------
# 3. SSM Parameter Store에서 파라미터 조회 (복호화)
# ---------------------------------------------------------------------------
echo "==> SSM에서 파라미터 조회 ($SSM_PATH)"
PARAMS_JSON="$(aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --recursive \
  --region "$REGION" \
  --output json)"

# 파라미터 이름의 마지막 세그먼트를 키로, 값을 매핑한다.
# 값은 jq -r 로 하나씩 추출한다(@tsv는 줄바꿈을 이스케이프하므로 사용하지 않는다 —
# fcm-service-account 같은 여러 줄 JSON 값 보존에 필수).
declare -A PARAMS=()
while IFS= read -r name; do
  [ -z "$name" ] && continue
  value="$(printf '%s' "$PARAMS_JSON" \
    | jq -r --arg n "$name" '.Parameters[] | select(.Name == $n) | .Value')"
  key="${name##*/}"
  PARAMS["$key"]="$value"
done < <(printf '%s' "$PARAMS_JSON" | jq -r '.Parameters[].Name')

# 필수 키 존재 확인 (이름만 출력 — 값은 절대 출력하지 않음)
required_keys=(
  anthropic-api-key
  openai-api-key
  supabase-db-connection-string
  supabase-url
  # 신형 API 키(sb_publishable_/sb_secret_) — legacy anon/service_role은 2026-08 유출로 폐기
  supabase-publishable-key
  supabase-secret-key
  revenuecat-webhook-auth
)
# dev는 광고·피드백 전용 Slack 연동 전에도 배포한다. 운영은 두 값을 필수로 둔다.
# 피드백 값이 빠지면 backend의 하위 호환 폴백이 alert 채널을 선택하므로, 조용히
# 잘못 라우팅하지 말고 실행 중인 env를 교체하기 전에 배포를 중단한다.
if [ "$ENV_NAME" = "prod" ]; then
  required_keys+=(fortune-ad-unit-ids slack-feedback-webhook-url)
fi
missing=()
for k in "${required_keys[@]}"; do
  if [ -z "${PARAMS[$k]+x}" ]; then
    missing+=("${SSM_PATH}${k}")
  fi
done
if [ "$ENV_NAME" = "prod" ] && [ -n "${PARAMS[fortune-ad-unit-ids]+x}" ] && [ -z "${PARAMS[fortune-ad-unit-ids]}" ]; then
  missing+=("${SSM_PATH}fortune-ad-unit-ids(빈 값)")
fi
if [ "$ENV_NAME" = "prod" ] && [ -n "${PARAMS[slack-feedback-webhook-url]+x}" ] \
  && [ -z "${PARAMS[slack-feedback-webhook-url]}" ]; then
  missing+=("${SSM_PATH}slack-feedback-webhook-url(빈 값)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: SSM 파라미터 누락: ${missing[*]}" >&2
  exit 1
fi
echo "==> 파라미터 ${#PARAMS[@]}개 수신"

# ---------------------------------------------------------------------------
# 4. env 파일 + FCM 서비스 계정 파일 생성
# ---------------------------------------------------------------------------
echo "==> env 파일 작성"
umask 077

# backend.env — 한 줄 값만. (여러 줄 값인 fcm-service-account는 파일로 별도 처리)
# FCM_PROJECT_ID/FCM 파일·SLACK_WEBHOOK_URL은 옵션(:-): 없으면 backend가 조용히 스킵/no-op.
# SLACK_WEBHOOK_URL은 워커 요약 알림용 — 이 줄이 빠지면 backend.env에 안 실려 워커가
# 값을 못 받고(env len=0) 슬랙 요약이 조용히 no-op 된다(2026-07 워커 알림 누락 원인).
# 모니터링(SOMA-301): SLACK_ALERT/STATUS/FEEDBACK_WEBHOOK_URL(severity 라우팅)·
# HEALTH_TOKEN(deep/synthetic 인증)·WORKER_PING_URL(Healthchecks 데드맨).
# feedback은 prod 필수, 나머지는 옵션(:-) — 미설정 시 알림 no-op/폴백.
# 여기 나열 안 하면 SSM에 있어도 컨테이너까지 안 감(backend.env는 명시 나열만 싣는다).
# META_INSTALL_REFERRER_DECRYPTION_KEY도 옵션(:-) — Meta 설치 리퍼러 복호화 키(64자 hex).
# 비면 /attribution/meta-referrer/decrypt 만 503으로 답하고 앱이 다음 실행에서 재시도한다.
# 다른 기능을 막지 않으므로 required_keys로 올리지 않는다(키 주입 전 배포가 통째로 죽는다).
# 원자적 쓰기(tmp + mv): 워커 타이머의 docker compose run이 임의 시점에 이 파일을 읽는다 —
# truncate 직후 반쪽 파일을 읽으면 DB 연결 문자열 없는 워커가 뜬다(교차검증 이슈 #15).
# 대화 기능 플래그(CURRENT_TURN_CONTEXT·CONTEXT_CHECKPOINT·AGENT)와 오늘의 운세·운세 대화는
# dev에서 실제로 돌려 검증한 뒤 운영에서도 켠다. 아침 푸시(MORNING_PUSH_ENABLED)는 SOMA-338
# 결정대로 계속 끈 상태를 유지한다 — 코드 기본값이 false다.
cat > "$NEXT_BACKEND_ENV_FILE" <<EOF
ENVIRONMENT=${APP_ENV}
REVENUECAT_WEBHOOK_AUTH=${PARAMS[revenuecat-webhook-auth]}
SUPABASE_URL=${PARAMS[supabase-url]}
SUPABASE_PUBLISHABLE_KEY=${PARAMS[supabase-publishable-key]}
SUPABASE_SECRET_KEY=${PARAMS[supabase-secret-key]}
SUPABASE_DB_CONNECTION_STRING=${PARAMS[supabase-db-connection-string]}
ANTHROPIC_API_KEY=${PARAMS[anthropic-api-key]}
OPENAI_API_KEY=${PARAMS[openai-api-key]}
SLACK_WEBHOOK_URL=${PARAMS[slack-webhook-url]:-}
SLACK_ALERT_WEBHOOK_URL=${PARAMS[slack-alert-webhook-url]:-}
SLACK_STATUS_WEBHOOK_URL=${PARAMS[slack-status-webhook-url]:-}
SLACK_FEEDBACK_WEBHOOK_URL=${PARAMS[slack-feedback-webhook-url]:-}
HEALTH_TOKEN=${PARAMS[health-token]:-}
WORKER_PING_URL=${PARAMS[worker-ping-url]:-}
FCM_PROJECT_ID=${PARAMS[fcm-project-id]:-}
FCM_SERVICE_ACCOUNT_FILE=/secrets/fcm-service-account.json
META_INSTALL_REFERRER_DECRYPTION_KEY=${PARAMS[meta-install-referrer-decryption-key]:-}
CURRENT_TURN_CONTEXT_ENABLED=true
CURRENT_CONTEXT_LAST_ACTIVE_ENABLED=true
CONTEXT_CHECKPOINT_ENABLED=true
AGENT_ENABLED=true
AGENT_CANARY_PCT=100
FORTUNE_ENABLED=true
FORTUNE_CHAT_ENABLED=true
FORTUNE_AD_UNIT_IDS=${PARAMS[fortune-ad-unit-ids]:-}
HAY_AD_UNIT_IDS=3343480648,3086065971
HAY_AD_REWARD_ITEM=Reward
HAY_AD_REWARD_AMOUNT=1
EOF

# dev 전용 — 운영에 가면 안 되는 것만 남긴다.
# ENABLE_DEV_ROUTES는 강제 생성·유료 모델 평가 같은 위험 route를 여는 스위치다.
# DEV_OPERATOR_USER_IDS는 Dev DB의 수동 검증 계정이라 운영에서는 의미가 없다.
if [ "$ENV_NAME" = "dev" ]; then
  cat >> "$NEXT_BACKEND_ENV_FILE" <<EOF
ENABLE_DEV_ROUTES=true
DEV_OPERATOR_USER_IDS=445bdde0-025b-403a-bab8-7816827016c3
EOF
fi
chmod 600 "$NEXT_BACKEND_ENV_FILE"

# FCM 서비스 계정 JSON — SSM SecureString(여러 줄) → 파일.
# 컨테이너는 비루트(appuser)로 돌아 파일에 other-read가 필요하다.
# 대신 secrets/ 디렉토리를 700으로 잠가 호스트의 비루트 접근을 막는다.
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -n "${PARAMS[fcm-service-account]+x}" ] && [ -n "${PARAMS[fcm-service-account]}" ]; then
  printf '%s' "${PARAMS[fcm-service-account]}" > "$FCM_FILE"
else
  echo "WARN: ${SSM_PATH}fcm-service-account 미설정 — FCM 푸시 비활성 (빈 파일로 대체)" >&2
  : > "$FCM_FILE"
fi
chmod 644 "$FCM_FILE"

# ---------------------------------------------------------------------------
# 4-b. 설정 지문 계산 (설정 변경 감지용)
# ---------------------------------------------------------------------------
# env/FCM 파일이 바뀌면 backend 컨테이너를 강제 재생성한다.
# (이미지 콘텐츠 변경은 pull + up -d 가 자연 처리하므로 지문에 포함하지 않는다.)
# 시크릿 값은 해시로만 다루고 출력하지 않는다.
new_backend_hash="$(cat "$NEXT_BACKEND_ENV_FILE" "$FCM_FILE" | sha256sum | awk '{print $1}')"
old_backend_hash="$(cat "$STATE_DIR/backend.hash" 2>/dev/null || true)"

RECREATE=()
if [ "$new_backend_hash" != "$old_backend_hash" ]; then RECREATE+=("backend"); fi

# ---------------------------------------------------------------------------
# 5. ECR에서 최신 이미지 pull
# ---------------------------------------------------------------------------
# --env-file 명시: compose의 .env 자동 탐색은 cwd에 좌우된다 — 탐색 실패 시 에러 없이
# :latest로 폴백되므로(태그 고정 무음 무력화) 경로를 항상 못박는다.
echo "==> 이미지 pull"
docker compose --env-file "$NEXT_COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" pull

# 운세 플래그를 켠 컨테이너가 뜨기 전에 DB 계약을 fail-closed로 확인한다. 일반 ready 체크는
# SELECT 1만 하므로 테이블·CHECK·필수 인덱스·migration checksum 누락을 잡지 못한다.
# 새 이미지의 asyncpg 환경을 사용하되 검증 코드는 infra에서 stdin으로 전달해 구 이미지 롤백도
# 동일한 DB gate를 통과할 수 있게 한다. 읽기 전용 트랜잭션이며 사용자 데이터는 출력하지 않는다.
BACKEND_IMAGE="$ECR_REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
FORTUNE_PREFLIGHT="$SCRIPT_DIR/scripts/verify_fortune_schema.py"
if [ ! -f "$FORTUNE_PREFLIGHT" ]; then
  echo "ERROR: 운세 DB preflight 스크립트 없음: $FORTUNE_PREFLIGHT" >&2
  exit 1
fi
echo "==> 운세 DB preflight"
docker run --rm -i --env-file "$NEXT_BACKEND_ENV_FILE" \
  --entrypoint python "$BACKEND_IMAGE" - < "$FORTUNE_PREFLIGHT"

# 모든 선행 검사가 끝난 뒤에만 live 파일을 원자적으로 교체한다. 여기부터 systemd worker와
# compose가 새 sha·기능 플래그를 함께 보며, preflight 실패 시에는 두 live 파일 모두 이전 값이다.
mv "$NEXT_BACKEND_ENV_FILE" "$SCRIPT_DIR/backend.env"
mv "$NEXT_COMPOSE_ENV_FILE" "$COMPOSE_ENV_FILE"

# ---------------------------------------------------------------------------
# 6. 컨테이너 기동/갱신
# ---------------------------------------------------------------------------
# --remove-orphans는 쓰지 않는다: 원래 목적(구 ai-voice/llm 스택 정리)은 완료됐고,
# compose 버전에 따라 실행 중인 `docker compose run worker` 틱 컨테이너를 orphan으로
# 오인해 죽일 수 있다 — 일기 생성 틱이 배포 타이밍에 잘리는 사고 방지.
echo "==> 컨테이너 기동"
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d

# 대화 후속 잡 consumer는 dev·prod 모두 상주 기동한다. 같은 sha 이미지와 backend.env를 쓰고,
# compose가 태그 변경을 감지해 배포마다 필요한 경우 재생성한다.
#
# 운영 EC2 두 대에서 동시에 떠도 같은 잡을 두 번 처리하지 않는다 — 잡을 집어갈 때
# `FOR UPDATE SKIP LOCKED`를 써서 한쪽이 잠근 행은 다른 쪽이 건너뛴다. 그래서 워커 틱과 달리
# 단일 호스트 마커(/etc/moly-worker-host)를 쓰지 않는다. 워커 틱은 대상 유저를 스스로 정해서
# 두 대가 같은 일을 하지만, consumer는 표에 적힌 행을 나눠 갖는다.
#
# 구 이미지 안전장치: 롤백으로 `worker.consumer`가 없는 이미지가 배포되면 컨테이너가 즉시 죽어
# 아래 배포 게이트가 막힌다 — 롤백 자체가 불가능해진다. 모듈이 없으면 consumer를 건너뛰고
# 배포는 계속한다. 구 이미지에는 애초에 이 잡들을 만드는 코드도 없다.
CONSUMER_IMAGE="$BACKEND_IMAGE"
CONSUMER_STARTED=0
echo "==> async job consumer 모듈 확인"
if docker run --rm --entrypoint python "$CONSUMER_IMAGE" \
     -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('worker.consumer') else 3)"; then
  # 모듈이 있으면 핸들러 등록까지 확인한다. registry가 비면 consumer는 살아서 모든 잡을
  # unknown으로 죽인다 — 조용히 도는 대신 여기서 배포를 세운다.
  echo "==> consumer 핸들러 등록 확인"
  docker run --rm --env-file "$SCRIPT_DIR/backend.env" \
    -e MOLY_CONSUMER_STARTUP_CHECK_ONLY=1 \
    -v "$FCM_FILE":/secrets/fcm-service-account.json:ro \
    --entrypoint python "$CONSUMER_IMAGE" -m worker.consumer

  echo "==> async job consumer 기동"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" \
    --profile consumer up -d consumer
  CONSUMER_STARTED=1
else
  consumer_rc=$?
  if [ "$consumer_rc" -eq 3 ]; then
    echo "WARN: 이 이미지에 worker.consumer가 없다(구 버전) — consumer 건너뜀." >&2
    echo "      대화 후속 잡(기억·일기 색인·약속·관계)이 처리되지 않는다." >&2
    # 새 이미지에서 뜬 consumer가 구 코드 배포 뒤에도 남아 도는 것을 막는다.
    docker rm -f moly-consumer >/dev/null 2>&1 || true
  else
    echo "ERROR: consumer 모듈 확인 실패 (exit=$consumer_rc) — 이미지 pull/실행 문제" >&2
    exit 1
  fi
fi

# 설정만 바뀐 서비스는 compose가 못 잡을 수 있으므로 해당 서비스만 강제 재생성한다.
if [ "${#RECREATE[@]}" -gt 0 ]; then
  echo "==> 설정 변경 감지: ${RECREATE[*]} 재생성"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d --force-recreate "${RECREATE[@]}"
fi

# 다음 배포 비교를 위해 새 지문 저장
printf '%s' "$new_backend_hash" > "$STATE_DIR/backend.hash"

# ---------------------------------------------------------------------------
# 6-b. 배포 헬스 게이트 — 컨테이너가 실제로 살아났는지 확인
# ---------------------------------------------------------------------------
# up -d는 "시작시켰다"까지만 보장한다. 크래시 루프(env 누락 등)여도 종료코드 0이라
# Actions가 초록불이 되는 사고 방지 — /health/ready 200을 확인할 때까지 배포 성공으로 안 친다.
# /health(liveness)가 아니라 /health/ready(DB SELECT 1)인 이유: DB 엔진은 lazy 생성이라
# 연결 문자열이 깨져도 부팅은 성공하고 /health는 200이다 — 그 상태로 배포가 초록불이 되면
# 모든 실제 API가 500인 채 방치된다. ready는 이 케이스를 게이트에서 잡는다.
echo "==> 헬스 게이트 (/health/ready 200 대기, 최대 60초)"
healthy=0
for i in $(seq 1 12); do
  sleep 5
  if curl -sf --max-time 5 http://127.0.0.1:8000/health/ready >/dev/null 2>&1; then
    healthy=1
    echo "  - health ready OK (${i}번째 시도)"
    break
  fi
done
if [ "$healthy" -ne 1 ]; then
  echo "ERROR: /health/ready 200 아님 — 컨테이너 상태/로그:" >&2
  docker ps --filter name=moly-backend >&2
  docker logs --tail 50 moly-backend >&2 || true
  exit 1
fi

# 실제 뜬 이미지가 요청한 태그인지 검증 — .env 폴백/탐색 실패가 조용히 :latest를
# 띄우는 사고를 여기서 잡는다.
RUNNING_IMAGE="$(docker inspect --format '{{.Config.Image}}' moly-backend)"
EXPECTED_TAG="$(grep '^IMAGE_TAG=' "$COMPOSE_ENV_FILE" | cut -d= -f2)"
case "$RUNNING_IMAGE" in
  *:"$EXPECTED_TAG") echo "  - 이미지 태그 일치: $RUNNING_IMAGE" ;;
  *) echo "ERROR: 기대 태그 '$EXPECTED_TAG', 실제 '$RUNNING_IMAGE'" >&2; exit 1 ;;
esac

# 기동을 건너뛴 경우(구 이미지)에는 검사하지 않는다 — 위에서 이미 경고했고, 여기서 막으면
# 롤백 배포가 실패한다.
if [ "$CONSUMER_STARTED" -eq 1 ]; then
  CONSUMER_STATE="$(docker inspect --format '{{.State.Status}}' moly-consumer 2>/dev/null || true)"
  if [ "$CONSUMER_STATE" != "running" ]; then
    echo "ERROR: async job consumer가 running이 아님 (state=${CONSUMER_STATE:-missing})" >&2
    docker logs --tail 50 moly-consumer >&2 || true
    exit 1
  fi
  echo "  - async job consumer running"
fi

# ALB 경로(nginx :8080 → 8000) 확인 — nginx 블록은 수동 반영이라 여기가 유일한
# 드리프트 감지 지점. 심링크 누락/reload 실패를 register 전에 즉시 잡는다.
if ! curl -sf --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1; then
  echo "ERROR: nginx :8080 → backend 경로 실패 — sites-enabled/alb-8080 확인" >&2
  exit 1
fi
echo "  - nginx :8080 경로 OK"

# ---------------------------------------------------------------------------
# 7. 배치 워커 systemd 유닛 설치/갱신 (15분마다 1틱 — :00/:15/:30/:45)
# ---------------------------------------------------------------------------
# 워커는 단일 호스트에서만 돈다 — /etc/moly-worker-host 마커가 있는 인스턴스(#1)만.
# 두 호스트에서 동시 실행되면 틱마다 2번 돌아 LLM 일기 생성 비용 2배 + 허위 실패 알림.
# 마커는 호스트 재구축(AMI 복원 등) 시 수동 재생성 필요: sudo touch /etc/moly-worker-host
# 워커 호스트를 옮길 때: 기존 마커 삭제 → 새 호스트 마커 생성 → 양쪽 재배포.
WORKER_HOST_MARKER="/etc/moly-worker-host"
if [ -f "$WORKER_HOST_MARKER" ]; then
  echo "==> 워커 호스트 — systemd 유닛 확인"
  units_changed=0
  for unit in moly-worker.service moly-worker.timer; do
    src="$SCRIPT_DIR/systemd/$unit"
    dst="/etc/systemd/system/$unit"
    if [ ! -f "$src" ]; then
      echo "ERROR: 유닛 원본 없음: $src" >&2
      exit 1
    fi
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
      install -m 644 "$src" "$dst"
      units_changed=1
      echo "  - $unit 설치/갱신"
    fi
  done
  if [ "$units_changed" -eq 1 ]; then
    systemctl daemon-reload
  fi
  # enable --now 는 멱등 — 이미 활성화돼 있으면 no-op (실패 시 stderr 그대로 노출)
  systemctl enable --now moly-worker.timer >/dev/null
  echo "  - moly-worker.timer 활성 ($(systemctl is-active moly-worker.timer))"
else
  echo "==> 워커 호스트 아님 — 타이머 비활성 보장"
  systemctl disable --now moly-worker.timer >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 8. dangling/오래된 이미지 정리
# ---------------------------------------------------------------------------
# sha 태그 고정 후엔 과거 이미지가 태그를 달고 영구 잔존한다(prune -f는 dangling 전용이라
# 아무것도 못 지움) — 방치하면 배포 10~15회에 디스크 풀. 최근 3개만 남기고 제거한다.
echo "==> 오래된 이미지 정리 (${IMAGE_REPO} 최근 3개 유지)"
docker image prune -f
# 레포 경계는 콜론 포함 매칭("/repo:")으로 — dev 호스트에서 /moly-backend: 패턴을 쓰면
# moly-backend-dev: 이미지가 안 걸려 영구 잔존, 배포 누적으로 디스크 풀이 난다.
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' \
  | grep "/${IMAGE_REPO}:" | grep -v ':latest' | sort -t"$(printf '\t')" -k2 -r \
  | tail -n +4 | cut -f1 | xargs -r docker rmi >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 9. 상태 출력
# ---------------------------------------------------------------------------
echo "==> 현재 상태"
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" ps

echo "==> moly-backend 배포 완료"
