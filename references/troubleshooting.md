# CalDAV 故障排查手册

## 快速诊断

运行全链路诊断脚本获取完整报告：

```bash
sudo bash scripts/diagnose.sh --domain <你的域名>
```

## 常见故障及解决方案

### 1. Baikal 服务无法启动

**症状**：`systemctl status baikal` 显示 failed

**排查步骤**：

```bash
# 查看服务日志
journalctl -xeu baikal --no-pager -n 50

# 手动测试 PHP 内置服务器
cd /opt/baikal/html
php -S 127.0.0.1:8080
```

**常见原因**：
- PHP 版本过低（需要 >= 8.0）
- 缺少 PHP 扩展（运行 `php -m | grep -E "xml|sqlite|mbstring"` 检查）
- 端口被占用（`ss -tlnp | grep 8080`）
- 文件权限不正确（检查 `/opt/baikal` 的所有权）

### 2. Nginx 502 Bad Gateway

**症状**：访问 `https://域名/` 返回 502

**排查**：

```bash
# 确认 Baikal 在运行
systemctl status baikal

# 确认端口监听
ss -tlnp | grep 8080

# 测试本地连接
curl -I http://127.0.0.1:8080/

# 查看 Nginx 错误日志
tail -50 /var/log/nginx/caldav_error.log
```

**修复**：`sudo systemctl restart baikal`

### 3. SSL 证书过期

**症状**：iPhone 提示 SSL 错误，浏览器显示证书警告

**检查**：

```bash
# 查看证书到期时间
sudo certbot certificates

# 或直接查看证书
openssl x509 -enddate -noout -in /etc/letsencrypt/live/<域名>/fullchain.pem
```

**修复**：

```bash
sudo certbot renew
sudo systemctl reload nginx
```

**预防**：设置自动续期

```bash
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" | sudo tee /etc/cron.d/certbot-renew
```

### 4. DNS 解析问题

**症状**：无法访问域名，但 IP 可以访问

**排查**：

```bash
# 检查 DNS 解析
dig +short <域名>

# 对比服务器 IP
curl -s ifconfig.me
```

**修复**：在 DNS 服务商处添加/修正 A 记录，指向服务器 IP

### 5. 端口不通

**症状**：`curl https://域名/` 连接超时

**排查**：

```bash
# 检查端口监听
ss -tlnp | grep -E ':443 |:80 '

# 检查防火墙
sudo ufw status
sudo firewall-cmd --list-all

# 从外部测试（在另一台机器上）
nc -zv <域名> 443
```

**修复**：开放 80 和 443 端口

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 6. 数据库损坏

**症状**：Baikal 运行但无法登录、日历数据丢失

**检查**：

```bash
# 检查数据库文件
ls -la /opt/baikal/Specific/db.sqlite

# 尝试用 sqlite3 打开
sqlite3 /opt/baikal/Specific/db.sqlite "PRAGMA integrity_check;"
```

**修复**：从备份恢复

```bash
sudo bash scripts/backup.sh restore --backup-file <备份文件路径>
```

### 7. iPhone 无法连接

**症状**：iPhone 提示"无法验证账户信息"

**逐项检查**：
1. 服务器地址是否正确（**不加** `https://`）
2. 用户名/密码是否正确
3. SSL 证书是否有效（非自签名）
4. 在 iPhone Safari 中能否打开 `https://域名/`

### 8. 同步慢或失败

**排查**：

```bash
# 检查服务器资源
free -h
df -h /opt/baikal

# 检查 PHP 错误
journalctl -u baikal --no-pager -n 100 | grep -i error

# 检查 Nginx 超时
grep -i timeout /var/log/nginx/caldav_error.log | tail -20
```

**优化**：
- 增大 Nginx `proxy_read_timeout`（默认 120s）
- 增大 PHP 内存限制
- 检查服务器 CPU/内存是否充足

## 日志位置

| 日志 | 路径 | 用途 |
|------|------|------|
| Baikal 服务 | `journalctl -u baikal` | PHP 错误、启动失败 |
| Nginx 访问 | `/var/log/nginx/caldav_access.log` | 请求记录、iPhone 连接 |
| Nginx 错误 | `/var/log/nginx/caldav_error.log` | 代理错误、SSL 错误 |
| 系统日志 | `/var/log/syslog` | 系统级问题 |

## 预防性维护

### 定期检查清单

```bash
# 每天检查一次
sudo bash scripts/diagnose.sh --domain <域名>

# 每周备份
sudo bash scripts/backup.sh backup
```

### 建议的监控指标

- SSL 证书剩余天数（告警阈值：< 15 天）
- Baikal 服务运行状态
- 磁盘使用率（告警阈值：> 80%）
- 数据库文件大小
