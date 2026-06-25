#!/usr/bin/env bash
#===============================================================================
# manage_calendar.sh - Baikal CalDAV Calendar Management
#
# Usage:
#   sudo bash manage_calendar.sh <command> [OPTIONS]
#
# Commands:
#   add       Create a new calendar for a user
#   delete    Delete a calendar
#   list      List all calendars (optionally filtered by user)
#   rename    Rename a calendar
#
# Options:
#   --username      Owner username (required for add/delete/rename)
#   --calendar      Calendar name/URI (required for add/delete/rename)
#   --display-name  Display name (optional for add, defaults to calendar name)
#   --color         Calendar color in hex (optional, e.g. #FF9500)
#   --description   Calendar description (optional)
#   --new-name      New display name (required for rename)
#   --install-dir   Baikal installation directory (default: /opt/baikal)
#   --help          Show this help
#
# Examples:
#   sudo bash manage_calendar.sh add --username myname --calendar work
#   sudo bash manage_calendar.sh add --username myname --calendar family --display-name "家庭日历" --color "#34C759"
#   sudo bash manage_calendar.sh list
#   sudo bash manage_calendar.sh list --username myname
#   sudo bash manage_calendar.sh delete --username myname --calendar work
#   sudo bash manage_calendar.sh rename --username myname --calendar work --new-name "工作日程"
#===============================================================================

set -euo pipefail

# ── Color Output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/baikal"
COMMAND=""
USERNAME=""
CALENDAR=""
DISPLAY_NAME=""
COLOR=""
DESCRIPTION=""
NEW_NAME=""

# ── Parse Arguments ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)      USERNAME="$2"; shift 2 ;;
            --calendar)      CALENDAR="$2"; shift 2 ;;
            --display-name)  DISPLAY_NAME="$2"; shift 2 ;;
            --color)         COLOR="$2"; shift 2 ;;
            --description)   DESCRIPTION="$2"; shift 2 ;;
            --new-name)      NEW_NAME="$2"; shift 2 ;;
            --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
            --help|-h)
                head -30 "$0" | tail -28
                exit 0
                ;;
            *)
                if [[ -z "$COMMAND" ]]; then
                    COMMAND="$1"
                    shift
                else
                    die "Unknown argument: $1"
                fi
                ;;
        esac
    done
}

parse_args "$@"

if [[ -z "$COMMAND" ]]; then
    die "Command required: add | delete | list | rename"
fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

DB_FILE="$INSTALL_DIR/Specific/db.sqlite"

if [[ ! -f "$DB_FILE" ]]; then
    die "Database not found: $DB_FILE. Is Baikal installed?"
fi

