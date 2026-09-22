# 测试与验收

## 离线回归

执行：

```bash
./tests/run.sh
```

当前 12 项回归测试覆盖：

1. 全套 9 个容器、WebDAV/缩略图路由、数据库及缓存连接、仅暴露 Caddy 端口。
2. 配置托管块幂等，保留自定义配置及配置备份。
3. 重跑保留 `.env`、凭据及数据，不接受环境变量偷偷覆盖。
4. 宿主环境中的数据库、Redis、Metadata 端口、SeaDoc 路径不能改变内部拓扑。
5. 外部反代与多站点格式。
6. HTTPS 80/443、镜像代理、第二实例容器和 Caddy 标签隔离。
7. 非法端口、协议、命令、主机、前缀和模式拒绝执行。
8. 数据存在但 `.env` 丢失时拒绝生成新凭据。
9. 并发操作锁。
10. 恶意 `.env` 命令替换不执行。
11. Pro/未知部署目录拒绝覆盖。
12. 缺少键、重复键拒绝执行。

还检查主脚本及生成脚本的 Bash 语法、生成 Python 的语法；安装 ShellCheck 时执行静态检查。Compose 渲染通过 Docker CLI 完成，无需启动 daemon。缺少 Docker CLI 时相关用例明确标为 skipped，不能当作已经验证渲染。

## 真实隔离集成测试

```bash
TEST_HOSTNAME=192.168.1.100 TEST_PORT=28913 ./tests/integration.sh
```

将主机地址替换成测试机器真实 LAN IPv4 或可解析域名。脚本创建唯一项目和目录，执行两轮完整部署/验收，结束时移除本次容器及网络；保留被 Git 忽略的测试数据、配置和命名卷用于排查。不会清理其他 Docker 资源，不执行全局 prune。

不要用 localhost/127.0.0.1：容器中的回环地址不是宿主机。`host.docker.internal` 在容器中通常可用，但宿主操作系统不一定能解析；双端验收会检测这一点。

每次 `verify.sh` 自动检查：

- 从容器访问公开 Seafile API。
- SeaDoc 公开入口及 Socket.IO 握手。
- ONLYOFFICE 健康和编辑器 JS。
- Notification 与 Thumbnail 的公开 ping。
- API 登录、创建资料库、上传文件、下载并比对内容。
- WebDAV Basic/应用密码认证、PROPFIND、读取、PUT、MOVE、移动后读取比对、DELETE。
- 上传 640×480 PNG，经过独立缩略图服务生成并读取最大边 256 的真实图片。
- 启用元数据、初始化记录、新增文件后等待元数据增量更新。
- 创建 Wiki、创建页面、验证 SeaDoc 访问令牌。
- 清理本次创建的 Wiki/资料库；失败时也清理并报告残留对象 ID。
- 从宿主机访问同一主地址。

## 本次验证记录（2026-09-22）

环境：macOS + OrbStack Linux ARM64，Docker Compose v5.1.2，独立项目 `seafile13ce-test`。

已通过 12 项回归、ShellCheck、Bash/Python 语法和 Compose 渲染。真实 HTTP 部署全部自动业务检查通过，包含多次重跑和主地址修改后重新生成配置。

另外使用独立 Nginx 容器在 28914 端口终止 TLS，再转发到内层 Caddy HTTP，完整自动验收也全部通过，包含 WebDAV PUT/MOVE/GET/DELETE、实际图片缩略图、Metadata 增量更新和 Wiki。测试使用一天有效期的自签名测试证书，显式加入测试容器的 requests CA bundle，宿主 curl 使用该证书作为 CA；没有关闭 TLS 校验，也没有修改系统级证书信任。测试不覆盖真实公网证书签发、实际 VPS/FRP 链路或浏览器 Office 保存回调。

主镜像实际版本为 **Seafile CE 13.0.28**；记录本机镜像 ID（不是可用于拉取的 registry digest）：

- Seafile CE：`sha256:b0c90832126bf432db908449f1bb450211e6bbf75a2193bab3399e2a9636eccf`，arm64。
- ONLYOFFICE 8.1.0.1：`sha256:423328ee377374c48a30c2aa416e4afedf621faff068f97966cb9b87a28550bd`，arm64。

`13.0-latest` 等通道以后可能指向新镜像；此记录只覆盖本次测试镜像，不代表未来更新已验证。生产固定镜像应使用 registry RepoDigest，不能把上面的本机 image ID 当成 registry digest。

## 仍需在目标环境验收

这些不是自动脚本已经证明的能力：

1. 浏览器打开 Wiki/SeaDoc，输入内容，刷新确认保存；两个不同用户同时编辑，确认协作与权限。
2. 上传实际 DOCX/XLSX/PPTX，编辑、关闭并重新打开，确认文件保存回调和版本变化。
3. 两个浏览器同时打开同一资料库，另一个新增/删除文件，确认通知自动更新；客户端同步及 SeaDrive 单独验证。
4. 上传目标相机/手机的视频、PDF及高分辨率图片，检查缩略图；本次自动图像测试使用 PNG，不覆盖所有编码格式。
5. 分享权限、加密资料库、目标 WebDAV 客户端、双因素认证/应用密码等按实际使用场景测试。
6. 公网 DNS、正式证书签发续期、实际 FRP/OpenResty 网络路径与代理来源 IP。
7. 备份恢复、大文件、大资料库及并发压力。

WebDAV 适合兼容访问；大量小文件的高频操作优先用同步客户端。预设图像大小限制为 256 MB；Thumbnail 对 PDF 等类型还有上游自身的限制，不能把图片成功等同于所有文件都可生成缩略图。
