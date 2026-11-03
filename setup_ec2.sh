#!/usr/bin/env bash
#
# setup_ec2.sh: 새 EC2 서버를 ALB 뒤에서 서비스할 수 있는 상태로 준비한다.
#
# Docker, AWS CLI v2, nginx, jq를 설치하고 이 저장소를 /root/moly-infra에 clone한다.
# nginx 설정과 journald 로그 보존 설정도 넣는다.
# 앱 배포는 하지 않는다. 끝나면 출력되는 안내대로 첫 배포를 하고 Target Group에 등록한다.
#
# 요청 경로: ALB(443, ACM) → Target Group(HTTP 8080) → nginx :8080 → 127.0.0.1:8000
# TLS는 ALB에서 끝나므로 서버에는 인증서를 설치하지 않는다.
#
# 전제 조건
#   - Ubuntu 24.04 x86_64, IMDSv2
#   - IAM 인스턴스 역할: SSM, Parameter Store 읽기, KMS 복호화, ECR pull
#     ECR pull 권한이 없으면 deploy.sh의 ECR 로그인에서 실패한다.
#   - 보안 그룹: 8080 포트를 ALB 보안 그룹에서만 허용한다. 접속은 SSM Session Manager로 하고
#     80, 443, 22 포트는 열지 않는다.
#   - EC2 태그 Role=moly-backend: 배포 workflow가 이 태그로 대상 서버를 찾는다.
#     서버 수를 바꾸면 moly-backend deploy.yml의 EXPECTED_INSTANCES도 바꿔야 한다.
#
# 실행: sudo bash setup_ec2.sh  (여러 번 실행해도 안전하다)

set -euo pipefail

# ---------------------------------------------------------------------------
# 설정값
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
# 2. Docker (compose v2가 필요해 Ubuntu의 docker.io 대신 공식 저장소에서 설치)
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
# 3. AWS CLI v2 (apt 패키지는 v1이라 공식 설치 파일 사용)
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

# 인스턴스 역할이 연결됐는지 확인한다. 실패해도 설치는 계속한다.
log "인스턴스 역할로 STS 자격 확인"
if aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "    STS 자격 정상 (인스턴스 역할 연결됨)"
else
  echo "    경고: STS 호출 실패 — IAM 인스턴스 역할이 연결됐는지 확인하세요" >&2
fi

# ---------------------------------------------------------------------------
# 4. moly-infra clone
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
# 4-1. journald 보존 기간 (컨테이너 로그도 journald에 쌓인다)
# ---------------------------------------------------------------------------
log "journald 보존 상한 설치 (원본: systemd/journald-moly.conf)"
install -D -m 0644 "$INFRA_DIR/systemd/journald-moly.conf" /etc/systemd/journald.conf.d/moly.conf
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
# 5. nginx (ALB에서 오는 :8080 요청을 backend로 전달)
# ---------------------------------------------------------------------------
log "nginx 설치"
apt-get install -y nginx
systemctl enable --now nginx

log "ALB용 nginx 설정 설치 (:8080 → 127.0.0.1:8000, 원본: nginx/alb-8080.conf)"
cp "$INFRA_DIR/nginx/alb-8080.conf" /etc/nginx/sites-available/alb-8080
ln -sf /etc/nginx/sites-available/alb-8080 /etc/nginx/sites-enabled/alb-8080
# 기본 사이트(:80)는 쓰지 않으므로 끈다.
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 6. 워커 마커 안내
# ---------------------------------------------------------------------------
# 배치 워커는 한 대에서만 돌아야 하므로 이 스크립트는 마커를 만들지 않는다. deploy.sh는
# /etc/moly-worker-host가 있는 호스트에만 워커 타이머를 설치한다. 워커 호스트로 정한 서버에서만 만든다:
#   sudo touch /etc/moly-worker-host
# 워커 호스트를 바꿀 때는 이전 호스트의 마커를 먼저 지우고 deploy.sh를 다시 실행한다.
log "워커 마커(/etc/moly-worker-host): 설치 안 함 — 워커 호스트 지정은 수동 (위 주석 참조)"

# ---------------------------------------------------------------------------
# 7. SSM 에이전트 확인 (Ubuntu AMI에는 보통 snap으로 설치돼 있다)
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
============================================================
DONE
