#!/bin/bash
# 워커 틱(moly-worker.service)이 실패하면 moly-worker-failed.service가 OnFailure=로 이 스크립트를 실행한다.
# Slack 상태 채널에 한 줄 알림을 보내고, 상태 채널 웹훅이 없으면 공용 웹훅을 쓴다.
# 한 번의 실패는 다음 틱이 이어받고, 실패가 계속되면 Healthchecks 데드맨 알림이 따로 온다.
# 로그 본문은 개인정보나 비밀값이 섞일 수 있어 보내지 않는다.
# 웹훅 URL이 출력이나 명령 인자에 남지 않도록 curl 설정을 stdin으로 넘긴다.
# 전송에 실패해도 0으로 끝내 알림 문제가 워커 운영을 막지 않게 한다.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/backend.env"
UNIT=moly-worker.service

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -1; }

url="$(env_value SLACK_STATUS_WEBHOOK_URL)"
[ -n "$url" ] || url="$(env_value SLACK_WEBHOOK_URL)"
if [ -z "$url" ]; then
  echo "상태 채널 웹훅 미설정 — 알림 생략" >&2
  exit 0
fi
# curl 설정 문법과 섞이지 않도록 따옴표나 역슬래시가 없는 https URL만 허용한다.
if ! printf '%s' "$url" | grep -Eq '^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'; then
  echo "상태 채널 웹훅 형식이 예상과 다름 — 알림 생략" >&2
  exit 0
fi

# systemd가 OnFailure 유닛에 넘겨 주는 MONITOR_* 값을 먼저 쓰고, 없으면 유닛 상태에서 읽는다.
result="${MONITOR_SERVICE_RESULT:-$(systemctl show "$UNIT" -p Result --value 2>/dev/null)}"
status="${MONITOR_EXIT_STATUS:-$(systemctl show "$UNIT" -p ExecMainStatus --value 2>/dev/null)}"
# JSON을 직접 만들기 때문에 메시지에 넣는 값은 안전한 문자만 남긴다.
clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:-' | cut -c1-40; }
result="$(clean "${result:-unknown}")"
status="$(clean "${status:-unknown}")"
host="$(clean "$(uname -n)")"
when="$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M KST')"

text="⚠️ [워커] 틱 비정상 종료 — result=${result} status=${status} · ${host} · ${when}"
text="${text}\\n한 번의 실패는 다음 틱이 이어받는다. timeout이면 컨테이너는 끝까지 처리 중일 수 있다(그 뒤 로그: journalctl -t moly-worker)."
payload="{\"text\":\"${text}\"}"

if ! printf 'url = "%s"\n' "$url" \
    | curl -fsS -m 10 -K - -H 'Content-type: application/json' --data-binary "$payload" -o /dev/null; then
  echo "상태 채널 전송 실패" >&2
fi
exit 0
