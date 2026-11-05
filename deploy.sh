#
# deploy.sh: 서버 한 대에 moly-backend를 배포한다.
#
#   sudo bash deploy.sh <image-tag>
#   sudo env DEPLOY_PREFLIGHT_ONLY=1 bash deploy.sh <image-tag>   # 이미지 pull과 DB 검증만
#
# 시크릿은 SSM Parameter Store에서 읽어 env 파일로 만들고, 값은 출력하지 않는다.
# 워커 호스트에서는 배치 워커용 systemd 유닛도 함께 설치한다.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. 변수 정의
# ---------------------------------------------------------------------------
REGION="ap-northeast-2"
ACCOUNT_ID="676972757138"
ECR_REGISTRY="676972757138.dkr.ecr.ap-northeast-2.amazonaws.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# 환경은 /etc/moly-env로 구분한다. 파일이 없거나 내용이 prod면 prod, dev면 dev다.
# 개발 서버를 처음 설정할 때 한 번 만든다: echo dev | sudo tee /etc/moly-env
# 그 밖의 값은 엉뚱한 SSM 경로를 읽게 되므로 바로 실패시킨다. sudo touch로 만든 빈 파일도 마찬가지다.
if [ -e /etc/moly-env ]; then
  # 파일이 있는데 읽지 못하면 prod로 넘어가지 않고 멈춘다. dev 서버가 prod 시크릿을 읽는 일을 막는다.
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
NEXT_FCM_FILE="$STATE_DIR/fcm-service-account.json.next"

# 이미지 태그는 커밋 SHA로 고정해, 서버마다 pull 시점이 달라도 같은 이미지를 받게 한다.
# 인자 없이 실행하면 마지막으로 배포한 태그를 다시 쓴다. 수동 재배포가 :latest로 바뀌지 않게 하기 위해서다.
IMAGE_TAG="${1:-}"
COMPOSE_ENV_FILE="$SCRIPT_DIR/.env"
if [ -z "$IMAGE_TAG" ] && [ -f "$COMPOSE_ENV_FILE" ]; then
  IMAGE_TAG="$(sed -n 's/^IMAGE_TAG=//p' "$COMPOSE_ENV_FILE")"
fi
IMAGE_TAG="${IMAGE_TAG:-latest}"
echo "==> 배포 태그: IMAGE_TAG=$IMAGE_TAG"

# 사전점검 모드. 0과 1만 받는다. true 같은 값을 그냥 넘기면 사전점검 대신 전체 배포가 돌아
# ALB에 붙어 있는 서버의 컨테이너가 교체되므로, 아무것도 하기 전에 멈춘다.
# moly-backend의 deploy.yml이 줄 맨 앞의 `PREFLIGHT_ONLY=`로 이 모드가 있는지 확인한 뒤
# DEPLOY_PREFLIGHT_ONLY=1을 넘긴다. 아래 줄의 두 변수 이름이나 들여쓰기를 바꾸면 workflow도 함께 고쳐야 한다.
PREFLIGHT_ONLY="${DEPLOY_PREFLIGHT_ONLY:-0}"
case "$PREFLIGHT_ONLY" in
  0|1) ;;
  *) printf "ERROR: DEPLOY_PREFLIGHT_ONLY 값이 0|1 이 아닙니다: %q\n" "$PREFLIGHT_ONLY" >&2; exit 1 ;;
esac
if [ "$PREFLIGHT_ONLY" = "1" ]; then
  echo "==> 사전점검 전용 모드 — 이미지 pull·DB 계약 검증까지만 하고 live 파일·컨테이너는 바꾸지 않는다"
fi

echo "==> moly-backend 배포 시작 (region=$REGION, account=$ACCOUNT_ID, env=$ENV_NAME)"

# 필요한 명령 확인
for bin in docker aws jq curl python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: 필수 명령어 '$bin' 를 PATH에서 찾을 수 없습니다" >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' (v2) 를 사용할 수 없습니다" >&2
  exit 1
fi

# 디스크 사용률이 80%를 넘으면 시작하지 않는다. pull 도중 디스크가 가득 차면 컨테이너를 띄울 수 없다.
disk_usage="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "$disk_usage" -gt 80 ]; then
  echo "ERROR: 루트 디스크 사용률 ${disk_usage}% (>80%) — 정리 후 재배포하세요" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. ECR 로그인 (IAM 인스턴스 역할 사용)
