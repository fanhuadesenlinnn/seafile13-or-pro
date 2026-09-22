# 外部反向代理与 WebDAV

推荐拓扑：浏览器 → HTTPS Nginx/OpenResty → FRP（可选）→ 内层 HTTP Caddy → Seafile/扩展。

脚本配置 `EXTERNAL_REVERSE_PROXY=1`、`SEAFILE_SERVER_PROTOCOL=https`，主域名为最终用户访问的域名。下面示例中的 `127.0.0.1:28080` 是反代所在机器可达的内层入口；使用 FRP 时换成实际 FRP 监听端口。

```nginx
# 放在 http 块中
map $http_upgrade $seafile_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name files.example.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:28080;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $seafile_connection_upgrade;
        proxy_read_timeout 1200s;
        proxy_send_timeout 1200s;
        proxy_request_buffering off;
    }
}
```

证书及端口由外部环境负责；本仓库不会修改现有 VPS 配置。

## 关键路径

| 路径 | Caddy 上游 | 是否剥离前缀 |
| --- | --- | --- |
| `/`、`/seafhttp/` | `seafile:80` | 否 |
| `/seafdav*` | `seafile:8080` | 否 |
| `/sdoc-server/*` | `seadoc:80` | 是 |
| `/socket.io/*` | `seadoc:80` | 最终保留 `/socket.io` |
| `/onlyofficeds/*` | `onlyoffice:80` | 是；向 Office 传递子路径和主协议 |
| `/notification*` | `notification-server:8083` | 去掉 `/notification` |
| `/thumbnail/*` | `thumbnail-server:80` | 否 |
| `/thumbnail/ping` | `thumbnail-server:80/ping` | 重写为 `/ping` |

Notification 规则沿用官方 `/notification*` + `handle_path`；不要在外层额外去掉这些路径，否则会重复改写。

## WebDAV MOVE 为什么直接转发 8080

HTTPS 在外部终止后，内层 HTTP 的 `$scheme` 是 `http`。如果再经过镜像内部 Nginx 并覆盖原始协议，WebDAV 的 `Destination: https://...` 与服务看到的源协议可能不一致，导致 MOVE/重命名报错。

本脚本在 Caddy 中将 `/seafdav*` 直接转发到内部 SeafDAV 8080，保留 `/seafdav` 前缀，并把 `X-Forwarded-Proto` 设为配置的主协议。8080 不暴露到宿主机；访问仍经过统一入口和 SeafDAV 身份认证。验收包含 PUT → MOVE → GET → DELETE，不能只用浏览目录代替。

## 内外网地址

- 一个部署使用一个 canonical URL；Office、SeaDoc 和文件服务会生成指向它的链接。
- 内网使用同一域名及协议最稳妥。可通过分区 DNS 让它走内网 HTTPS 入口。
- `CADDY_SITE` 多站点只让 Caddy 接收这些 Host，不自动保证跨域 Cookie、CSRF、所有客户端及编辑器均支持多个主地址。
- `CADDY_TRUSTED_PROXIES` 填实际代理来源 IP/CIDR，避免任意信任所有来访地址。
- 主机能打开首页但容器不能访问主地址时，Office 下载/保存回调仍可能失败。`verify.sh` 会同时检查容器内和宿主机访问。
- 对外 HTTPS 反代建议限制内层 HTTP 端口的访问范围。默认 `CADDY_BIND_ADDRESS=0.0.0.0` 适合 LAN/FRP；同机反代可设置 `127.0.0.1`，同时确保容器回连主域名的网络路径可用。
