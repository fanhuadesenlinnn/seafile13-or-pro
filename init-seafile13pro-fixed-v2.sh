#!/usr/bin/env bash
# Seafile 13 Professional Edition. Bash 3.2+, OpenSSL, Docker Compose v2.20+.
# One distributable script; no template downloads and no host Python dependency.
set -euo pipefail
umask 077

# 配置说明：修改 ${变量名:-默认值} 中的“默认值”即可，也可以传入同名环境变量。
# 仅首次部署：环境变量优先；已有 .env 或数据时拒绝覆盖，请选择空目录。
# 管理员密码、数据库密码和 JWT 密钥自动随机生成，无需填写。

# ==================== 常用修改配置 ====================
# 部署目录：保存配置和数据；运行时指定的第一个目录参数优先。
DEPLOY_DIR="${DEPLOY_DIR:-./deployments/seafile13-pro}"
# 访问域名或内网 IPv4，例如 files.example.com 或 192.168.1.100；不带协议和端口。
# 留空尝试检测本机 IP；建议明确填写，宿主机和容器都必须能访问此地址。
SEAFILE_SERVER_HOSTNAME="${SEAFILE_SERVER_HOSTNAME:-}"
# 用户访问协议：http / https；通过公网 HTTPS 反代访问时填 https。
SEAFILE_SERVER_PROTOCOL="${SEAFILE_SERVER_PROTOCOL:-http}"
# 0=Caddy 直接提供访问；1=已有 Nginx/OpenResty/FRP 反代，内层使用 HTTP。
EXTERNAL_REVERSE_PROXY="${EXTERNAL_REVERSE_PROXY:-0}"
# 本机入口端口：留空时 HTTP/外部反代为 28080，Caddy 直出 HTTPS 为 443。
CADDY_HOST_PORT="${CADDY_HOST_PORT:-}"
# 管理员登录邮箱；初始密码部署后在 .env 中查看。
INIT_SEAFILE_ADMIN_EMAIL="${INIT_SEAFILE_ADMIN_EMAIL:-admin@example.com}"
# 镜像下载代理：留空直连；例如 mirror.example.com，不带 http:// 或 https://。
IMAGE_PREFIX="${IMAGE_PREFIX:-}"
# 容器名称前缀：部署多个实例时，分别设置不同前缀、部署目录和入口端口。
CONTAINER_PREFIX="${CONTAINER_PREFIX:-seafile13pro}"

# ==================== 一般不需要修改配置 ====================
# 时区：中国大陆一般保持 Asia/Shanghai。
TIME_ZONE="${TIME_ZONE:-Asia/Shanghai}"
# 0=生成文件并部署；1=只生成文件，稍后手动执行部署目录中的 deploy.sh。
GENERATE_ONLY="${GENERATE_ONLY:-0}"

# --- 反向代理细节：通常留默认值；使用外部反代时检查可信代理地址 ---
# 容器内部入口端口：留空自动选择 80/443，与本机入口端口不同。
CADDY_CONTAINER_PORT="${CADDY_CONTAINER_PORT:-}"
# 本机监听地址：0.0.0.0 接受各网卡访问；仅同机反代可按需设为 127.0.0.1。
CADDY_BIND_ADDRESS="${CADDY_BIND_ADDRESS:-0.0.0.0}"
# 站点：留空按主地址生成；外部反代可填 http://域名, http://内网IP。
CADDY_SITE="${CADDY_SITE:-}"
# 可信代理：外部反代时填写 Caddy 实际看到的来源 IP/CIDR，多个用空格隔开。
CADDY_TRUSTED_PROXIES="${CADDY_TRUSTED_PROXIES:-127.0.0.1/32}"

# --- Docker 命令：普通 Docker 和懒猫微服通常可以自动识别 ---
# 留空优先选择 pg-docker，不存在则使用 docker。
DOCKER_COMMAND="${DOCKER_COMMAND:-}"
# 留空使用上面的命令 + compose；也可填写 pg-docker-compose 等独立命令。
DOCKER_COMPOSE_COMMAND="${DOCKER_COMPOSE_COMMAND:-}"
# 留空自动选择；自定义时必须指向同一 Docker 服务端的 socket。
DOCKER_SOCKET="${DOCKER_SOCKET:-}"

# --- 镜像版本：首次部署需要固定版本或 digest 时修改 ---
SEAFILE_IMAGE="${SEAFILE_IMAGE:-seafileltd/seafile-pro-mc:13.0-latest}" # 专业版主服务
SEAFILE_DB_IMAGE="${SEAFILE_DB_IMAGE:-mariadb:10.11}" # 数据库
SEAFILE_REDIS_IMAGE="${SEAFILE_REDIS_IMAGE:-redis:7-alpine}" # 缓存与事件队列
SEAFILE_CADDY_IMAGE="${SEAFILE_CADDY_IMAGE:-lucaslorentz/caddy-docker-proxy:2.12-alpine}" # 统一访问入口
SEASEARCH_IMAGE="${SEASEARCH_IMAGE:-}" # 留空自动选架构；ARM 使用 nomkl 镜像
SEADOC_IMAGE="${SEADOC_IMAGE:-seafileltd/sdoc-server:2.0-latest}" # 在线文档与 Wiki
ONLYOFFICE_IMAGE="${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:8.1.0.1}" # Office 预览与编辑
MD_IMAGE="${MD_IMAGE:-seafileltd/seafile-md-server:13.0-latest}" # 文件扩展属性
NOTIFICATION_SERVER_IMAGE="${NOTIFICATION_SERVER_IMAGE:-seafileltd/notification-server:13.0-latest}" # 实时通知

