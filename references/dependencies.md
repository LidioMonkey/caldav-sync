# 依赖安装指南

## 各 Linux 发行版安装命令

### Debian / Ubuntu

```bash
# 更新包列表
sudo apt update

# PHP 8.x 及必要扩展
sudo apt install -y php php-cli php-xml php-mbstring php-sqlite3 php-ctype php-json php-curl php-zip unzip

# Nginx
sudo apt install -y nginx

# Certbot (Let's Encrypt)
sudo apt install -y certbot

# 可选：诊断工具
sudo apt install -y curl sqlite3 dnsutils
```

### CentOS / RHEL / Fedora

```bash
# 启用 EPEL 和 Remi 仓库（CentOS/RHEL）
sudo dnf install -y epel-release
sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
sudo dnf module reset php
sudo dnf module enable php:remi-8.2

# PHP 及扩展
sudo dnf install -y php php-cli php-xml php-mbstring php-pdo php-ctype php-json php-curl php-zip unzip

# Nginx
sudo dnf install -y nginx

# Certbot
sudo dnf install -y certbot

# 可选工具
sudo dnf install -y curl sqlite
```

### Arch Linux

```bash
sudo pacman -Syu
sudo pacman -S php php-sqlite nginx certbot curl sqlite3 unzip
```

### Alpine Linux

```bash
sudo apk add php81 php81-xml php81-mbstring php81-pdo_sqlite php81-sqlite3 \
         php81-ctype php81-json php81-curl php81-openssl php81-zip \
         php81-simplexml php81-dom php81-iconv \
         nginx certbot curl sqlite unzip
```

## 验证安装

```bash
# PHP 版本
php -v

# PHP 扩展检查
php -m | grep -E "xml|mbstring|sqlite|ctype|json|curl|dom|simplexml|iconv|zip"

# Nginx 版本
nginx -v

# Certbot 版本
certbot --version
```

## PHP 配置优化

编辑 `/etc/php/*/cli/php.ini` 或 `/etc/php.ini`：

```ini
# 内存限制（Baikal 建议至少 128M）
memory_limit = 256M

# 上传大小限制（用于导入日历文件）
upload_max_filesize = 50M
post_max_size = 50M

# 时区
date.timezone = Asia/Shanghai

# 错误报告（生产环境）
display_errors = Off
log_errors = On
```
