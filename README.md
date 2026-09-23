# Seafile 13 CE / Pro 单脚本初始化

选一个版本，只复制对应的 **一个脚本** 到服务器即可。脚本自动生成配置、启动全部服务并执行业务验收，不需要另外下载模板，也不依赖宿主机 Python。

- 社区版：`init-seafile13ce.sh`，不包含全文检索，增加独立缩略图服务和 WebDAV。
- 专业版：`init-seafile13pro-fixed-v2.sh`，包含 SeaSearch 全文检索和 WebDAV；授权条件遵循 Seafile Pro。

两个脚本都只负责**首次部署**，不提供迁移、接管旧实例或升级流程；生成的 `deploy.sh` 也拒绝复用已有数据。部署目录非空时拒绝覆盖。所有服务的持久化数据均在指定部署目录的 `data/` 下，没有需要另行寻找的 Docker 数据卷。

## 功能

| 功能 | CE | Pro |
| --- | --- | --- |
| Seafile 13 网盘、同步与分享 | ✓ | ✓ |
| MariaDB、Redis 密码认证和 AOF 持久化 | ✓ | ✓ |
| SeaDoc 2、Wiki | ✓ | ✓ |
| ONLYOFFICE 预览编辑、JWT、同域反代 | ✓ | ✓ |
| Metadata 扩展属性、Notification 通知 | ✓ | ✓ |
| 独立 Thumbnail 服务、视频缩略图配置 | ✓ | 未添加 |
| WebDAV 读写与重命名 | ✓ | ✓ |
| SeaSearch 全文检索 | 不包含 | ✓ |
| Caddy HTTP/HTTPS、外部反代、镜像代理、多实例隔离 | ✓ | ✓ |

“未添加”表示脚本没有配置该功能，不表示产品不支持。服务启动及 API 验收不等于所有浏览器交互均已测试，详见 [测试说明](docs/testing.md)。

## 使用

部署目录须位于支持 Linux UID/GID 和权限的本地文件系统。OrbStack 的 macOS 共享目录不满足 Office PostgreSQL 的属主要求；应在 Linux 主机/虚拟机内部署，脚本会提前检查并拒绝不兼容挂载。

要求 Bash 3.2+、OpenSSL、curl、Docker 和 Compose v2.20+。支持普通 Docker、`pg-docker`，镜像必须支持服务端 CPU 架构。脚本不会安装 Docker。

修改脚本顶部的“常用修改配置”，一般只需设置访问域名/IP、端口和管理员邮箱；每项都有简短备注。也可直接传环境变量：

