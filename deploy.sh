#
# deploy.sh — 최신 ECR 이미지를 받아 moly 스택을 EC2에서 (재)기동한다.
#
#
# 시크릿은 런타임에 SSM Parameter Store에서 읽어 .env 파일(chmod 600, git 제외)로
# 생성한다. 시크릿 값은 절대 출력/로그에 노출하지 않는다.

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

echo "==> moly 배포 시작 (region=$REGION, account=$ACCOUNT_ID)"

# 의존성 확인
for bin in docker aws jq; do
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
# 값은 jq -r 로 하나씩 추출해 실제 줄바꿈(SYSTEM_PROMPT)을 보존한다.
# @tsv는 줄바꿈을 이스케이프하므로 사용하지 않는다.
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
  deepgram-api-key
  elevenlabs-api-key
  groq-api-key
  anthropic-api-key
  openai-api-key
  supabase-db-connection-string
  system-prompt
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
# 4. .env 파일 생성 (chmod 600) + 여러 줄 SYSTEM_PROMPT export
# ---------------------------------------------------------------------------
echo "==> env 파일 작성"
umask 077

# ai-voice.env — 한 줄 값만
cat > "$SCRIPT_DIR/ai-voice.env" <<EOF
DEEPGRAM_API_KEY=${PARAMS[deepgram-api-key]}
ELEVENLABS_API_KEY=${PARAMS[elevenlabs-api-key]}
ELEVENLABS_VOICE_ID=cgSgspJ2msm6clMCkdW9
SERVER_URL=https://moly-server.vercel.app
EOF
chmod 600 "$SCRIPT_DIR/ai-voice.env"

# llm.env — 한 줄 값만.
# SYSTEM_PROMPT은 줄바꿈 / '#' / 따옴표를 포함할 수 있어 env_file로 안전하게
# 표현할 수 없으므로 여기에 넣지 않는다. 아래에서 export한 셸 변수를 compose의
# `environment: - SYSTEM_PROMPT` 로 주입한다.
cat > "$SCRIPT_DIR/llm.env" <<EOF
GROQ_API_KEY=${PARAMS[groq-api-key]}
ANTHROPIC_API_KEY=${PARAMS[anthropic-api-key]}
OPENAI_API_KEY=${PARAMS[openai-api-key]}
SUPABASE_DB_CONNECTION_STRING=${PARAMS[supabase-db-connection-string]}
APP_NAME=moly-llm
ENVIRONMENT=production
LLM_PROVIDER=anthropic
LLM_MODEL=claude-sonnet-4-6
MEMORY_TOP_K=5
MEMORY_CACHE_TTL_SECONDS=300
MEMORY_SAVE_EVERY_N_TURNS=5
EMBEDDER_PROVIDER=openai
EMBEDDER_MODEL=text-embedding-3-small
MEMORY_LLM_MODEL=gpt-4.1-mini
EOF
chmod 600 "$SCRIPT_DIR/llm.env"

# 여러 줄 값을 그대로 export하여 compose로 전달 (줄바꿈 보존)
export SYSTEM_PROMPT="${PARAMS[system-prompt]}"

# ---------------------------------------------------------------------------
# 4-b. 서비스별 설정 지문 계산 (설정 변경 감지용)
# ---------------------------------------------------------------------------
# compose의 config-hash가 environment 패스스루(SYSTEM_PROMPT) 값 변경을 항상
# 감지하지는 못하므로, 우리가 직접 서비스별 설정 해시를 계산해 변경 여부를 판단한다.
# (이미지 콘텐츠 변경은 pull + up -d 가 자연 처리하므로 지문에 포함하지 않는다.)
# 시크릿 값은 해시로만 다루고 출력하지 않는다.
STATE_DIR="$SCRIPT_DIR/.deploy-state"
mkdir -p "$STATE_DIR"

new_voice_hash="$(sha256sum "$SCRIPT_DIR/ai-voice.env" | awk '{print $1}')"
new_llm_hash="$( { cat "$SCRIPT_DIR/llm.env"; printf '\0%s' "$SYSTEM_PROMPT"; } \
                | sha256sum | awk '{print $1}')"

old_voice_hash="$(cat "$STATE_DIR/ai-voice.hash" 2>/dev/null || true)"
old_llm_hash="$(cat "$STATE_DIR/llm.hash" 2>/dev/null || true)"

# 이전 지문이 없거나(최초 배포 = 베이스라인 확보) 달라진 서비스만 강제 재생성한다.
RECREATE=()
if [ "$new_voice_hash" != "$old_voice_hash" ]; then RECREATE+=("ai-voice"); fi
if [ "$new_llm_hash" != "$old_llm_hash" ]; then RECREATE+=("llm"); fi

# ---------------------------------------------------------------------------
# 5. ECR에서 최신 이미지 pull
# ---------------------------------------------------------------------------
echo "==> 이미지 pull"
docker compose -f "$COMPOSE_FILE" pull

# ---------------------------------------------------------------------------
# 6. 컨테이너 기동/갱신
# ---------------------------------------------------------------------------
# 먼저 일반 up -d 로 이미지 변경분을 자연 반영하고 전체를 기동(중단 최소화).
echo "==> 컨테이너 기동"
docker compose -f "$COMPOSE_FILE" up -d

# 설정만 바뀐 서비스는 compose가 못 잡을 수 있으므로 해당 서비스만 강제 재생성한다.
# 안 바뀐 컨테이너는 건드리지 않는다.
if [ "${#RECREATE[@]}" -gt 0 ]; then
  echo "==> 설정 변경 감지: ${RECREATE[*]} 재생성"
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${RECREATE[@]}"
fi

# 다음 배포 비교를 위해 새 지문 저장
printf '%s' "$new_voice_hash" > "$STATE_DIR/ai-voice.hash"
printf '%s' "$new_llm_hash" > "$STATE_DIR/llm.hash"

# ---------------------------------------------------------------------------
# 7. dangling/오래된 이미지 정리
# ---------------------------------------------------------------------------
echo "==> dangling 이미지 정리"
docker image prune -f

# ---------------------------------------------------------------------------
# 8. 상태 출력
# ---------------------------------------------------------------------------
echo "==> 현재 상태"
docker compose -f "$COMPOSE_FILE" ps

echo "==> moly 배포 완료"
