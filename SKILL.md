---
name: caldav-sync
description: "CalDAV 日历同步服务 — 在个人服务器上基于 Baikal 搭建 CalDAV 服务，实现 iPhone 日历同步。触发词：搭建日历服务、部署CalDAV、安装日历同步、配置日历、连接iPhone日历、iPhone同步日历、iOS日历配置、日历同步失败、日历不同步、CalDAV排查、修复日历、查看日历状态、备份日历、恢复日历、日历服务状态"
---

# CalDAV 日历同步 Skill

> **目标**：在本机服务器上部署 Baikal CalDAV 服务，配置 Nginx 反向代理 + Let's Encrypt SSL，实现 iPhone 日历同步。裸机部署，单用户场景。

## 触发规则

### 搭建部署类（触发完整部署流程）
用户说：`搭建日历服务` `部署CalDAV` `安装日历同步` `搭建CalDAV服务器` `部署日历同步`

→ 执行 **工作流 A：首次部署**

### 配置管理类
用户说：`配置日历` `添加日历用户` `日历权限` `SSL证书` `域名配置` `日历配置`

→ 执行对应子步骤或 **工作流 B：增量配置**

### 设备连接类
用户说：`连接iPhone日历` `iPhone同步日历` `iOS日历配置` `手机连日历` `iPad日历同步`

→ 执行 **工作流 C：设备连接指引**

### 诊断修复类
用户说：`日历同步失败` `日历不同步` `CalDAV排查` `修复日历` `同步出问题了`

→ 执行 **工作流 D：故障诊断**

### 运维操作类
用户说：`查看日历状态` `备份日历` `恢复日历` `日历服务状态`

→ 执行 **工作流 E：日常运维**

---

## 技术架构

```
用户 iPhone (iOS 日历 App)
        │
        ▼ HTTPS (443)
┌──────────────────────┐
│   Nginx (反向代理)    │  ← SSL 终止 (Let's Encrypt)
│   监听 443 端口       │
└────────┬─────────────┘
         │ HTTP (127.0.0.1:8080)
         ▼
┌──────────────────────┐
│   Baikal (PHP)       │  ← CalDAV / CardDAV 服务
│   内置 HTTP Server    │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   SQLite 数据库       │  ← 日历/联系人数据存储
└──────────────────────┘
```

### 关键路径

| 组件 | 路径/地址 |
|------|----------|
| Baikal 安装目录 | `/opt/baikal` |
| Nginx 配置 | `/etc/nginx/sites-available/caldav` |
| SSL 证书 | `/etc/letsencrypt/live/<域名>/` |
| Baikal 数据目录 | `/opt/baikal/Specific/` |
| PHP Built-in Server | `127.0.0.1:8080` |
| CalDAV 端点 | `https://<域名>/cal.php/principals/<用户名>/` |

---

## 工作流 A：首次部署

这是核心工作流，从零搭建完整 CalDAV 服务。按顺序执行以下步骤，每步完成后确认再继续。

### A1. 收集部署信息

部署前必须确认以下信息，缺少任何一项都**先询问用户**：

| 信息项 | 说明 | 示例 |
|--------|------|------|
| 域名 | 用于 CalDAV 服务的子域名 | `cal.example.com` |
| 邮箱 | Let's Encrypt 证书通知邮箱 | `admin@example.com` |
| 用户名 | CalDAV 登录用户名 | `myname` |
| 密码 | CalDAV 登录密码（或自动生成） | 自动生成 16 位随机密码 |

**询问模板**：
```
搭建 CalDAV 日历服务前需要确认以下信息：
1. 你准备用什么域名？（如 cal.example.com，需提前将 DNS A 记录指向本机 IP）
2. SSL 证书通知邮箱？
3. CalDAV 登录用户名？（默认用你当前用户名）
4. 登录密码？（留空则自动生成安全密码）
```

### A2. 检查系统环境

运行系统检查，确保依赖可用：

```bash
# 检查 PHP 版本（需要 >= 8.0）
php -v 2>/dev/null || echo "PHP_NOT_INSTALLED"

# 检查 PHP 必要扩展
php -m 2>/dev/null | grep -E "xml|mbstring|pdo_sqlite|sqlite3|ctype|json|filter|dom|libxml|simplexml|iconv"

# 检查 Nginx
nginx -v 2>/dev/null || echo "NGINX_NOT_INSTALLED"

# 检查 certbot
certbot --version 2>/dev/null || echo "CERTBOT_NOT_INSTALLED"

# 检查 80/443 端口
ss -tlnp | grep -E ':80 |:443 '
```

