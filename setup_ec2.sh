#!/usr/bin/env bash
#
# setup_ec2.sh — moly-backend 스택을 위한 EC2 호스트 부트스트랩 (ALB + 2대 이중화 시대).
#
# 새 EC2(Ubuntu 24.04, ap-northeast-2)를 ALB Target Group 뒤에서 서빙 가능한 상태로 재현한다.
# 이 스크립트는 호스트 레벨 의존성(docker / aws cli / nginx / jq)만 설치하고,
# moly-infra를 clone한 뒤 안내를 출력한다. 실제 앱 배포는 moly-infra/deploy.sh가 한다.
#
# 현재 아키텍처 (2026-07 ALB 컷오버 이후):
#   voice.moly.asia (가비아 CNAME) → ALB(443, ACM TLS 종료) → TG(HTTP:8080)
#     → 각 EC2의 nginx :8080 → 127.0.0.1:8000 백엔드 컨테이너
#   TLS는 ALB가 종료하므로 인스턴스에는 certbot/Let's Encrypt가 필요 없다.
#   (레거시: 인스턴스 #1에만 EIP + nginx :443 + LE 경로가 남아 있음 — 신규 인스턴스엔 만들지 않는다)
#
# 전제:
#   - Ubuntu 24.04, x86_64, IMDSv2
#   - IAM 인스턴스 역할(moly-voice-ec2-role) 연결:
#     SSM(Session/RunCommand) + Parameter Store 읽기(/moly/prod/*) + KMS 복호화 + ECR pull.
#     (ECR pull 권한이 빠지면 deploy.sh의 ECR 로그인이 AccessDenied로 실패한다)
#   - 보안 그룹: 인바운드 8080을 ALB SG(sg-0efceca4a4fece8ac)에서만 허용.
#     80/443/22는 열지 않는다(접속은 SSM Session Manager).
#   - EC2 태그 Role=moly-backend 필수 — GitHub Actions 롤링 배포가 이 태그로 대상을 발견한다.
#     ⚠ 인스턴스를 늘리면 moly-backend .github/workflows/deploy.yml의 EXPECTED_INSTANCES도 같이 수정.
#
# 실행: sudo bash setup_ec2.sh
#
# 멱등성: 여러 번 실행해도 안전하도록 작성했다.

set -euo pipefail

# ---------------------------------------------------------------------------
# 설정값 (필요 시 수정)
# ---------------------------------------------------------------------------
INFRA_REPO="https://github.com/SOMA-OneTwoThree/moly-infra.git"
INFRA_DIR="/root/moly-infra"
AWS_REGION="ap-northeast-2"
TG_ARN="arn:aws:elasticloadbalancing:ap-northeast-2:676972757138:targetgroup/moly-backend-tg/5d725ff95a85e070"