```bash
SEAFILE_SERVER_HOSTNAME=192.168.1.100 \
INIT_SEAFILE_ADMIN_EMAIL=admin@example.com \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

专业版把脚本和目录分别换成 `init-seafile13pro-fixed-v2.sh`、`./deployments/seafile13-pro`。默认 HTTP 端口为 `28080`。宿主机和所有容器都必须能访问所填主地址，不能使用容器回环地址 `127.0.0.1`。

初始管理员密码保存在部署目录 `.env` 的 `INIT_SEAFILE_ADMIN_PASSWORD` 中；数据库密码和 JWT 密钥也自动随机生成，不打印到日志。

如需先检查生成结果，在命令前加 `GENERATE_ONLY=1`，然后进入部署目录执行 `bash deploy.sh` 完成初始化。正常部署不需要此选项。首次启动 Office 前，脚本会将镜像自带的初始数据库等文件复制到 `data/onlyoffice/`，这是空目录初始化，不读取任何旧实例数据。

## HTTPS 和外部反代

Caddy 直接管理 HTTPS：设置 `SEAFILE_SERVER_PROTOCOL=https`，域名 DNS 指向服务器并开放标准 80/443 端口。

已有 Nginx/OpenResty/FRP 的 HTTPS 入口：

```bash
SEAFILE_SERVER_HOSTNAME=files.example.com \
SEAFILE_SERVER_PROTOCOL=https \
EXTERNAL_REVERSE_PROXY=1 \
CADDY_HOST_PORT=28080 \
CADDY_TRUSTED_PROXIES='192.168.1.20/32' \
bash init-seafile13ce.sh ./deployments/seafile13-ce
```

可信代理填写 Caddy 实际看到的来源 IP/CIDR。外层需要保留 Host、传递协议并支持 WebSocket；脚本不会配置 VPS、FRP 或外层证书。Office 反代明确传递最终访问协议，并交由 Caddy 处理来源地址链。详见 [反向代理说明](docs/reverse-proxy.md)。

两个版本都会启用 `/seafdav/`。如需同时用公网域名和局域网 IP，可在 `CADDY_SITE` 中列出两个 HTTP 内层站点；WebDAV 路由对两者生效。局域网 HTTP 会明文传输登录凭据，实际使用优先选择 HTTPS 地址。

## 其他常用配置

- `IMAGE_PREFIX=mirror.example.com`：镜像代理，不带协议，作用于全部镜像。
- `CONTAINER_PREFIX=seafile-second`：多实例时配合不同端口和部署目录使用；容器、网络、Caddy 标签隔离。
- `DOCKER_COMMAND=pg-docker`、`DOCKER_COMPOSE_COMMAND='pg-docker compose'`：可手动指定 Docker 命令。
- `DOCKER_SOCKET`：Docker 服务端的 socket，懒猫可按实际路径设置。
- `DEPLOY_TIMEOUT=900 VERIFY_TIMEOUT=600`：慢机器可增加等待时间。

镜像在“一般不需要修改配置”中。首次部署可固定版本或 registry digest；默认 `13.0-latest` 等通道未来会变化，本仓库测试只覆盖记录中的镜像。此项目不实现已有数据的镜像/数据库升级。

## 文件、状态与重新初始化

脚本生成 `.env`、`docker-compose.yml` 和部署/验收辅助文件；它们是运行产物，不需要事先准备。

```bash
cd deployments/seafile13-ce
./compose.sh ps
./compose.sh logs --tail=100 seafile
./verify.sh
./compose.sh stop   # 停止服务
./compose.sh down   # 移除本项目容器和网络，保留目录中的数据
```

数据包括 `data/mysql`、`data/seafile`、`data/redis`、`data/seadoc`、`data/caddy*`、`data/onlyoffice`，Pro 另有 `data/seasearch`。Office 的 PostgreSQL、Redis、RabbitMQ、字体、日志和业务数据均挂载到该目录。

**如果失败后想从头开始：先在部署目录运行 `./compose.sh down`，再自行删除该部署目录，最后重新执行主脚本。** 删除目录会丢失全部数据和凭据；仅删除目录不会停止还在运行的容器。脚本不会替你删除数据。

备份时保留整个部署目录；先停止服务再复制，避免直接复制正在写入的数据库文件。配置文件中的 `.before-deploy-*` 只是配置备份。

## 测试

```bash
bash tests/run.sh
TEST_EDITION=ce TEST_HOSTNAME=192.168.1.100 bash tests/integration.sh
TEST_EDITION=pro TEST_HOSTNAME=192.168.1.100 bash tests/integration.sh
```

离线回归使用 Python 标准库；Compose 渲染需要 Docker CLI。真实集成测试需要 Docker 服务，创建独立项目，结束后移除测试容器并保留忽略目录中的数据。覆盖范围及限制见 [测试说明](docs/testing.md)。

默认部署目录、凭据、数据及测试产物均被 Git 忽略；如果改用仓库内其他路径，需自行添加忽略规则。

## 官方参考

- [CE 13 部署](https://manual.seafile.com/13.0/setup/setup_ce_by_docker/)
- [SeaDoc](https://manual.seafile.com/13.0/extension/setup_seadoc/)、[ONLYOFFICE](https://manual.seafile.com/13.0/extension/only_office/)
- [Metadata](https://manual.seafile.com/13.0/extension/metadata-server/)、[Notification](https://manual.seafile.com/13.0/extension/notification-server/)
- [Thumbnail](https://manual.seafile.com/13.0/extension/thumbnail-server/)、[WebDAV](https://manual.seafile.com/13.0/extension/webdav/)