# ---------------------------------------------------------------------------
echo "==> ECR 로그인"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# 새 태그는 DB 검증이 끝날 때까지 임시 파일에만 적는다. 검증이 실패했는데 live .env만 새 태그를
# 가리키면 다음 워커 틱이 API보다 먼저 새 이미지로 실행된다.
# IMAGE_REPO는 환경별 ECR 저장소다. compose 기본값이 prod 저장소라서 prod는 이 값이 없어도 같다.
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf 'IMAGE_TAG=%s\nIMAGE_REPO=%s\n' "$IMAGE_TAG" "$IMAGE_REPO" > "$NEXT_COMPOSE_ENV_FILE"

# ---------------------------------------------------------------------------
# 3. SSM Parameter Store 조회
# ---------------------------------------------------------------------------
echo "==> SSM에서 파라미터 조회 ($SSM_PATH)"
PARAMS_JSON="$(aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --recursive \
  --region "$REGION" \
  --output json)"

# 파라미터 이름의 마지막 부분을 키로 쓴다. FCM 서비스 계정처럼 여러 줄인 값이 있어서
# 줄바꿈을 이스케이프하는 @tsv 대신 jq -r로 하나씩 꺼낸다.
declare -A PARAMS=()
while IFS= read -r name; do
  [ -z "$name" ] && continue
  value="$(printf '%s' "$PARAMS_JSON" \
    | jq -r --arg n "$name" '.Parameters[] | select(.Name == $n) | .Value')"
  key="${name##*/}"
  PARAMS["$key"]="$value"
done < <(printf '%s' "$PARAMS_JSON" | jq -r '.Parameters[].Name')

# 필수 키 확인. 빠진 키는 이름만 출력한다.
required_keys=(
  anthropic-api-key
  openai-api-key
  supabase-db-connection-string
  supabase-url
  # Supabase 신형 API 키 (sb_publishable_, sb_secret_)
  supabase-publishable-key
  supabase-secret-key
  revenuecat-webhook-auth
)
# 운영에서는 운세 광고 단위 ID와 피드백 웹훅도 필수다. 피드백 웹훅이 비어 있으면 backend가
# 알림 채널로 대신 보내므로, 잘못 보내기 전에 배포를 멈춘다. dev는 둘 다 없어도 배포한다.
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
# 4. env 파일과 FCM 서비스 계정 파일 생성
# ---------------------------------------------------------------------------
# 선택 플래그는 true와 false만 받고, 없으면 false다. 잘못된 값이면 live 파일을 바꾸기 전에 멈춘다.
MORNING_PUSH_ENABLED="${PARAMS[morning-push-enabled]:-false}"
case "$MORNING_PUSH_ENABLED" in
  true|false) ;;
  *) echo "ERROR: morning-push-enabled must be true or false" >&2; exit 1 ;;
esac
# FCM이 UNREGISTERED로 판정한 토큰을 비활성 처리할지 정한다. false면 로그만 남긴다.
FCM_INVALIDATE_DEAD_TOKENS="${PARAMS[fcm-invalidate-dead-tokens]:-false}"
case "$FCM_INVALIDATE_DEAD_TOKENS" in
  true|false) ;;
  *) echo "ERROR: fcm-invalidate-dead-tokens must be true or false" >&2; exit 1 ;;
esac

echo "==> env 파일 작성"
umask 077
# Optional for pre-encryption images. A capable candidate's checker below
# requires a valid keyring even before first adoption. Never echo its value.
CRYPTO_FLOOR="$SCRIPT_DIR/scripts/verify_chat_content_floor.py"
CHAT_CONTENT_ENCRYPTION_KEYS="${PARAMS[chat-content-keyring]:-}"
if [ -n "$CHAT_CONTENT_ENCRYPTION_KEYS" ]; then
  if ! CHAT_CONTENT_ENCRYPTION_KEYS="$(printf '%s' "$CHAT_CONTENT_ENCRYPTION_KEYS" \
      | python3 "$CRYPTO_FLOOR" --normalize-keyring --environment "$APP_ENV" 2>/dev/null)"; then
    echo "ERROR: chat_content_keyring_invalid" >&2
    exit 1
  fi