根据检查结果，缺什么装什么。参考 `references/dependencies.md` 了解各系统安装命令。

### A3. 部署 Baikal

执行 `scripts/deploy_baikal.sh` 完成 Baikal 下载、配置和启动：

```bash
sudo bash <skill-directory>/scripts/deploy_baikal.sh \
  --domain "<域名>" \
  --install-dir /opt/baikal \
  --port 8080
```

脚本执行内容：
1. 下载 Baikal 最新发行版到 `/opt/baikal`
2. 创建目录结构并设置权限
3. 生成 Baikal 配置文件 `config.php` 和 `Specific/config.system.php`
4. 初始化 SQLite 数据库
5. 创建 systemd service 文件 `baikal.service`
6. 启动 Baikal PHP 内置服务器（监听 127.0.0.1:8080）

部署完成后验证：

```bash
# 检查服务状态
sudo systemctl status baikal

# 检查端口监听
ss -tlnp | grep 8080

# 测试本地访问
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/
```

### A4. 配置 Nginx 反向代理 + SSL

#### 4a. 先确认 DNS 解析生效：

```bash
dig +short <域名> A
# 应返回本机公网 IP
```

#### 4b. 申请 SSL 证书（HTTP-01 验证，需 80 端口可用）：

```bash
sudo certbot certonly --standalone \
  -d "<域名>" \
  --email "<邮箱>" \
  --agree-tos \
  --non-interactive
```

#### 4c. 写入 Nginx 配置：

读取参考模板 `references/nginx_config.md`，根据实际域名生成配置并写入 `/etc/nginx/sites-available/caldav`。

关键配置要点：
- 监听 443 端口，HTTP/2
- SSL 证书路径指向 Let's Encrypt
- 反向代理到 `http://127.0.0.1:8080`
- 透传 `Host`、`X-Forwarded-For`、`X-Forwarded-Proto` 头
- 限制请求体大小（日历数据通常不大，设 10M 即可）
- 增加 `.well-known` 路径用于证书续期

#### 4d. 启用站点并重载 Nginx：

```bash
sudo ln -sf /etc/nginx/sites-available/caldav /etc/nginx/sites-enabled/caldav
sudo nginx -t && sudo systemctl reload nginx
```

#### 4e. 验证 HTTPS 访问：

```bash
curl -s -o /dev/null -w "%{http_code}" https://<域名>/
# 应返回 200
```

### A5. 初始化 Baikal 并创建用户

部署完成后，通过 Baikal 的 Web 管理界面或命令行完成初始化。

**方式一：命令行初始化（推荐）**

执行 `scripts/init_baikal.sh`：

```bash
sudo bash <skill-directory>/scripts/init_baikal.sh \
  --install-dir /opt/baikal \
  --admin-password "<管理密码>"
```

**方式二：Web 界面初始化**

如果命令行方式不可行，引导用户访问 `https://<域名>/` 完成 Web 初始化：
1. 浏览器打开 `https://<域名>/`
2. 按向导设置管理员密码
3. 进入管理面板 → 创建用户
4. 为用户创建默认日历

### A6. 输出 iPhone 连接信息

部署成功后，输出以下信息给用户：

```
✅ CalDAV 日历服务部署完成！

📱 iPhone 连接配置：
━━━━━━━━━━━━━━━━━━━━━━━━━━━
设置 → 日历 → 账户 → 添加账户 → 其他 → 添加 CalDAV 账户

服务器：  <域名>
用户名：  <用户名>
密码：    <密码>
描述：    个人日历
使用 SSL： ✅ 开启
端口：    443
━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔗 管理面板：https://<域名>/admin/
📋 详细配置指引见：references/iphone_setup_guide.md
```

---

## 工作流 B：增量配置

### 添加新用户

```bash
# 通过 Baikal 管理面板操作
# 引导用户访问 https://<域名>/admin/ 登录后添加
```

或使用脚本 `scripts/manage_user.sh`：

```bash
sudo bash <skill-directory>/scripts/manage_user.sh add \
  --install-dir /opt/baikal \
  --username "<用户名>" \
  --password "<密码>"
```

### 续期 SSL 证书

