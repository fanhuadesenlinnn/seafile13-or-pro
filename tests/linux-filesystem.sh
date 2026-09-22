#!/usr/bin/env bash
# Optional Docker-host-native filesystem test for macOS/OrbStack bind-mount limitations.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEST_HOSTNAME:?设置为宿主机和容器均可访问的 IPv4/域名}"
case "${TEST_EDITION:-ce}" in ce|pro) ;; *) echo 'TEST_EDITION 必须是 ce 或 pro' >&2; exit 2;; esac
# This directory is on the Docker daemon host, not on the macOS shared filesystem.
native_root="/var/lib/seafile13-linux-test-$(date +%Y%m%d%H%M%S)-$$"
echo "Linux 测试目录: $native_root"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/source:ro" \
  -v "$native_root:$native_root" -w "$native_root" \
  -e TEST_HOSTNAME -e "TEST_EDITION=${TEST_EDITION:-ce}" -e "TEST_PORT=${TEST_PORT:-28913}" \
  docker:27-cli sh -ec '
    apk add --no-cache bash openssl curl python3 >/dev/null
    cp /source/init-seafile13ce.sh /source/init-seafile13pro-fixed-v2.sh .
    mkdir tests
    cp /source/tests/integration.sh tests/
    bash tests/integration.sh
  '
# integration.sh removes its own containers; native data remains for diagnosis.
echo "测试数据留在 Docker 主机 ${native_root}；未写入 macOS 部署目录。"
