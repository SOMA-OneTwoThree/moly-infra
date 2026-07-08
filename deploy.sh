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
SSM_PATH="/moly/prod/"
SECRETS_DIR="$SCRIPT_DIR/secrets"
FCM_FILE="$SECRETS_DIR/fcm-service-account.json"

echo "==> moly-backend 배포 시작 (region=$REGION, account=$ACCOUNT_ID)"

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

# ---------------------------------------------------------------------------
# 2. ECR 로그인 (인스턴스 역할 사용 — 키 불필요)
# ---------------------------------------------------------------------------
echo "==> ECR 로그인"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

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
  supabase-anon-key
  supabase-service-role-key
)
missing=()
for k in "${required_keys[@]}"; do
  if [ -z "${PARAMS[$k]+x}" ]; then
    missing+=("${SSM_PATH}${k}")
  fi
done
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
# FCM_PROJECT_ID/FCM 파일은 옵션: 없으면 backend가 푸시만 조용히 스킵한다.
cat > "$SCRIPT_DIR/backend.env" <<EOF
ENVIRONMENT=production
APP_STORE_BUNDLE_ID=com.geniusjun.moly
APP_STORE_ENVIRONMENT=Production
APP_STORE_APP_APPLE_ID=6784125709
SUPABASE_URL=${PARAMS[supabase-url]}
SUPABASE_ANON_KEY=${PARAMS[supabase-anon-key]}
SUPABASE_SERVICE_ROLE_KEY=${PARAMS[supabase-service-role-key]}
SUPABASE_DB_CONNECTION_STRING=${PARAMS[supabase-db-connection-string]}
ANTHROPIC_API_KEY=${PARAMS[anthropic-api-key]}
OPENAI_API_KEY=${PARAMS[openai-api-key]}
FCM_PROJECT_ID=${PARAMS[fcm-project-id]:-}
FCM_SERVICE_ACCOUNT_FILE=/secrets/fcm-service-account.json
EOF
chmod 600 "$SCRIPT_DIR/backend.env"

# FCM 서비스 계정 JSON — SSM SecureString(여러 줄) → 파일.
# 컨테이너는 비루트(appuser)로 돌아 파일에 other-read가 필요하다.
# 대신 secrets/ 디렉토리를 700으로 잠가 호스트의 비루트 접근을 막는다.
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -n "${PARAMS[fcm-service-account]+x}" ] && [ -n "${PARAMS[fcm-service-account]}" ]; then
  printf '%s' "${PARAMS[fcm-service-account]}" > "$FCM_FILE"
else
  echo "WARN: /moly/prod/fcm-service-account 미설정 — FCM 푸시 비활성 (빈 파일로 대체)" >&2
  : > "$FCM_FILE"
fi
chmod 644 "$FCM_FILE"

# ---------------------------------------------------------------------------
# 4-b. 설정 지문 계산 (설정 변경 감지용)
# ---------------------------------------------------------------------------
# env/FCM 파일이 바뀌면 backend 컨테이너를 강제 재생성한다.
# (이미지 콘텐츠 변경은 pull + up -d 가 자연 처리하므로 지문에 포함하지 않는다.)
# 시크릿 값은 해시로만 다루고 출력하지 않는다.
STATE_DIR="$SCRIPT_DIR/.deploy-state"
mkdir -p "$STATE_DIR"

new_backend_hash="$(cat "$SCRIPT_DIR/backend.env" "$FCM_FILE" | sha256sum | awk '{print $1}')"
old_backend_hash="$(cat "$STATE_DIR/backend.hash" 2>/dev/null || true)"

RECREATE=()
if [ "$new_backend_hash" != "$old_backend_hash" ]; then RECREATE+=("backend"); fi

# ---------------------------------------------------------------------------
# 5. ECR에서 최신 이미지 pull
# ---------------------------------------------------------------------------
echo "==> 이미지 pull"
docker compose -f "$COMPOSE_FILE" pull

# ---------------------------------------------------------------------------
# 6. 컨테이너 기동/갱신
# ---------------------------------------------------------------------------
# --remove-orphans: 구 스택(ai-voice, llm) 등 compose 파일에서 사라진 서비스의
# 컨테이너를 자동 제거한다 (voice → backend 전환 컷오버 포함).
echo "==> 컨테이너 기동"
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

# 설정만 바뀐 서비스는 compose가 못 잡을 수 있으므로 해당 서비스만 강제 재생성한다.
if [ "${#RECREATE[@]}" -gt 0 ]; then
  echo "==> 설정 변경 감지: ${RECREATE[*]} 재생성"
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${RECREATE[@]}"
fi

# 다음 배포 비교를 위해 새 지문 저장
printf '%s' "$new_backend_hash" > "$STATE_DIR/backend.hash"

# ---------------------------------------------------------------------------
# 6-b. 배포 헬스 게이트 — 컨테이너가 실제로 살아났는지 확인
# ---------------------------------------------------------------------------
# up -d는 "시작시켰다"까지만 보장한다. 크래시 루프(env 누락 등)여도 종료코드 0이라
# Actions가 초록불이 되는 사고 방지 — /health 200을 확인할 때까지 배포 성공으로 안 친다.
echo "==> 헬스 게이트 (/health 200 대기, 최대 60초)"
healthy=0
for i in $(seq 1 12); do
  sleep 5
  if curl -sf --max-time 3 http://127.0.0.1:8000/health >/dev/null 2>&1; then
    healthy=1
    echo "  - health OK (${i}번째 시도)"
    break
  fi
done
if [ "$healthy" -ne 1 ]; then
  echo "ERROR: /health 응답 없음 — 컨테이너 상태/로그:" >&2
  docker ps --filter name=moly-backend >&2
  docker logs --tail 50 moly-backend >&2 || true
  exit 1
fi

# ---------------------------------------------------------------------------
# 7. 배치 워커 systemd 유닛 설치/갱신 (매시 정각 1틱)
# ---------------------------------------------------------------------------
echo "==> 워커 systemd 유닛 확인"
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

# ---------------------------------------------------------------------------
# 8. dangling/오래된 이미지 정리
# ---------------------------------------------------------------------------
echo "==> dangling 이미지 정리"
docker image prune -f

# ---------------------------------------------------------------------------
# 9. 상태 출력
# ---------------------------------------------------------------------------
echo "==> 현재 상태"
docker compose -f "$COMPOSE_FILE" ps

echo "==> moly-backend 배포 완료"
