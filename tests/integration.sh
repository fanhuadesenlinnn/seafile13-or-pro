#!/usr/bin/env bash
# Explicit opt-in real integration deployment; no existing project is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEST_HOSTNAME:?设置为宿主机和容器均可访问的 IPv4/域名（不带端口）}"
case "$TEST_HOSTNAME" in localhost|127.*) echo '测试主地址不能使用容器回环地址' >&2; exit 2;; esac
case "${TEST_EDITION:-ce}" in
  ce) script=init-seafile13ce.sh;;
  pro) script=init-seafile13pro-fixed-v2.sh;;
  *) echo 'TEST_EDITION 必须是 ce 或 pro' >&2; exit 2;;
esac
run_id="$(date +%Y%m%d%H%M%S)-$$"
target="$PWD/deployments/test-$run_id"
export CONTAINER_PREFIX="seafile13${TEST_EDITION:-ce}-test-$run_id"
export SEAFILE_SERVER_HOSTNAME="$TEST_HOSTNAME"
export CADDY_HOST_PORT="${TEST_PORT:-28913}"
export CADDY_CONTAINER_PORT=80
export EXTERNAL_REVERSE_PROXY=0
export SEAFILE_SERVER_PROTOCOL=http
export CADDY_SITE="http://$TEST_HOSTNAME"
export GENERATE_ONLY=0
cleanup() {
  if [[ -f "$target/compose.sh" ]]; then bash "$target/compose.sh" down || true; fi
  echo "测试数据与凭据保留于 ${target}（已被 Git 忽略）。所有持久化数据均在该目录。"
}
trap cleanup EXIT
bash "./$script" "$target"