```bash
sudo certbot renew --dry-run  # 先测试
sudo certbot renew             # 正式续期
sudo systemctl reload nginx
```

建议设置自动续期 cron：
```bash
# 每天凌晨 3 点检查续期
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" | sudo tee /etc/cron.d/certbot-renew
```

### 修改域名

1. 重新申请新域名的 SSL 证书
2. 更新 Nginx 配置中的 `server_name`
3. 重载 Nginx
4. 更新 iPhone 上的服务器地址

---

## 工作流 C：设备连接指引

### iPhone / iPad 连接步骤

详细图文指引见 `references/iphone_setup_guide.md`。

快速步骤：
1. 打开 **设置** → **日历** → **账户** → **添加账户** → **其他**
2. 选择 **添加 CalDAV 账户**
3. 填写：
   - 服务器：`<域名>`（不带 https://）
   - 用户名：`<用户名>`
   - 密码：`<密码>`
   - 描述：`个人日历`
4. 点击 **下一步**，等待验证
5. 验证通过后，打开 **日历 App**，稍等片刻即可看到同步的日历

### 常见连接问题

| 问题 | 原因 | 解决 |
|------|------|------|
| "无法验证账户信息" | 密码错误或路径不对 | 检查密码，确认服务器地址不含 https:// |
| 连接超时 | 443 端口不通 | 检查防火墙、Nginx 状态 |
| SSL 错误 | 证书问题 | 检查证书是否过期 |
| 日历空白 | 用户未分配日历 | 登录管理面板创建日历 |

---

## 工作流 D：故障诊断

执行诊断脚本进行全面检查：

```bash
sudo bash <skill-directory>/scripts/diagnose.sh --domain "<域名>"
```

诊断项目：
1. **服务进程**：`baikal.service` 是否 running
2. **端口监听**：8080（Baikal）、443（Nginx）、80（HTTP）是否正常
3. **Nginx 状态**：配置语法是否正确，服务是否运行
4. **SSL 证书**：是否过期（Let's Encrypt 90 天有效期）
5. **DNS 解析**：域名是否正确指向本机 IP
6. **Baikal 响应**：HTTP 200 正常返回
7. **CalDAV 端点**：PROPFIND 请求是否正常
8. **磁盘空间**：数据目录是否有足够空间
9. **日志检查**：Nginx 错误日志、Baikal 日志有无异常

根据诊断结果给出针对性修复建议。参考 `references/troubleshooting.md` 了解常见故障处理。

---

## 工作流 E：日常运维

### 查看服务状态

```bash
# Baikal 状态
sudo systemctl status baikal

# Nginx 状态
sudo systemctl status nginx

# SSL 证书有效期
sudo certbot certificates
```

### 备份日历数据

```bash
sudo bash <skill-directory>/scripts/backup.sh \
  --install-dir /opt/baikal \
  --backup-dir /workspace/caldav-backups
```

备份内容：
- `Specific/` 目录（含 SQLite 数据库和用户数据）
- `config.php` 和 `Specific/config.system.php`
- Nginx 配置文件

### 恢复日历数据

```bash
sudo bash <skill-directory>/scripts/backup.sh restore \
  --backup-file /workspace/caldav-backups/baikal_backup_<日期>.tar.gz \
  --install-dir /opt/baikal
```

---

## 安全注意事项

1. **密码安全**：所有生成的密码通过安全方式展示给用户，不存储明文
2. **文件权限**：Baikal 数据目录权限设为 750，防止未授权访问
3. **防火墙**：确保只开放 80/443 端口对外，8080 仅本地监听
4. **自动更新**：建议定期检查 Baikal 新版本并升级
5. **日志清理**：Nginx 访问日志建议配置 logrotate

---

## 资源文件说明

### scripts/
- `deploy_baikal.sh` — Baikal 一键部署（下载、配置、启动 systemd 服务）
- `init_baikal.sh` — Baikal 初始化和管理员创建
- `manage_user.sh` — 用户管理（添加/删除/修改密码）
- `diagnose.sh` — 全链路故障诊断
- `backup.sh` — 日历数据备份与恢复

### references/
- `nginx_config.md` — Nginx 反向代理配置模板（含详细注释）
- `iphone_setup_guide.md` — iPhone/iPad CalDAV 连接配置图文指南
- `troubleshooting.md` — 常见问题排查手册
- `dependencies.md` — 各 Linux 发行版 PHP/Nginx/certbot 安装命令