fi

# backend.env에는 여기 적은 키만 들어간다. SSM에 값을 추가해도 이 목록에 없으면 컨테이너에 전달되지 않는다.
# 기본값이 빈 키(:-)는 없어도 배포가 계속되는 선택 설정이다. 운세 광고 단위 ID와 피드백 웹훅은
# 운영에서는 필수라서 위에서 이미 확인했다.
# 대화 기능과 운세 플래그는 모든 환경에서 켠다. 아침 푸시와 FCM 토큰 정리는 위에서 읽은 SSM 값을 따른다.
cat > "$NEXT_BACKEND_ENV_FILE" <<EOF
ENVIRONMENT=${APP_ENV}
CHAT_CONTENT_ENCRYPTION_KEYS=${CHAT_CONTENT_ENCRYPTION_KEYS}
REVENUECAT_WEBHOOK_AUTH=${PARAMS[revenuecat-webhook-auth]}
REVENUECAT_API_V2_KEY=${PARAMS[revenuecat-api-v2-key]:-}
REVENUECAT_PROJECT_ID=${PARAMS[revenuecat-project-id]:-}
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
MORNING_PUSH_ENABLED=${MORNING_PUSH_ENABLED}
FCM_INVALIDATE_DEAD_TOKENS=${FCM_INVALIDATE_DEAD_TOKENS}
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

# dev에만 들어가는 설정. 위험한 개발용 라우트를 열고, dev DB의 검증용 운영자 계정을 지정한다.
if [ "$ENV_NAME" = "dev" ]; then
  cat >> "$NEXT_BACKEND_ENV_FILE" <<EOF
ENABLE_DEV_ROUTES=true
DEV_OPERATOR_USER_IDS=445bdde0-025b-403a-bab8-7816827016c3
EOF
fi
chmod 600 "$NEXT_BACKEND_ENV_FILE"

# FCM 서비스 계정 JSON은 여러 줄이라 env가 아닌 파일로 전달한다.
# 컨테이너가 비루트 사용자로 실행돼 파일 자체는 누구나 읽을 수 있어야 하므로,
# 대신 secrets/ 디렉터리를 700으로 막아 호스트의 다른 사용자가 접근하지 못하게 한다.
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -n "${PARAMS[fcm-service-account]+x}" ] && [ -n "${PARAMS[fcm-service-account]}" ]; then
  printf '%s' "${PARAMS[fcm-service-account]}" > "$NEXT_FCM_FILE"
else
  echo "WARN: ${SSM_PATH}fcm-service-account 미설정 — FCM 푸시 비활성 (빈 파일로 대체)" >&2
  : > "$NEXT_FCM_FILE"
fi
chmod 600 "$NEXT_FCM_FILE"

# ---------------------------------------------------------------------------
# 4-b. 설정 변경 감지
# ---------------------------------------------------------------------------
# env나 FCM 파일 내용이 바뀌면 backend 컨테이너를 다시 만든다. 이미지가 바뀐 경우는 compose가 처리한다.
# 시크릿은 해시로만 비교한다.
new_backend_hash="$(cat "$NEXT_BACKEND_ENV_FILE" "$NEXT_FCM_FILE" | sha256sum | awk '{print $1}')"
old_backend_hash="$(cat "$STATE_DIR/backend.hash" 2>/dev/null || true)"

RECREATE=()
if [ "$new_backend_hash" != "$old_backend_hash" ]; then RECREATE+=("backend"); fi

# ---------------------------------------------------------------------------
# 5. 이미지 pull과 DB 스키마 검증
# ---------------------------------------------------------------------------
# --env-file을 항상 지정한다. compose의 .env 자동 탐색은 현재 디렉터리에 따라 달라지고,
# 찾지 못하면 오류 없이 :latest를 쓴다.
echo "==> 이미지 pull"
docker compose --env-file "$NEXT_COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" pull