# --- 功能限制：按资料库大小和服务器资源调整 ---
MD_FILE_COUNT_LIMIT="${MD_FILE_COUNT_LIMIT:-100000}" # 单个资料库启用元数据管理的文件数上限
# ==================== 配置区结束 ====================
fail() { echo "错误: $*" >&2; exit 2; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'HELP'
用法: bash init-seafile13pro-fixed-v2.sh [部署目录]
仅初始化新部署，可设置配置区的同名环境变量；已有部署目录不会覆盖。
GENERATE_ONLY=1 只生成配置，不访问 Docker daemon、不拉取镜像。
PULL=1 显式拉取镜像；DEPLOY_TIMEOUT=600；VERIFY_TIMEOUT=300。
生成后: ./deploy.sh 执行初始化；./verify.sh 验收；./compose.sh ps 查看状态。
HELP
  exit 0
fi
[[ $# -le 1 ]] || fail '最多接受一个部署目录参数'
[[ "$GENERATE_ONLY" == 0 || "$GENERATE_ONLY" == 1 ]] || fail 'GENERATE_ONLY 必须为 0 或 1'
command -v openssl >/dev/null || fail '需要 openssl'
mkdir -p "${1:-$DEPLOY_DIR}"
TARGET="$(cd "${1:-$DEPLOY_DIR}" && pwd)"
# Reject a concurrent generator/deployer; stale locks are removable after checking processes.
mkdir "$TARGET/.operation-lock" 2>/dev/null || fail '已有操作或遗留 .operation-lock；确认无操作后再移除锁目录'
STAGE=''
DEPLOY_TARGET="$TARGET"
cleanup_generator() {
  rm -f "$DEPLOY_TARGET/.env.new"
  if [[ -n "$STAGE" && "$STAGE" == "$DEPLOY_TARGET"/.generated.* ]]; then rm -rf "$STAGE"; fi
  rmdir "$DEPLOY_TARGET/.operation-lock" 2>/dev/null || true
}
trap cleanup_generator EXIT
for entry in "$TARGET"/* "$TARGET"/.[!.]* "$TARGET"/..?*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  [[ "$entry" == "$TARGET/.operation-lock" ]] || fail '本脚本只初始化新部署；请使用空部署目录，或自行清理旧目录后重试'
done
if [[ -z "$SEAFILE_SERVER_HOSTNAME" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then
    SEAFILE_SERVER_HOSTNAME="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  elif command -v ip >/dev/null; then
    SEAFILE_SERVER_HOSTNAME="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
fi
[[ -n "$SEAFILE_SERVER_HOSTNAME" ]] || fail '请设置 SEAFILE_SERVER_HOSTNAME 为可从宿主机和容器访问的域名或 IPv4'
[[ "$SEAFILE_SERVER_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail '首次主机名不带协议、路径和端口'
if [[ "$EXTERNAL_REVERSE_PROXY" == 1 ]]; then
  CADDY_HOST_PORT="${CADDY_HOST_PORT:-28080}"
  CADDY_CONTAINER_PORT="${CADDY_CONTAINER_PORT:-80}"
  CADDY_SITE="${CADDY_SITE:-http://$SEAFILE_SERVER_HOSTNAME}"
else
  if [[ "$SEAFILE_SERVER_PROTOCOL" == https ]]; then
    CADDY_HOST_PORT="${CADDY_HOST_PORT:-443}"
    CADDY_CONTAINER_PORT="${CADDY_CONTAINER_PORT:-443}"
  else
    CADDY_HOST_PORT="${CADDY_HOST_PORT:-28080}"
    CADDY_CONTAINER_PORT="${CADDY_CONTAINER_PORT:-80}"
  fi
  CADDY_SITE="${CADDY_SITE:-$SEAFILE_SERVER_PROTOCOL://$SEAFILE_SERVER_HOSTNAME}"
  if [[ "$SEAFILE_SERVER_PROTOCOL:$CADDY_HOST_PORT" != http:80 && "$SEAFILE_SERVER_PROTOCOL:$CADDY_HOST_PORT" != https:443 ]]; then
    SEAFILE_SERVER_HOSTNAME="$SEAFILE_SERVER_HOSTNAME:$CADDY_HOST_PORT"
  fi
fi
CADDY_SITE="$(printf '%s' "$CADDY_SITE" | sed 's/,[[:space:]]*/, /g')"
CONTAINER_PREFIX="${CONTAINER_PREFIX%-}"
if [[ -z "$DOCKER_COMMAND" ]]; then
  if command -v pg-docker >/dev/null; then DOCKER_COMMAND=pg-docker; else DOCKER_COMMAND=docker; fi
fi
DOCKER_COMPOSE_COMMAND="${DOCKER_COMPOSE_COMMAND:-$DOCKER_COMMAND compose}"
if [[ -z "$DOCKER_SOCKET" ]]; then
  case "${DOCKER_COMMAND##*/}" in
    pg-docker) DOCKER_SOCKET=/lzcsys/data/playground/docker.sock ;;
    lzc-docker) fail '使用 lzc-docker 时请显式指定 DOCKER_SOCKET' ;;
    *)
      # Docker Desktop/OrbStack daemon-side socket differs from the host client socket.
      if [[ "$(uname -s)" == Darwin ]]; then DOCKER_SOCKET=/var/run/docker.sock
      else
        endpoint="${DOCKER_HOST:-}"
        if [[ -z "$endpoint" ]] && command -v "$DOCKER_COMMAND" >/dev/null; then
          endpoint="$("$DOCKER_COMMAND" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
        fi
        endpoint="${endpoint:-unix:///var/run/docker.sock}"
        [[ "$endpoint" == unix:///* ]] || fail '远程 daemon 请显式指定服务端 DOCKER_SOCKET'
        DOCKER_SOCKET="${endpoint#unix://}"
      fi ;;
  esac
fi
IMAGE_PREFIX="${IMAGE_PREFIX%/}"
[[ -z "$IMAGE_PREFIX" ]] || IMAGE_PREFIX="$IMAGE_PREFIX/"
COMPOSE_PROJECT_NAME="$(printf '%s' "$CONTAINER_PREFIX" | tr '[:upper:].' '[:lower:]_')"
DEPLOYMENT_KIND=seafile13-pro-v1
INIT_SS_ADMIN_USER=seasearch-admin
INIT_SS_ADMIN_PASSWORD="$(openssl rand -hex 24)"
SEASEARCH_TOKEN="$(printf '%s' "$INIT_SS_ADMIN_USER:$INIT_SS_ADMIN_PASSWORD" | base64 | tr -d '\r\n')"
if [[ -z "$SEASEARCH_IMAGE" ]]; then
  arch="$(uname -m)"
  if [[ "$GENERATE_ONLY" != 1 ]]; then
    arch="$("$DOCKER_COMMAND" info --format '{{.Architecture}}')"
  fi
  case "$arch" in
    arm64|aarch64) SEASEARCH_IMAGE=seafileltd/seasearch-nomkl:1.0-latest ;;
    *) SEASEARCH_IMAGE=seafileltd/seasearch:1.0-latest ;;
  esac
