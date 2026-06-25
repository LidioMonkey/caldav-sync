# Nginx 反向代理配置模板

## 完整配置

将以下内容写入 `/etc/nginx/sites-available/caldav`，替换 `<DOMAIN>` 为实际域名：

```nginx
#===============================================================================
# CalDAV Reverse Proxy — Baikal
#===============================================================================

# HTTP → HTTPS 重定向
server {
    listen 80;
    listen [::]:80;
    server_name <DOMAIN>;

    # Let's Encrypt ACME 验证
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # 其他请求重定向到 HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS 主服务
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name <DOMAIN>;

    # ── SSL 证书 ──────────────────────────────────────────────
    ssl_certificate     /etc/letsencrypt/live/<DOMAIN>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<DOMAIN>/privkey.pem;

    # ── SSL 安全配置 ──────────────────────────────────────────
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS (取消注释以启用，注意：一旦启用浏览器会强制 HTTPS)
    # add_header Strict-Transport-Security "max-age=63072000" always;

    # ── 安全头 ────────────────────────────────────────────────
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ── 日志 ──────────────────────────────────────────────────
    access_log /var/log/nginx/caldav_access.log;
    error_log  /var/log/nginx/caldav_error.log;

    # ── 客户端限制 ────────────────────────────────────────────
    client_max_body_size 50M;          # 日历数据导入限制
    client_body_timeout 120s;

    # ── 反向代理到 Baikal ─────────────────────────────────────
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        # 透传关键头部
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  $server_port;

        # CalDAV 需要正确处理 Authorization 头
        proxy_set_header Authorization     $http_authorization;
        proxy_pass_header  Authorization;

        # 超时设置（日历同步可能较慢）
        proxy_connect_timeout 60s;
        proxy_send_timeout    120s;
        proxy_read_timeout    120s;

        # 缓冲设置
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Let's Encrypt ACME 验证
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
```

## 配置要点说明

### 1. 为什么用 HTTP/2？

CalDAV 涉及大量小请求（PROPFIND、REPORT），HTTP/2 的多路复用能显著减少延迟。

### 2. `proxy_buffering off`

CalDAV 响应可能是流式的（特别是同步大量事件时），关闭缓冲避免超时。

### 3. `Authorization` 头透传

iPhone 使用 HTTP Basic Auth 连接 CalDAV，必须透传 `Authorization` 头到后端 Baikal。

### 4. `client_max_body_size 50M`

如果你要导入大型日历（几千个事件），需要足够的上传限制。

## 启用配置

```bash
# 测试配置语法
sudo nginx -t

# 创建软链接启用站点
sudo ln -sf /etc/nginx/sites-available/caldav /etc/nginx/sites-enabled/caldav

# 重载 Nginx
sudo systemctl reload nginx
```

## 防火墙配置

```bash
# UFW
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# iptables（仅示例，推荐用 ufw 或 firewalld）
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

## 验证反向代理

```bash
# 检查 Nginx 状态
sudo systemctl status nginx

# 测试 HTTPS 访问
curl -I https://<DOMAIN>/

# 测试 CalDAV 端点（应返回 401 要求认证）
curl -I -X PROPFIND https://<DOMAIN>/cal.php
```

## 常见配置问题

| 问题 | 症状 | 解决 |
|------|------|------|
| 502 Bad Gateway | Nginx 无法连接 Baikal | 检查 Baikal 是否在 8080 端口运行 |
| 413 Request Entity Too Large | 上传被拒绝 | 增大 `client_max_body_size` |
| SSL 证书不匹配 | 浏览器警告 | 确认 `server_name` 与证书域名一致 |
| 504 Gateway Timeout | 代理超时 | 增大 `proxy_read_timeout` |