# 새 컨테이너를 띄우기 전에, 이미지가 기대하는 스키마와 실제 DB가 맞는지 확인한다.
# /health/ready는 SELECT 1만 하므로 테이블, 제약 조건, 인덱스가 빠진 것은 여기서 잡아야 한다.
# 새 이미지는 자체 검사(db.schema_contract)를 쓰고, 이 모듈이 없는 예전 이미지로 롤백할 때는
# scripts/verify_fortune_schema.py를 대신 실행한다. 둘 다 읽기 전용 트랜잭션이다.
BACKEND_IMAGE="$ECR_REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
FORTUNE_PREFLIGHT="$SCRIPT_DIR/scripts/verify_fortune_schema.py"
if [ ! -f "$FORTUNE_PREFLIGHT" ]; then
  echo "ERROR: 운세 DB preflight 스크립트 없음: $FORTUNE_PREFLIGHT" >&2
  exit 1
fi
echo "==> DB schema preflight"
if docker run --rm --entrypoint python "$BACKEND_IMAGE" \
    -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('db') and importlib.util.find_spec('db.schema_contract') else 3)"; then
  docker run --rm --env-file "$NEXT_BACKEND_ENV_FILE" \
    --entrypoint python "$BACKEND_IMAGE" -m db.schema_contract
else
  schema_probe_rc=$?
  if [ "$schema_probe_rc" -ne 3 ]; then
    echo "ERROR: DB schema verifier probe failed (exit=$schema_probe_rc)" >&2
    exit 1
  fi
  # 예전 이미지: 당시 운세 기능의 테이블 구조와 권한만 확인한다.
  docker run --rm -i --env-file "$NEXT_BACKEND_ENV_FILE" \
    --entrypoint python "$BACKEND_IMAGE" - < "$FORTUNE_PREFLIGHT"
fi

# Fixed infra source reads only the policy row, so an old rollback image
# cannot bypass the encryption floor via its legacy schema/consumer fallbacks.
CRYPTO_FLOOR="$SCRIPT_DIR/scripts/verify_chat_content_floor.py"
CRYPTO_SUPPORTED=0
if [ ! -f "$CRYPTO_FLOOR" ]; then
  echo "ERROR: chat content downgrade checker missing" >&2; exit 1
fi
if ! crypto_floor="$(docker run --rm -i --env-file "$NEXT_BACKEND_ENV_FILE" \
    --entrypoint python "$BACKEND_IMAGE" - < "$CRYPTO_FLOOR" 2>/dev/null)"; then
  echo "ERROR: chat content encryption downgrade floor rejected candidate" >&2; exit 1
fi
if ! CRYPTO_SUPPORTED="$(printf '%s' "$crypto_floor" | python3 -c 'import json,sys;v=json.load(sys.stdin);assert set(v)=={"supported","started","state_present"};assert all(type(x)is bool for x in v.values());print(int(v["supported"]))' 2>/dev/null)"; then
  echo "ERROR: chat content encryption floor result invalid" >&2; exit 1
fi
if [ "$CRYPTO_SUPPORTED" = 1 ]; then
  # The backend checker is read-only and self-tests local crypto. Its stdout
  # contains key fingerprints, so keep it private and never feed it to SSM logs.
  crypto_proof="$STATE_DIR/chat-content-proof.next.json"
  if ! docker run --rm --env-file "$NEXT_BACKEND_ENV_FILE" --entrypoint python "$BACKEND_IMAGE" \
      scripts/check_chat_content_crypto.py --environment "$APP_ENV" \
      --expected-sha "${IMAGE_TAG#dev-}" > "$crypto_proof" 2>/dev/null; then
    echo "ERROR: chat content crypto key/capability preflight failed" >&2; exit 1
  fi
  chmod 600 "$crypto_proof"
  if ! python3 "$CRYPTO_FLOOR" --proof "$crypto_proof" --environment "$APP_ENV" \
      --expected-sha "${IMAGE_TAG#dev-}" >/dev/null 2>&1; then
    echo "ERROR: chat content crypto candidate proof invalid" >&2; exit 1
  fi
  echo "==> chat content crypto candidate preflight OK"
fi

# 사전점검 모드는 여기서 끝낸다. prod workflow는 서버를 ALB에서 빼기 전에 모든 서버에서 이 단계를
# 먼저 실행하므로, 검증이 실패해도 서비스에는 영향이 없다.
# 임시 파일만 지우고 live 파일, 컨테이너, 워커 타이머는 그대로 둔다.
if [ "$PREFLIGHT_ONLY" = "1" ]; then
  rm -f "$NEXT_FCM_FILE" "$NEXT_BACKEND_ENV_FILE" "$NEXT_COMPOSE_ENV_FILE"
  echo "==> preflight-only 통과: 이미지 pull·DB 계약 검증 OK — live 파일·컨테이너 미변경"
  exit 0
