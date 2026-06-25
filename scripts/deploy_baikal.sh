#!/usr/bin/env bash
#===============================================================================
# deploy_baikal.sh - Baikal CalDAV Server One-Click Deployment
#
# Usage:
#   sudo bash deploy_baikal.sh --domain <domain> [OPTIONS]
#
# Options:
#   --domain       FQDN for the CalDAV service (required)
#   --install-dir  Installation directory (default: /opt/baikal)
#   --port         PHP built-in server port (default: 8080)
#   --php-bin      PHP binary path (default: php)
#   --version      Baikal version to install (default: latest)
#   --help         Show this help
#
# Examples:
#   sudo bash deploy_baikal.sh --domain cal.example.com
#   sudo bash deploy_baikal.sh --domain cal.example.com --install-dir /srv/baikal --port 9090
#===============================================================================

set -euo pipefail

# ── Color Output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
step()    { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }
die()     { error "$*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN=""
INSTALL_DIR="/opt/baikal"
PORT="8080"
PHP_BIN="php"
VERSION="latest"
GITHUB_REPO="sabre-io/Baikal"

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --port)        PORT="$2"; shift 2 ;;
        --php-bin)     PHP_BIN="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --help|-h)
            head -20 "$0" | tail -16
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$DOMAIN" ]]; then
    die "--domain is required"
fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

# ── Step 1: System Check ─────────────────────────────────────────────────────
step "Step 1/7: Checking system environment"

info "Checking PHP..."
if ! command -v "$PHP_BIN" &>/dev/null; then
    die "PHP not found at '$PHP_BIN'. Please install PHP >= 8.0 first."
fi

PHP_VERSION=$("$PHP_BIN" -r 'echo PHP_VERSION;')
PHP_MAJOR=$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION;')
PHP_MINOR=$("$PHP_BIN" -r 'echo PHP_MINOR_VERSION;')
info "PHP version: $PHP_VERSION"

if [[ "$PHP_MAJOR" -lt 8 ]]; then
    die "PHP >= 8.0 required, found $PHP_VERSION"
fi
success "PHP $PHP_VERSION OK"

info "Checking PHP extensions..."
REQUIRED_EXTENSIONS=("xml" "mbstring" "pdo_sqlite" "sqlite3" "ctype" "json" "filter" "dom" "libxml" "simplexml" "iconv" "curl" "zip")
MISSING=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
    if ! "$PHP_BIN" -m | grep -qi "^$ext$"; then
        MISSING+=("$ext")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing PHP extensions: ${MISSING[*]}. Install them and retry."
fi
success "All PHP extensions OK"

# Check unzip
if ! command -v unzip &>/dev/null; then
    die "unzip not found. Install: apt install unzip / yum install unzip"
fi

# ── Step 2: Determine Baikal Version ─────────────────────────────────────────
step "Step 2/7: Resolving Baikal version"

if [[ "$VERSION" == "latest" ]]; then
    info "Fetching latest release tag from GitHub..."
    LATEST_TAG=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [[ -z "$LATEST_TAG" ]]; then
        die "Failed to fetch latest version from GitHub"
    fi
    VERSION="$LATEST_TAG"
fi
# Strip leading 'v' if present
VERSION_CLEAN="${VERSION#v}"
success "Baikal version: $VERSION_CLEAN"

# ── Step 3: Download Baikal ──────────────────────────────────────────────────
step "Step 3/7: Downloading Baikal"

TMP_DIR=$(mktemp -d)
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/baikal-${VERSION_CLEAN}.zip"
ZIP_FILE="$TMP_DIR/baikal-${VERSION_CLEAN}.zip"

info "Downloading from $DOWNLOAD_URL"
if ! curl -sSL -o "$ZIP_FILE" "$DOWNLOAD_URL"; then
    # Try without 'v' prefix in the release name
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/baikal-${VERSION}.zip"
    info "Retrying with $DOWNLOAD_URL"
    if ! curl -sSL -o "$ZIP_FILE" "$DOWNLOAD_URL"; then
        die "Failed to download Baikal. Check version and network."
    fi
fi
success "Downloaded: $ZIP_FILE"

# ── Step 4: Install Baikal ───────────────────────────────────────────────────
step "Step 4/7: Installing Baikal to $INSTALL_DIR"

# Remove existing installation if present
if [[ -d "$INSTALL_DIR" ]]; then
    warn "Installation directory already exists: $INSTALL_DIR"
    info "Removing old installation..."
    rm -rf "$INSTALL_DIR"
fi

info "Extracting..."
mkdir -p "$INSTALL_DIR"
unzip -q "$ZIP_FILE" -d "$TMP_DIR/baikal-extract"

# Baikal zip typically has everything in a 'baikal/' subdirectory
EXTRACTED_DIR="$TMP_DIR/baikal-extract"
if [[ -d "$EXTRACTED_DIR/baikal" ]]; then
    EXTRACTED_DIR="$EXTRACTED_DIR/baikal"
fi

