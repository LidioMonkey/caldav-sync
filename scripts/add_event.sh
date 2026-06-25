#!/usr/bin/env bash
#===============================================================================
# add_event.sh - Add Calendar Event to Baikal CalDAV
#
# Usage:
#   sudo bash add_event.sh [OPTIONS]
#
# Options:
#   --username      CalDAV username (required)
#   --calendar      Calendar URI (required, e.g. work, family, personal)
#   --title         Event title (required)
#   --start         Start time in format "YYYY-MM-DD HH:MM" (required)
#   --end           End time in format "YYYY-MM-DD HH:MM" (optional, default +1h)
#   --location      Event location (optional)
#   --description   Event description / notes (optional)
#   --all-day       Set as all-day event (flag, optional)
#   --install-dir   Baikal installation directory (default: /opt/baikal)
#   --help          Show this help
#
# Examples:
#   sudo bash add_event.sh --username myname --calendar work \
#     --title "Q3计划讨论会" --start "2026-06-26 15:00" \
#     --location "301会议室" --description "讨论Q3计划"
#
#   sudo bash add_event.sh --username myname --calendar personal \
#     --title "跑步" --start "2026-06-27 08:00"
#
#   sudo bash add_event.sh --username myname --calendar family \
#     --title "家庭聚餐" --start "2026-06-27 19:00" \
#     --location "海底捞" --description "地点：海底捞"
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
USERNAME=""
CALENDAR=""
TITLE=""
START_TIME=""
END_TIME=""
LOCATION=""
DESCRIPTION=""
ALL_DAY=false

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --username)    USERNAME="$2"; shift 2 ;;
        --calendar)    CALENDAR="$2"; shift 2 ;;
        --title)       TITLE="$2"; shift 2 ;;
        --start)       START_TIME="$2"; shift 2 ;;
        --end)         END_TIME="$2"; shift 2 ;;
        --location)    LOCATION="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --all-day)     ALL_DAY=true; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            head -28 "$0" | tail -26
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$USERNAME" ]]; then die "--username is required"; fi
if [[ -z "$CALENDAR" ]]; then die "--calendar is required (e.g. work, family, personal)"; fi
if [[ -z "$TITLE" ]]; then die "--title is required"; fi
if [[ -z "$START_TIME" ]]; then die "--start is required (format: 'YYYY-MM-DD HH:MM')"; fi

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

DB_FILE="$INSTALL_DIR/Specific/db.sqlite"

if [[ ! -f "$DB_FILE" ]]; then
    die "Database not found: $DB_FILE. Is Baikal installed?"
fi

# ── Check user exists ────────────────────────────────────────────────────────
USER_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM principals WHERE uri='principals/$USERNAME';" 2>/dev/null || echo "0")
if [[ "$USER_COUNT" -eq 0 ]]; then
    die "User '$USERNAME' does not exist"
fi

# ── Check calendar exists ────────────────────────────────────────────────────
CAL_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM calendars WHERE principaluri='principals/$USERNAME' AND uri='$CALENDAR';" 2>/dev/null || echo "0")
if [[ "$CAL_COUNT" -eq 0 ]]; then
    die "Calendar '$CALENDAR' does not exist for user '$USERNAME'. Create it first with manage_calendar.sh"
fi

# ── Get calendar ID ──────────────────────────────────────────────────────────
CAL_ID=$(sqlite3 "$DB_FILE" "SELECT id FROM calendars WHERE principaluri='principals/$USERNAME' AND uri='$CALENDAR';")

# ── Parse times ──────────────────────────────────────────────────────────────
# Convert "YYYY-MM-DD HH:MM" to Unix timestamp
if [[ "$ALL_DAY" == true ]]; then
    # All-day event: strip time, use date only
    START_DATE="${START_TIME%% *}"
    START_TS=$(date -d "${START_DATE} 00:00:00" +%s 2>/dev/null || echo "")
    END_TS=$(date -d "${START_DATE} 23:59:59" +%s 2>/dev/null || echo "")
    IS_FLOATING=1
else
    START_TS=$(date -d "$START_TIME" +%s 2>/dev/null || echo "")
    if [[ -z "$END_TIME" ]]; then
        # Default: 1 hour duration
        END_TS=$((START_TS + 3600))
    else
        END_TS=$(date -d "$END_TIME" +%s 2>/dev/null || echo "")
    fi
    IS_FLOATING=0
fi

