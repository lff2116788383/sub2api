#!/usr/bin/env bash
set -euo pipefail

# =========================
# 可修改配置
# =========================
REPO_URL="https://github.com/lff2116788383/sub2api.git"
BRANCH="main"
APP_DIR="/opt/sub2api"
DEPLOY_DIR="${APP_DIR}/deploy"

# 镜像与运行配置
IMAGE_NAME="weishaw/sub2api:latest"
BIND_HOST="127.0.0.1"
SERVER_PORT="8088"
TZ="Asia/Shanghai"
RUN_MODE="standard"
SERVER_MODE="release"

# 域名 / 反向代理配置（写死）
DOMAIN="sub.tbco1a.top"
ENABLE_CADDY="true"

# 管理员配置
ADMIN_EMAIL="admin@sub2api.local"
ADMIN_PASSWORD=""

# 数据库与缓存配置
POSTGRES_USER="sub2api"
POSTGRES_PASSWORD=""
POSTGRES_DB="sub2api"
REDIS_PASSWORD=""
REDIS_DB="0"

# 安全密钥（留空会自动生成）
JWT_SECRET=""
TOTP_ENCRYPTION_KEY=""

# 可选 OAuth / 网络配置
GEMINI_OAUTH_CLIENT_ID=""
GEMINI_OAUTH_CLIENT_SECRET=""
GEMINI_CLI_OAUTH_CLIENT_SECRET=""
ANTIGRAVITY_OAUTH_CLIENT_SECRET=""
UPDATE_PROXY_URL=""

# 是否启动后跟随日志
FOLLOW_LOGS="false"

# =========================
# 输出辅助
# =========================
log() {
  echo "[deploy] $1"
}

warn() {
  echo "[warn] $1"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行此脚本"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

generate_secret() {
  openssl rand -hex 32
}

install_base_deps() {
  log "安装基础依赖"
  apt update
  apt install -y curl git ca-certificates gnupg lsb-release openssl ufw
}

install_caddy() {
  if command_exists caddy; then
    log "检测到 Caddy 已安装: $(caddy version)"
    systemctl enable --now caddy >/dev/null 2>&1 || true
    return
  fi

  log "安装 Caddy"
  apt install -y debian-keyring debian-archive-keyring apt-transport-https
  install -m 0755 -d /etc/apt/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt update
  apt install -y caddy
  systemctl enable --now caddy
  log "Caddy 安装完成: $(caddy version)"
}

install_docker() {
  if command_exists docker; then
    log "检测到 Docker 已安装: $(docker --version)"
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    log "安装 Docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    . /etc/os-release
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker 安装完成: $(docker --version)"
  fi

  if docker compose version >/dev/null 2>&1; then
    log "检测到 Docker Compose 插件: $(docker compose version | head -n 1)"
  else
    log "安装 Docker Compose 插件"
    apt update
    apt install -y docker-compose-plugin
  fi
}

prepare_app_dir() {
  log "准备应用目录: $APP_DIR"
  mkdir -p "$APP_DIR"

  if [ ! -d "$APP_DIR/.git" ]; then
    log "首次克隆仓库"
    git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
  else
    log "仓库已存在，拉取最新代码"
    git -C "$APP_DIR" fetch origin
    git -C "$APP_DIR" checkout "$BRANCH"
    git -C "$APP_DIR" pull origin "$BRANCH"
  fi
}

validate_env() {
  log "校验部署参数"

  [ -n "$REPO_URL" ] || { echo "REPO_URL 不能为空"; exit 1; }
  [ -n "$BRANCH" ] || { echo "BRANCH 不能为空"; exit 1; }
  [ -n "$APP_DIR" ] || { echo "APP_DIR 不能为空"; exit 1; }
  [ -n "$DEPLOY_DIR" ] || { echo "DEPLOY_DIR 不能为空"; exit 1; }
  [ -n "$IMAGE_NAME" ] || { echo "IMAGE_NAME 不能为空"; exit 1; }
  [ -n "$BIND_HOST" ] || { echo "BIND_HOST 不能为空"; exit 1; }
  [ -n "$SERVER_PORT" ] || { echo "SERVER_PORT 不能为空"; exit 1; }
  [ -n "$POSTGRES_USER" ] || { echo "POSTGRES_USER 不能为空"; exit 1; }
  [ -n "$POSTGRES_DB" ] || { echo "POSTGRES_DB 不能为空"; exit 1; }
  if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
    echo "SERVER_PORT 必须是 1-65535 之间的数字"
    exit 1
  fi

  if [ -n "$ADMIN_EMAIL" ] && ! [[ "$ADMIN_EMAIL" == *@*.* ]]; then
    echo "ADMIN_EMAIL 必须是邮箱格式，例如 admin@sub2api.local"
    exit 1
  fi
}

configure_firewall() {
  log "放行 HTTP/HTTPS 端口"
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
}

write_caddyfile() {
  if [ "$ENABLE_CADDY" != "true" ]; then
    log "已禁用 Caddy 配置写入"
    return
  fi

  log "写入 Caddy 反向代理配置: $DOMAIN -> 127.0.0.1:$SERVER_PORT"
  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    reverse_proxy 127.0.0.1:${SERVER_PORT}
}
EOF

  caddy fmt --overwrite /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy
}

