#!/usr/bin/env bash
#===============================================================================
# diagnose.sh - CalDAV Full-Stack Diagnostic Tool
#
# Usage:
#   sudo bash diagnose.sh --domain <domain> [--port <baikal-port>]
#
# Options:
#   --domain    CalDAV domain (required)
#   --port      Baikal internal port (default: 8080)
#   --help      Show this help
#
# Example:
#   sudo bash diagnose.sh --domain cal.example.com
#===============================================================================

set -euo pipefail

# ── Color Output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

PASS="${GREEN}PASS${NC}"
FAIL="${RED}FAIL${NC}"
WARN="${YELLOW}WARN${NC}"

step()    { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Counters ─────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0

check() {
    local name="$1"
    local status="$2"
    local detail="$3"
    TOTAL=$((TOTAL + 1))
    local icon=""
    case "$status" in
        PASS) icon="$PASS"; PASSED=$((PASSED + 1)) ;;
        FAIL) icon="$FAIL"; FAILED=$((FAILED + 1)) ;;
        WARN) icon="$WARN"; FAILED=$((FAILED + 1)) ;;
    esac
    printf "  [%s] %-50s %s\n" "$icon" "$name" "$detail"
}

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN=""
PORT="8080"

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --port)   PORT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo bash diagnose.sh --domain <domain> [--port <port>]"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    die "--domain is required"
fi

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║       CalDAV Full-Stack Diagnostic — $DOMAIN${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Check 1: baikal.service status ──────────────────────────────────────────
step "1. Baikal Service Status"

if systemctl is-active --quiet baikal 2>/dev/null; then
    check "baikal.service running" PASS "active"
else
    STATUS=$(systemctl is-active baikal 2>/dev/null || echo "not-found")
    check "baikal.service running" FAIL "status: $STATUS"
    echo "         → Fix: sudo systemctl start baikal"
fi

# ── Check 2: Baikal port listening ───────────────────────────────────────────
step "2. Baikal Port (127.0.0.1:$PORT)"

if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
    PID=$(ss -tlnp 2>/dev/null | grep "127.0.0.1:$PORT" | awk '{print $NF}' | sed 's/.*pid=//' | sed 's/,.*//')
    check "Port $PORT listening" PASS "pid=$PID"
else
    check "Port $PORT listening" FAIL "not listening on 127.0.0.1:$PORT"
    echo "         → Fix: sudo systemctl restart baikal"
fi

# ── Check 3: Nginx running ──────────────────────────────────────────────────
step "3. Nginx Status"

if command -v nginx &>/dev/null; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
        check "nginx running" PASS "active"
    else
        NGINX_STATUS=$(systemctl is-active nginx 2>/dev/null || echo "not-found")
        check "nginx running" FAIL "status: $NGINX_STATUS"
        echo "         → Fix: sudo systemctl start nginx"
    fi
else
    check "nginx installed" FAIL "nginx not found"
    echo "         → Fix: Install nginx (apt install nginx / yum install nginx)"
fi

# ── Check 4: Nginx config syntax ────────────────────────────────────────────
step "4. Nginx Configuration"

if command -v nginx &>/dev/null; then
    if nginx -t &>/dev/null 2>&1; then
        check "nginx config syntax" PASS "OK"
    else
        NGINX_ERR=$(nginx -t 2>&1 | tail -3)
        check "nginx config syntax" FAIL "$NGINX_ERR"
        echo "         → Fix: Check /etc/nginx/sites-available/caldav"
    fi

    if [[ -f "/etc/nginx/sites-enabled/caldav" ]] || nginx -T 2>/dev/null | grep -q "server_name.*$DOMAIN"; then
        check "nginx site for $DOMAIN" PASS "configured"
    else
        check "nginx site for $DOMAIN" FAIL "no config found for $DOMAIN"
        echo "         → Fix: Create /etc/nginx/sites-available/caldav and enable it"
    fi
else
    check "nginx config" WARN "nginx not installed, skipping"
fi

# ── Check 5: Port 443 listening ─────────────────────────────────────────────
step "5. HTTPS Port (443)"

if ss -tlnp 2>/dev/null | grep -q ':443 '; then
    PROCESS=$(ss -tlnp 2>/dev/null | grep ':443 ' | awk '{print $NF}')
    check "Port 443 listening" PASS "$PROCESS"
else
    check "Port 443 listening" FAIL "not listening"
    echo "         → Fix: Ensure nginx is configured for SSL and running"
fi

# ── Check 6: SSL Certificate ────────────────────────────────────────────────
step "6. SSL Certificate"

CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
if [[ -f "$CERT_PATH" ]]; then
    # Check expiry
    if command -v openssl &>/dev/null; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
        if [[ -n "$EXPIRY" ]]; then
            EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            if [[ "$EXPIRY_EPOCH" -gt 0 ]]; then
                DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                if [[ "$DAYS_LEFT" -lt 0 ]]; then
                    check "SSL certificate" FAIL "EXPIRED on $EXPIRY"
                    echo "         → Fix: sudo certbot renew"
                elif [[ "$DAYS_LEFT" -lt 15 ]]; then
                    check "SSL certificate" WARN "expires in $DAYS_LEFT days ($EXPIRY)"
                    echo "         → Fix: sudo certbot renew"
                else
                    check "SSL certificate" PASS "valid until $EXPIRY ($DAYS_LEFT days)"
                fi
            else
                check "SSL certificate" PASS "expires: $EXPIRY"
            fi
        fi
    else
        check "SSL certificate" PASS "found at $CERT_PATH"
    fi

    # Check cert matches domain
    if command -v openssl &>/dev/null; then
        CERT_DOMAIN=$(openssl x509 -text -noout -in "$CERT_PATH" 2>/dev/null | grep "DNS:" | head -1 | sed 's/.*DNS://' | tr -d ' ,')
        if [[ "$CERT_DOMAIN" == *"$DOMAIN"* ]] || [[ "$DOMAIN" == *"$CERT_DOMAIN"* ]]; then
            check "Certificate domain match" PASS "$CERT_DOMAIN"
        else
            check "Certificate domain match" WARN "cert for $CERT_DOMAIN, requested $DOMAIN"
        fi
    fi
else
    check "SSL certificate" FAIL "not found at $CERT_PATH"
    echo "         → Fix: sudo certbot certonly --standalone -d $DOMAIN"
fi

# ── Check 7: DNS Resolution ─────────────────────────────────────────────────
step "7. DNS Resolution"

if command -v dig &>/dev/null; then
    DNS_RESULT=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
elif command -v nslookup &>/dev/null; then
    DNS_RESULT=$(nslookup "$DOMAIN" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
else
    DNS_RESULT=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}')
fi

if [[ -n "$DNS_RESULT" ]]; then
    # Get server public IP
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "unknown")
    if [[ "$DNS_RESULT" == "$SERVER_IP" ]]; then
        check "DNS resolution" PASS "$DOMAIN → $DNS_RESULT (matches server)"
    else
        check "DNS resolution" WARN "$DOMAIN → $DNS_RESULT (server IP: $SERVER_IP)"
        echo "         → DNS record may not point to this server"
    fi
