#!/usr/bin/env bash
#===============================================================================
# manage_user.sh - Baikal CalDAV User Management
#
# Usage:
#   sudo bash manage_user.sh <command> [OPTIONS]
#
# Commands:
#   add       Create a new user
#   delete    Remove a user
#   list      List all users
#   password  Change user password
#
# Options:
#   --username      Username (required for add/delete/password)
#   --password      Password for new user (optional for add, auto-generated)
#   --new-password  New password (required for password command)
#   --install-dir   Baikal installation directory (default: /opt/baikal)
#   --help          Show this help
#
# Examples:
#   sudo bash manage_user.sh add --username myname --password MyPass123
#   sudo bash manage_user.sh add --username myname
#   sudo bash manage_user.sh list
#   sudo bash manage_user.sh delete --username myname
#   sudo bash manage_user.sh password --username myname --new-password NewPass456
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
COMMAND=""
USERNAME=""
PASSWORD=""
NEW_PASSWORD=""
YES=false

# ── Parse Arguments ──────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --username)     USERNAME="$2"; shift 2 ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --new-password) NEW_PASSWORD="$2"; shift 2 ;;
    --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
    --yes)          YES=true; shift ;;
    --help|-h)
            head -26 "$0" | tail -22
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$COMMAND" ]]; then
    die "No command specified. Use: add, delete, list, password"
fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    die "Baikal not found at $INSTALL_DIR. Run deploy_baikal.sh first."
fi

DB_FILE="$INSTALL_DIR/Specific/db.sqlite"
PHP_BIN=$(command -v php || die "PHP not found")

# ── Helper: Generate Random Password ─────────────────────────────────────────
generate_password() {
    openssl rand -base64 18 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=' | head -c 16
}