# Copy contents
shopt -s dotglob
cp -r "$EXTRACTED_DIR"/* "$INSTALL_DIR/"
shopt -u dotglob
success "Files extracted to $INSTALL_DIR"

# Create required directories
info "Creating directory structure..."
mkdir -p "$INSTALL_DIR/Specific"
chmod 750 "$INSTALL_DIR/Specific"

# ── Step 5: Generate Configuration ───────────────────────────────────────────
step "Step 5/7: Generating configuration files"

# config.php
info "Generating $INSTALL_DIR/config.php..."
cat > "$INSTALL_DIR/config.php" << 'PHPEOF'
<?php
#===============================================================================
# Baikal Configuration — Auto-generated by deploy_baikal.sh
#===============================================================================

define("PROJECT_CONTEXT", "Production");
define("PROJECT_PACKAGE", "Baikal");

# Database — SQLite
define("BAIKAL_DB_DRIVER", "sqlite");
define("BAIKAL_DB_FILE",  PROJECT_PATH . "Specific/db.sqlite");

# Auth realm
define("BAIKAL_AUTH_REALM", "Baikal");

# CardDAV
define("BAIKAL_CARD_ENABLED", true);

# CalDAV
define("BAIKAL_CAL_ENABLED", true);

# Invites (email disabled by default)
define("BAIKAL_INVITE_ENABLED", false);

# Email (disabled)
define("BAIKAL_EMAIL_ENABLED", false);

# LDAP (disabled)
define("BAIKAL_LDAP_ENABLED", false);

# Admin password hash — set via web init or init_baikal.sh
define("BAIKAL_ADMIN_PASSWORDHASH", "");

# Encryption key — auto-generated
define("BAIKAL_ENCRYPTION_KEY", "");
PHPEOF

# Append domain-specific settings
cat >> "$INSTALL_DIR/config.php" << PHPEOF

# Auto-generated settings
define("BAIKAL_BASE_URI", "https://${DOMAIN}/");
PHPEOF

# config.system.php
info "Generating $INSTALL_DIR/Specific/config.system.php..."
ENCRYPTION_KEY=$(openssl rand -hex 32)

cat > "$INSTALL_DIR/Specific/config.system.php" << PHPEOF
<?php
#===============================================================================
# Baikal System Configuration — Auto-generated by deploy_baikal.sh
#===============================================================================
# This file is auto-generated. Do not edit manually unless you know
# what you are doing.

define("BAIKAL_ENCRYPTION_KEY", "$ENCRYPTION_KEY");
PHPEOF

chmod 640 "$INSTALL_DIR/Specific/config.system.php"
success "Configuration files generated"

# ── Step 6: Create systemd Service ───────────────────────────────────────────
step "Step 6/7: Creating systemd service"

info "Determining web server user..."
WEB_USER="www-data"
if id "nginx" &>/dev/null; then
    WEB_USER="nginx"
elif id "www-data" &>/dev/null; then
    WEB_USER="www-data"
elif id "apache" &>/dev/null; then
    WEB_USER="apache"
fi

# Set ownership
info "Setting ownership to $WEB_USER..."
chown -R "$WEB_USER:$WEB_USER" "$INSTALL_DIR"
chmod -R u+rwX,g+rX,o-rwx "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR/Specific"

# Create systemd service
info "Creating /etc/systemd/system/baikal.service..."
cat > /etc/systemd/system/baikal.service << SYSTEMDEOF
[Unit]
Description=Baikal CalDAV/CardDAV Server (PHP Built-in)
After=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$INSTALL_DIR/html
ExecStart=$PHP_BIN -S 127.0.0.1:$PORT -t $INSTALL_DIR/html
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=baikal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR/Specific
ReadOnlyPaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable baikal
success "systemd service created and enabled"

# ── Step 7: Start Service ────────────────────────────────────────────────────
step "Step 7/7: Starting Baikal service"

info "Starting baikal.service..."
if systemctl start baikal; then
    success "Baikal service started"
else
    die "Failed to start baikal.service. Check: journalctl -xeu baikal"
fi

# Verify
sleep 2
if systemctl is-active --quiet baikal; then
    success "Service is running"
else
    die "Service not active after start. Check: journalctl -xeu baikal"
fi

# Quick health check
info "Performing health check..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" ]]; then
    success "Health check passed (HTTP $HTTP_CODE)"
else
    warn "Health check returned HTTP $HTTP_CODE (this may be normal before initialization)"
fi

# Cleanup
rm -rf "$TMP_DIR"

# ── Final Output ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Baikal CalDAV Server Deployed Successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Install dir:   ${BOLD}$INSTALL_DIR${NC}"
echo -e "  Local address: ${BOLD}http://127.0.0.1:$PORT/${NC}"
echo -e "  Public URL:    ${BOLD}https://$DOMAIN/${NC} (after Nginx + SSL setup)"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Set up Nginx reverse proxy with SSL (certbot)"
echo -e "  2. Initialize Baikal: ${BOLD}bash scripts/init_baikal.sh${NC}"
echo -e "  3. Or visit: ${BOLD}https://$DOMAIN/admin/install/${NC}"
echo ""
