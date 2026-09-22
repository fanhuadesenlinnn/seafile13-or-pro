#!/usr/bin/env bash
# Seafile Pro 13 single-host deployment. Bash 3.2+, Docker Compose v2.
# Usage: SEAFILE_SERVER_HOSTNAME=192.168.1.108 bash init-seafile13pro.sh ./seafile-pro
# Generate only: GENERATE_ONLY=1 bash init-seafile13pro.sh ./seafile-pro
# Existing deployment: edit its .env, then run this command again; passwords survive.
set -euo pipefail
umask 077
# ==================== 用户配置区 ====================
# 修改下方默认值即可；同名环境变量优先于这里的默认值。
# 已有部署的地址、凭据、镜像等以部署目录 .env 为准，请直接修改 .env。
# 密码和 JWT 密钥首次部署自动随机生成，不要在脚本中写固定密码。

# 部署目录（命令行第一个参数优先）；不影响现有目录中的数据。
DEPLOY_DIR="${DEPLOY_DIR:-./seafile13-pro}"
# Seafile 对外主地址（canonical URL）。公网 HTTPS 在 VPS/OpenResty 终止。
# 只填域名或 IPv4，不带协议和端口。
SEAFILE_SERVER_HOSTNAME="${SEAFILE_SERVER_HOSTNAME-seafile13pro.babadafafafafa.cn}"
SEAFILE_SERVER_PROTOCOL="${SEAFILE_SERVER_PROTOCOL:-https}"  # http / https
# 1=外部反向代理/TLS 终止模式：内层 Caddy 保持 HTTP，允许“内网 IP:端口 + 公网域名”同时访问。
# 0=保持原来的 Caddy 直出模式（HTTP 默认 28080；HTTPS 默认 443，并由 Caddy 处理证书）。
EXTERNAL_REVERSE_PROXY="${EXTERNAL_REVERSE_PROXY:-1}"
# 外部反代模式下默认宿主机 28080 → 容器 80；留空即可使用该默认值。
# Caddy 直出模式下继续保持原逻辑：http 默认 28080，https 默认 443。
CADDY_HOST_PORT="${CADDY_HOST_PORT:-}"
CADDY_CONTAINER_PORT="${CADDY_CONTAINER_PORT:-}"
# Caddy 站点可包含多个地址；这里同时接受局域网 IP 和公网域名，但内层链路均使用 HTTP。
CADDY_SITE="${CADDY_SITE:-http://192.168.123.182, http://seafile13pro.babadafafafafa.cn}"
# Caddy 多站点地址要求逗号后有空格；同时自动修复上一版脚本产生的“地址1,地址2”格式。
CADDY_SITE="$(printf '%s' "$CADDY_SITE" | sed 's/,[[:space:]]*/, /g')"
# FRP 在本机回连 Caddy 时保留 VPS 传来的 X-Forwarded-*。按实际 frpc 来源地址可覆盖此值。
CADDY_TRUSTED_PROXIES="${CADDY_TRUSTED_PROXIES:-127.0.0.1/8 192.168.123.182/32}"
TIME_ZONE="${TIME_ZONE:-Asia/Shanghai}"
INIT_SEAFILE_ADMIN_EMAIL="${INIT_SEAFILE_ADMIN_EMAIL:-fanhuadesenlinnn@gmail.com}"

# 镜像代理不带 https://；留空表示直连。
IMAGE_PREFIX="${IMAGE_PREFIX-hubproxy.babadafafafafa.cn}"
# 容器名称前缀；留空保留原名称。多实例需分别设置前缀和端口。
CONTAINER_PREFIX="${CONTAINER_PREFIX-seafile13pro}"
# 留空自动选择：本机有 pg-docker 则使用它，否则使用 docker。
DOCKER_COMMAND="${DOCKER_COMMAND:-pg-docker}"
# 留空使用上面命令 + compose；也可填 pg-docker-compose 等独立命令。
DOCKER_COMPOSE_COMMAND="${DOCKER_COMPOSE_COMMAND:-pg-docker compose}"
# 留空自动检测，必须与 Docker 命令使用的 daemon 一致。
DOCKER_SOCKET="${DOCKER_SOCKET:-}"

# 镜像名称（会统一加上 IMAGE_PREFIX；使用完整仓库地址时请将代理设为空）。
SEAFILE_IMAGE="${SEAFILE_IMAGE:-seafileltd/seafile-pro-mc:13.0-latest}"
SEAFILE_DB_IMAGE="${SEAFILE_DB_IMAGE:-mariadb:10.11}"
SEAFILE_REDIS_IMAGE="${SEAFILE_REDIS_IMAGE:-redis:7-alpine}"
SEAFILE_CADDY_IMAGE="${SEAFILE_CADDY_IMAGE:-lucaslorentz/caddy-docker-proxy:2.12-alpine}"
SEADOC_IMAGE="${SEADOC_IMAGE:-seafileltd/sdoc-server:2.0-latest}"
ONLYOFFICE_IMAGE="${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:8.1.0.1}"
MD_IMAGE="${MD_IMAGE:-seafileltd/seafile-md-server:13.0-latest}"
NOTIFICATION_SERVER_IMAGE="${NOTIFICATION_SERVER_IMAGE:-seafileltd/notification-server:13.0-latest}"
# 留空按架构选择 seasearch:1.0-latest；ARM 使用 seasearch-nomkl:1.0-latest。
SEASEARCH_IMAGE="${SEASEARCH_IMAGE:-}"