fi

# Pause scheduling before replacing live env, but let the current tick finish
# in parallel with API/consumer rolling. Do not stop/kill the service/container.
CRYPTO_TIMER_PAUSED=0
CRYPTO_TIMER_WAS_ACTIVE=0
CRYPTO_DRAIN_STARTED=$SECONDS
crypto_restore_timer() {
  local result=$?
  if [ "$CRYPTO_TIMER_PAUSED" = 1 ] && [ "$CRYPTO_TIMER_WAS_ACTIVE" = 1 ]; then
    if ! systemctl start moly-worker.timer >/dev/null 2>&1; then
      echo "ERROR: chat content drain timer restore failed" >&2
      result=1
    fi
  fi
  return "$result"
}
if [ "$CRYPTO_SUPPORTED" = 1 ]; then
  timer_before="$(systemctl is-active moly-worker.timer 2>/dev/null || true)"
  CRYPTO_TIMER_PAUSED=1
  trap crypto_restore_timer EXIT
  case "$timer_before" in
    active) CRYPTO_TIMER_WAS_ACTIVE=1; systemctl stop moly-worker.timer >/dev/null ;;
    inactive|failed|unknown) ;;
    *) echo "ERROR: chat content timer state unavailable" >&2; exit 1 ;;
  esac
fi

# 여기서부터 live 파일을 바꾼다. 이후 단계에서 실패해도 자동으로 되돌리지 않으므로, 이전 SHA로 다시 배포해 복구한다.
# FCM 파일은 기존 파일에 덮어써서 inode를 유지한다. bind mount가 같은 inode를 보므로
# 실행 중인 consumer도 새 내용을 읽는다.
cp "$NEXT_FCM_FILE" "$FCM_FILE"
chmod 644 "$FCM_FILE"
rm -f "$NEXT_FCM_FILE"

# env 파일은 mv로 한 번에 교체한다. 워커 타이머가 언제든 이 파일을 읽을 수 있어서
# 반쯤 쓰인 파일이 보이면 안 된다.
mv "$NEXT_BACKEND_ENV_FILE" "$SCRIPT_DIR/backend.env"
mv "$NEXT_COMPOSE_ENV_FILE" "$COMPOSE_ENV_FILE"

# ---------------------------------------------------------------------------
# 6. 컨테이너 기동
# ---------------------------------------------------------------------------
# --remove-orphans는 쓰지 않는다. compose 버전에 따라 실행 중인 워커 틱 컨테이너
# (docker compose run worker)를 orphan으로 보고 종료할 수 있다.
echo "==> 컨테이너 기동"
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d

# consumer는 작업을 FOR UPDATE SKIP LOCKED로 나눠 가져가므로 워커와 달리 모든 서버에서 실행한다.
#
# 예전 이미지에는 worker.consumer 모듈이 없어서 그대로 띄우면 consumer가 바로 죽고 롤백이 실패한다.
# 그런 이미지에서는 consumer만 건너뛰고 배포를 계속한다.
CONSUMER_IMAGE="$BACKEND_IMAGE"
CONSUMER_STARTED=0
echo "==> async job consumer 모듈 확인"
if docker run --rm --entrypoint python "$CONSUMER_IMAGE" \
     -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('worker.consumer') else 3)"; then
  # 등록된 핸들러가 없으면 consumer는 떠 있어도 모든 작업을 실패 처리한다. 기동 전에 확인한다.
  echo "==> consumer 핸들러 등록 확인"
  docker run --rm --env-file "$SCRIPT_DIR/backend.env" \
    -e MOLY_CONSUMER_STARTUP_CHECK_ONLY=1 \
    -v "$FCM_FILE":/secrets/fcm-service-account.json:ro \
    --entrypoint python "$CONSUMER_IMAGE" -m worker.consumer

  echo "==> async job consumer 기동"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" \
    --profile consumer up -d consumer
  CONSUMER_STARTED=1
  if [ "$CRYPTO_SUPPORTED" = 1 ] && [ "$new_backend_hash" != "$old_backend_hash" ]; then
    RECREATE+=("consumer")
  fi
