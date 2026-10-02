#!/bin/bash
# moly-worker.service가 실패하면 systemd OnFailure=(moly-worker-failed.service)가 실행한다.
# 상태 채널(SLACK_STATUS_WEBHOOK_URL, 없으면 공용 SLACK_WEBHOOK_URL — backend의 status 라우팅과 같다)에
# 한 줄만 보낸다. 한 번의 실패는 다음 틱이 이어받고, 계속 실패하면 데드맨(Healthchecks)이 따로 경보한다.
# 로그 본문은 보내지 않는다(개인정보·비밀값이 섞일 수 있다 — journalctl -u moly-worker.service로 확인).
# 웹훅은 backend.env에서 그 키만 읽고 출력·인자로 노출하지 않는다(curl 설정은 stdin으로 넘긴다).
# 전송에 실패해도 0으로 끝난다 — 알림 경로가 워커 운영을 막지 않게.
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
# curl 설정 파일 문법(따옴표·역슬래시)과 섞이지 않는 https URL만 쓴다.
if ! printf '%s' "$url" | grep -Eq '^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'; then
  echo "상태 채널 웹훅 형식이 예상과 다름 — 알림 생략" >&2
  exit 0
fi

# systemd가 OnFailure 유닛에 넘기는 값(MONITOR_*)을 우선 쓰고, 없으면 유닛 상태에서 읽는다.
result="${MONITOR_SERVICE_RESULT:-$(systemctl show "$UNIT" -p Result --value 2>/dev/null)}"
status="${MONITOR_EXIT_STATUS:-$(systemctl show "$UNIT" -p ExecMainStatus --value 2>/dev/null)}"
# JSON을 직접 만들므로 메시지에 넣는 값은 안전한 문자로 제한한다.
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