else
    check "DNS resolution" FAIL "$DOMAIN does not resolve"
    echo "         → Fix: Add A record pointing to this server's IP"
fi

# ── Check 8: Baikal HTTP response ───────────────────────────────────────────
step "8. Baikal Local HTTP Response"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" ]]; then
    check "Baikal HTTP response" PASS "HTTP $HTTP_CODE from http://127.0.0.1:$PORT/"
else
    check "Baikal HTTP response" FAIL "HTTP $HTTP_CODE from http://127.0.0.1:$PORT/"
    echo "         → Fix: Check baikal service status and logs"
fi

# ── Check 9: HTTPS response ─────────────────────────────────────────────────
step "9. Public HTTPS Response"

HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://$DOMAIN/" 2>/dev/null || echo "000")
if [[ "$HTTPS_CODE" == "200" || "$HTTPS_CODE" == "302" || "$HTTPS_CODE" == "301" ]]; then
    check "HTTPS response" PASS "HTTP $HTTPS_CODE from https://$DOMAIN/"
elif [[ "$HTTPS_CODE" == "000" ]]; then
    check "HTTPS response" FAIL "connection failed — SSL or network issue"
    echo "         → Check firewall, nginx, and SSL configuration"
else
    check "HTTPS response" WARN "HTTP $HTTPS_CODE from https://$DOMAIN/"
fi

# ── Check 10: CalDAV endpoint ────────────────────────────────────────────────
step "10. CalDAV Endpoint"

CALDAV_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X PROPFIND \
    -H "Depth: 0" \
    "https://$DOMAIN/cal.php" 2>/dev/null || echo "000")