else
  consumer_rc=$?
  if [ "$consumer_rc" -eq 3 ]; then
    echo "WARN: 이 이미지에 worker.consumer가 없다(구 버전) — consumer 건너뜀." >&2
    echo "      대화 후속 잡(기억·일기 색인·약속·관계)이 처리되지 않는다." >&2
    # 새 이미지로 떠 있던 consumer가 예전 코드 배포 뒤에도 남아 있지 않게 지운다.
    docker rm -f moly-consumer >/dev/null 2>&1 || true
  else
    echo "ERROR: consumer 모듈 확인 실패 (exit=$consumer_rc) — 이미지 pull/실행 문제" >&2
    exit 1
  fi
fi

# 설정만 바뀐 경우 compose가 변경을 감지하지 못할 수 있어 해당 서비스를 강제로 다시 만든다.
if [ "${#RECREATE[@]}" -gt 0 ]; then
  echo "==> 설정 변경 감지: ${RECREATE[*]} 재생성"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d --force-recreate "${RECREATE[@]}"
fi

# 다음 배포에서 비교할 설정 해시를 저장한다.
printf '%s' "$new_backend_hash" > "$STATE_DIR/backend.hash"

# ---------------------------------------------------------------------------
# 6-b. 배포 확인
# ---------------------------------------------------------------------------
# up -d는 컨테이너를 시작시키기만 해서 크래시 루프여도 성공으로 끝난다.
# /health는 DB 연결이 깨져도 200을 주므로 DB까지 확인하는 /health/ready를 기준으로 삼는다.
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

# 실제로 뜬 이미지가 요청한 태그인지 확인한다. .env를 읽지 못해 :latest로 뜬 경우를 잡는다.
RUNNING_IMAGE="$(docker inspect --format '{{.Config.Image}}' moly-backend)"
EXPECTED_TAG="$(grep '^IMAGE_TAG=' "$COMPOSE_ENV_FILE" | cut -d= -f2)"
case "$RUNNING_IMAGE" in
  *:"$EXPECTED_TAG") echo "  - 이미지 태그 일치: $RUNNING_IMAGE" ;;
  *) echo "ERROR: 기대 태그 '$EXPECTED_TAG', 실제 '$RUNNING_IMAGE'" >&2; exit 1 ;;
esac

# consumer를 건너뛴 경우(예전 이미지)는 확인하지 않는다. 여기서 막으면 롤백이 실패한다.
if [ "$CONSUMER_STARTED" -eq 1 ]; then
  CONSUMER_STATE="$(docker inspect --format '{{.State.Status}}' moly-consumer 2>/dev/null || true)"
  if [ "$CONSUMER_STATE" != "running" ]; then
    echo "ERROR: async job consumer가 running이 아님 (state=${CONSUMER_STATE:-missing})" >&2
    docker logs --tail 50 moly-consumer >&2 || true
    exit 1
  fi
  echo "  - async job consumer running"
fi

if [ "$CRYPTO_SUPPORTED" = 1 ]; then
  for crypto_role in moly-backend moly-consumer; do
    runtime_proof="$STATE_DIR/chat-content-${crypto_role}.json"
    if ! docker exec "$crypto_role" python scripts/check_chat_content_crypto.py \
        --environment "$APP_ENV" --expected-sha "${IMAGE_TAG#dev-}" > "$runtime_proof" 2>/dev/null; then
      echo "ERROR: chat content runtime capability check failed" >&2; exit 1
    fi
    chmod 600 "$runtime_proof"
    if ! python3 "$CRYPTO_FLOOR" --proof "$runtime_proof" --reference "$crypto_proof" \
        --environment "$APP_ENV" --expected-sha "${IMAGE_TAG#dev-}" >/dev/null 2>&1; then
      echo "ERROR: chat content runtime key/policy mismatch" >&2; exit 1
    fi
  done
  echo "==> chat content API/consumer capability verified"
fi

