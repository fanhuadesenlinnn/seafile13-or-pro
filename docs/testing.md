# 测试与验收

## 离线回归

```bash
bash tests/run.sh
```

22 项回归覆盖 CE/Pro 的服务与反代配置、所有持久化挂载位于部署目录、已有部署拒绝覆盖、随机凭据与环境变量隔离、非法配置拒绝、并发锁、配置文件生成与幂等写入。还执行 Bash/Python 语法检查及 ShellCheck（已安装时）。Compose 渲染需要 Docker CLI，不需要启动服务；缺少 CLI 的项目会明确跳过。

## 真实首次部署测试

```bash
TEST_EDITION=ce TEST_HOSTNAME=192.168.1.100 TEST_PORT=28913 bash tests/integration.sh
TEST_EDITION=pro TEST_HOSTNAME=192.168.1.100 TEST_PORT=28914 bash tests/integration.sh
```

测试创建唯一目录和独立 Compose 项目，执行首次初始化和自动验收，结束后移除本次容器及网络。数据和凭据留在被 Git 忽略的 `deployments/` 下，不清理其他 Docker 资源。

宿主机和所有容器均须能访问 `TEST_HOSTNAME`。不要使用容器回环地址 `localhost/127.0.0.1`。

OrbStack 的 macOS 共享目录不能保留 Office PostgreSQL 要求的属主，因此最终全目录挂载方案不能在该共享目录部署。可使用以下测试入口，在 Docker 主机的 Linux `/var/lib/seafile13-linux-test-*` 目录运行同一脚本：

```bash
TEST_EDITION=ce TEST_HOSTNAME=192.168.1.100 bash tests/linux-filesystem.sh
TEST_EDITION=pro TEST_HOSTNAME=192.168.1.100 bash tests/linux-filesystem.sh
```

该入口临时使用 `docker:27-cli` 并安装测试依赖，通过 Docker socket 调用现有 daemon，打印 Linux 测试数据目录；测试容器自动清理，数据留作排查。它只是测试工具，正常部署只需要对应版本的一个初始化脚本。macOS 仓库内保存测试源码，可将日志重定向到忽略目录 `test-results/`。

## 自动业务验收

两个版本共同检查：

- 容器端和执行脚本的一端访问公开 Seafile API。
- API 登录、创建临时资料库、上传、下载及内容比对。
- SeaDoc 公开路由和 Socket.IO 握手、Wiki/页面创建及 SeaDoc 令牌。
- ONLYOFFICE 公开健康接口及编辑器 JavaScript。
- Notification 的公开 ping。
- Metadata 初始化及新增文件后的增量更新。
- 最后删除本次资料库和 Wiki；失败也尝试清理，未成功时报告对象 ID。

CE 另检查 WebDAV 认证、PROPFIND、GET、PUT、MOVE、DELETE，以及上传真实 PNG 后读取独立服务生成的缩略图。

Pro 另上传含随机正文标记的文件，调用全文检索 API 并确认返回该文件，避免只验证文件名搜索。

## 验证记录与边界

2026-09-23，macOS + OrbStack Linux ARM64：22 项回归、ShellCheck 与语法检查通过。CE 13.0.28、Pro 13.0.28 和 ONLYOFFICE 8.1.0.1 在 Docker 主机 Linux 文件系统上的空目录部署，两个版本上述自动业务检查均通过，包括 CE WebDAV/实际缩略图和 Pro 正文全文检索。运行中的挂载检查确认持久化数据使用部署目录下的 bind mount，没有匿名数据卷；Docker socket 是唯一的外部挂载。

同日生产维护验证了 Pro 13.0.28 现有实例启用 WebDAV 后，公网 HTTPS 与局域网 HTTP 的 PROPFIND、PUT、GET、MOVE、DELETE 均正常；还将该实例遗留的五个 Docker 卷切换为项目 `data/` 绑定目录并核对服务健康。Pro 脚本随后补入 WebDAV 的首次部署配置与验收；该修改已通过离线生成、Compose 渲染和配置幂等回归，尚未再做一次全新 Pro 实例的端到端部署。

macOS 共享目录测试明确复现 PostgreSQL 属主不兼容；初始化已加入提前报错。测试入口与完整日志保存在项目中，日志位于 Git 忽略的 `test-results/`。

早期 CE 反代方案已通过独立 Nginx HTTPS 终止后的 API/WebDAV MOVE/缩略图/Metadata/Wiki 验收；该次使用项目命名卷存储 Office PostgreSQL，不能代替最终全目录挂载方案的验收。

仍需在目标环境人工测试浏览器内的 Office 编辑保存回调、SeaDoc 多人协作和刷新持久化、实时通知更新、客户端同步。自动缩略图用例使用 PNG，不覆盖全部视频/PDF 格式；公网证书签发、实际 FRP/VPS 链路、大文件压力与备份恢复也不在自动验收范围内。

默认版本通道未来可能变化，测试结果不代表未来镜像已经验证。
