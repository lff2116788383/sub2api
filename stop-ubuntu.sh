#!/usr/bin/env bash
set -euo pipefail

# =========================
# 可修改配置
# =========================
APP_DIR="/opt/sub2api"
DEPLOY_DIR="${APP_DIR}/deploy"

# 停止模式：
# false：仅停止并移除容器/网络，保留 data、postgres_data、redis_data、.env 与 Caddy 配置
# true ：同时删除本地数据目录、.env 与 Caddy 配置，危险操作
PURGE_DATA="false"

# 域名 / 反向代理配置（与部署脚本保持一致）
DOMAIN="sub.tbco1a.top"
ENABLE_CADDY="true"

log() {
  echo "[stop] $1"
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

ensure_deploy_dir() {
  if [ ! -d "$DEPLOY_DIR" ]; then
    log "部署目录不存在，跳过停止: $DEPLOY_DIR"
    exit 0
  fi

  if [ ! -f "$DEPLOY_DIR/docker-compose.yml" ] && [ ! -f "$DEPLOY_DIR/docker-compose.local.yml" ]; then
    log "未找到 Docker Compose 文件，跳过停止: $DEPLOY_DIR"
    exit 0
  fi
}

compose_file_args() {
  if [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
    echo "-f docker-compose.yml"
  else
    echo "-f docker-compose.local.yml"
  fi
}

stop_services() {
  if ! command_exists docker; then
    log "未检测到 Docker，跳过容器停止"
    return
  fi

  log "停止 Sub2API Docker Compose 服务"
  cd "$DEPLOY_DIR"
  docker compose $(compose_file_args) down --remove-orphans
}

remove_caddy_if_needed() {
  if [ "$ENABLE_CADDY" != "true" ]; then
    return
  fi

  if [ ! -f /etc/caddy/Caddyfile ]; then
    return
  fi

  log "移除 Caddy 中的 Sub2API 域名配置: $DOMAIN"
  cat > /etc/caddy/Caddyfile <<EOF
{
    auto_https disable_redirects
}
EOF

  caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  systemctl reload caddy >/dev/null 2>&1 || true
}

purge_data_if_needed() {
  if [ "$PURGE_DATA" != "true" ]; then
    log "已保留数据与配置目录"
    echo "保留内容："
    echo "  $DEPLOY_DIR/.env"
    echo "  $DEPLOY_DIR/data"
    echo "  $DEPLOY_DIR/postgres_data"
    echo "  $DEPLOY_DIR/redis_data"
    if [ "$ENABLE_CADDY" = "true" ]; then
      echo "  /etc/caddy/Caddyfile"
    fi
    return
  fi

  warn "PURGE_DATA=true，将删除 Sub2API 本地数据与配置"
  rm -rf "$DEPLOY_DIR/data" "$DEPLOY_DIR/postgres_data" "$DEPLOY_DIR/redis_data"
  rm -f "$DEPLOY_DIR/.env"
  remove_caddy_if_needed
  log "本地数据、.env 与相关 Caddy 配置已删除"
}

print_summary() {
  echo
  log "停止完成"
  echo "部署目录: $DEPLOY_DIR"
  echo
  echo "常用后续命令："
  echo "重新启动: cd ${DEPLOY_DIR} && docker compose up -d"
  echo "查看状态: cd ${DEPLOY_DIR} && docker compose ps"
  echo "查看日志: cd ${DEPLOY_DIR} && docker compose logs -f sub2api"
  echo
  echo "如需彻底删除数据，请先确认已备份，再把脚本中的 PURGE_DATA 改为 true 后重新运行。"
  if [ "$ENABLE_CADDY" = "true" ]; then
    echo "如需重新启用域名访问，请重新执行 [`deploy-ubuntu.sh`](sub2api/deploy-ubuntu.sh:1) 以恢复 Caddy 配置。"
  fi
}

main() {
  require_root
  ensure_deploy_dir
  stop_services
  purge_data_if_needed
  print_summary
}

main "$@"