if [[ -z "$START_TS" ]]; then
    die "Invalid start time: $START_TIME. Use format 'YYYY-MM-DD HH:MM'"
fi

# ── Generate UID ─────────────────────────────────────────────────────────────
EVENT_UID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$RANDOM")
EVENT_URI="${EVENT_UID}.ics"

# ── Build iCalendar (ICS) data ───────────────────────────────────────────────
# Build DTSTART/DTEND in iCal format
if [[ "$ALL_DAY" == true ]]; then
    DTSTART=$(date -d "@$START_TS" +%Y%m%d 2>/dev/null)
    DTEND=$(date -d "@$END_TS" +%Y%m%d 2>/dev/null)
    DTSTART_LINE="DTSTART;VALUE=DATE:${DTSTART}"
    DTEND_LINE="DTEND;VALUE=DATE:${DTEND}"
else
    DTSTART=$(date -d "@$START_TS" +%Y%m%dT%H%M%S 2>/dev/null)
    DTEND=$(date -d "@$END_TS" +%Y%m%dT%H%M%S 2>/dev/null)
    DTSTART_LINE="DTSTART:${DTSTART}"
    DTEND_LINE="DTEND:${DTEND}"
fi

DTSTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# Escape special characters for iCalendar
escape_ical() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//;/\\;}"
    s="${s//,/\\,}"
    s="${s//$'\n'/\\n}"
    echo "$s"
}

TITLE_ESC=$(escape_ical "$TITLE")
LOCATION_ESC=$(escape_ical "$LOCATION")
DESC_ESC=$(escape_ical "$DESCRIPTION")

# Build ICS content
ICS_CONTENT="BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Baikal//CalDAV Server//EN
BEGIN:VEVENT
UID:${EVENT_UID}
DTSTAMP:${DTSTAMP}
${DTSTART_LINE}
${DTEND_LINE}
SUMMARY:${TITLE_ESC}"

if [[ -n "$LOCATION" ]]; then
    ICS_CONTENT+=$'\n'"LOCATION:${LOCATION_ESC}"
fi

if [[ -n "$DESCRIPTION" ]]; then
    ICS_CONTENT+=$'\n'"DESCRIPTION:${DESC_ESC}"
fi

ICS_CONTENT+=$'\n'"END:VEVENT"
ICS_CONTENT+=$'\n'"END:VCALENDAR"

# ── Calculate size ───────────────────────────────────────────────────────────
ICS_SIZE=${#ICS_CONTENT}

# ── Insert into database ─────────────────────────────────────────────────────
info "Adding event to database..."
info "  Calendar:  $CALENDAR (id=$CAL_ID)"
info "  Title:     $TITLE"
info "  Start:     $(date -d "@$START_TS" '+%Y-%m-%d %H:%M')"
info "  End:       $(date -d "@$END_TS" '+%Y-%m-%d %H:%M')"
[[ -n "$LOCATION" ]] && info "  Location:  $LOCATION"

# Insert the calendar object
sqlite3 "$DB_FILE" << SQL
INSERT INTO calendarobjects (calendardata, uri, calendarid, lastmodified, etag, size, componenttype, firstoccurence, lastoccurence, uid)
VALUES (
    '${ICS_CONTENT//\'/\'\'}',
    '${EVENT_URI}',
    ${CAL_ID},
    ${START_TS},
    '$(echo -n "$ICS_CONTENT" | md5sum | cut -d' ' -f1)',
    ${ICS_SIZE},
    'VEVENT',
    ${START_TS},
    ${END_TS},
    '${EVENT_UID}'
);
SQL

# ── Update calendar ctag (change tag) to notify clients ──────────────────────
NEW_CTAG=$(date +%s)
sqlite3 "$DB_FILE" "UPDATE calendars SET ctag='${NEW_CTAG}', synctoken=synctoken+1 WHERE id=${CAL_ID};"

success "Event created successfully!"

# ── Output ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ 日程已添加${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  标题:    ${BOLD}${TITLE}${NC}"
echo -e "  时间:    ${BOLD}$(date -d "@$START_TS" '+%Y年%m月%d日 %H:%M') - $(date -d "@$END_TS" '+%H:%M')${NC}"
[[ -n "$LOCATION" ]] && echo -e "  地点:    ${BOLD}${LOCATION}${NC}"
echo -e "  日历:    ${BOLD}${CALENDAR}${NC}"
echo ""
echo -e "  ${YELLOW}📱 iPhone 上打开日历 App 即可看到，等待几秒自动同步。${NC}"
echo ""
