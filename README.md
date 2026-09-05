# moly-infra

ECR 이미지를 받아 EC2(Ubuntu 24.04, ap-northeast-2)에서 **moly-backend**를 띄우는 배포 레포.
빌드는 앱 레포(`moly-backend`)의 GitHub Actions가 담당하고, 이 레포는 **이미지를 실행**만 한다.

> 구 스택(ai-voice + llm 2컨테이너)은 2026-07 moly-backend 단일 서비스로 전환됨.
> 전환 작업 상세는 moly-backend 레포의 `docs/DEPLOY_MIGRATION.md` 참고.

## 구성

| 파일 | 역할 |
|------|------|
| `docker-compose.yml` | `backend`(API) + `worker`(15분 배치) + `consumer`(대화 후속 잡 상주). 이미지는 `.env`의 `IMAGE_TAG`(git-sha)·`IMAGE_REPO`(환경별 ECR 레포)로 고정 |
| `deploy.sh` | EC2에서 실행: `bash deploy.sh <git-sha>` — ECR 로그인 → SSM 시크릿 조회 → `backend.env`/FCM 파일 생성 → pull → 운세 DB preflight → up → 게이트 → consumer → 워커 systemd 유닛(워커 호스트만) |
| `systemd/moly-worker.{service,timer}` | 배치 워커 매시 정각 1틱 (`docker compose run --rm worker`) — **워커 호스트에서만 활성** |
| `nginx/voice.moly.asia.conf` | EIP 직결 경로 참조본 (443 → 127.0.0.1:8000, LE 인증서 — DNS 롤백 경로로 유지) |
| `nginx/alb-8080.conf` | ALB 경로 참조본 (Target Group → :8080 → 127.0.0.1:8000, 수동 반영) |

- `backend`: `127.0.0.1:8000` 루프백만 바인딩. 외부 유입은 ALB(ACM, 443) → nginx :8080 프록시
- `worker`: 상주하지 않음. `moly-worker.timer`가 매시 정각 `docker compose run --rm worker` 실행(멱등 1틱)
- `consumer`: 기억·일기 색인·약속·관계·대화 요약 잡을 상주 처리. dev·prod 모두 deploy.sh가 `consumer` profile을 기동한다. **워커와 달리 호스트 제한이 없다** — 잡을 집어갈 때 `FOR UPDATE SKIP LOCKED`를 써서 두 대가 같은 잡을 처리하지 않고 나눠 갖는다. 이미지에 `worker.consumer`가 없으면(구 버전 롤백) 기동을 건너뛰고 배포는 계속한다
- **워커 단일 호스트 규칙**: `/etc/moly-worker-host` 마커가 있는 인스턴스에서만 deploy.sh가 타이머를 설치/활성하고, 없는 호스트에선 비활성화한다. 두 대에서 동시 실행되면 매시 틱 2회 = LLM 일기 비용 2배 + 허위 알림. **호스트 재구축(AMI 복원 등) 시 마커를 수동 재생성해야 한다** (`sudo touch /etc/moly-worker-host`). 워커 호스트 이동: 기존 마커 삭제 → 새 호스트 마커 생성 → 양쪽 재배포
- **환경 마커** (개발서버 전용): `/etc/moly-env`에 `dev`가 적힌 호스트는 deploy.sh가 SSM `/moly/dev/`를 읽는다. **prod 호스트에는 이 파일을 만들지 않는다** (없음 = prod, 기존 동작). 워커 마커와 달리 **내용이 필요** — `sudo touch`로 만들면 빈 값으로 배포가 즉시 실패한다. dev 호스트 재구축 시 재생성: `echo dev | sudo tee /etc/moly-env`. 상세: `docs/DEV-SERVER.md`
- 이미지 태그: GH Actions가 `deploy.sh <git-sha>`로 넘기고 `.env`(IMAGE_TAG·IMAGE_REPO)에 기록된다. `IMAGE_REPO`는 환경 마커에 따라 deploy.sh가 결정 — prod `moly-backend` / dev `moly-backend-dev`. 인자 없이 재실행하면 마지막 태그 재사용(멱등). `:latest`는 소비하지 않는다
- `backend.env` / `secrets/fcm-service-account.json` / `.env` 는 `deploy.sh`가 런타임에 생성하며 git에 커밋하지 않는다

## 배포

1. moly-backend 레포 main push → GitHub Actions가 이미지 빌드 → ECR push
2. Actions가 SSM SendCommand로 EC2에서 `git pull && bash deploy.sh` 실행

수동 배포 (EC2에서, `sudo su -` 후):

```bash
cd /root/moly-infra && git pull --ff-only && bash deploy.sh
```

멱등이라 여러 번 실행해도 안전하다.

오늘의 운세와 운세 대화는 dev·prod에서 활성화돼 있으며 `deploy.sh`가
`FORTUNE_ENABLED=true`, `FORTUNE_CHAT_ENABLED=true`를 명시적으로 주입한다. 배포할 때마다
`scripts/verify_fortune_schema.py`가 세 운세 테이블, RLS·권한, `messages.kind`, 필수 인덱스,
건초 광고 세션 만료 계약과 migration checksum을 먼저 확인한다. 하나라도 다르면 후보 env를
실행 중인 env로 교체하지 않고 기존 컨테이너를 유지한 채 배포를 중단한다.

운세 관련 스키마를 바꾸는 릴리스는 운영 DB에 하위 호환 migration과 검증을 먼저 끝내고 코드를
배포한다. infra만 머지해서는 실행 중인 컨테이너 설정이 바뀌지 않으므로, 기능 플래그나 Parameter
Store 값을 바꾼 뒤에는 검증한 backend 이미지 SHA를 명시해 두 인스턴스를 다시 롤링 배포한다.

## 배치 워커 운영

```bash
systemctl list-timers moly-worker.timer     # 다음 실행 시각
systemctl status moly-worker.service        # 마지막 실행 결과
journalctl -u moly-worker.service -n 100    # 워커 로그
systemctl start moly-worker.service         # 수동 1틱 (멱등이라 안전)
```

## 시크릿

SSM Parameter Store `/moly/prod/` 에서 런타임에 조회한다 (`/etc/moly-env` 마커가 `dev`인
개발서버는 `/moly/dev/`). AWS 인증은 EC2 인스턴스
IAM 역할로 처리되며 자격증명을 레포/스크립트에 두지 않는다.

필수: `anthropic-api-key`, `openai-api-key`, `supabase-url`, `supabase-publishable-key`,
`supabase-secret-key`, `supabase-db-connection-string`, `revenuecat-webhook-auth`,
`fortune-ad-unit-ids`
(legacy `supabase-anon-key`/`supabase-service-role-key`는 2026-08 키 유출로 폐기)
옵션: `fcm-project-id`, `fcm-service-account`(여러 줄 JSON — 파일로 생성돼 컨테이너에 마운트, 없으면 푸시만 비활성),
`meta-install-referrer-decryption-key`(64자 hex — 없으면 설치 귀속 복호화 엔드포인트만 503)

`fortune-ad-unit-ids`는 AdMob SSV의 `ad_unit`과 비교할 숫자 ID를 쉼표로 구분한다. 운영값은 iOS
`3157498952`, Android `2146352961`이며 빈 값이면 운세 광고를 허용하지 않고 배포 자체도 실패한다.

새 시크릿 추가 시: 파라미터 생성(`/moly/prod/<소문자-하이픈>`) + `deploy.sh`의 env 매핑에 한 줄 추가.

## 의존성 (EC2)

docker, docker compose v2, aws cli v2, jq, nginx(+certbot), systemd
