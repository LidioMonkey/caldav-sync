#!/usr/bin/env bash
#===============================================================================
# backup.sh - CalDAV Data Backup & Restore
#
# Usage:
#   sudo bash backup.sh <command> [OPTIONS]
#
# Commands:
#   backup   Create a backup of Baikal data
#   restore  Restore from a backup file
#   list     List available backups
#
# Options:
#   --install-dir  Baikal installation directory (default: /opt/baikal)
#   --backup-dir   Backup storage directory (default: /tmp/caldav-backups)
#   --backup-file  Backup file to restore from (required for restore)
#   --help         Show this help
#
# Examples:
#   sudo bash backup.sh backup
#   sudo bash backup.sh backup --backup-dir /mnt/backups
#   sudo bash backup.sh list
#   sudo bash backup.sh restore --backup-file /tmp/caldav-backups/baikal_backup_20260625.tar.gz
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
BACKUP_DIR="/tmp/caldav-backups"
COMMAND=""
BACKUP_FILE=""

# ── Parse Arguments ──────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --backup-dir)  BACKUP_DIR="$2"; shift 2 ;;
        --backup-file) BACKUP_FILE="$2"; shift 2 ;;
        --help|-h)
            head -26 "$0" | tail -22
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    die "No command specified. Use: backup, restore, list"
fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

# ── Execute Command ──────────────────────────────────────────────────────────

case "$COMMAND" in
    backup)
        step "Creating CalDAV backup"

        if [[ ! -d "$INSTALL_DIR" ]]; then
            die "Baikal not found at $INSTALL_DIR"
        fi

        # Create backup directory
        mkdir -p "$BACKUP_DIR"

        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_NAME="baikal_backup_${TIMESTAMP}"
        BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
        TMP_BACKUP_DIR="$BACKUP_DIR/${BACKUP_NAME}"

        info "Preparing backup in $TMP_BACKUP_DIR..."
        mkdir -p "$TMP_BACKUP_DIR/baikal"
        mkdir -p "$TMP_BACKUP_DIR/nginx"

        # Copy Baikal data
        info "Copying Baikal data..."
        if [[ -d "$INSTALL_DIR/Specific" ]]; then
            cp -r "$INSTALL_DIR/Specific" "$TMP_BACKUP_DIR/baikal/"
            success "Copied Specific/ (database + user data)"
        else
            warn "Specific/ directory not found — skipping"
        fi

        if [[ -f "$INSTALL_DIR/config.php" ]]; then
            cp "$INSTALL_DIR/config.php" "$TMP_BACKUP_DIR/baikal/"
            success "Copied config.php"
        fi

        if [[ -f "$INSTALL_DIR/Specific/config.system.php" ]]; then
            cp "$INSTALL_DIR/Specific/config.system.php" "$TMP_BACKUP_DIR/baikal/"
            success "Copied config.system.php"
        fi

        # Copy Nginx config
        info "Copying Nginx configuration..."
        if [[ -f "/etc/nginx/sites-available/caldav" ]]; then
            cp "/etc/nginx/sites-available/caldav" "$TMP_BACKUP_DIR/nginx/"
            success "Copied Nginx site config"
        else
            warn "No Nginx config found at /etc/nginx/sites-available/caldav"
        fi

        if [[ -d "/etc/letsencrypt/live" ]]; then
            # Note: just record the domain, not the cert (certs should be re-issued)
            ls /etc/letsencrypt/live/ > "$TMP_BACKUP_DIR/nginx/ssl_domains.txt" 2>/dev/null || true
            success "Recorded SSL domain list"
        fi

        # Create backup manifest
        cat > "$TMP_BACKUP_DIR/backup_info.txt" << MANIFEST
Backup created: $(date)
Server: $(hostname)
Baikal install: $INSTALL_DIR
Timestamp: $TIMESTAMP

