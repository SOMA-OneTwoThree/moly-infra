# moly-infra

moly-backend의 ECR 이미지를 EC2에서 실행하는 인프라 원본이다. 이미지 빌드와 호스트별 롤링
배포 순서는 moly-backend의 `.github/workflows/deploy.yml`과 `deploy-dev.yml`이 소유한다.
이 저장소의 `deploy.sh`는 한 호스트를 배포한다.

## 실행 구조

HTTPS → ALB(ACM TLS 종료) → nginx `:8080` → API `127.0.0.1:8000`.
nginx 원본은 `nginx/alb-8080.conf`이며 `setup_ec2.sh`가 설치한다. 인스턴스에 별도 TLS 인증서를
설치하지 않는다. nginx 수정 시에는 원본과 호스트 설정을 함께 갱신하고 `nginx -t`로 검증한다.

| 구성 | 실행 계약 |
|---|---|
| `backend` | API 상주 프로세스. 외부에 컨테이너 포트를 직접 열지 않는다 |
| `worker` | `moly-worker.timer`가 매시 :00·:15·:30·:45에 1틱 실행. 최대 14분 |
| `consumer` | 대화 후속 잡을 상주 처리. 각 호스트에서 `SKIP LOCKED`로 잡을 나눠 처리 |
| `/etc/moly-worker-host` | 이 파일이 있는 호스트에서만 배치 타이머 설치·활성화 |
| `/etc/moly-env` | 없음: prod. 내용 `dev`: dev. 빈 값·잘못된 값·읽기 실패: 배포 중단 |

동일 환경의 배치 워커는 한 호스트에만 둔다. 이전 호스트의 마커를 제거하고 재배포해 타이머를
중지한 다음 새 호스트에 마커를 생성하고 배포한다. consumer에는 이 마커 제한이 없다.

## 환경과 설정

| 환경 | SSM 경로 | ECR 저장소 | `ENVIRONMENT` |
|---|---|---|---|
| prod | `/moly/prod/` | `moly-backend` | `production` |
| dev | `/moly/dev/` | `moly-backend-dev` | `development` |

개발 호스트에서는 `echo dev | sudo tee /etc/moly-env`로 내용을 기록한다.
prod 호스트에는 마커 파일이 필요 없다. 환경별 Supabase Auth와 데이터 프로젝트는 분리된
현재 구성을 사용한다. 배너 검증 계정도 dev 프로젝트의 계정이다.

SSM 값은 EC2 IAM 역할로 조회한다. `deploy.sh`가 `.env`, `backend.env`,
`secrets/fcm-service-account.json`을 생성하므로 이 파일들을 직접 편집하지 않는다.
환경변수의 정확한 이름·기본값·매핑은 `deploy.sh`가 원본이다.

필수 SSM 키:
`anthropic-api-key`, `openai-api-key`, `supabase-db-connection-string`, `supabase-url`,
`supabase-publishable-key`, `supabase-secret-key`, `revenuecat-webhook-auth`.
prod는 `fortune-ad-unit-ids`와 `slack-feedback-webhook-url`도 비어 있지 않아야 한다. dev의 빈 운세 광고 allowlist는 배포를
허용하지만 해당 광고 보상은 서버에서 거부한다.

옵션에는 FCM 설정, Slack 요약·알림·상태 webhook(dev의 사용자 피드백 webhook도 옵션), `health-token`,
`worker-ping-url`, `meta-install-referrer-decryption-key`가 있다. 해당 SSM 키가 존재해도
`backend.env`에 매핑되지 않으면 컨테이너에 전달되지 않는다.

대화 컨텍스트·checkpoint·agent와 운세·운세 대화 기능은 dev·prod에서 켠다.
위험한 개발 라우트와 개발 운영자 계정 설정은 dev에만 넣는다.

## 배포와 롤백

1. backend의 dev/main 브랜치 배포 workflow가 해당 환경의 이미지를 빌드한다.
2. prod workflow는 기본 2대를 확인하고 ALB에서 한 호스트씩 제외한다. dev는 별도 태그의
   1대에 중단 배포하며 ALB를 조작하지 않는다.
