#!/bin/sh
#
# verify.sh - Verification script for Xiaomi Router Transparent Proxy
#
# Run this on the router to check if everything is working.
# Usage: sh verify.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; [ $# -ge 2 ] && exit "$2"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
CONTAINER=openwrt
XRAY_PORT=12346

echo "================================================"
echo "  Xiaomi TProxy Verification"
echo "================================================"
echo ""

# 1. Docker
echo "--- Docker ---"
if [ -f "$DOCKER" ] || DOCKER=$(which docker 2>/dev/null); then
    pass "Docker binary found"
else
    fail "Docker not found"
fi

# 2. Container
echo "--- Container ---"
if $DOCKER ps -q -f name="$CONTAINER" 2>/dev/null | grep -q .; then
    pass "Container '$CONTAINER' is running"

    PRIV=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
    if [ "$PRIV" = "true" ]; then
        pass "Container is privileged"
    else
        fail "Container not privileged --proxy won't work"
    fi

    RESTART=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
    if [ "$RESTART" = "always" ]; then
        pass "Container restart policy: always"
    else
        warn "Container restart policy: $RESTART (not 'always', won't survive reboot)"
    fi
else
    fail "Container '$CONTAINER' not running"
fi

# 3. xray process
echo "--- xray Process ---"
XRAY_PID=$($DOCKER exec "$CONTAINER" pidof xray 2>/dev/null || echo "")
if [ -n "$XRAY_PID" ]; then
    pass "xray running (PID: $XRAY_PID)"

    XRAY_LISTEN=$($DOCKER exec "$CONTAINER" netstat -tlnp 2>/dev/null | grep ":$XRAY_PORT " | head -1)
    if [ -n "$XRAY_LISTEN" ]; then
        pass "xray listening on port $XRAY_PORT"
    else
        fail "xray NOT listening on port $XRAY_PORT"
    fi
else
    fail "xray not running"
fi

# 4. xray config
echo "--- xray Config ---"
if $DOCKER exec "$CONTAINER" test -f /etc/xray/config.json 2>/dev/null; then
    pass "Config file exists"
    DOMAIN_COUNT=$($DOCKER exec "$CONTAINER" grep -c "domain:" /etc/xray/config.json 2>/dev/null || echo 0)
    pass "Domain rules: $DOMAIN_COUNT"
else
    fail "Config file /etc/xray/config.json not found"
fi

# 5. iptables
echo "--- iptables ---"
XRAY_CHAIN=$(iptables -t nat -L XRAY -n 2>/dev/null || echo "")
if echo "$XRAY_CHAIN" | grep -q "REDIRECT"; then
    pass "XRAY chain exists with REDIRECT rules"
    REDIRECT_443=$(echo "$XRAY_CHAIN" | grep "dpt:443" | awk '{print $1}')
    if [ "$REDIRECT_443" -gt 0 ] 2>/dev/null; then
        pass "Port 443 REDIRECT: $REDIRECT_443 packets redirected"
    else
        warn "No packets redirected yet (wait for traffic)"
    fi
else
    fail "XRAY iptables chain not found"
fi

# Check QUIC block
if iptables -L FORWARD -n 2>/dev/null | grep -q "udp dpt:443 DROP"; then
    pass "QUIC blocked (UDP 443 DROP)"
else
    warn "QUIC not blocked - mobile apps may bypass proxy"
fi

# 6. Reboot persistence
echo "--- Persistence ---"
if grep -q "xray run" /etc/rc.local 2>/dev/null; then
    pass "rc.local configured for auto-start"
else
    warn "rc.local NOT configured - proxy won't survive reboot"
fi

# 7. SOCKS proxy test (if available)
echo "--- Proxy Functionality ---"
if $DOCKER exec "$CONTAINER" which curl 2>/dev/null >/dev/null; then
    # Check if xray config has SOCKS inbound for testing
    if $DOCKER exec "$CONTAINER" grep -q "socks" /etc/xray/config.json 2>/dev/null; then
        SOCKS_PORT=$($DOCKER exec "$CONTAINER" grep -A5 "socks" /etc/xray/config.json 2>/dev/null | grep "port" | grep -oP '\d+' | head -1)
        if [ -n "$SOCKS_PORT" ]; then
            RESULT=$($DOCKER exec "$CONTAINER" sh -c "curl -s --max-time 10 --socks5-hostname 127.0.0.1:$SOCKS_PORT -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null" || echo "FAIL")
            if [ "$RESULT" != "FAIL" ]; then
                pass "SOCKS proxy test: HTTP $RESULT"
            fi
        fi
    else
        warn "No SOCKS test port configured (normal for production)"
    fi
else
    warn "curl not available in container - skip proxy test"
fi

# 8. Summary
echo ""
echo "================================================"
echo "  Summary"
echo "================================================"
echo ""
echo "To test from a WiFi device:"
echo "  curl https://ip.sb          # Shows proxy IP"
echo "  curl https://chatgpt.com    # Should work"
echo "  curl https://claude.ai      # Should work"
echo ""
echo "To check live connections:"
echo "  $DOCKER exec $CONTAINER netstat -tnp | grep xray | grep -v LISTEN"
echo ""
echo "To view xray debug log:"
echo "  $DOCKER exec -d $CONTAINER sh -c 'xray run -c /etc/xray/config.json > /tmp/x.log 2>&1'"
echo "  $DOCKER exec $CONTAINER cat /tmp/x.log"