# ── Helper: check if user exists ────────────────────────────────────────────
user_exists() {
    local u="$1"
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM principals WHERE uri='principals/$u';" 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# ── Helper: check if calendar exists for user ───────────────────────────────
calendar_exists() {
    local u="$1"
    local c="$2"
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM calendars WHERE principaluri='principals/$u' AND uri='$c';" 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# ── Helper: get user's principal URI ────────────────────────────────────────
get_principal_uri() {
    echo "principals/$1"
}

# ══════════════════════════════════════════════════════════════════════════════
#  ADD CALENDAR
# ══════════════════════════════════════════════════════════════════════════════
cmd_add() {
    if [[ -z "$USERNAME" ]]; then die "--username is required for add"; fi
    if [[ -z "$CALENDAR" ]]; then die "--calendar is required for add (e.g. --calendar work)"; fi

    if ! user_exists "$USERNAME"; then
        die "User '$USERNAME' does not exist. Create the user first: manage_user.sh add --username $USERNAME"
    fi

    if calendar_exists "$USERNAME" "$CALENDAR"; then
        die "Calendar '$CALENDAR' already exists for user '$USERNAME'"
    fi

    local display="${DISPLAY_NAME:-$CALENDAR}"
    local color="${COLOR:-#007AFF}"
    local desc="${DESCRIPTION:-}"
    local now
    now=$(date +%s)

    info "Creating calendar '$CALENDAR' for user '$USERNAME'..."
    info "  Display name: $display"
    info "  Color:        $color"
    [[ -n "$desc" ]] && info "  Description:  $desc"

    sqlite3 "$DB_FILE" << SQL
INSERT INTO calendars (principaluri, displayname, uri, description, components, ctag, calendarcolor, synctoken)
VALUES ('principals/${USERNAME}', '${display}', '${CALENDAR}', '${desc}', 'VEVENT,VJOURNAL,VTODO', '$now', '${color}', '1');
SQL

    success "Calendar '$CALENDAR' created successfully!"
    echo ""
    echo -e "  Calendar URL: ${BOLD}https://<domain>/cal.php/calendars/${USERNAME}/${CALENDAR}/${NC}"
    echo -e "  Display name: ${BOLD}${display}${NC}"
    echo -e "  Components:   VEVENT (events), VJOURNAL (journal), VTODO (tasks)"
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} Re-open Calendar app on iPhone to see the new calendar."
}

# ══════════════════════════════════════════════════════════════════════════════
#  DELETE CALENDAR
# ══════════════════════════════════════════════════════════════════════════════
cmd_delete() {
    if [[ -z "$USERNAME" ]]; then die "--username is required for delete"; fi
    if [[ -z "$CALENDAR" ]]; then die "--calendar is required for delete"; fi

    if ! user_exists "$USERNAME"; then
        die "User '$USERNAME' does not exist"
    fi

    if ! calendar_exists "$USERNAME" "$CALENDAR"; then
        die "Calendar '$CALENDAR' does not exist for user '$USERNAME'"
    fi

    # Get calendar ID
    local cal_id
    cal_id=$(sqlite3 "$DB_FILE" "SELECT id FROM calendars WHERE principaluri='principals/$USERNAME' AND uri='$CALENDAR';")

    warn "This will permanently delete calendar '$CALENDAR' and ALL its events for user '$USERNAME'."
    read -r -p "  Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Cancelled."
        exit 0
    fi

    sqlite3 "$DB_FILE" << SQL
DELETE FROM calendarobjects WHERE calendarid = $cal_id;
DELETE FROM calendars WHERE id = $cal_id;
SQL

    success "Calendar '$CALENDAR' deleted."
}

# ══════════════════════════════════════════════════════════════════════════════
#  LIST CALENDARS
# ══════════════════════════════════════════════════════════════════════════════
cmd_list() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║                     Calendar List                            ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local where=""
    if [[ -n "$USERNAME" ]]; then
        where="WHERE principaluri = 'principals/$USERNAME'"
    fi

    sqlite3 -header -column "$DB_FILE" << SQL
SELECT
    REPLACE(principaluri, 'principals/', '') AS user,
    uri AS calendar_id,
    displayname AS display_name,
    calendarcolor AS color,
    COALESCE((SELECT COUNT(*) FROM calendarobjects co WHERE co.calendarid = calendars.id), 0) AS events,
    components
FROM calendars
$where
ORDER BY principaluri, uri;
SQL

    echo ""
    local total
    total=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM calendars $where;")
    echo -e "  Total calendars: ${BOLD}$total${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  RENAME CALENDAR
# ══════════════════════════════════════════════════════════════════════════════
cmd_rename() {
    if [[ -z "$USERNAME" ]]; then die "--username is required for rename"; fi
    if [[ -z "$CALENDAR" ]]; then die "--calendar is required for rename"; fi
    if [[ -z "$NEW_NAME" ]]; then die "--new-name is required for rename"; fi

    if ! calendar_exists "$USERNAME" "$CALENDAR"; then
        die "Calendar '$CALENDAR' does not exist for user '$USERNAME'"
    fi

    sqlite3 "$DB_FILE" "UPDATE calendars SET displayname='$NEW_NAME' WHERE principaluri='principals/$USERNAME' AND uri='$CALENDAR';"

    success "Calendar '$CALENDAR' renamed to '$NEW_NAME'"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$COMMAND" in
    add)    cmd_add ;;
    delete) cmd_delete ;;
    list)   cmd_list ;;
    rename) cmd_rename ;;
    *)      die "Unknown command: $COMMAND. Use: add | delete | list | rename" ;;
esac
