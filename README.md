# Seafile 13 社区版单脚本部署

一个可独立分发的 Bash 脚本：`init-seafile13ce.sh`。基于原 Pro 部署流程改写，默认一次部署所有下列功能，不需要手动下载 Compose 模板。

| 功能 | 实现 |
| --- | --- |
| 网盘、同步、分享 | Seafile CE 13，官方 `seafileltd/seafile-mc` 镜像 |
| 数据库、缓存与事件队列 | MariaDB 10.11 + 带密码及 AOF 持久化的 Redis |
| 在线文档、Wiki | SeaDoc 2.0 + WebSocket |
| Office 在线预览、编辑 | ONLYOFFICE + JWT + `/onlyofficeds/` 同域反代 |
| 扩展属性 | Metadata Server，默认每个资料库 100000 文件限制 |
| 实时通知 | Notification Server |
| 图片、视频缩略图 | Thumbnail Server，启用视频缩略图配置 |
| WebDAV | `/seafdav/`，支持认证、读写与重命名 |
| HTTP/HTTPS | Caddy 直出，或接在已有 Nginx/OpenResty/FRP 后 |

**不包含 SeaSearch/全文检索、AI、人脸识别或其他 Pro 专属能力。** 本脚本用于新建 CE 部署以及重跑本脚本建立的部署，不用于 Pro → CE 降级迁移。

## 前提

- Linux Docker 主机，或测试用 Docker Desktop/OrbStack；Bash 3.2+、OpenSSL、curl。
- Docker Compose v2.20+（支持 `up --wait --wait-timeout`）。支持 `pg-docker`；已有 `.env` 会记录实际命令。
- 全套带 Office、Metadata、缩略图的环境建议预留至少 4 核 / 8 GB 内存及充足磁盘；这是本项目的运行预算建议，不是 CE 核心最低要求。
- 选定镜像必须支持 Docker daemon 的架构。脚本不强制跨架构模拟。
- 浏览器、宿主机、容器、Office 服务都必须能访问主地址。不要将 `127.0.0.1` 作为需要容器回连的主地址。

## 直接 HTTP 部署

```bash
SEAFILE_SERVER_HOSTNAME=192.168.1.100 \
INIT_SEAFILE_ADMIN_EMAIL=admin@example.com \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

默认入口 `http://192.168.1.100:28080`。管理员初始密码随机生成在部署目录 `.env`；不打印到日志。脚本会生成配置、启动服务并自动验收。

只生成文件：

```bash
GENERATE_ONLY=1 SEAFILE_SERVER_HOSTNAME=192.168.1.100 \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

该模式不启动容器、不拉取镜像。首次 Linux 自动探测 socket 可能读取 Docker context，不连接 daemon。

## 公网域名 + VPS/OpenResty/FRP

```bash
SEAFILE_SERVER_HOSTNAME=files.example.com \
SEAFILE_SERVER_PROTOCOL=https \
EXTERNAL_REVERSE_PROXY=1 \
CADDY_HOST_PORT=28080 \
CADDY_SITE='http://files.example.com, http://192.168.1.100' \
CADDY_TRUSTED_PROXIES='192.168.1.20/32' \
INIT_SEAFILE_ADMIN_EMAIL=admin@example.com \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

把示例地址换成实际环境；可信代理填 **Caddy 实际看到的反代源 IP**，考虑 Docker NAT。此模式只提供内层 HTTP 入口，**不会安装 FRP、配置 VPS 或申请外层证书**。外层必须保留 Host、正确传递协议并支持 WebSocket。配置示例及 WebDAV MOVE 注意事项见 [反向代理说明](docs/reverse-proxy.md)。

公网主地址始终为 `https://files.example.com`。内网 IP 可作为附加路由入口，但 API 链接、CSRF、Office/SeaDoc 的主地址仍使用域名；完整使用推荐内网 DNS 将同一域名指向可用的 HTTPS 入口。

## Caddy 直接管理 HTTPS