GENERATE_ONLY="${GENERATE_ONLY:-0}"  # 1=仅生成文件，0=生成并部署
export PULL="${PULL:-0}"             # 1=部署前拉取镜像，0=优先复用本地镜像
export DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-600}"  # 启动等待时间（秒）
export VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"  # 每项验收等待时间（秒）
# ==================== 配置区结束 ====================
# 下方为部署逻辑，一般不需要修改。
CONTAINER_PREFIX="${CONTAINER_PREFIX%-}"
[[ -z "$CONTAINER_PREFIX" || "$CONTAINER_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo '容器名称前缀只能包含字母、数字、下划线、点和连字符，且以字母或数字开头' >&2; exit 2; }
if command -v pg-docker >/dev/null; then DEFAULT_DOCKER=pg-docker; else DEFAULT_DOCKER=docker; fi
DOCKER_COMMAND="${DOCKER_COMMAND:-$DEFAULT_DOCKER}"
DOCKER_COMPOSE_COMMAND="${DOCKER_COMPOSE_COMMAND:-$DOCKER_COMMAND compose}"
# Accept executable names / paths and plain command arguments, never shell fragments.
[[ "$DOCKER_COMMAND" =~ ^[A-Za-z0-9_./-]+$ && "$DOCKER_COMPOSE_COMMAND" =~ ^[A-Za-z0-9_./\ -]+$ ]] || { echo 'Docker 命令包含不支持的字符' >&2; exit 2; }
if [[ -z "${DOCKER_SOCKET:-}" ]]; then
  case "${DOCKER_COMMAND##*/}" in
    pg-docker) DOCKER_SOCKET=/lzcsys/data/playground/docker.sock ;;
    lzc-docker) echo '请显式设置 DOCKER_SOCKET 为 lzc-docker 对应的 socket' >&2; exit 2 ;;
    *)
      endpoint="${DOCKER_HOST:-}"
      if [[ -z "$endpoint" ]] && command -v "$DOCKER_COMMAND" >/dev/null; then
        endpoint="$("$DOCKER_COMMAND" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
      fi
      endpoint="${endpoint:-unix:///var/run/docker.sock}"
      [[ "$endpoint" == unix:///* ]] || { echo '远程 Docker 请显式设置服务端 DOCKER_SOCKET 路径' >&2; exit 2; }
      DOCKER_SOCKET="${endpoint#unix://}" ;;
  esac
fi
[[ "$DOCKER_SOCKET" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo '无效 DOCKER_SOCKET 路径' >&2; exit 2; }
# 自定义命令示例：DOCKER_COMMAND=pg-docker，DOCKER_COMPOSE_COMMAND=pg-docker-compose。
# 命令需要能在 Bash 脚本中直接执行（例如 PATH 中的可执行文件）。
IMAGE_PREFIX="${IMAGE_PREFIX%/}"
[[ -z "$IMAGE_PREFIX" ]] || IMAGE_PREFIX="$IMAGE_PREFIX/"
TARGET="${1:-$DEPLOY_DIR}"
[[ $# -le 1 ]] || { echo '用法: bash init-seafile13pro.sh [部署目录]' >&2; exit 2; }
command -v openssl >/dev/null || { echo '需要 openssl' >&2; exit 1; }
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
# Preserve the original configuration before regenerating managed files.
if [[ -f "$TARGET/.env" ]]; then
  BACKUP="$TARGET/config-backups/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$BACKUP"
  for file in .env docker-compose.yml post-init.sh configure.py verify.py verify.sh deploy.sh README.txt; do
    [[ ! -f "$TARGET/$file" ]] || cp -p "$TARGET/$file" "$BACKUP/"
  done
  echo "保留现有 .env 和全部凭据；配置备份: $BACKUP"
else
  if [[ -d "$TARGET/data/mysql/mysql" || -d "$TARGET/data/seafile/seafile/seafile-data" ]]; then
    echo '发现现有数据但缺少 .env；请恢复原 .env，不能生成新密码。' >&2
    exit 1
  fi
  detect_host() {
    local detected=""
    if [[ "$(uname -s)" == Darwin ]]; then
      detected="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    elif command -v ip >/dev/null; then
      detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi
    printf '%s' "${detected:-127.0.0.1}"
  }
  PROTOCOL="${SEAFILE_SERVER_PROTOCOL:-http}"
  [[ "$PROTOCOL" == http || "$PROTOCOL" == https ]] || { echo '协议必须是 http 或 https' >&2; exit 2; }
  [[ "$EXTERNAL_REVERSE_PROXY" == 0 || "$EXTERNAL_REVERSE_PROXY" == 1 ]] || { echo 'EXTERNAL_REVERSE_PROXY 只能是 0 或 1' >&2; exit 2; }
  SRV_HOST="${SEAFILE_SERVER_HOSTNAME:-$(detect_host)}"
  # Deliberately require a bare IPv4/DNS hostname; do not silently discard URL parts.
  [[ "$SRV_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'SEAFILE_SERVER_HOSTNAME 请只填域名或 IPv4' >&2; exit 2; }
  if [[ "$EXTERNAL_REVERSE_PROXY" == 1 ]]; then
    PORT="${CADDY_HOST_PORT:-28080}"
    CADDY_PORT="${CADDY_CONTAINER_PORT:-80}"
    CADDY_SITE_VALUE="${CADDY_SITE:-http://$SRV_HOST}"
    SEAFILE_HOSTNAME="$SRV_HOST"
  else
    DEFAULT_PORT=28080
    [[ "$PROTOCOL" != https ]] || DEFAULT_PORT=443
    PORT="${CADDY_HOST_PORT:-$DEFAULT_PORT}"
    CADDY_PORT="${CADDY_CONTAINER_PORT:-}"
    [[ -n "$CADDY_PORT" ]] || { if [[ "$PROTOCOL" == https ]]; then CADDY_PORT=443; else CADDY_PORT=80; fi; }
    CADDY_SITE_VALUE="$PROTOCOL://$SRV_HOST"
    SEAFILE_HOSTNAME="$SRV_HOST:$PORT"
    if [[ "$PROTOCOL:$PORT" == http:80 || "$PROTOCOL:$PORT" == https:443 ]]; then SEAFILE_HOSTNAME="$SRV_HOST"; fi
  fi
  [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ && "$PORT" -le 65535 ]] || { echo 'CADDY_HOST_PORT 必须是 1–65535，不带前导零' >&2; exit 2; }
  [[ "$CADDY_PORT" =~ ^[1-9][0-9]{0,4}$ && "$CADDY_PORT" -le 65535 ]] || { echo 'CADDY_CONTAINER_PORT 必须是 1–65535，不带前导零' >&2; exit 2; }
  [[ -n "$CADDY_SITE_VALUE" ]] || { echo 'CADDY_SITE 不能为空' >&2; exit 2; }
  ADMIN_EMAIL="${INIT_SEAFILE_ADMIN_EMAIL:-admin@example.com}"
  TZ_VALUE="${TIME_ZONE:-Asia/Shanghai}"
  [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9_.+@-]+$ && "$TZ_VALUE" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo '邮箱或时区格式错误' >&2; exit 2; }
  rand() { openssl rand -hex 24; }
  ADMIN_PW="$(rand)"
  SS_USER=seasearch-admin
  SS_PW="$(rand)"
  SS_TOKEN="$(printf '%s' "$SS_USER:$SS_PW" | base64 | tr -d '\r\n')"
  SS_IMAGE=seafileltd/seasearch:1.0-latest
  if [[ "$(uname -m)" == arm64 || "$(uname -m)" == aarch64 ]]; then SS_IMAGE=seafileltd/seasearch-nomkl:1.0-latest; fi
  SS_IMAGE="${SEASEARCH_IMAGE:-$SS_IMAGE}"
  cat > "$TARGET/.env" <<EOF
SEAFILE_SERVER_HOSTNAME=$SEAFILE_HOSTNAME
SEAFILE_SERVER_PROTOCOL=$PROTOCOL
EXTERNAL_REVERSE_PROXY=$EXTERNAL_REVERSE_PROXY
CADDY_HOST_PORT=$PORT
CADDY_CONTAINER_PORT=$CADDY_PORT
CADDY_SITE=$CADDY_SITE_VALUE
CADDY_TRUSTED_PROXIES=$CADDY_TRUSTED_PROXIES
TIME_ZONE=$TZ_VALUE
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$(rand)
SEAFILE_MYSQL_DB_PASSWORD=$(rand)
REDIS_PASSWORD=$(rand)
INIT_SEAFILE_ADMIN_EMAIL=$ADMIN_EMAIL
INIT_SEAFILE_ADMIN_PASSWORD=$ADMIN_PW
INIT_SS_ADMIN_USER=$SS_USER
INIT_SS_ADMIN_PASSWORD=$SS_PW
SEASEARCH_TOKEN=$SS_TOKEN
JWT_PRIVATE_KEY=$(rand)
ONLYOFFICE_JWT_SECRET=$(rand)
SEAFILE_IMAGE=$SEAFILE_IMAGE
SEAFILE_DB_IMAGE=$SEAFILE_DB_IMAGE
SEAFILE_REDIS_IMAGE=$SEAFILE_REDIS_IMAGE
SEAFILE_CADDY_IMAGE=$SEAFILE_CADDY_IMAGE
MD_IMAGE=$MD_IMAGE
NOTIFICATION_SERVER_IMAGE=$NOTIFICATION_SERVER_IMAGE
SEASEARCH_IMAGE=$SS_IMAGE
SEADOC_IMAGE=$SEADOC_IMAGE
SEADOC_VOLUME=./data/seadoc
# Docker selects the native platform; keep existing local images during repair.
ONLYOFFICE_IMAGE=$ONLYOFFICE_IMAGE
EOF
fi
# Read only simple generated keys; do not execute .env as shell code.
value() { awk -v key="$1" 'index($0,key"=")==1 {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$TARGET/.env"; }
set_value() {
  local key="$1" val="$2" tmp="$TARGET/.env.tmp.$$"
  awk -v key="$key" -v val="$val" '
    BEGIN { found=0 }
    index($0,key"=")==1 { print key"="val; found=1; next }
    { print }
    END { if (!found) print key"="val }
  ' "$TARGET/.env" > "$tmp"
  mv "$tmp" "$TARGET/.env"
}
# 外部反代模式只更新地址/入口相关键；已有密码、JWT、镜像及数据配置保持不变。
if [[ "$EXTERNAL_REVERSE_PROXY" == 1 ]]; then
  set_value SEAFILE_SERVER_HOSTNAME "$SEAFILE_SERVER_HOSTNAME"
  set_value SEAFILE_SERVER_PROTOCOL "$SEAFILE_SERVER_PROTOCOL"
  set_value EXTERNAL_REVERSE_PROXY "1"
  set_value CADDY_HOST_PORT "${CADDY_HOST_PORT:-28080}"
  set_value CADDY_CONTAINER_PORT "${CADDY_CONTAINER_PORT:-80}"
  set_value CADDY_SITE "$CADDY_SITE"
  set_value CADDY_TRUSTED_PROXIES "$CADDY_TRUSTED_PROXIES"
else
  # 兼容旧版脚本生成的 .env：补齐新增键，但不改原地址、端口、凭据和镜像配置。
  if ! grep -q '^EXTERNAL_REVERSE_PROXY=' "$TARGET/.env"; then set_value EXTERNAL_REVERSE_PROXY "0"; fi
  if ! grep -q '^CADDY_CONTAINER_PORT=' "$TARGET/.env"; then
    old_protocol="$(value SEAFILE_SERVER_PROTOCOL)"
    if [[ "$old_protocol" == https ]]; then set_value CADDY_CONTAINER_PORT "443"; else set_value CADDY_CONTAINER_PORT "80"; fi
  fi
  if ! grep -q '^CADDY_TRUSTED_PROXIES=' "$TARGET/.env"; then set_value CADDY_TRUSTED_PROXIES "$CADDY_TRUSTED_PROXIES"; fi
fi
PROTOCOL="$(value SEAFILE_SERVER_PROTOCOL)"
PORT="$(value CADDY_HOST_PORT)"
CADDY_PORT="$(value CADDY_CONTAINER_PORT)"
CADDY_SITE_VALUE="$(value CADDY_SITE)"
MODE="$(value EXTERNAL_REVERSE_PROXY)"
MODE="${MODE:-0}"
SEAFILE_HOSTNAME="$(value SEAFILE_SERVER_HOSTNAME)"
[[ "$PROTOCOL" == http || "$PROTOCOL" == https ]] || { echo '无效协议' >&2; exit 2; }
[[ "$MODE" == 0 || "$MODE" == 1 ]] || { echo '无效 EXTERNAL_REVERSE_PROXY' >&2; exit 2; }
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ && "$PORT" -le 65535 ]] || { echo '无效 CADDY_HOST_PORT' >&2; exit 2; }
[[ "$CADDY_PORT" =~ ^[1-9][0-9]{0,4}$ && "$CADDY_PORT" -le 65535 ]] || { echo '无效 CADDY_CONTAINER_PORT' >&2; exit 2; }
[[ "$SEAFILE_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$ ]] || { echo '无效主机名' >&2; exit 2; }
[[ -n "$CADDY_SITE_VALUE" ]] || { echo 'CADDY_SITE 不能为空' >&2; exit 2; }
SRV_HOST="${SEAFILE_HOSTNAME%%:*}"
if [[ "$MODE" == 0 ]]; then
  EXPECTED="$SRV_HOST:$PORT"
  if [[ "$PROTOCOL:$PORT" == http:80 || "$PROTOCOL:$PORT" == https:443 ]]; then EXPECTED="$SRV_HOST"; fi
  [[ "$SEAFILE_HOSTNAME" == "$EXPECTED" ]] || { echo 'Caddy 直出模式下，请让 SEAFILE_SERVER_HOSTNAME 的端口与 CADDY_HOST_PORT 保持一致' >&2; exit 2; }
  [[ "$CADDY_SITE_VALUE" == "$PROTOCOL://$SRV_HOST" ]] || { echo 'Caddy 直出模式下，CADDY_SITE 应为协议://主机，不带端口' >&2; exit 2; }
  if [[ "$PROTOCOL" == https && ( "$SRV_HOST" == localhost || "$SRV_HOST" =~ ^[0-9.]+$ ) ]]; then
    echo '自动 HTTPS 模式需要有效域名，DNS 指向本机，并开放公网 80/443；局域网 IP 请用 http。' >&2; exit 2
  fi
fi
for key in INIT_SEAFILE_MYSQL_ROOT_PASSWORD SEAFILE_MYSQL_DB_PASSWORD REDIS_PASSWORD INIT_SEAFILE_ADMIN_EMAIL INIT_SEAFILE_ADMIN_PASSWORD INIT_SS_ADMIN_USER INIT_SS_ADMIN_PASSWORD SEASEARCH_TOKEN JWT_PRIVATE_KEY ONLYOFFICE_JWT_SECRET; do
  [[ -n "$(value "$key")" ]] || { echo "缺少 .env 配置: $key" >&2; exit 2; }
done
# Migrate older generated environments without replacing any existing credentials.
if ! grep -q '^DOCKER_SOCKET=' "$TARGET/.env"; then
  printf '\nDOCKER_SOCKET=%s\n' "$DOCKER_SOCKET" >> "$TARGET/.env"
fi
if ! grep -q '^COMPOSE_PROJECT_NAME=' "$TARGET/.env"; then
  PROJECT_NAME="${CONTAINER_PREFIX:-seafile13pro}"
  # Older versions used a literal project name. Keep managing the same project.
  if [[ -f "$TARGET/docker-compose.yml" ]]; then
    old_project="$(awk '/^name: [a-z0-9][a-z0-9_-]*$/ { print $2; exit }' "$TARGET/docker-compose.yml")"
    PROJECT_NAME="${old_project:-$PROJECT_NAME}"
  fi
  PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:].' '[:lower:]_')"
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT_NAME" >> "$TARGET/.env"
fi
chmod 600 "$TARGET/.env"

cat > "$TARGET/docker-compose.yml" <<'YAML'
name: ${COMPOSE_PROJECT_NAME:-seafile13pro}

services:
  db:
    image: ${SEAFILE_DB_IMAGE:-mariadb:10.11}
    container_name: seafile-mysql
    restart: unless-stopped
    command: --lower-case-table-names=1
    environment:
      MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      MYSQL_LOG_CONSOLE: "true"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - ./data/mysql:/var/lib/mysql
    networks:
      - seafile-net
    healthcheck:
      test:
        [
          "CMD",
          "/usr/local/bin/healthcheck.sh",
          "--connect",
          "--mariadbupgrade",
          "--innodb_initialized",
        ]
      interval: 20s
      start_period: 30s
      timeout: 5s
      retries: 10

  redis:
    image: ${SEAFILE_REDIS_IMAGE:-redis:7-alpine}
    container_name: seafile-redis
    healthcheck:
      test: ["CMD-SHELL", 'REDISCLI_AUTH="$$REDIS_PASSWORD" redis-cli ping | grep -qx PONG']
      interval: 5s
      timeout: 3s
      retries: 30
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command:
      - /bin/sh
      - -c
      - exec redis-server --requirepass "$$REDIS_PASSWORD" --save "" --appendonly no
    networks:
      - seafile-net

  seasearch:
    image: ${SEASEARCH_IMAGE:-seafileltd/seasearch:1.0-latest}
    container_name: seafile-seasearch
    restart: unless-stopped
    volumes:
      - ./data/seasearch:/opt/seasearch/data
    environment:
      SS_FIRST_ADMIN_USER: ${INIT_SS_ADMIN_USER}
      SS_FIRST_ADMIN_PASSWORD: ${INIT_SS_ADMIN_PASSWORD}
      SS_MAX_OBJ_CACHE_SIZE: ${SS_MAX_OBJ_CACHE_SIZE:-2GB}
      SS_STORAGE_TYPE: disk
      SS_LOG_TO_STDOUT: "true"
      SS_LOG_LEVEL: info
    networks:
      - seafile-net

  seafile:
    image: ${SEAFILE_IMAGE:-seafileltd/seafile-pro-mc:13.0-latest}
    container_name: seafile
    restart: unless-stopped
    volumes:
      - ./data/seafile:/shared
    environment:
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_PORT: "3306"
      SEAFILE_MYSQL_DB_USER: ${SEAFILE_MYSQL_DB_USER:-seafile}
      SEAFILE_MYSQL_DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      INIT_SEAFILE_MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      SEAFILE_MYSQL_DB_CCNET_DB_NAME: ccnet_db
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME: seafile_db
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME: seahub_db
      TIME_ZONE: ${TIME_ZONE:-Asia/Shanghai}
      SEAFILE_SERVER_HOSTNAME: ${SEAFILE_SERVER_HOSTNAME}
      SEAFILE_SERVER_PROTOCOL: ${SEAFILE_SERVER_PROTOCOL:-http}
      INIT_SEAFILE_ADMIN_EMAIL: ${INIT_SEAFILE_ADMIN_EMAIL}
      INIT_SEAFILE_ADMIN_PASSWORD: ${INIT_SEAFILE_ADMIN_PASSWORD}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
      ENABLE_GO_FILESERVER: "true"
      ENABLE_SEADOC: "true"
      SEADOC_SERVER_URL: ${SEAFILE_SERVER_PROTOCOL}://${SEAFILE_SERVER_HOSTNAME}/sdoc-server
      ONLYOFFICE_JWT_SECRET: ${ONLYOFFICE_JWT_SECRET}
      SEASEARCH_TOKEN: ${SEASEARCH_TOKEN}
      CACHE_PROVIDER: redis
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      ENABLE_NOTIFICATION_SERVER: "true"
      NOTIFICATION_SERVER_URL: ${SEAFILE_SERVER_PROTOCOL}://${SEAFILE_SERVER_HOSTNAME}/notification
      INNER_NOTIFICATION_SERVER_URL: http://notification-server:8083
      ENABLE_SEAFILE_AI: "false"
      ENABLE_FACE_RECOGNITION: "false"
    labels:
      caddy: "${CADDY_SITE}"
      caddy.reverse_proxy: "{{upstreams 80}}"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:80 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 8
      start_period: 90s
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      seasearch:
        condition: service_started
    networks:
      - seafile-net

  onlyoffice:
    image: ${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:8.1.0.1}
    container_name: seafile-onlyoffice
    restart: unless-stopped
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: ${ONLYOFFICE_JWT_SECRET}
      ALLOW_PRIVATE_IP_ADDRESS: "true"
    volumes:
      - ./data/onlyoffice/logs:/var/log/onlyoffice
      - ./data/onlyoffice/data:/var/www/onlyoffice/Data
      - ./data/onlyoffice/lib:/var/lib/onlyoffice
    labels:
      caddy: "${CADDY_SITE}"
      caddy.handle_path: "/onlyofficeds/*"
      caddy.handle_path.0_reverse_proxy: "{{upstreams 80}}"
      caddy.handle_path.0_reverse_proxy.header_up_1: "X-Forwarded-Host {http.request.hostport}/onlyofficeds"
      caddy.handle_path.0_reverse_proxy.header_up_2: "X-Forwarded-For {remote}"
    networks:
      - seafile-net

  seadoc:
    image: ${SEADOC_IMAGE:-seafileltd/sdoc-server:2.0-latest}
    container_name: seadoc
    restart: unless-stopped
    volumes:
      - ${SEADOC_VOLUME:-./data/seadoc}:/shared
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      DB_USER: ${SEAFILE_MYSQL_DB_USER:-seafile}
      DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      DB_NAME: seahub_db
      TIME_ZONE: ${TIME_ZONE:-Asia/Shanghai}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
      SEAHUB_SERVICE_URL: http://seafile
    labels:
      caddy: "${CADDY_SITE}"
      caddy.1_handle_path: "/socket.io/*"
      caddy.1_handle_path.0_rewrite: "* /socket.io{uri}"
      caddy.1_handle_path.1_reverse_proxy: "{{upstreams 80}}"
      caddy.2_handle_path: "/sdoc-server/*"
      caddy.2_handle_path.0_rewrite: "* {uri}"
      caddy.2_handle_path.1_reverse_proxy: "{{upstreams 80}}"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - seafile-net

  caddy:
    image: ${SEAFILE_CADDY_IMAGE:-lucaslorentz/caddy-docker-proxy:2.12-alpine}
    container_name: seafile-caddy
    restart: unless-stopped
    ports:
      - "${CADDY_HOST_PORT:-28080}:${CADDY_CONTAINER_PORT:-80}"
    environment:
      CADDY_INGRESS_NETWORKS: ${COMPOSE_PROJECT_NAME:-seafile13pro}_seafile-net
    labels:
      caddy: ""
      caddy.servers.trusted_proxies: "static ${CADDY_TRUSTED_PROXIES:-127.0.0.1/8 192.168.123.182/32}"
      caddy.servers.trusted_proxies_strict: ""
    volumes:
      - ${DOCKER_SOCKET:?Docker socket is required}:/var/run/docker.sock:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    networks:
      - seafile-net


  seafile-md-server:
    image: ${MD_IMAGE:-seafileltd/seafile-md-server:13.0-latest}
    container_name: seafile-md-server
    restart: unless-stopped
    volumes:
      - ./data/seafile:/shared
    environment:
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST:-db}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-false}
      - MD_PORT=${MD_PORT:-8084}
      - MD_LOG_LEVEL=${MD_LOG_LEVEL:-info}
      - MD_MAX_CACHE_SIZE=${MD_MAX_CACHE_SIZE:-1GB}
      - MD_CHECK_UPDATE_INTERVAL=${MD_CHECK_UPDATE_INTERVAL:-30m}
      - MD_FILE_COUNT_LIMIT=${MD_FILE_COUNT_LIMIT:-100000}
      - SEAF_SERVER_STORAGE_TYPE=${SEAF_SERVER_STORAGE_TYPE:-}
      - MD_STORAGE_TYPE=${MD_STORAGE_TYPE:-disk}
      - S3_COMMIT_BUCKET=${S3_COMMIT_BUCKET:-}
      - S3_FS_BUCKET=${S3_FS_BUCKET:-}
      - S3_BLOCK_BUCKET=${S3_BLOCK_BUCKET:-}
      - S3_MD_BUCKET=${S3_MD_BUCKET:-}
      - S3_HOST=${S3_HOST:-}
      - S3_AWS_REGION=${S3_AWS_REGION:-}
      - S3_USE_HTTPS=${S3_USE_HTTPS:-true}
      - S3_PATH_STYLE_REQUEST=${S3_PATH_STYLE_REQUEST:-false}
      - S3_KEY_ID=${S3_KEY_ID:-}
      - S3_SECRET_KEY=${S3_SECRET_KEY:-}
      - S3_USE_V4_SIGNATURE=${S3_USE_V4_SIGNATURE:-true}
      - S3_SSE_C_KEY=${S3_SSE_C_KEY:-}
      - MD_CEPH_CONFIG=${MD_CEPH_CONFIG:-}
      - MD_CEPH_POOL=${MD_CEPH_POOL:-}
      - MD_CEPH_CLIENT_ID=${MD_CEPH_CLIENT_ID:-}
      - CACHE_PROVIDER=${CACHE_PROVIDER:-redis}
      - REDIS_HOST=${REDIS_HOST:-redis}
      - REDIS_PORT=${REDIS_PORT:-6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
    depends_on:
      db:
        condition: service_healthy
      seafile:
        condition: service_healthy

    networks:
      - seafile-net



  notification-server:
    image: ${NOTIFICATION_SERVER_IMAGE:-seafileltd/notification-server:13.0-latest}
    container_name: notification-server
    restart: always
    volumes:
      - ./data/seafile/seafile/logs:/shared/seafile/logs
    environment:
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST:-db}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY:?Variable is not set or empty}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-false}
      - NOTIFICATION_SERVER_LOG_LEVEL=${NOTIFICATION_SERVER_LOG_LEVEL:-info}
    labels:
      caddy: "${CADDY_SITE}"
      caddy.3_handle_path: "/notification*"
      caddy.3_handle_path.0_rewrite: "* {uri}"
      caddy.3_handle_path.1_reverse_proxy: "{{upstreams 8083}}"
    depends_on:
      db:
        condition: service_healthy
      seafile:
        condition: service_healthy
    networks:
      - seafile-net

networks:
  seafile-net:
    name: ${COMPOSE_PROJECT_NAME:-seafile13pro}_seafile-net
YAML

if [[ "$MODE" == 0 && "$PROTOCOL" == https && "$CADDY_PORT" == 443 ]]; then
  # Caddy 直出 HTTPS 时额外暴露 80，供 ACME HTTP challenge 和 HTTP→HTTPS 重定向使用。
  awk '{print} /CADDY_HOST_PORT.*CADDY_CONTAINER_PORT/ {print "      - \"80:80\""}' "$TARGET/docker-compose.yml" > "$TARGET/docker-compose.yml.tmp"
  mv "$TARGET/docker-compose.yml.tmp" "$TARGET/docker-compose.yml"
fi

cat > "$TARGET/configure.py" <<'GENERATED_FILE'
"""Run inside Seafile; preserve user settings, replace only our managed block."""
import ast
import configparser
import io
import os
from pathlib import Path
import re
import shutil
import tempfile
import time

conf = Path('/shared/seafile/conf')
url = os.environ['SEAFILE_SERVER_PROTOCOL'] + '://' + os.environ['SEAFILE_SERVER_HOSTNAME']
def save(path, content):
    if path.read_text() == content:
        return
    shutil.copy2(path, str(path) + '.before-deploy-' + str(time.time_ns()))
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        st = path.stat()
        os.chmod(tmp, st.st_mode & 0o777)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

path = conf / 'seafevents.conf'
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.read_string(path.read_text())
for section, values in {
    'INDEX FILES': {'enabled': 'false'},
    'SEASEARCH': {'enabled': 'true', 'seasearch_url': 'http://seasearch:4080',
                  'seasearch_token': os.environ['SEASEARCH_TOKEN'], 'interval': '1m',
                  'index_office_pdf': 'true'},
}.items():
    if not cfg.has_section(section): cfg.add_section(section)
    for key, value in values.items(): cfg.set(section, key, value)
buf = io.StringIO(); cfg.write(buf)
# Check strict parsing before replacing a potentially damaged old file.
configparser.ConfigParser(interpolation=None).read_string(buf.getvalue())
save(path, buf.getvalue())
path = conf / 'seahub_settings.py'
text = re.sub(r'\n# BEGIN TEST_SH MANAGED\n.*?# END TEST_SH MANAGED\n?', '\n', path.read_text(), flags=re.S)
settings = {
    'ENABLE_WIKI': True,
    'ENABLE_SEADOC': True,
    'SEADOC_SERVER_URL': url + '/sdoc-server',
    'ENABLE_ONLYOFFICE': True,
    'ONLYOFFICE_APIJS_URL': url + '/onlyofficeds/web-apps/apps/api/documents/api.js',
    'ONLYOFFICE_JWT_SECRET': os.environ['ONLYOFFICE_JWT_SECRET'],
    'ONLYOFFICE_FILE_EXTENSION': ('doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'odt', 'fodt', 'odp', 'fodp', 'ods', 'fods'),
    'ONLYOFFICE_EDIT_FILE_EXTENSION': ('docx', 'pptx', 'xlsx'),
    'ENABLE_METADATA_MANAGEMENT': True,
    'METADATA_SERVER_URL': 'http://seafile-md-server:8084',
}
text = text.rstrip() + '\n\n# BEGIN TEST_SH MANAGED\n' + ''.join(f'{key} = {value!r}\n' for key, value in settings.items()) + '# END TEST_SH MANAGED\n'
ast.parse(text)
save(path, text)
print('SeaDoc / Wiki / SeaSearch / OnlyOffice / Metadata 配置已更新。')
GENERATED_FILE

cat > "$TARGET/deploy.sh" <<'GENERATED_FILE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_FILE=docker-compose.yml
unset COMPOSE_PATH_SEPARATOR
command -v docker >/dev/null || { echo '请先安装并启动 Docker + Compose v2' >&2; exit 1; }
docker compose version >/dev/null
docker info >/dev/null
command -v curl >/dev/null || { echo '需要宿主机安装 curl 以验收公开入口' >&2; exit 1; }
# Render silently: config output contains passwords.
docker compose config --quiet
WAIT="${DEPLOY_TIMEOUT:-600}"
[[ "$WAIT" =~ ^[1-9][0-9]*$ ]] || exit 2
trap 'echo "部署或验收失败，请检查 docker compose ps 和对应服务日志；修复后可重跑 ./deploy.sh。" >&2' ERR
# Do not implicitly pull newer images on every repair run. PULL=1 opts into refresh.
if [[ "${PULL:-0}" == 1 ]]; then docker compose pull; fi
# Seafile initializes DB/schema first; SeaDoc must not race DB user creation.
docker compose up -d --wait --wait-timeout "$WAIT" db redis seasearch seafile
# Use container Python so hosts need neither Python nor write access to root-owned configs.
docker compose exec -T seafile python3 - < configure.py
docker compose restart seafile
docker compose up -d --wait --wait-timeout "$WAIT"
./verify.sh
GENERATED_FILE

cat > "$TARGET/post-init.sh" <<'GENERATED_FILE'
#!/usr/bin/env bash
# Backward-compatible entry point, now performs complete deployment and verification.
set -euo pipefail
cd "$(dirname "$0")"
exec ./deploy.sh
GENERATED_FILE

cat > "$TARGET/verify.py" <<'GENERATED_FILE'
"""Functional smoke tests. Only delete objects created by this invocation."""
import json
import os
import socket
import sys
import time
import uuid
import requests

base = os.environ['SEAFILE_SERVER_PROTOCOL'] + '://' + os.environ['SEAFILE_SERVER_HOSTNAME']
session = requests.Session(); session.trust_env = False
limit = int(os.getenv('VERIFY_TIMEOUT') or '300')
def request(method, path, **kwargs):
    response = session.request(method, path if path.startswith('http') else base + path, timeout=20, **kwargs)
    if not 200 <= response.status_code < 300:
        # Avoid printing response bodies, signed URLs, passwords or bearer tokens.
        raise RuntimeError(f'{method} {path.split("?")[0] if not path.startswith("http") else "service URL"}: HTTP {response.status_code}')
    return response

def wait(label, fn):
    deadline = time.monotonic() + limit
    while True:
        try:
            result = fn()
            print('PASS ' + label, flush=True)
            return result
        except Exception as exc:
            if time.monotonic() >= deadline:
                raise RuntimeError(f'{label} 超时 ({type(exc).__name__})') from None
            time.sleep(5)

def check_text(path, text):
    result = request('GET', path).text
    if text not in result: raise RuntimeError('unexpected response')

repo = wiki = None
try:
    wait('Seafile 公开入口', lambda: check_text('/api2/ping/', 'pong'))
    wait('SeaDoc 公开入口', lambda: check_text('/sdoc-server/', 'Welcome to sdoc-server'))
    wait('OnlyOffice 健康检查', lambda: check_text('/onlyofficeds/healthcheck', 'true'))
    wait('OnlyOffice 编辑器脚本', lambda: check_text('/onlyofficeds/web-apps/apps/api/documents/api.js', 'DocsAPI'))
    wait('SeaDoc Socket.IO 握手', lambda: check_text('/socket.io/?EIO=4&transport=polling', '"sid"'))
    for host, port in [('seafile-md-server', 8084), ('notification-server', 8083)]:
        def connect(h=host, p=port):
            with socket.create_connection((h, p), timeout=5): pass
        wait(host + ' TCP（业务验收另列）', connect)
    token = os.getenv('VERIFY_TOKEN')
    if not token:
        token = request('POST', '/api2/auth-token/', data={
            'username': os.getenv('VERIFY_USERNAME') or os.environ['INIT_SEAFILE_ADMIN_EMAIL'],
            'password': os.getenv('VERIFY_PASSWORD') or os.environ['INIT_SEAFILE_ADMIN_PASSWORD'],
        }).json()['token']
    session.headers['Authorization'] = 'Token ' + token
    request('GET', '/api2/account/info/')
    print('PASS 用户登录', flush=True)
    suffix = uuid.uuid4().hex
    repo = request('POST', '/api2/repos/', data={'name': 'deploy-check-' + suffix, 'desc': 'Temporary deployment verification'}).json()['repo_id']
    payload = ('seafile deployment verification ' + suffix).encode()
    upload = request('GET', f'/api2/repos/{repo}/upload-link/').json()
    request('POST', upload, data={'parent_dir': '/'}, files={'file': ('check.txt', payload, 'text/plain')})
    download = request('GET', f'/api2/repos/{repo}/file/', params={'p': '/check.txt'}).json()
    if request('GET', download).content != payload: raise RuntimeError('上传下载内容不一致')
    print('PASS 资料库创建、上传、下载内容校验', flush=True)
    info = request('POST', '/api/v2.1/wikis2/', json={'name': 'deploy-wiki-' + suffix}).json()
    wiki = info.get('id') or info.get('wiki_id') or info.get('repo_id')
    if not wiki: raise RuntimeError('知识库返回值缺少 ID')
    page = request('POST', f'/api/v2.1/wiki2/{wiki}/pages/', json={'page_name': 'Deployment check'}).json()['file_info']
    detail = request('GET', f'/api/v2.1/wiki2/{wiki}/page/{page["page_id"]}/').json()
    if not detail.get('seadoc_access_token'): raise RuntimeError('知识库缺少 SeaDoc 访问令牌')
    print('PASS 知识库创建、页面创建、SeaDoc 令牌签发', flush=True)
    print('注意：浏览器协同编辑与保存、Office 保存回调、搜索索引结果仍需业务验收。', flush=True)
finally:
    # Cleanup only identifiers returned from successful creation in this run.
    cleanup_failed = False
    for kind, identifier in [('wiki2', wiki), ('repo', repo)]:
        if identifier:
            path = f'/api/v2.1/wiki2/{identifier}/' if kind == 'wiki2' else f'/api2/repos/{identifier}/'
            try:
                request('DELETE', path)
                print('CLEAN ' + kind, flush=True)
            except Exception:
                print(f'FAIL 请手动清理本次测试对象 {kind}: {identifier}', file=sys.stderr)
                cleanup_failed = True
    if cleanup_failed:
        raise RuntimeError('部分测试对象清理失败，见上述 ID')
GENERATED_FILE

cat > "$TARGET/verify.sh" <<'GENERATED_FILE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_FILE=docker-compose.yml
unset COMPOSE_PATH_SEPARATOR
# Optional credentials after the admin password has been changed. Never print tokens.
docker compose exec -T -e VERIFY_USERNAME -e VERIFY_PASSWORD -e VERIFY_TOKEN -e VERIFY_TIMEOUT \
  seafile python3 - < verify.py
# Also verify the public URL from the host (container reachability alone is insufficient).
PUBLIC_URL="$(docker compose exec -T seafile sh -c 'printf "%s://%s" "$SEAFILE_SERVER_PROTOCOL" "$SEAFILE_SERVER_HOSTNAME"')"
curl --noproxy '*' --fail --silent --show-error --max-time 20 "$PUBLIC_URL/api2/ping/" | grep -q pong
echo 'PASS 宿主机公开 URL 访问。'
GENERATED_FILE

chmod 700 "$TARGET/deploy.sh" "$TARGET/post-init.sh" "$TARGET/verify.sh"
cat > "$TARGET/README.txt" <<EOF
Seafile Pro 13 部署
公网主地址: $PROTOCOL://$SEAFILE_HOSTNAME
Caddy 入口: $CADDY_SITE_VALUE （宿主机端口 $PORT → 容器端口 $CADDY_PORT）
账号与初始密码: .env 中 INIT_SEAFILE_ADMIN_EMAIL / INIT_SEAFILE_ADMIN_PASSWORD
一键部署 / 修复: ./deploy.sh
重复验收: ./verify.sh
配置备份: config-backups/；应用配置更改前自动生成 .before-deploy-*。
这些是配置备份，不替代数据库和资料库备份。

默认服务: MariaDB、Redis、Seafile Pro、SeaSearch、SeaDoc、OnlyOffice、Caddy、Metadata、Notification。
Wiki 的 SeaDoc 地址必须是浏览器可访问的公开 URL；容器互联使用 Docker 服务名。
重复运行保留 .env、全部凭据和数据；外部反代模式只同步地址/入口相关键，不重置密码。
外部反代模式：SEAFILE_SERVER_HOSTNAME/PROTOCOL 表示公网主地址；CADDY_SITE/CADDY_HOST_PORT/CADDY_CONTAINER_PORT 表示内层入口。
Caddy 直出模式（EXTERNAL_REVERSE_PROXY=0）保持原有行为。管理员网页系统设置中的 URL 覆盖项也需保持一致。
Caddy 直出自动 HTTPS 需要域名、公网 DNS 和 80/443 入站；非标准 HTTPS 端口不能替代 ACME 所需端口。
镜像架构由 Docker 选择；请确保选定镜像支持宿主架构并分配足够内存。
不自动升级已有数据库的大小写策略；旧库若不是 lower_case_table_names=1，需单独备份迁移。

验收会创建临时资料库和知识库并删除，回收站和审计可能保留记录。
管理员改过密码时用 VERIFY_USERNAME / VERIFY_PASSWORD 或 VERIFY_TOKEN 执行 verify.sh。
VERIFY_TIMEOUT 默认每项 300 秒，DEPLOY_TIMEOUT 默认 600 秒。
自动检查覆盖登录、文件上传下载、Wiki 页面/令牌、公开路由、SeaDoc 握手和 Office 健康。
必须另外人工验收: 两浏览器协同编辑和刷新后的内容持久化、Office 编辑保存回调、
搜索实际索引结果、扩展属性实时更新、通知、分享权限、客户端同步。
邮件需 SMTP；AI 需模型服务配置；SSO/LDAP、杀毒、备份计划、商业授权按实际环境另配。
不能将容器启动成功等同于所有业务功能已通过。
镜像使用现有 13.0/2.0/1.0 版本通道；生产环境请在验证后用 .env 固定镜像 digest。
只有 PULL=1 ./deploy.sh 才主动刷新已有镜像。
懒猫微服默认使用 pg-docker，否则使用 docker；可用 DOCKER_COMMAND / DOCKER_COMPOSE_COMMAND 覆盖。
DOCKER_SOCKET 写入 .env，必须与上述命令连接同一 Docker daemon，Caddy 才能发现服务。
首次生成可用 IMAGE_PREFIX='' 直连镜像仓库；镜像代理、命令和容器前缀更改需重跑生成器。
不同部署请分别设置 CONTAINER_PREFIX 和 CADDY_HOST_PORT；项目及网络默认按前缀隔离。
EOF
# IMAGE_PREFIX applies to all image references; use IMAGE_PREFIX='' for full registry references in .env.
if [[ -n "$IMAGE_PREFIX" ]]; then
  content="$(cat "$TARGET/docker-compose.yml")"
  content="${content//image: /image: $IMAGE_PREFIX}"
  printf '%s\n' "$content" > "$TARGET/docker-compose.yml"
fi
# 按 Compose 服务名替换容器名称，服务间连接继续使用原服务名。
if [[ -n "$CONTAINER_PREFIX" ]]; then
  awk -v prefix="$CONTAINER_PREFIX" '
    /^  [A-Za-z0-9_-]+:$/ { service=$1; sub(/:$/, "", service) }
    /^    container_name:/ { $0="    container_name: " prefix "-" service }
    { print }
  ' "$TARGET/docker-compose.yml" > "$TARGET/docker-compose.yml.tmp"
  mv "$TARGET/docker-compose.yml.tmp" "$TARGET/docker-compose.yml"
fi
for file in deploy.sh verify.sh; do
  content="$(cat "$TARGET/$file")"
  content="${content//command -v docker /command -v $DOCKER_COMMAND }"
  content="${content//docker info/$DOCKER_COMMAND info}"
  content="${content//docker compose/$DOCKER_COMPOSE_COMMAND}"
  printf '%s\n' "$content" > "$TARGET/$file"
done

echo "文件已生成: ${TARGET}；凭据见该目录 .env。"
if [[ "${GENERATE_ONLY:-0}" != 1 ]]; then
  "$TARGET/deploy.sh"
else
  echo "仅生成模式；部署命令: $TARGET/deploy.sh"
fi
