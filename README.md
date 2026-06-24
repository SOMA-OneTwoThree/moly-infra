# moly-infra

ECR 이미지를 받아 EC2(Ubuntu 24.04, ap-northeast-2)에서 두 컨테이너를 띄우는 배포 레포.
빌드는 각 앱 레포(`moly-voice`, `moly-llm`)의 GitHub Actions가 담당하고, 이 레포는
**이미지를 묶어 실행**만 한다.

## 구성

| 파일 | 역할 |
|------|------|
| `docker-compose.yml` | ECR 이미지 2개(`ai-voice`, `llm`)를 묶어 실행 (빌드 없음) |
| `deploy.sh` | EC2에서 실행: ECR 로그인 → SSM 시크릿 조회 → `.env` 생성 → pull → up |

- `ai-voice`: `127.0.0.1:8001` (루프백만, 호스트 nginx가 프록시)
- `llm`: 호스트 포트 없음, 내부에서 `http://llm:8000` 로만 접근
- `ai-voice.env` / `llm.env` 는 `deploy.sh`가 런타임에 생성하며 git에 커밋하지 않는다.

## 배포

1. 앱 레포 GitHub Actions가 이미지를 ECR에 push
2. SSM으로 EC2에서 `deploy.sh` 실행

수동 배포 (EC2에서):

```bash
./deploy.sh
```

멱등이라 여러 번 실행해도 안전하다.

## 시크릿

SSM Parameter Store `/moly/prod/` 에서 런타임에 조회한다. AWS 인증은 EC2 인스턴스
IAM 역할로 처리되며 자격증명을 레포/스크립트에 두지 않는다. `SYSTEM_PROMPT`는 여러 줄
값이라 `llm.env` 대신 compose `environment` 로 전달한다.

## 의존성 (EC2)

docker, docker compose v2, aws cli v2, jq
