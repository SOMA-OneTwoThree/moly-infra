#!/usr/bin/env bash
#
# setup-ec2.sh — moly-backend 스택을 위한 EC2 호스트 부트스트랩.
#
# 새 EC2(Ubuntu 24.04, ap-northeast-2)를 우리가 손으로 셋업했던 상태로 재현한다.
# 이 스크립트는 호스트 레벨 의존성(docker / aws cli / nginx / certbot / jq)만 설치하고,
# moly-infra를 clone한 뒤 안내를 출력한다. 실제 앱 배포는 moly-infra/deploy.sh가 한다.
#
# 전제:
#   - Ubuntu 24.04, x86_64
#   - EC2에 IAM 인스턴스 역할(moly-voice-ec2-role)이 연결돼 있어야 한다.
#     필요 권한: SSM(Session/RunCommand) + Parameter Store 읽기 + KMS 복호화 + ECR pull.
#     (ECR pull 권한이 빠지면 deploy.sh의 ECR 로그인이 AccessDenied로 실패한다 — 이 세션에서 겪음)
#   - 보안 그룹: 인바운드 80/443, 아웃바운드 전체 허용. SSH(22)는 열지 않는다(SSM 사용).
#   - Route53/가비아 등에서 voice.moly.asia A레코드가 이 EC2의 EIP를 가리켜야 certbot이 동작.
#
# 실행: sudo bash setup-ec2.sh
#
# 멱등성: 가능한 한 여러 번 실행해도 안전하도록 작성했다. 다만 certbot 발급은
# 도메인 DNS가 EC2를 가리킬 때만 성공한다.

set -euo pipefail

# ---------------------------------------------------------------------------
# 설정값 (필요 시 수정)
# ---------------------------------------------------------------------------
DOMAIN="voice.moly.asia"
CERTBOT_EMAIL=""                 # ← Let's Encrypt 알림 이메일. 비우면 --register-unsafely-without-email 사용
INFRA_REPO="https://github.com/SOMA-OneTwoThree/moly-infra.git"
INFRA_DIR="/root/moly-infra"
AWS_REGION="ap-northeast-2"

log() { echo -e "\n==> $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root로 실행하세요 (sudo bash setup-ec2.sh)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. 기본 패키지
# ---------------------------------------------------------------------------
log "apt 업데이트 및 기본 패키지 설치 (curl, unzip, jq, ca-certificates)"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl unzip jq gnupg lsb-release

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
# 4. nginx (TLS 종료 + HTTP 프록시 → 127.0.0.1:8000)
# ---------------------------------------------------------------------------
log "nginx 설치"
apt-get install -y nginx
systemctl enable --now nginx

# HTTP 프록시 설정 작성 (certbot이 이후 443 블록을 추가/수정한다)
# 최종 형태 참조본: nginx/voice.moly.asia.conf
NGINX_SITE="/etc/nginx/sites-available/default"
log "nginx 사이트 설정 작성 ($DOMAIN → 127.0.0.1:8000, HTTP 프록시)"
cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 1m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # LLM 응답 생성이 길어질 수 있음 — 일반 API보다 넉넉히
        proxy_read_timeout 120s;
    }
}
NGINX

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 5. certbot (Let's Encrypt TLS 인증서 — 자동 갱신 포함)
# ---------------------------------------------------------------------------
log "certbot 설치"
apt-get install -y certbot python3-certbot-nginx

log "TLS 인증서 발급 시도 ($DOMAIN)"
echo "    주의: 이 단계는 $DOMAIN 의 DNS A레코드가 이 EC2를 가리킬 때만 성공합니다."
if [ -n "$CERTBOT_EMAIL" ]; then
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect \
    || echo "    경고: certbot 발급 실패 — DNS 전파/도메인 설정 확인 후 수동 실행하세요" >&2
else
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    --register-unsafely-without-email --redirect \
    || echo "    경고: certbot 발급 실패 — DNS 전파/도메인 설정 확인 후 수동 실행하세요" >&2
fi

# certbot.timer가 자동 갱신을 담당 (설치 시 기본 활성)
systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. moly-infra clone (compose + deploy.sh)
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
 EC2 부트스트랩 완료.
------------------------------------------------------------
 다음 단계:
   1) ECR에 moly-backend:latest 이미지가 있는지 확인
      (없으면 moly-backend 레포의 GitHub Actions를 먼저 돌려 push)
   2) 첫 배포 실행:
        cd $INFRA_DIR && bash deploy.sh
   3) curl https://$DOMAIN/health 로 200 확인

 확인 명령:
   docker compose -f $INFRA_DIR/docker-compose.yml ps
   systemctl status nginx
   ls /etc/letsencrypt/live/$DOMAIN/

 IAM 인스턴스 역할(moly-voice-ec2-role)에 다음 권한이 있어야 함:
   - SSM (Session Manager / Run Command 수신)
   - ssm:GetParameter* (/moly/prod/* 경로)
   - kms:Decrypt (SecureString 복호화)
   - ECR pull (ecr:GetAuthorizationToken + BatchGetImage 등)  ← 빠지면 배포 실패
============================================================
DONE