if [[ "$CALDAV_CODE" == "401" ]]; then
    check "CalDAV PROPFIND" PASS "HTTP 401 (auth required — normal)"
elif [[ "$CALDAV_CODE" == "207" ]]; then
    check "CalDAV PROPFIND" PASS "HTTP 207 (Multi-Status — responding)"
elif [[ "$CALDAV_CODE" == "200" ]]; then
    check "CalDAV PROPFIND" PASS "HTTP 200 (OK)"
elif [[ "$CALDAV_CODE" == "404" ]]; then
    check "CalDAV PROPFIND" WARN "HTTP 404 — CalDAV endpoint not found"
    echo "         → Check Baikal installation and URL path"
elif [[ "$CALDAV_CODE" == "000" ]]; then
    check "CalDAV PROPFIND" FAIL "connection failed"
else
    check "CalDAV PROPFIND" WARN "HTTP $CALDAV_CODE — unexpected response"
fi

# ── Check 11: Disk Space ─────────────────────────────────────────────────────
step "11. Disk Space"

INSTALL_DIR="/opt/baikal"
if [[ -d "$INSTALL_DIR" ]]; then
    DISK_USAGE=$(df -h "$INSTALL_DIR" 2>/dev/null | tail -1)
    USE_PCT=$(echo "$DISK_USAGE" | awk '{print $5}' | tr -d '%')
    AVAIL=$(echo "$DISK_USAGE" | awk '{print $4}')
    if [[ "$USE_PCT" -lt 80 ]]; then
        check "Disk space" PASS "used ${USE_PCT}%, ${AVAIL} available"
    elif [[ "$USE_PCT" -lt 95 ]]; then
        check "Disk space" WARN "used ${USE_PCT}%, ${AVAIL} available — consider cleanup"
    else
        check "Disk space" FAIL "used ${USE_PCT}%, ${AVAIL} available — critically low!"
    fi
else
    check "Disk space" WARN "install dir not found, skipping"
fi

# ── Check 12: Recent Error Logs ──────────────────────────────────────────────
step "12. Recent Error Logs"

ERRORS_FOUND=0

# Nginx error log
if [[ -f "/var/log/nginx/error.log" ]]; then
    NGINX_ERRORS=$(tail -50 /var/log/nginx/error.log 2>/dev/null | grep -i "error\|warn" | grep -i "$DOMAIN\|caldav\|upstream\|connect" | tail -5)
    if [[ -n "$NGINX_ERRORS" ]]; then
        check "nginx error log" WARN "found recent errors"
        echo "         Recent nginx errors:"
        echo "$NGINX_ERRORS" | while read -r line; do echo "           $line"; done
        ERRORS_FOUND=$((ERRORS_FOUND + 1))
    else
        check "nginx error log" PASS "no recent errors for $DOMAIN"
    fi
else
    check "nginx error log" WARN "/var/log/nginx/error.log not found"
fi

# Systemd journal for baikal
if journalctl -u baikal --no-pager -n 5 2>/dev/null | grep -qi "error\|fatal\|failed"; then
    BAIKAL_ERRORS=$(journalctl -u baikal --no-pager -n 20 2>/dev/null | grep -i "error\|fatal\|failed" | tail -5)
    if [[ -n "$BAIKAL_ERRORS" ]]; then
        check "baikal journal" WARN "found recent errors"
        echo "         Recent baikal errors:"
        echo "$BAIKAL_ERRORS" | while read -r line; do echo "           $line"; done
        ERRORS_FOUND=$((ERRORS_FOUND + 1))
    fi
else
    check "baikal journal" PASS "no recent errors"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                      DIAGNOSTIC SUMMARY                     ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}✅ All $TOTAL checks passed! CalDAV service is healthy.${NC}"
else
    echo -e "  ${RED}Results: $PASSED passed, $FAILED failed (out of $TOTAL checks)${NC}"
    echo ""
    echo -e "  ${YELLOW}Quick fixes to try:${NC}"
    echo "  1. Restart services: sudo systemctl restart baikal nginx"
    echo "  2. Check firewall:   sudo ufw status"
    echo "  3. Check DNS:        dig +short $DOMAIN"
    echo "  4. Renew SSL:        sudo certbot renew"
    echo "  5. Full logs:        journalctl -xeu baikal"
fi

echo ""