# ── Helper: Check if user exists ─────────────────────────────────────────────
user_exists() {
    local user="$1"
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE username='$user';" 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# ── Helper: Get web user ─────────────────────────────────────────────────────
get_web_user() {
    id "nginx" &>/dev/null && echo "nginx" && return
    id "www-data" &>/dev/null && echo "www-data" && return
    id "apache" &>/dev/null && echo "apache" && return
    echo "root"
}

# ── Execute Command ──────────────────────────────────────────────────────────

case "$COMMAND" in
    add)
        # ── Add User ───────────────────────────────────────────────────────
        if [[ -z "$USERNAME" ]]; then
            die "--username is required for add"
        fi

        step "Adding user: $USERNAME"

        # Check DB exists
        if [[ ! -f "$DB_FILE" ]]; then
            die "Database not found: $DB_FILE. Run init_baikal.sh first."
        fi

        # Check if user already exists via PHP
        USER_CHECK=$("$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$stmt = \$db->prepare('SELECT COUNT(*) FROM users WHERE username = :u');
                \$stmt->bindValue(':u', '$USERNAME', SQLITE3_TEXT);
                \$result = \$stmt->execute();
                \$row = \$result->fetchArray(SQLITE3_NUM);
                echo \$row[0];
            } catch (Exception \$e) {
                echo '0';
            }
        " 2>/dev/null || echo "0")

        if [[ "$USER_CHECK" -gt 0 ]]; then
            die "User '$USERNAME' already exists"
        fi

        # Generate password if not provided
        if [[ -z "$PASSWORD" ]]; then
            PASSWORD=$(generate_password)
            info "Auto-generated password: $PASSWORD"
        fi

        # Hash password
        PASSWORD_HASH=$("$PHP_BIN" -r "echo password_hash('$PASSWORD', PASSWORD_BCRYPT);")
        DISPLAY_NAME="$USERNAME"
        EMAIL="${USERNAME}@localhost"
        URI="principals/${USERNAME}"

        # Insert user via PHP
        ADD_RESULT=$("$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$db->enableExceptions(true);

                // Begin transaction
                \$db->exec('BEGIN');

                // Insert into users table
                \$stmt = \$db->prepare('INSERT INTO users (username, password, displayname, email) VALUES (:u, :p, :d, :e)');
                \$stmt->bindValue(':u', '$USERNAME', SQLITE3_TEXT);
                \$stmt->bindValue(':p', '$PASSWORD_HASH', SQLITE3_TEXT);
                \$stmt->bindValue(':d', '$DISPLAY_NAME', SQLITE3_TEXT);
                \$stmt->bindValue(':e', '$EMAIL', SQLITE3_TEXT);
                \$stmt->execute();

                // Insert into principals table
                \$stmt2 = \$db->prepare('INSERT INTO principals (uri, displayname, email) VALUES (:u, :d, :e)');
                \$stmt2->bindValue(':u', '$URI', SQLITE3_TEXT);
                \$stmt2->bindValue(':d', '$DISPLAY_NAME', SQLITE3_TEXT);
                \$stmt2->bindValue(':e', '$EMAIL', SQLITE3_TEXT);
                \$stmt2->execute();

                // Create default calendar
                \$calUri = 'calendars/${USERNAME}/default';
                \$components = 'VEVENT,VTODO,VJOURNAL';
                \$stmt3 = \$db->prepare('INSERT INTO calendars (uri, displayname, components, principaluri) VALUES (:u, :d, :c, :p)');
                \$stmt3->bindValue(':u', \$calUri, SQLITE3_TEXT);
                \$stmt3->bindValue(':d', 'Default', SQLITE3_TEXT);
                \$stmt3->bindValue(':c', \$components, SQLITE3_TEXT);
                \$stmt3->bindValue(':p', '$URI', SQLITE3_TEXT);
                \$stmt3->execute();

                \$db->exec('COMMIT');
                echo 'SUCCESS';
            } catch (Exception \$e) {
                if (isset(\$db)) {
                    try { \$db->exec('ROLLBACK'); } catch (Exception \$ex) {}
                }
                echo 'ERROR: ' . \$e->getMessage();
            }
        " 2>&1)

        if [[ "$ADD_RESULT" == "SUCCESS" ]]; then
            # Set ownership
            WEB_USER=$(get_web_user)
            chown "$WEB_USER:$WEB_USER" "$DB_FILE" 2>/dev/null || true

            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}  ✅ User created successfully!${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "  Username:  ${BOLD}$USERNAME${NC}"
            echo -e "  Password:  ${BOLD}$PASSWORD${NC}"
            echo -e "  CalDAV URL: https://<domain>/cal.php/principals/$USERNAME/"
            echo -e "  Calendar:  https://<domain>/cal.php/calendars/$USERNAME/default/"
            echo ""
        else
            die "Failed to add user: $ADD_RESULT"
        fi
        ;;

    delete)
        # ── Delete User ────────────────────────────────────────────────────
        if [[ -z "$USERNAME" ]]; then
            die "--username is required for delete"
        fi

        step "Deleting user: $USERNAME"

        if [[ ! -f "$DB_FILE" ]]; then
            die "Database not found: $DB_FILE"
        fi

        if [[ "$YES" != true ]]; then
            read -r -p "$(echo -e "${YELLOW}Are you sure you want to delete user '$USERNAME' and all their data? [y/N] ${NC}")" CONFIRM
            if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                info "Cancelled"
                exit 0
            fi
        fi

        # Delete in correct order: calendar objects -> calendars -> principals -> user
        DEL_RESULT=$("$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$db->enableExceptions(true);
                \$db->exec('BEGIN');

                // Get calendar IDs first
                \$calIds = [];
                \$result = \$db->query(\"SELECT id FROM calendars WHERE principaluri = 'principals/${USERNAME}'\");
                while (\$row = \$result->fetchArray(SQLITE3_NUM)) {
                    \$calIds[] = \$row[0];
                }

                // Delete calendar objects
                if (!empty(\$calIds)) {
                    \$calIdList = implode(',', array_map('intval', \$calIds));
                    \$db->exec(\"DELETE FROM calendarobjects WHERE calendarid IN (\$calIdList)\");
                }

                // Delete calendars
                \$db->exec(\"DELETE FROM calendars WHERE principaluri = 'principals/${USERNAME}'\");

                // Delete principals
                \$db->exec(\"DELETE FROM principals WHERE uri = 'principals/${USERNAME}'\");

                // Delete user
                \$db->exec(\"DELETE FROM users WHERE username = '${USERNAME}'\");

                \$db->exec('COMMIT');
                echo 'SUCCESS';
            } catch (Exception \$e) {
                if (isset(\$db)) {
                    try { \$db->exec('ROLLBACK'); } catch (Exception \$ex) {}
                }
                echo 'ERROR: ' . \$e->getMessage();
            }
        " 2>&1)

        if [[ "$DEL_RESULT" == "SUCCESS" ]]; then
            success "User '$USERNAME' deleted"
        else
            die "Failed to delete user: $DEL_RESULT"
        fi
        ;;

    list)
        # ── List Users ─────────────────────────────────────────────────────
        step "Listing users..."

        if [[ ! -f "$DB_FILE" ]]; then
            die "Database not found: $DB_FILE"
        fi

        echo ""
        printf "  %-5s %-20s %-20s %-30s\n" "ID" "Username" "Display Name" "Email"
        printf "  %-5s %-20s %-20s %-30s\n" "─────" "────────────────────" "────────────────────" "──────────────────────────────"

        "$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$result = \$db->query('SELECT id, username, displayname, email FROM users ORDER BY id');
                while (\$row = \$result->fetchArray(SQLITE3_ASSOC)) {
                    printf(\"  %-5s %-20s %-20s %-30s\n\",
                        \$row['id'],
                        \$row['username'],
                        \$row['displayname'] ?? '(none)',
                        \$row['email'] ?? '(none)'
                    );
                }
            } catch (Exception \$e) {
                echo 'Error: ' . \$e->getMessage() . '\n';
            }
        " 2>&1

        echo ""

        # Also show calendars per user
        info "Calendars per user:"
        "$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$result = \$db->query(\"
                    SELECT p.uri as principal_uri, c.uri as calendar_uri, c.displayname, c.components
                    FROM calendars c
                    JOIN principals p ON c.principaluri = p.uri
                    ORDER BY p.uri, c.uri
                \");
                while (\$row = \$result->fetchArray(SQLITE3_ASSOC)) {
                    printf(\"  %-30s → %-40s [%s]\n\",
                        \$row['principal_uri'],
                        \$row['calendar_uri'],
                        \$row['components']
                    );
                }
            } catch (Exception \$e) {
                echo '  (no calendars or error: ' . \$e->getMessage() . ')\n';
            }
        " 2>&1
        ;;

    password)
        # ── Change Password ────────────────────────────────────────────────
        if [[ -z "$USERNAME" ]]; then
            die "--username is required for password"
        fi
        if [[ -z "$NEW_PASSWORD" ]]; then
            die "--new-password is required for password"
        fi

        step "Changing password for: $USERNAME"

        if [[ ! -f "$DB_FILE" ]]; then
            die "Database not found: $DB_FILE"
        fi

        NEW_HASH=$("$PHP_BIN" -r "echo password_hash('$NEW_PASSWORD', PASSWORD_BCRYPT);")

        PW_RESULT=$("$PHP_BIN" -r "
            try {
                \$db = new SQLite3('$DB_FILE');
                \$db->enableExceptions(true);
                \$stmt = \$db->prepare('UPDATE users SET password = :p WHERE username = :u');
                \$stmt->bindValue(':p', '$NEW_HASH', SQLITE3_TEXT);
                \$stmt->bindValue(':u', '$USERNAME', SQLITE3_TEXT);
                \$stmt->execute();
                \$changes = \$db->changes();
                echo \$changes > 0 ? 'SUCCESS' : 'NOT_FOUND';
            } catch (Exception \$e) {
                echo 'ERROR: ' . \$e->getMessage();
            }
        " 2>&1)

        if [[ "$PW_RESULT" == "SUCCESS" ]]; then
            success "Password changed for user '$USERNAME'"
            echo -e "  New password: ${BOLD}$NEW_PASSWORD${NC}"
        elif [[ "$PW_RESULT" == "NOT_FOUND" ]]; then
            die "User '$USERNAME' not found"
        else
            die "Failed to change password: $PW_RESULT"
        fi
        ;;

    *)
        die "Unknown command: '$COMMAND'. Use: add, delete, list, password"
        ;;
esac