fi
for key in INIT_SEAFILE_MYSQL_ROOT_PASSWORD SEAFILE_MYSQL_DB_PASSWORD REDIS_PASSWORD INIT_SEAFILE_ADMIN_PASSWORD JWT_PRIVATE_KEY ONLYOFFICE_JWT_SECRET; do
  printf -v "$key" '%s' "$(openssl rand -hex 24)"
done
# Atomic file publication; do not leave a partial .env after failure.
: > "$TARGET/.env.new"
for key in DEPLOYMENT_KIND COMPOSE_PROJECT_NAME CONTAINER_PREFIX SEAFILE_SERVER_HOSTNAME SEAFILE_SERVER_PROTOCOL EXTERNAL_REVERSE_PROXY CADDY_HOST_PORT CADDY_CONTAINER_PORT CADDY_BIND_ADDRESS CADDY_SITE CADDY_TRUSTED_PROXIES TIME_ZONE INIT_SEAFILE_ADMIN_EMAIL INIT_SEAFILE_ADMIN_PASSWORD INIT_SEAFILE_MYSQL_ROOT_PASSWORD SEAFILE_MYSQL_DB_PASSWORD REDIS_PASSWORD JWT_PRIVATE_KEY ONLYOFFICE_JWT_SECRET IMAGE_PREFIX DOCKER_COMMAND DOCKER_COMPOSE_COMMAND DOCKER_SOCKET SEAFILE_IMAGE SEAFILE_DB_IMAGE SEAFILE_REDIS_IMAGE SEAFILE_CADDY_IMAGE SEADOC_IMAGE ONLYOFFICE_IMAGE MD_IMAGE NOTIFICATION_SERVER_IMAGE MD_FILE_COUNT_LIMIT SEASEARCH_IMAGE INIT_SS_ADMIN_USER INIT_SS_ADMIN_PASSWORD SEASEARCH_TOKEN; do
  printf '%s=%s\n' "$key" "${!key}" >> "$TARGET/.env.new"