```bash
SEAFILE_SERVER_HOSTNAME=files.example.com \
SEAFILE_SERVER_PROTOCOL=https \
EXTERNAL_REVERSE_PROXY=0 \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

DNS 指向服务器，并开放公网 80/443。本脚本将自动 HTTPS 限定为标准端口；非标准 TLS 入口请使用外部反代模式。

## 懒猫微服、镜像代理、多实例

首次部署可设置：

```bash
DOCKER_COMMAND=pg-docker \
DOCKER_COMPOSE_COMMAND='pg-docker compose' \
DOCKER_SOCKET=/lzcsys/data/playground/docker.sock \
IMAGE_PREFIX=mirror.example.com \
CONTAINER_PREFIX=seafile13ce-second \
CADDY_HOST_PORT=28081 \
SEAFILE_SERVER_HOSTNAME=192.168.1.100 \
bash init-seafile13ce.sh ./deployments/seafile13ce-second
```

- 未指定命令时优先选择存在的 `pg-docker`，否则 `docker`。
- `DOCKER_SOCKET` 是 **Docker daemon 所在环境** 的 socket，不一定等于宿主 CLI 连接路径；macOS Desktop/OrbStack 默认 `/var/run/docker.sock`。
- 镜像代理不带协议，自动加末尾 `/`，对所有镜像生效。使用完整私有仓库镜像地址时将 `IMAGE_PREFIX` 留空。
- 多实例使用不同目录、`CONTAINER_PREFIX` 和端口；网络、命名卷及 Caddy Docker 标签命名空间均按 Compose 项目隔离。
- 不要修改运行中实例的项目名或前缀来“重命名”；这可能造成容器冲突或多个实例同时使用同一数据。

## 日常操作

```bash
cd deployments/seafile13-ce
./compose.sh ps
./compose.sh logs --tail=100 seafile
./deploy.sh                       # 重跑部署和验收
./verify.sh                       # 只做验收
./compose.sh stop                  # 停止，不删除数据
./compose.sh down                  # 移除容器和网络，保留数据及命名卷
```

更新配置：修改部署目录 `.env`，再从仓库根目录执行原单脚本。**已有 `.env` 优先于环境变量及脚本默认值**，不会被首次配置覆盖。`GENERATE_ONLY`、`PULL`、`DEPLOY_TIMEOUT`、`VERIFY_TIMEOUT` 是当次操作参数。

`.env` 使用未加引号的 `KEY=value`；密码自动使用十六进制字符。脚本不 `source .env`，不支持 `$` 插值、命令替换、多行值或带引号的值；未知键、重复键、缺少凭据会拒绝执行。自定义 Seafile 配置应放在 `data/seafile/seafile/conf/seahub_settings.py` 的托管块之外；同名托管配置会以托管块为准。网页管理中的 URL 覆盖项也需与主地址保持一致。

```bash
PULL=1 ./deploy.sh                # 明确请求拉取更新，事先备份
DEPLOY_TIMEOUT=900 VERIFY_TIMEOUT=600 ./deploy.sh
VERIFY_USERNAME=admin@example.com VERIFY_PASSWORD='当前密码' ./verify.sh
```

还可以用 `VERIFY_TOKEN` 验证 API，但 WebDAV 仍需要用户名/密码；可用 `VERIFY_WEBDAV_USERNAME`、`VERIFY_WEBDAV_PASSWORD` 单独提供应用密码。凭据的环境变量传入方式需要考虑本机 shell 历史，勿在共享终端直接粘贴真实密码。

镜像默认沿用原脚本的版本通道和 Office 8.1.0.1。`PULL=0` 不主动刷新已有镜像，缺少镜像时仍会下载。生产部署在兼容性验证后，可在 `.env` 将镜像固定为 `仓库@sha256:...`；本项目不宣称旧 Office 版本已完成安全审计。升级是独立运维操作，重跑不是数据回滚。

## 文件与备份

运行后生成 `.env`、`docker-compose.yml`、`common.sh`、`configure.py`、`deploy.sh`、`compose.sh`、`verify.sh`、`verify.py`、`README.txt`。

- `data/mysql`：Seafile 数据库。
- `data/seafile`：Seafile 配置、资料库、Metadata/缩略图等共享数据。
- `data/seadoc`、`data/redis`、`data/caddy*`、`data/onlyoffice`：各服务数据。
- **ONLYOFFICE PostgreSQL 使用项目命名卷 `<项目名>_onlyoffice-postgres`**，不在部署目录内。采用命名卷是为了保留镜像内预置数据库并维持正确权限。
- `config-backups/` 和 `.before-deploy-*` 仅为配置备份，**不是完整数据备份**。

完整备份必须包含一致的数据库备份、资料库和各扩展数据；ONLYOFFICE 命名卷也需单独备份。可在停止写入并停止服务后对目录和命名卷进行冷备份，或依官方方案执行数据库逻辑备份及文件备份。不要仅复制运行中的 MariaDB 文件夹，不要使用 `down -v` 作为日常停止命令。恢复流程应在独立环境演练。

## 测试与已知边界

```bash
python3 -m unittest discover -s tests -v
shellcheck init-seafile13ce.sh
```

单元/回归测试只需 Python 标准库；Compose 渲染测试需要 Docker CLI，不需要 daemon。真实部署测试及覆盖范围见 [测试说明](docs/testing.md)。`verify.sh` 会创建临时资料库/Wiki 后删除；回收站可能保留记录。失败也尝试清理，并输出未清理对象的 ID。

配置生成成功不等于业务验收成功；Office 和 SeaDoc 的浏览器编辑保存、双人协作、通知 WebSocket 及客户端同步需按测试清单验收。

## 官方参考

- [CE 13 部署](https://manual.seafile.com/13.0/setup/setup_ce_by_docker/)
- [SeaDoc](https://manual.seafile.com/13.0/extension/setup_seadoc/)、[ONLYOFFICE](https://manual.seafile.com/13.0/extension/only_office/)
- [Metadata](https://manual.seafile.com/13.0/extension/metadata-server/)、[Notification](https://manual.seafile.com/13.0/extension/notification-server/)
- [Thumbnail](https://manual.seafile.com/13.0/extension/thumbnail-server/)、[WebDAV](https://manual.seafile.com/13.0/extension/webdav/)

本仓库只提交脚本、文档与测试；默认部署目录、凭据、数据和测试输出已加入 `.gitignore`。自选仓库内的其他部署路径时，必须自行加入忽略规则后再推送。