log() { echo -e "\n==> $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root로 실행하세요 (sudo bash setup_ec2.sh)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. 기본 패키지
# ---------------------------------------------------------------------------
log "apt 업데이트 및 기본 패키지 설치 (curl, unzip, jq, git, ca-certificates)"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl unzip jq git gnupg lsb-release

# ---------------------------------------------------------------------------
# 2. Docker (공식 apt 저장소 — Ubuntu 기본 docker.io 대신 최신 docker-ce + compose v2)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker 공식 저장소 추가 및 설치"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker 이미 설치됨 — 건너뜀"
fi
docker --version
docker compose version

# ---------------------------------------------------------------------------
# 3. AWS CLI v2 (apt의 v1이 아니라 공식 v2 — ECR 인증에 v2 권장)
# ---------------------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  log "AWS CLI v2 설치"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install" --update
  rm -rf "$tmp"
else
  log "AWS CLI 이미 설치됨 — 건너뜀"
fi
aws --version

# IAM 인스턴스 역할이 제대로 붙어 있는지 가볍게 확인 (실패해도 치명적 아님)
log "인스턴스 역할로 STS 자격 확인"
if aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "    STS 자격 정상 (인스턴스 역할 연결됨)"
else
  echo "    경고: STS 호출 실패 — IAM 인스턴스 역할이 연결됐는지 확인하세요" >&2
fi

# ---------------------------------------------------------------------------
# 4. moly-infra clone (compose + deploy.sh + nginx 설정 원본)
# ---------------------------------------------------------------------------
if [ ! -d "$INFRA_DIR/.git" ]; then
  log "moly-infra clone → $INFRA_DIR"
  git clone "$INFRA_REPO" "$INFRA_DIR"
else
  log "moly-infra 이미 존재 — git pull"
  git -C "$INFRA_DIR" pull --ff-only || true
fi
chmod +x "$INFRA_DIR/deploy.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. nginx — ALB 전용 :8080 블록 (TLS 없음: ALB가 ACM으로 종료)
# ---------------------------------------------------------------------------
log "nginx 설치"
apt-get install -y nginx
systemctl enable --now nginx

log "ALB용 nginx 설정 설치 (:8080 → 127.0.0.1:8000, 원본: nginx/alb-8080.conf)"
cp "$INFRA_DIR/nginx/alb-8080.conf" /etc/nginx/sites-available/alb-8080
ln -sf /etc/nginx/sites-available/alb-8080 /etc/nginx/sites-enabled/alb-8080
# Ubuntu 기본 default 사이트(:80)는 ALB 인스턴스에선 불필요 — 존재해도 무해하나 비활성화
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 6. 워커 마커 안내 (설치하지 않음 — 명시적 결정 사항)
# ---------------------------------------------------------------------------
# 배치 워커(일기/푸시 틱)는 전체 플릿에서 정확히 1대에서만 돌아야 한다.
# deploy.sh는 /etc/moly-worker-host 마커 파일이 있는 호스트에만 systemd timer를 설치하고,
# 없는 호스트에서는 timer를 disable한다. 이 스크립트는 마커를 만들지 않는다 —
# 워커 호스트를 지정하려면 해당 인스턴스에서 수동으로:
#   sudo touch /etc/moly-worker-host
# (기존 워커 호스트를 교체할 때는 이전 호스트의 마커를 먼저 지우고 deploy.sh를 재실행할 것)
log "워커 마커(/etc/moly-worker-host): 설치 안 함 — 워커 호스트 지정은 수동 (위 주석 참조)"

# ---------------------------------------------------------------------------
# 7. SSM 에이전트 확인 (Ubuntu는 snap으로 사전 설치돼 있는 경우가 많음)
# ---------------------------------------------------------------------------
log "SSM 에이전트 확인"
if snap list amazon-ssm-agent >/dev/null 2>&1; then
  echo "    snap amazon-ssm-agent 설치됨"
  snap restart amazon-ssm-agent >/dev/null 2>&1 || true
elif systemctl list-unit-files 2>/dev/null | grep -q amazon-ssm-agent; then
  echo "    systemd amazon-ssm-agent 설치됨"
  systemctl restart amazon-ssm-agent || true
else
  echo "    경고: SSM 에이전트를 찾지 못함. snap install amazon-ssm-agent --classic 고려" >&2
fi

# ---------------------------------------------------------------------------
# 완료 안내
# ---------------------------------------------------------------------------
cat <<DONE

============================================================
 EC2 부트스트랩 완료 (ALB 이중화 구성).
------------------------------------------------------------
 다음 단계:
   1) EC2 태그 확인: Role=moly-backend (롤링 배포 대상 발견용)
      aws ec2 create-tags --resources <instance-id> --tags Key=Role,Value=moly-backend
   2) 첫 배포 — 현재 서비스 중인 git sha로 (다른 인스턴스와 동일 버전!):
        cd $INFRA_DIR && bash deploy.sh <git-sha>
      (sha는 기존 인스턴스 curl -s localhost:8080/health 의 version 값)
   3) 로컬 헬스 확인: curl -s http://127.0.0.1:8080/health → 200
   4) Target Group 등록:
        aws elbv2 register-targets --target-group-arn $TG_ARN \\
          --targets Id=<instance-id> --region $AWS_REGION
        aws elbv2 wait target-in-service --target-group-arn $TG_ARN \\
          --targets Id=<instance-id> --region $AWS_REGION
   5) ⚠ moly-backend .github/workflows/deploy.yml 의 EXPECTED_INSTANCES 를
      새 총 대수로 수정 (안 하면 다음 배포가 대수 불일치로 중단됨)

 확인 명령:
   docker compose -f $INFRA_DIR/docker-compose.yml ps
   systemctl status nginx
   aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $AWS_REGION

 IAM 인스턴스 역할(moly-voice-ec2-role)에 다음 권한이 있어야 함:
   - SSM (Session Manager / Run Command 수신)
   - ssm:GetParameter* (/moly/prod/* 경로)
   - kms:Decrypt (SecureString 복호화)
   - ECR pull (ecr:GetAuthorizationToken + BatchGetImage 등)  ← 빠지면 배포 실패

 참고: TLS는 ALB(ACM)가 종료하므로 이 호스트에 certbot/LE는 설치하지 않는다.
       레거시 EIP+LE 경로는 인스턴스 #1에만 존재하며 폐기 예정.
============================================================
DONE