# ALB가 쓰는 경로(nginx :8080 → :8000)도 확인한다. nginx 설정은 이 스크립트가 관리하지 않으므로
# 설정이 빠졌거나 reload에 실패한 것을 ALB에 다시 등록하기 전에 여기서 잡는다.
if ! curl -sf --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1; then
  echo "ERROR: nginx :8080 → backend 경로 실패 — sites-enabled/alb-8080 확인" >&2
  exit 1
fi
echo "  - nginx :8080 경로 OK"

if [ "$CRYPTO_SUPPORTED" = 1 ]; then
  while true; do
    # A timed-out systemd compose client can leave an orphan worker. Both
    # actual containers and the still-starting service must be quiescent.
    if ! old_ticks="$(docker ps --filter label=com.docker.compose.service=worker --format '{{.ID}}' 2>/dev/null)"; then
      echo "ERROR: chat content old worker inventory unavailable" >&2; exit 1
    fi
    tick_service="$(systemctl is-active moly-worker.service 2>/dev/null || true)"
    case "$tick_service" in
      inactive|failed|unknown) service_idle=1 ;;
      active|activating|deactivating) service_idle=0 ;;
      *) echo "ERROR: chat content worker service state unknown" >&2; exit 1 ;;
    esac
    if [ -z "$old_ticks" ] && [ "$service_idle" = 1 ]; then break; fi
    if [ "$((SECONDS - CRYPTO_DRAIN_STARTED))" -ge 900 ]; then
      echo "ERROR: chat content old worker graceful drain timed out" >&2; exit 1
    fi
    sleep 2
  done
  echo "==> chat content old worker drain complete"
fi

# ---------------------------------------------------------------------------
# 7. 배치 워커 systemd 유닛 (15분마다 1회 실행)
# ---------------------------------------------------------------------------
# 워커는 /etc/moly-worker-host 파일이 있는 워커 호스트 한 대에서만 돈다. 두 대에서 돌면 틱마다
# 같은 작업이 두 번 실행돼 LLM 비용이 두 배가 되고 실패 알림도 잘못 울린다.
# 워커 호스트를 다시 만들면(AMI 복원 등) 마커도 다시 만든다: sudo touch /etc/moly-worker-host
# 워커 호스트를 옮길 때는 기존 호스트의 마커를 지우고 배포해 타이머를 끈 다음, 새 호스트에 마커를 만들고 배포한다.
WORKER_HOST_MARKER="/etc/moly-worker-host"
if [ -f "$WORKER_HOST_MARKER" ]; then
  echo "==> 워커 호스트 — systemd 유닛 확인"
  units_changed=0
  # moly-worker-failed.service는 틱이 실패하면 OnFailure=로 실행되므로 enable하지 않는다.
  for unit in moly-worker.service moly-worker.timer moly-worker-failed.service; do
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
  # 이미 켜져 있으면 아무것도 바뀌지 않는다. 오류는 보이도록 표준 출력만 버린다.
  systemctl enable --now moly-worker.timer >/dev/null
  echo "  - moly-worker.timer 활성 ($(systemctl is-active moly-worker.timer))"
else
  echo "==> 워커 호스트 아님 — 타이머 비활성 보장"
  systemctl disable --now moly-worker.timer >/dev/null 2>&1 || true
fi

# Timer is now restored according to the existing legitimate worker-host
# policy. The caller still performs fleet checks before any DB activation.
if [ "$CRYPTO_SUPPORTED" = 1 ]; then
  CRYPTO_TIMER_PAUSED=0
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# 8. 오래된 이미지 정리
# ---------------------------------------------------------------------------
# 태그가 붙은 이미지는 prune으로 지워지지 않아 배포할수록 쌓인다. 최근 3개만 남긴다.
echo "==> 오래된 이미지 정리 (${IMAGE_REPO} 최근 3개 유지)"
docker image prune -f
# 저장소 이름을 콜론까지 붙여 찾는다. 그래야 moly-backend와 moly-backend-dev가 섞이지 않는다.
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' \
  | grep "/${IMAGE_REPO}:" | grep -v ':latest' | sort -t"$(printf '\t')" -k2 -r \
  | tail -n +4 | cut -f1 | xargs -r docker rmi >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 9. 상태 출력
# ---------------------------------------------------------------------------
echo "==> 현재 상태"
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" ps

echo "==> moly-backend 배포 완료"
