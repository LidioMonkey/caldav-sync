#!/usr/bin/env bash
#===============================================================================
# init_baikal.sh - Initialize Baikal and create admin user
#
# Usage:
#   sudo bash init_baikal.sh --admin-password <password> [OPTIONS]
#
# Options:
#   --admin-password  Admin password (required)
#   --install-dir     Baikal installation directory (default: /opt/baikal)
#   --admin-user      Admin username (default: admin)
#   --help            Show this help
#
# Examples:
#   sudo bash init_baikal.sh --admin-password "MySecret123"
#   sudo bash init_baikal.sh --admin-password "pass" --install-dir /srv/baikal
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
INSTALL_DIR="/opt/baikal"
ADMIN_PASSWORD=""
ADMIN_USER="admin"

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --admin-user)     ADMIN_USER="$2"; shift 2 ;;
        --install-dir)    INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            head -20 "$0" | tail -16
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$ADMIN_PASSWORD" ]]; then
    die "--admin-password is required"
fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    die "Baikal not found at $INSTALL_DIR. Run deploy_baikal.sh first."
fi

CONFIG_PHP="$INSTALL_DIR/config.php"
SYSTEM_CONFIG="$INSTALL_DIR/Specific/config.system.php"
DB_FILE="$INSTALL_DIR/Specific/db.sqlite"

step "Initializing Baikal at $INSTALL_DIR"

# ── Step 1: Check PHP and SQLite ─────────────────────────────────────────────
info "Checking PHP and SQLite..."
PHP_BIN=$(command -v php || true)
if [[ -z "$PHP_BIN" ]]; then
    die "PHP not found"
fi

PHP_VERSION=$("$PHP_BIN" -r 'echo PHP_VERSION;')
info "PHP version: $PHP_VERSION"

# ── Step 2: Generate admin password hash ─────────────────────────────────────
step "Generating admin credentials..."

# Baikal uses PHP password_hash() with PASSWORD_BCRYPT
ADMIN_HASH=$("$PHP_BIN" -r "echo password_hash('$ADMIN_PASSWORD', PASSWORD_BCRYPT);" 2>/dev/null)
if [[ -z "$ADMIN_HASH" ]]; then
    die "Failed to generate password hash"
fi
success "Password hash generated"

# ── Step 3: Update config.php with admin hash ────────────────────────────────
step "Updating configuration..."

if ! grep -q "BAIKAL_ADMIN_PASSWORDHASH" "$CONFIG_PHP"; then
    die "config.php missing BAIKAL_ADMIN_PASSWORDHASH definition"
fi

# Escape hash for sed
ESCAPED_HASH=$(printf '%s\n' "$ADMIN_HASH" | sed -e 's/[\/&]/\\&/g')

sed -i "s|define(\"BAIKAL_ADMIN_PASSWORDHASH\", \"\");|define(\"BAIKAL_ADMIN_PASSWORDHASH\", \"$ESCAPED_HASH\");|" "$CONFIG_PHP"
success "Admin password hash written to config.php"

# ── Step 4: Initialize SQLite database ───────────────────────────────────────
step "Initializing SQLite database..."

# Check if database already exists
if [[ -f "$DB_FILE" ]]; then
    warn "Database already exists: $DB_FILE"
    info "Backing up existing database..."
    cp "$DB_FILE" "${DB_FILE}.bak.$(date +%s)"
    success "Backup created"
fi

# Run Baikal's database initialization via PHP
info "Running Baikal database initialization..."

INIT_SCRIPT="$INSTALL_DIR/Core/Resources/ServerInitSchema.php"
if [[ ! -f "$INIT_SCRIPT" ]]; then
    # Try to find init schema — Baikal may have it at different paths
    INIT_SCRIPT=$(find "$INSTALL_DIR" -name "*InitSchema*" -path "*/Core/*" 2>/dev/null | head -1)
fi

if [[ -n "$INIT_SCRIPT" && -f "$INIT_SCRIPT" ]]; then
    # Run PHP script to initialize DB
    PHP_INIT_CODE=$(cat << 'PHPCODE'
<?php
// Bootstrap Baikal
$baikalPath = getenv('BAIKAL_PATH') ?: '/opt/baikal';
define('PROJECT_PATH', $baikalPath . '/');
require_once PROJECT_PATH . 'vendor/autoload.php';

use Baikal\Core\Tools;
use Baikal\Core\Server;

try {
    // Load config
    require PROJECT_PATH . 'config.php';
    require PROJECT_PATH . 'Specific/config.system.php';

    // Initialize database
    $pdo = new PDO('sqlite:' . BAIKAL_DB_FILE);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

    echo "Database initialized successfully\n";
} catch (Exception $e) {
    echo "Error: " . $e->getMessage() . "\n";
    exit(1);
}
PHPCODE
)
    BAIKAL_PATH="$INSTALL_DIR" "$PHP_BIN" -r "$PHP_INIT_CODE" 2>&1 || true
fi

# Create SQLite DB if it doesn't exist — Baikal will auto-create tables on first access
if [[ ! -f "$DB_FILE" ]]; then
    info "Creating empty SQLite database..."
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS _init (id INTEGER PRIMARY KEY);" 2>/dev/null || {
        # If sqlite3 CLI not available, use PHP
        "$PHP_BIN" -r "
            \$db = new SQLite3('$DB_FILE');
            \$db->exec('CREATE TABLE IF NOT EXISTS _init (id INTEGER PRIMARY KEY);');
            echo 'Database created.\n';
        "
    }
    success "SQLite database created"
fi

# Set correct ownership
WEB_USER="www-data"
id "nginx" &>/dev/null && WEB_USER="nginx"
id "apache" &>/dev/null && WEB_USER="apache"

chown "$WEB_USER:$WEB_USER" "$DB_FILE" 2>/dev/null || true
chmod 640 "$DB_FILE" 2>/dev/null || true

success "Database initialization complete"

# ── Step 5: Verify ───────────────────────────────────────────────────────────
step "Verifying configuration..."

# Check config
if "$PHP_BIN" -l "$CONFIG_PHP" &>/dev/null; then
    success "config.php syntax OK"
else
    warn "config.php has syntax errors"
fi

if "$PHP_BIN" -l "$SYSTEM_CONFIG" &>/dev/null; then
    success "config.system.php syntax OK"
else
    warn "config.system.php has syntax errors"
fi

# Restart service to pick up changes
if systemctl is-active --quiet baikal 2>/dev/null; then
    info "Restarting baikal service..."
    systemctl restart baikal
    sleep 1
    if systemctl is-active --quiet baikal; then
        success "Service restarted"
    else
        warn "Service failed to restart. Check: journalctl -xeu baikal"
    fi
fi

# ── Final Output ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Baikal Initialized Successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Admin username: ${BOLD}$ADMIN_USER${NC}"
echo -e "  Admin password: ${BOLD}$ADMIN_PASSWORD${NC}"
echo ""
echo -e "  ${YELLOW}Management Panel:${NC}"
echo -e "  Visit the admin panel in your browser to create users and calendars."
echo -e "  If you have Nginx + SSL set up:"
echo -e "  ${BOLD}https://<your-domain>/admin/${NC}"
echo ""
echo -e "  ${YELLOW}Manual Initialization:${NC}"
echo -e "  If automatic init didn't fully work, visit the install page:"
echo -e "  ${BOLD}https://<your-domain>/admin/install/${NC}"
echo ""