Contents:
- Baikal Specific/ directory (database + user data)
- config.php and config.system.php
- Nginx site configuration
MANIFEST

        # Create archive
        info "Creating archive..."
        tar -czf "$BACKUP_FILE" -C "$BACKUP_DIR" "$BACKUP_NAME" 2>/dev/null

        # Cleanup temp
        rm -rf "$TMP_BACKUP_DIR"

        # Stats
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✅ Backup created successfully!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  Backup file: ${BOLD}$BACKUP_FILE${NC}"
        echo -e "  Size:        ${BOLD}$BACKUP_SIZE${NC}"
        echo ""
        ;;

    restore)
        step "Restoring CalDAV backup"

        if [[ -z "$BACKUP_FILE" ]]; then
            die "--backup-file is required for restore"
        fi
        if [[ ! -f "$BACKUP_FILE" ]]; then
            die "Backup file not found: $BACKUP_FILE"
        fi

        # Stop services
        info "Stopping services..."
        systemctl stop baikal 2>/dev/null && success "Baikal stopped" || warn "Baikal was not running"

        # Extract backup
        info "Extracting backup..."
        TMP_RESTORE_DIR=$(mktemp -d)
        tar -xzf "$BACKUP_FILE" -C "$TMP_RESTORE_DIR"

        # Find the backup content directory
        BACKUP_CONTENT=$(find "$TMP_RESTORE_DIR" -name "backup_info.txt" -type f 2>/dev/null | head -1 | xargs dirname)
        if [[ -z "$BACKUP_CONTENT" ]]; then
            BACKUP_CONTENT=$(ls -d "$TMP_RESTORE_DIR"/*/ 2>/dev/null | head -1)
        fi

        if [[ -z "$BACKUP_CONTENT" ]]; then
            die "Could not find backup content in archive"
        fi

        info "Backup content found in: $BACKUP_CONTENT"

        # Restore Baikal data
        if [[ -d "$BACKUP_CONTENT/baikal" ]]; then
            info "Restoring Baikal data..."

            # Backup current data first (safety)
            if [[ -d "$INSTALL_DIR/Specific" ]]; then
                SAFETY_BACKUP="$INSTALL_DIR/Specific.before_restore_$(date +%Y%m%d_%H%M%S)"
                cp -r "$INSTALL_DIR/Specific" "$SAFETY_BACKUP"
                info "Current data backed up to $SAFETY_BACKUP"
            fi

            # Restore Specific directory
            if [[ -d "$BACKUP_CONTENT/baikal/Specific" ]]; then
                rm -rf "$INSTALL_DIR/Specific"
                cp -r "$BACKUP_CONTENT/baikal/Specific" "$INSTALL_DIR/"
                success "Restored Specific/ directory"
            fi

            # Restore config files
            if [[ -f "$BACKUP_CONTENT/baikal/config.php" ]]; then
                cp "$BACKUP_CONTENT/baikal/config.php" "$INSTALL_DIR/"
                success "Restored config.php"
            fi
            if [[ -f "$BACKUP_CONTENT/baikal/config.system.php" ]]; then
                mkdir -p "$INSTALL_DIR/Specific"
                cp "$BACKUP_CONTENT/baikal/config.system.php" "$INSTALL_DIR/Specific/"
                success "Restored config.system.php"
            fi

            # Set permissions
            WEB_USER="www-data"
            id "nginx" &>/dev/null && WEB_USER="nginx"
            id "apache" &>/dev/null && WEB_USER="apache"
            chown -R "$WEB_USER:$WEB_USER" "$INSTALL_DIR/Specific" 2>/dev/null || true
            chmod 750 "$INSTALL_DIR/Specific" 2>/dev/null || true
        fi

        # Restore Nginx config
        if [[ -f "$BACKUP_CONTENT/nginx/caldav" ]]; then
            info "Restoring Nginx configuration..."
            cp "$BACKUP_CONTENT/nginx/caldav" /etc/nginx/sites-available/caldav
            success "Restored Nginx site config"
            nginx -t && systemctl reload nginx 2>/dev/null && success "Nginx reloaded" || warn "Nginx reload failed — check config"
        fi

        # Cleanup
        rm -rf "$TMP_RESTORE_DIR"

        # Start services
        info "Starting services..."
        systemctl start baikal 2>/dev/null && success "Baikal started" || warn "Baikal failed to start"

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✅ Backup restored successfully!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        ;;

    list)
        step "Available backups"

        if [[ ! -d "$BACKUP_DIR" ]]; then
            info "No backups directory found: $BACKUP_DIR"
            exit 0
        fi

        BACKUPS=$(find "$BACKUP_DIR" -name "baikal_backup_*.tar.gz" -type f 2>/dev/null | sort -r)
        if [[ -z "$BACKUPS" ]]; then
            info "No backups found in $BACKUP_DIR"
            exit 0
        fi

        echo ""
        printf "  %-40s %-10s %-20s\n" "Filename" "Size" "Date"
        printf "  %-40s %-10s %-20s\n" "────────────────────────────────────────" "──────────" "────────────────────"

        echo "$BACKUPS" | while read -r backup; do
            FNAME=$(basename "$backup")
            FSIZE=$(du -h "$backup" | cut -f1)
            FDATE=$(stat -c '%y' "$backup" 2>/dev/null | cut -d. -f1 || echo "unknown")
            printf "  %-40s %-10s %-20s\n" "$FNAME" "$FSIZE" "$FDATE"
        done

        echo ""
        info "Total backups: $(echo "$BACKUPS" | wc -l)"
        ;;

    *)
        die "Unknown command: '$COMMAND'. Use: backup, restore, list"
        ;;
esac