ensure_required_secrets() {
  if [ -z "$POSTGRES_PASSWORD" ]; then
    log "未设置 POSTGRES_PASSWORD，自动生成"
    POSTGRES_PASSWORD="$(generate_secret)"
  fi

  if [ -z "$JWT_SECRET" ]; then
    log "未设置 JWT_SECRET，自动生成"
    JWT_SECRET="$(generate_secret)"
  fi

  if [ -z "$TOTP_ENCRYPTION_KEY" ]; then
    log "未设置 TOTP_ENCRYPTION_KEY，自动生成"
    TOTP_ENCRYPTION_KEY="$(generate_secret)"
  fi
}

prepare_runtime_files() {
  log "准备 Docker 部署目录"
  mkdir -p "$DEPLOY_DIR"
  cd "$DEPLOY_DIR"

  cp -f docker-compose.local.yml docker-compose.yml
  mkdir -p data postgres_data redis_data
}

write_env_file() {
  log "生成部署环境文件: $DEPLOY_DIR/.env"
  cat > "$DEPLOY_DIR/.env" <<EOF
BIND_HOST=${BIND_HOST}
SERVER_PORT=${SERVER_PORT}
SERVER_MODE=${SERVER_MODE}
RUN_MODE=${RUN_MODE}
TZ=${TZ}
IMAGE_NAME=${IMAGE_NAME}

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}

ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}

GEMINI_OAUTH_CLIENT_ID=${GEMINI_OAUTH_CLIENT_ID}
GEMINI_OAUTH_CLIENT_SECRET=${GEMINI_OAUTH_CLIENT_SECRET}
GEMINI_CLI_OAUTH_CLIENT_SECRET=${GEMINI_CLI_OAUTH_CLIENT_SECRET}
ANTIGRAVITY_OAUTH_CLIENT_SECRET=${ANTIGRAVITY_OAUTH_CLIENT_SECRET}
UPDATE_PROXY_URL=${UPDATE_PROXY_URL}
EOF
  chmod 600 "$DEPLOY_DIR/.env"
}

start_services() {
  log "拉取并启动容器"
  cd "$DEPLOY_DIR"
  docker compose pull
  docker compose up -d
}

show_summary() {
  echo
  log "部署完成"
  echo "应用目录: $APP_DIR"
  echo "部署目录: $DEPLOY_DIR"
  if [ "$ENABLE_CADDY" = "true" ]; then
    echo "访问地址: https://${DOMAIN}"
    echo "本机回源: http://${BIND_HOST}:${SERVER_PORT}"
  elif [ "$BIND_HOST" = "0.0.0.0" ]; then
    echo "访问地址: http://服务器公网IP:${SERVER_PORT}"
  else
    echo "访问地址: http://${BIND_HOST}:${SERVER_PORT}"
  fi
  echo
  echo "重要凭据："
  echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
  echo "JWT_SECRET=${JWT_SECRET}"
  echo "TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}"
  if [ -n "$ADMIN_PASSWORD" ]; then
    echo "ADMIN_EMAIL=${ADMIN_EMAIL}"
    echo "ADMIN_PASSWORD=${ADMIN_PASSWORD}"
  else
    warn "ADMIN_PASSWORD 为空，Sub2API 首次启动时会自动生成管理员密码，请通过日志查看。"
  fi
  echo
  echo "常用命令："
  echo "cd ${DEPLOY_DIR} && docker compose ps"
  echo "cd ${DEPLOY_DIR} && docker compose logs -f sub2api"
  echo "cd ${DEPLOY_DIR} && docker compose restart sub2api"
  echo "cd ${DEPLOY_DIR} && docker compose down"
}

follow_logs_if_needed() {
  if [ "$FOLLOW_LOGS" = "true" ]; then
    log "跟随查看 sub2api 日志"
    cd "$DEPLOY_DIR"
    docker compose logs -f sub2api
  fi
}

main() {
  require_root
  validate_env
  install_base_deps
  install_docker
  install_caddy
  prepare_app_dir
  ensure_required_secrets
  prepare_runtime_files
  write_env_file
  start_services
  configure_firewall
  write_caddyfile
  show_summary
  follow_logs_if_needed
}

main "$@"