done
ENV_INPUT="$TARGET/.env.new"
# COMMON_BEGIN -- copied verbatim into generated common.sh and tested there.
load_env() {
  local file="$1" line key val seen=' '
  [[ -f "$file" && ! -L "$file" ]] || fail '配置文件不存在或为符号链接'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || fail '配置必须为 KEY=value 格式'
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      DEPLOYMENT_KIND|COMPOSE_PROJECT_NAME|CONTAINER_PREFIX|SEAFILE_SERVER_HOSTNAME|SEAFILE_SERVER_PROTOCOL|EXTERNAL_REVERSE_PROXY|CADDY_HOST_PORT|CADDY_CONTAINER_PORT|CADDY_BIND_ADDRESS|CADDY_SITE|CADDY_TRUSTED_PROXIES|TIME_ZONE|INIT_SEAFILE_ADMIN_EMAIL|INIT_SEAFILE_ADMIN_PASSWORD|INIT_SEAFILE_MYSQL_ROOT_PASSWORD|SEAFILE_MYSQL_DB_PASSWORD|REDIS_PASSWORD|JWT_PRIVATE_KEY|ONLYOFFICE_JWT_SECRET|IMAGE_PREFIX|DOCKER_COMMAND|DOCKER_COMPOSE_COMMAND|DOCKER_SOCKET|SEAFILE_IMAGE|SEAFILE_DB_IMAGE|SEAFILE_REDIS_IMAGE|SEAFILE_CADDY_IMAGE|SEADOC_IMAGE|ONLYOFFICE_IMAGE|MD_IMAGE|NOTIFICATION_SERVER_IMAGE|MD_FILE_COUNT_LIMIT|SEASEARCH_IMAGE|INIT_SS_ADMIN_USER|INIT_SS_ADMIN_PASSWORD|SEASEARCH_TOKEN) ;;
      *) fail "未知配置键: $key" ;;
    esac
    [[ "$seen" != *" $key "* ]] || fail "重复配置键: $key"
    seen="$seen$key "
    # No shell execution, Compose interpolation or quote ambiguities in stored values.
    [[ "$val" =~ ^[A-Za-z0-9_./:@,+=\ -]*$ ]] || fail "配置 $key 含不支持字符；使用未加引号的纯文本值"
    export "$key=$val"
  done < "$file"
  for key in DEPLOYMENT_KIND COMPOSE_PROJECT_NAME CONTAINER_PREFIX SEAFILE_SERVER_HOSTNAME SEAFILE_SERVER_PROTOCOL EXTERNAL_REVERSE_PROXY CADDY_HOST_PORT CADDY_CONTAINER_PORT CADDY_BIND_ADDRESS CADDY_SITE CADDY_TRUSTED_PROXIES TIME_ZONE INIT_SEAFILE_ADMIN_EMAIL INIT_SEAFILE_ADMIN_PASSWORD INIT_SEAFILE_MYSQL_ROOT_PASSWORD SEAFILE_MYSQL_DB_PASSWORD REDIS_PASSWORD JWT_PRIVATE_KEY ONLYOFFICE_JWT_SECRET IMAGE_PREFIX DOCKER_COMMAND DOCKER_COMPOSE_COMMAND DOCKER_SOCKET SEAFILE_IMAGE SEAFILE_DB_IMAGE SEAFILE_REDIS_IMAGE SEAFILE_CADDY_IMAGE SEADOC_IMAGE ONLYOFFICE_IMAGE MD_IMAGE NOTIFICATION_SERVER_IMAGE MD_FILE_COUNT_LIMIT SEASEARCH_IMAGE INIT_SS_ADMIN_USER INIT_SS_ADMIN_PASSWORD SEASEARCH_TOKEN; do
    [[ "$seen" == *" $key "* ]] || fail ".env 缺少 $key"
    [[ "$key" == IMAGE_PREFIX || -n "${!key}" ]] || fail ".env 中 $key 不能为空"
  done
  [[ "$DEPLOYMENT_KIND" == seafile13-pro-v1 ]] || fail '不是本脚本的 Pro 部署；禁止覆盖 CE/未知数据'
  [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ && "$CONTAINER_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail '项目名或容器前缀格式错误'
  [[ "$SEAFILE_IMAGE" == *seafile-pro-mc* ]] || fail 'Pro 部署必须使用 seafile-pro-mc 镜像'
  [[ "$DOCKER_COMMAND" =~ ^[A-Za-z0-9_./-]+$ && "$DOCKER_COMPOSE_COMMAND" =~ ^[A-Za-z0-9_./\ -]+$ ]] || fail 'Docker 命令只能是可执行文件及普通参数'
  [[ "$DOCKER_SOCKET" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail 'DOCKER_SOCKET 必须是绝对路径'
  [[ "$CADDY_BIND_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '绑定地址必须是 IPv4'
  [[ "$SEAFILE_SERVER_PROTOCOL" == http || "$SEAFILE_SERVER_PROTOCOL" == https ]] || fail '协议必须为 http/https'
  [[ "$EXTERNAL_REVERSE_PROXY" == 0 || "$EXTERNAL_REVERSE_PROXY" == 1 ]] || fail 'EXTERNAL_REVERSE_PROXY 必须为 0/1'
  [[ "$SEAFILE_SERVER_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[1-9][0-9]{0,4})?$ ]] || fail '无效主机名'
  for key in CADDY_HOST_PORT CADDY_CONTAINER_PORT; do
    [[ "${!key}" =~ ^[1-9][0-9]{0,4}$ && "${!key}" -le 65535 ]] || fail "无效端口 $key"
  done
  [[ "$MD_FILE_COUNT_LIMIT" =~ ^[1-9][0-9]*$ ]] || fail "无效 MD_FILE_COUNT_LIMIT"
  [[ "$(printf '%s' "$INIT_SS_ADMIN_USER:$INIT_SS_ADMIN_PASSWORD" | base64 | tr -d '\r\n')" == "$SEASEARCH_TOKEN" ]] || fail 'SeaSearch token 与账户密码不一致'
  [[ ${#JWT_PRIVATE_KEY} -ge 32 && ${#ONLYOFFICE_JWT_SECRET} -ge 32 ]] || fail 'JWT 密钥长度至少 32'
  [[ -z "$IMAGE_PREFIX" || "$IMAGE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*/$ ]] || fail '镜像代理格式为 registry[:port]/'
  local host="${SEAFILE_SERVER_HOSTNAME%%:*}" expected site
  if [[ "$EXTERNAL_REVERSE_PROXY" == 0 ]]; then
    expected="$host:$CADDY_HOST_PORT"
    [[ "$SEAFILE_SERVER_PROTOCOL:$CADDY_HOST_PORT" != http:80 && "$SEAFILE_SERVER_PROTOCOL:$CADDY_HOST_PORT" != https:443 ]] || expected="$host"
    [[ "$SEAFILE_SERVER_HOSTNAME" == "$expected" && "$CADDY_SITE" == "$SEAFILE_SERVER_PROTOCOL://$host" ]] || fail '直出模式的主地址、端口及 Caddy 站点不一致'
    if [[ "$SEAFILE_SERVER_PROTOCOL" == https ]]; then
      [[ "$CADDY_CONTAINER_PORT" == 443 && "$CADDY_HOST_PORT" == 443 && ! "$host" =~ ^[0-9.]+$ && "$host" != localhost ]] || fail '自动 HTTPS 需要域名及标准公网 80/443；其它情况请用外部反代'
    else
      [[ "$CADDY_CONTAINER_PORT" == 80 ]] || fail 'HTTP 内部端口必须为 80'
    fi
  else
    [[ "$CADDY_CONTAINER_PORT" == 80 ]] || fail '外部反代模式内部端口必须为 80'
    # A site list is deliberately constrained to HTTP hostnames/IPs, no directives.
    local sites="${CADDY_SITE//,/ }"
    for site in $sites; do
      [[ "$site" =~ ^http://[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail '外部反代 CADDY_SITE 只能是 http://主机 的逗号分隔列表'
    done
    [[ ", ${CADDY_SITE}, " == *", http://$host, "* ]] || fail 'CADDY_SITE 必须包含主地址对应的 http://主机'
  fi
  for site in $CADDY_TRUSTED_PROXIES; do
    [[ "$site" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || fail '可信代理请使用 IPv4/CIDR'
  done
  # Drop ambient Compose options; every managed setting now comes from .env.
  unset COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_PROFILES
  read -r -a COMPOSE_CMD <<< "$DOCKER_COMPOSE_COMMAND"
}
dc() { "${COMPOSE_CMD[@]}" --env-file .env -f docker-compose.yml -p "$COMPOSE_PROJECT_NAME" "$@"; }
# COMMON_END
load_env "$ENV_INPUT"
mv "$ENV_INPUT" "$TARGET/.env"
chmod 600 "$TARGET/.env"
# Generate and syntax-check the complete helper set before replacing managed files.
STAGE="$(mktemp -d "$TARGET/.generated.XXXXXX")"
TARGET="$STAGE"
# Persist the same validated environment loader into runtime helpers.
{ printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'fail() { echo "错误: $*" >&2; exit 2; }'; sed -n '/^# COMMON_BEGIN/,/^# COMMON_END/p' "$0"; } > "$TARGET/common.sh"
cat > "$TARGET/docker-compose.yml" <<'YAML'
name: ${COMPOSE_PROJECT_NAME:-seafile13pro}

services:
  db:
    image: ${IMAGE_PREFIX}${SEAFILE_DB_IMAGE:-mariadb:10.11}
    container_name: ${CONTAINER_PREFIX}-db
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
    volumes:
      - ./data/redis:/data
    image: ${IMAGE_PREFIX}${SEAFILE_REDIS_IMAGE:-redis:7-alpine}
    container_name: ${CONTAINER_PREFIX}-redis
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
      - exec redis-server --requirepass "$$REDIS_PASSWORD" --appendonly yes
    networks:
      - seafile-net

  seasearch:
    image: ${IMAGE_PREFIX}${SEASEARCH_IMAGE}
    container_name: ${CONTAINER_PREFIX}-seasearch
    restart: unless-stopped
    volumes:
      - ./data/seasearch:/opt/seasearch/data
    environment:
      SS_FIRST_ADMIN_USER: ${INIT_SS_ADMIN_USER}
      SS_FIRST_ADMIN_PASSWORD: ${INIT_SS_ADMIN_PASSWORD}
      SS_MAX_OBJ_CACHE_SIZE: 2GB
      SS_STORAGE_TYPE: disk
      SS_LOG_TO_STDOUT: "true"
      SS_LOG_LEVEL: info
    networks:
      - seafile-net

  seafile:
    image: ${IMAGE_PREFIX}${SEAFILE_IMAGE:-seafileltd/seafile-pro-mc:13.0-latest}
    container_name: ${CONTAINER_PREFIX}-seafile
    restart: unless-stopped
    volumes:
      - ./data/seafile:/shared
    environment:
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_PORT: "3306"
      SEAFILE_MYSQL_DB_USER: seafile
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
      MD_FILE_COUNT_LIMIT: ${MD_FILE_COUNT_LIMIT}
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
    networks:
      - seafile-net

  onlyoffice:
    image: ${IMAGE_PREFIX}${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:8.1.0.1}
    container_name: ${CONTAINER_PREFIX}-onlyoffice
    volumes:
      - ./data/onlyoffice/data:/var/www/onlyoffice/Data
      - ./data/onlyoffice/logs:/var/log/onlyoffice
      - ./data/onlyoffice/lib:/var/lib/onlyoffice
      - ./data/onlyoffice/postgresql:/var/lib/postgresql
      - ./data/onlyoffice/rabbitmq:/var/lib/rabbitmq
      - ./data/onlyoffice/redis:/var/lib/redis
      - ./data/onlyoffice/fonts:/usr/share/fonts/truetype/custom
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost/healthcheck | grep -qx true"]
      start_period: 120s
      interval: 10s
      timeout: 5s
      retries: 30
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: ${ONLYOFFICE_JWT_SECRET}
      ALLOW_PRIVATE_IP_ADDRESS: "true"
    labels:
      caddy: "${CADDY_SITE}"
      caddy.handle_path: "/onlyofficeds/*"
      caddy.handle_path.0_reverse_proxy: "{{upstreams 80}}"
      caddy.handle_path.0_reverse_proxy.header_up_1: "X-Forwarded-Host {http.request.hostport}/onlyofficeds"
      caddy.handle_path.0_reverse_proxy.header_up_2: "X-Forwarded-Proto ${SEAFILE_SERVER_PROTOCOL}"
    networks:
      - seafile-net

  seadoc:
    image: ${IMAGE_PREFIX}${SEADOC_IMAGE:-seafileltd/sdoc-server:2.0-latest}
    container_name: ${CONTAINER_PREFIX}-seadoc
    restart: unless-stopped
    volumes:
      - ./data/seadoc:/shared
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      DB_USER: seafile
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
    image: ${IMAGE_PREFIX}${SEAFILE_CADDY_IMAGE:-lucaslorentz/caddy-docker-proxy:2.12-alpine}
    container_name: ${CONTAINER_PREFIX}-caddy
    restart: unless-stopped
    ports:
      - "${CADDY_BIND_ADDRESS}:${CADDY_HOST_PORT}:${CADDY_CONTAINER_PORT}"
      # HTTPS_CHALLENGE_PORT
    environment:
      CADDY_DOCKER_LABEL_PREFIX: seafile-${COMPOSE_PROJECT_NAME}
      CADDY_INGRESS_NETWORKS: ${COMPOSE_PROJECT_NAME:-seafile13pro}_seafile-net
    labels:
      caddy: ""
      caddy.servers.trusted_proxies: "static ${CADDY_TRUSTED_PROXIES:-127.0.0.1/32}"
      caddy.servers.trusted_proxies_strict: ""
    volumes:
      - ${DOCKER_SOCKET:?Docker socket is required}:/var/run/docker.sock:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    networks:
      - seafile-net


  seafile-md-server:
    image: ${IMAGE_PREFIX}${MD_IMAGE:-seafileltd/seafile-md-server:13.0-latest}
    container_name: ${CONTAINER_PREFIX}-seafile-md-server
    restart: unless-stopped
    volumes:
      - ./data/seafile:/shared
    environment:
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_HOST=db
      - SEAFILE_MYSQL_DB_PORT=3306
      - SEAFILE_MYSQL_DB_USER=seafile
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
      - SEAFILE_LOG_TO_STDOUT=false
      - MD_PORT=8084
      - MD_LOG_LEVEL=info
      - MD_MAX_CACHE_SIZE=1GB
      - MD_CHECK_UPDATE_INTERVAL=30m
      - MD_FILE_COUNT_LIMIT=${MD_FILE_COUNT_LIMIT:-100000}
      - MD_STORAGE_TYPE=disk
      - CACHE_PROVIDER=redis
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
    depends_on:
      db:
        condition: service_healthy
      seafile:
        condition: service_healthy

    networks:
      - seafile-net



  notification-server:
    image: ${IMAGE_PREFIX}${NOTIFICATION_SERVER_IMAGE:-seafileltd/notification-server:13.0-latest}
    container_name: ${CONTAINER_PREFIX}-notification-server
    restart: always
    volumes:
      - ./data/seafile/seafile/logs:/shared/seafile/logs
    environment:
      - SEAFILE_MYSQL_DB_HOST=db
      - SEAFILE_MYSQL_DB_PORT=3306
      - SEAFILE_MYSQL_DB_USER=seafile
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD:?Variable is not set or empty}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY:?Variable is not set or empty}
      - SEAFILE_LOG_TO_STDOUT=false
      - NOTIFICATION_SERVER_LOG_LEVEL=info
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
# Docker label keys do not support Compose interpolation. Render a project-specific
# namespace so concurrent Caddy instances never merge each other's routes.
awk -v prefix="seafile-$COMPOSE_PROJECT_NAME" '{sub(/^      caddy/, "      " prefix); print}' \
  "$TARGET/docker-compose.yml" > "$TARGET/docker-compose.yml.new"
mv "$TARGET/docker-compose.yml.new" "$TARGET/docker-compose.yml"
if [[ "$EXTERNAL_REVERSE_PROXY" == 0 && "$SEAFILE_SERVER_PROTOCOL" == https ]]; then
  # shellcheck disable=SC2016
  sed 's|      # HTTPS_CHALLENGE_PORT|      - "${CADDY_BIND_ADDRESS}:80:80"|' "$TARGET/docker-compose.yml" > "$TARGET/docker-compose.yml.new"
  mv "$TARGET/docker-compose.yml.new" "$TARGET/docker-compose.yml"
fi
cat > "$TARGET/configure.py" <<'PY'
"""Idempotent managed settings. Run inside the initialized Pro container."""
import ast
import configparser
import io
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time

conf = Path(sys.argv[1] if len(sys.argv) > 1 else '/shared/seafile/conf')
url = os.environ['SEAFILE_SERVER_PROTOCOL'] + '://' + os.environ['SEAFILE_SERVER_HOSTNAME']

def save(path, content):
    if path.exists() and path.read_text() == content:
        return
    stat = path.stat() if path.exists() else None
    if stat:
        shutil.copy2(path, str(path) + '.before-deploy-' + str(time.time_ns()))
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        os.chmod(tmp, stat.st_mode & 0o777 if stat else 0o600)
        if stat:
            os.chown(tmp, stat.st_uid, stat.st_gid)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

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
text = path.read_text()
text = re.sub(r'\n# BEGIN SEAFILE13_PRO MANAGED\n.*?# END SEAFILE13_PRO MANAGED\n?', '\n', text, flags=re.S)
settings = {
    'SERVICE_URL': url,
    'FILE_SERVER_ROOT': url + '/seafhttp',
    'CSRF_TRUSTED_ORIGINS': [url],
    'ENABLE_WIKI': True,
    'ENABLE_SEADOC': True,
    'SEADOC_SERVER_URL': url + '/sdoc-server',
    'ENABLE_ONLYOFFICE': True,
    'ONLYOFFICE_APIJS_URL': url + '/onlyofficeds/web-apps/apps/api/documents/api.js',
    'ONLYOFFICE_JWT_SECRET': os.environ['ONLYOFFICE_JWT_SECRET'],
    'ONLYOFFICE_FILE_EXTENSION': ('doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'odt', 'fodt', 'odp', 'fodp', 'ods', 'fods', 'pps', 'ppsx', 'csv'),
    'ONLYOFFICE_EDIT_FILE_EXTENSION': ('docx', 'pptx', 'xlsx', 'csv'),
    'ENABLE_METADATA_MANAGEMENT': True,
    'METADATA_SERVER_URL': 'http://seafile-md-server:8084',
}
text = text.rstrip() + '\n\n# BEGIN SEAFILE13_PRO MANAGED\n' + ''.join(f'{k} = {v!r}\n' for k, v in settings.items()) + '# END SEAFILE13_PRO MANAGED\n'
ast.parse(text)
save(path, text)
print('Pro 配置完成：SeaDoc / Wiki / Office / Metadata / SeaSearch。')
PY
cat > "$TARGET/compose.sh" <<'SH_HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./common.sh
load_env .env
dc "$@"
SH_HELPER
cat > "$TARGET/deploy.sh" <<'SH_HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./common.sh
load_env .env
mkdir .operation-lock 2>/dev/null || fail '已有操作或遗留 .operation-lock'
trap 'rmdir .operation-lock 2>/dev/null || true' EXIT
trap 'echo "部署/验收失败。请运行 ./compose.sh ps 和 ./compose.sh logs；如需重新初始化，请先移除本项目容器，再自行清理部署目录。" >&2' ERR
[[ ! -e ./data && ! -L ./data ]] || fail '仅支持首次初始化；data 已存在，请先移除本项目容器并自行清理部署目录后重试'
command -v "$DOCKER_COMMAND" >/dev/null || fail '请安装并启动 Docker'
command -v "${COMPOSE_CMD[0]}" >/dev/null || fail '找不到 Compose 命令'
"$DOCKER_COMMAND" info >/dev/null
# --wait and --wait-timeout require a recent Compose (v2.20+ recommended).
dc version >/dev/null
dc config --quiet
command -v curl >/dev/null || fail '宿主机需要 curl'
WAIT="${DEPLOY_TIMEOUT:-600}"
[[ "$WAIT" =~ ^[1-9][0-9]*$ ]] || fail 'DEPLOY_TIMEOUT 必须为正整数'
[[ "${PULL:-0}" == 0 || "${PULL:-0}" == 1 ]] || fail 'PULL 必须为 0/1'
if [[ "${PULL:-0}" == 1 ]]; then dc pull; fi
# Seed pristine image data before using bind mounts (empty mounts hide image files).
# This initializes a NEW directory only. It never reads an existing Office container.
office_image="${IMAGE_PREFIX}${ONLYOFFICE_IMAGE}"
if ! "$DOCKER_COMMAND" image inspect "$office_image" >/dev/null 2>&1; then
  "$DOCKER_COMMAND" pull "$office_image"
fi
office_image_id="$("$DOCKER_COMMAND" image inspect --format '{{.Id}}' "$office_image")"
mkdir -p ./data/onlyoffice
# --rm removes the temporary container and its image-declared anonymous volumes.
# shellcheck disable=SC2016
"$DOCKER_COMMAND" run --rm --network none --entrypoint sh \
  -v "$PWD/data/onlyoffice:/seed-target" "$office_image_id" -c '
    set -eu
    seed() { mkdir -p "/seed-target/$1"; cp -a "$2/." "/seed-target/$1/"; }
    seed data /var/www/onlyoffice/Data
    seed logs /var/log/onlyoffice
    seed lib /var/lib/onlyoffice
    seed postgresql /var/lib/postgresql
    seed rabbitmq /var/lib/rabbitmq
    seed redis /var/lib/redis
    seed fonts /usr/share/fonts/truetype/custom
    find /seed-target/postgresql -name PG_VERSION | grep -q .
    if [ "$(stat -c %u /seed-target/postgresql)" != "$(id -u postgres)" ]; then
      echo "Office 数据目录无法保留 PostgreSQL 属主；请使用支持 Linux 权限的本地文件系统（不要使用 OrbStack 的 macOS 共享目录）。" >&2
      exit 2
    fi
  '
# DB account/schema and shared configuration must exist before extension startup.
dc up -d --wait --wait-timeout "$WAIT" db redis seasearch seafile
dc exec -T seafile python3 - < configure.py
dc restart seafile
dc up -d --wait --wait-timeout "$WAIT"
./verify.sh
SH_HELPER
cat > "$TARGET/verify.sh" <<'SH_HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./common.sh
load_env .env
dc exec -T -e VERIFY_USERNAME -e VERIFY_PASSWORD -e VERIFY_TOKEN -e VERIFY_TIMEOUT \
  seafile python3 - < verify.py
PUBLIC_URL="$SEAFILE_SERVER_PROTOCOL://$SEAFILE_SERVER_HOSTNAME"
[[ "$(curl --noproxy '*' --fail --silent --show-error --max-time 20 "$PUBLIC_URL/api2/ping/")" == *pong* ]] || fail '宿主机主地址验收失败'
echo 'PASS 宿主机主地址访问'
SH_HELPER
cat > "$TARGET/verify.py" <<'PY'
"""Public-route smoke tests. Delete only resources created by this invocation."""
import json
import os
import sys
import time
import uuid
from urllib.parse import urlsplit
import requests

base = os.environ['SEAFILE_SERVER_PROTOCOL'] + '://' + os.environ['SEAFILE_SERVER_HOSTNAME']
session = requests.Session()
session.trust_env = False
limit = int(os.getenv('VERIFY_TIMEOUT') or '300')
if limit <= 0:
    raise SystemExit('VERIFY_TIMEOUT 必须为正整数')

class CheckError(Exception):
    pass

def request(method, path, **kwargs):
    target = path if path.startswith(('http://', 'https://')) else base + path
    # Do not leak API tokens to an unexpected file-service host or HTTP downgrade.
    if urlsplit(target).netloc != urlsplit(base).netloc or urlsplit(target).scheme != urlsplit(base).scheme:
        raise CheckError('服务生成的 URL 与主地址不一致；请检查 FILE_SERVER_ROOT/网页 URL 设置')
    r = session.request(method, target, timeout=20, allow_redirects=False, **kwargs)
    if not 200 <= r.status_code < 300:
        raise CheckError(f'{method}: HTTP {r.status_code}')
    return r

def wait(label, fn):
    deadline = time.monotonic() + limit
    while True:
        try:
            value = fn()
            print('PASS ' + label, flush=True)
            return value
        except Exception as exc:
            if time.monotonic() >= deadline:
                detail = str(exc) if isinstance(exc, CheckError) else type(exc).__name__
                raise CheckError(f'{label} 超时：{detail}') from None
            time.sleep(3)

def check_text(path, content):
    if content not in request('GET', path).text:
        raise CheckError('响应内容不匹配')

repo = wiki = None
failed = False
try:
    wait('Seafile 主地址', lambda: check_text('/api2/ping/', 'pong'))
    wait('SeaDoc 主地址', lambda: check_text('/sdoc-server/', 'Welcome to sdoc-server'))
    wait('SeaDoc Socket.IO 握手', lambda: check_text('/socket.io/?EIO=4&transport=polling', '"sid"'))
    wait('ONLYOFFICE 健康', lambda: check_text('/onlyofficeds/healthcheck', 'true'))
    wait('ONLYOFFICE 编辑器脚本', lambda: check_text('/onlyofficeds/web-apps/apps/api/documents/api.js', 'DocsAPI'))
    wait('Notification 主地址', lambda: check_text('/notification/ping', 'pong'))
    username = os.getenv('VERIFY_USERNAME') or os.environ['INIT_SEAFILE_ADMIN_EMAIL']
    password = os.getenv('VERIFY_PASSWORD') or os.environ['INIT_SEAFILE_ADMIN_PASSWORD']
    token = os.getenv('VERIFY_TOKEN') or request('POST', '/api2/auth-token/', data={'username': username, 'password': password}).json()['token']
    session.headers['Authorization'] = 'Token ' + token
    request('GET', '/api2/account/info/')
    print('PASS 用户登录', flush=True)
    name = 'deploy-check-' + uuid.uuid4().hex
    repo = request('POST', '/api2/repos/', data={'name': name, 'desc': 'Temporary deployment verification'}).json()['repo_id']
    search_marker = 'seafilecontent' + uuid.uuid4().hex
    payload = ('seafile Pro deployment verification ' + search_marker).encode()
    upload = request('GET', f'/api2/repos/{repo}/upload-link/').json()
    request('POST', upload, data={'parent_dir': '/'}, files={'file': ('check.txt', payload, 'text/plain')})
    download = request('GET', f'/api2/repos/{repo}/file/', params={'p': '/check.txt'}).json()
    if request('GET', download).content != payload:
        raise CheckError('上传下载内容不一致')
    print('PASS 资料库创建、上传、下载内容校验', flush=True)

    meta = f'/api/v2.1/repos/{repo}/metadata/'
    request('PUT', meta, json={'enabled': True})
    views = request('GET', meta + 'views/').json()['views']
    view_id = views[0]['_id']
    def metadata():
        r = request('GET', meta + 'records/', params={'view_id': view_id}).json()
        if 'check.txt' not in json.dumps(r):
            raise CheckError('元数据还未索引测试文件')
    wait('Metadata 文件记录初始化', metadata)
    request('POST', upload, data={'parent_dir': '/'}, files={'file': ('metadata-new.txt', payload, 'text/plain')})
    def metadata_update():
        r = request('GET', meta + 'records/', params={'view_id': view_id}).json()
        if 'metadata-new.txt' not in json.dumps(r):
            raise CheckError('元数据还未更新')
    wait('Metadata 增量更新', metadata_update)

    # The marker exists only in file contents, never in filename/library name.
    def search_content():
        result = request('GET', '/api2/search/', params={'q': search_marker, 'search_repo': repo, 'search_filename_only': 'false'}).json()
        if 'check.txt' not in json.dumps(result):
            raise CheckError('SeaSearch 尚未索引测试文件正文')
    wait('SeaSearch 实际正文索引结果', search_content)

    info = request('POST', '/api/v2.1/wikis2/', json={'name': 'deploy-wiki-' + uuid.uuid4().hex}).json()
    wiki = info.get('id') or info.get('wiki_id') or info.get('repo_id')
    if not wiki:
        raise CheckError('知识库未返回 ID')
    page = request('POST', f'/api/v2.1/wiki2/{wiki}/pages/', json={'page_name': 'Deployment check'}).json()['file_info']
    detail = request('GET', f'/api/v2.1/wiki2/{wiki}/page/{page["page_id"]}/').json()
    if not detail.get('seadoc_access_token'):
        raise CheckError('知识库缺少 SeaDoc 令牌')
    print('PASS Wiki 创建、页面创建、SeaDoc 令牌签发', flush=True)
    print('待浏览器验收：SeaDoc 双人协作及持久化、Office 编辑保存回调、实时通知与客户端同步。', flush=True)
except Exception as exc:
    failed = True
    # Requests exceptions can include token-bearing URLs; never print their raw values.
    print('FAIL ' + (str(exc) if isinstance(exc, CheckError) else type(exc).__name__), file=sys.stderr)
finally:
    for kind, identifier in [('wiki2', wiki), ('repo', repo)]:
        if identifier:
            path = f'/api/v2.1/wiki2/{identifier}/' if kind == 'wiki2' else f'/api2/repos/{identifier}/'
            try:
                request('DELETE', path)
                print('CLEAN ' + kind, flush=True)
            except Exception:
                failed = True
                print(f'FAIL 请手动清理本次测试对象 {kind}: {identifier}', file=sys.stderr)
if failed:
    sys.exit(1)
PY
cat > "$TARGET/README.txt" <<EOF
Seafile 13 Pro 部署（含 SeaSearch 全文搜索）
主地址: $SEAFILE_SERVER_PROTOCOL://$SEAFILE_SERVER_HOSTNAME
账号及随机初始密码: .env 的 INIT_SEAFILE_ADMIN_EMAIL / INIT_SEAFILE_ADMIN_PASSWORD
./deploy.sh 执行初始化；./verify.sh 业务验收；./compose.sh ps / logs 查看状态。
PULL=1 ./deploy.sh 才主动刷新已有镜像；缺少镜像时 Compose 自动拉取。
本脚本只初始化空目录，不包含旧版本识别、迁移或升级逻辑。
请勿修改项目名/容器前缀后直接复用运行中的目录；不要将 CE 数据直接混用到本目录。
全部持久化数据位于本目录 data/；不使用项目命名卷。
浏览器与容器必须能访问主地址；内网 IP 次要入口不承诺完整协同/Office/登录行为。
外部反代必须转发 Host、X-Forwarded-Proto 及 WebSocket，配置实际代理来源到可信代理列表。
验收会创建并删除测试资料库和 Wiki，回收站可能保留测试记录。
改过管理员密码后用 VERIFY_USERNAME/VERIFY_PASSWORD 或 VERIFY_TOKEN；
详细说明、测试边界与反代示例见仓库 README.md / docs/。
EOF
chmod 700 "$TARGET/compose.sh" "$TARGET/deploy.sh" "$TARGET/verify.sh"
for file in common.sh compose.sh deploy.sh verify.sh; do
  bash -n "$TARGET/$file"
done
for file in docker-compose.yml common.sh configure.py verify.py verify.sh deploy.sh compose.sh README.txt; do
  mv "$TARGET/$file" "$DEPLOY_TARGET/$file"
done
rmdir "$STAGE"
STAGE=''
TARGET="$DEPLOY_TARGET"
echo "已生成 Pro 部署文件: ${TARGET}；凭据见 .env（请勿提交 Git）。"
# Release generator lock before the generated deployer acquires it.
rmdir "$TARGET/.operation-lock"
trap - EXIT
if [[ "$GENERATE_ONLY" == 1 ]]; then
  echo "仅生成完成。部署: $TARGET/deploy.sh"
else
  "$TARGET/deploy.sh"
fi