3. 해당 호스트에서 infra를 갱신하고 `bash deploy.sh <image-tag>`를 실행한다.
4. prod는 호스트·외부 경로 검증 후 ALB에 다시 등록하고 다음 호스트를 처리한다.
   dev 태그는 `dev-<sha>`, prod 태그는 `<sha>`다.

`deploy.sh`의 실행 순서는 ECR 로그인 → SSM 조회 → 후보 env·FCM 생성 → 이미지 pull → DB preflight
→ live FCM·env 교체 → API·consumer 기동 → 헬스·이미지·nginx 검사 → 워커 타이머 갱신이다.
이미지 pull·DB preflight 실패 시 live `.env`·`backend.env`·FCM 자격증명 파일을 교체하지 않는다.
FCM 반영은 기존 bind mount의 파일 inode를 유지한다. 이 단계 이후의 컨테이너 기동 실패까지
모든 파일을 자동으로 원복하는 것은 아니며, 운영 롤백 절차로 처리한다.

이미지 SHA를 인자로 전달하는 것이 표준이다. 인자를 생략하면 마지막 `.env`의 태그를 재사용한다.
아직 기록된 태그도 없으면 현재 구현은 `latest`로 폴백하므로 첫 배포에도 검증한 SHA를 명시한다.
이미지는 호스트에서 해당 저장소의 최근 3개 태그를 유지하며, 사용 중인 이미지는 제거되지 않는다.

운영 롤백은 backend 배포 workflow의 `workflow_dispatch`에서 기존 `image_tag`를 지정한다.
workflow의 ALB 제외·복귀 절차를 그대로 사용한다. 호스트의 `deploy.sh`를 단독 실행하는 것은
전체 플릿의 롤링 배포가 아니다.

구 이미지에 `worker.consumer`가 없으면 consumer를 건너뛰고 남은 consumer 컨테이너를 제거한다.
모듈이 있으면 실제 핸들러 등록까지 검사한다. 이 분기는 구 이미지로 롤백할 때도 유지하는 계약이다.

## DB 계약

DB 구조 원본은 moly-backend의 `db/schema.sql`이다. 기존 DB 변경은 검토한 SQL을 수동으로
적용하고 검증한다. 배포 스크립트는 DB를 변경하지 않는다.

새 이미지의 `python -m db.schema_contract`가 해당 이미지에 포함된 스키마 계약을 읽어
실제 DB의 컬럼·제약·인덱스·함수·트리거·RLS·권한을 검사한다. 새 테이블 추가는 구 이미지
롤백을 막지 않으며, 기존 객체의 제약 변경·누락·권한 확대는 실패한다.

검증 모듈이 없는 구 이미지로 롤백할 때는 `scripts/verify_fortune_schema.py`로 당시 운세
테이블·권한·광고 만료·메시지 제약·인덱스를 검사한다. 파일 checksum이나 적용 원장 행은
요구하지 않는다. 검증 실패 시 후보 컨테이너 기동 전에 중단한다.

## 호스트 구성과 점검

`setup_ec2.sh`는 Ubuntu 24.04 x86_64에 Docker/Compose, AWS CLI, nginx와 저장소를 설치한다.
SG는 ALB에서 오는 8080만 허용하고 접속은 SSM을 사용한다. 워커 마커는 자동 생성하지 않는다.
호스트를 추가하면 backend workflow의 대상 수·태그·Target Group도 함께 확인한다.

```bash
docker compose --env-file /root/moly-infra/.env -f /root/moly-infra/docker-compose.yml ps
curl -fsS http://127.0.0.1:8000/health/ready
curl -fsS http://127.0.0.1:8080/health
systemctl list-timers moly-worker.timer
systemctl status moly-worker.service
journalctl -u moly-worker.service -n 100
```

`/health/ready`는 DB 연결, `/health`의 version은 이미지 버전 확인에 사용한다.
외부 경로 장애는 ALB 대상 상태 → nginx `:8080` → API readiness 순으로 확인한다.
배포 실패 시에는 workflow 출력과 해당 호스트의 컨테이너·systemd 로그를 확인한다.
