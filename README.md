# moly-infra

ECR 이미지를 받아 EC2(Ubuntu 24.04, ap-northeast-2)에서 **moly-backend**를 띄우는 배포 레포.
빌드는 앱 레포(`moly-backend`)의 GitHub Actions가 담당하고, 이 레포는 **이미지를 실행**만 한다.

> 구 스택(ai-voice + llm 2컨테이너)은 2026-07 moly-backend 단일 서비스로 전환됨.
> 전환 작업 상세는 moly-backend 레포의 `docs/DEPLOY_MIGRATION.md` 참고.

## 구성

| 파일 | 역할 |
|------|------|
| `docker-compose.yml` | `backend`(API, 127.0.0.1:8000) + `worker`(배치, profiles로 상주 안 함) |
| `deploy.sh` | EC2에서 실행: ECR 로그인 → SSM 시크릿 조회 → `backend.env`/FCM 파일 생성 → pull → up → 워커 systemd 유닛 설치 |
| `systemd/moly-worker.{service,timer}` | 배치 워커 매시 정각 1틱 (`docker compose run --rm worker`) |
| `nginx/voice.moly.asia.conf` | 호스트 nginx 설정 참조본 (443 → 127.0.0.1:8000 프록시, 수동 반영) |

- `backend`: `127.0.0.1:8000` 루프백만 바인딩, 호스트 nginx(443, voice.moly.asia)가 프록시
- `worker`: 상주하지 않음. `moly-worker.timer`가 매시 정각 `docker compose run --rm worker` 실행(멱등 1틱)
- `backend.env` / `secrets/fcm-service-account.json` 은 `deploy.sh`가 런타임에 SSM에서 생성하며 git에 커밋하지 않는다

## 배포

1. moly-backend 레포 main push → GitHub Actions가 이미지 빌드 → ECR push
2. Actions가 SSM SendCommand로 EC2에서 `git pull && bash deploy.sh` 실행

수동 배포 (EC2에서, `sudo su -` 후):

```bash
cd /root/moly-infra && git pull --ff-only && bash deploy.sh
```

멱등이라 여러 번 실행해도 안전하다.

## 배치 워커 운영

```bash
systemctl list-timers moly-worker.timer     # 다음 실행 시각
systemctl status moly-worker.service        # 마지막 실행 결과
journalctl -u moly-worker.service -n 100    # 워커 로그
systemctl start moly-worker.service         # 수동 1틱 (멱등이라 안전)
```

## 시크릿

SSM Parameter Store `/moly/prod/` 에서 런타임에 조회한다. AWS 인증은 EC2 인스턴스
IAM 역할로 처리되며 자격증명을 레포/스크립트에 두지 않는다.

필수: `anthropic-api-key`, `openai-api-key`, `supabase-url`, `supabase-anon-key`,
`supabase-service-role-key`, `supabase-db-connection-string`
옵션: `fcm-project-id`, `fcm-service-account`(여러 줄 JSON — 파일로 생성돼 컨테이너에 마운트, 없으면 푸시만 비활성)

새 시크릿 추가 시: 파라미터 생성(`/moly/prod/<소문자-하이픈>`) + `deploy.sh`의 env 매핑에 한 줄 추가.

## 의존성 (EC2)

docker, docker compose v2, aws cli v2, jq, nginx(+certbot), systemd
