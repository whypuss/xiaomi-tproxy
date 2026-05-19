#!/bin/sh
#
# verify.sh - xray transparent proxy 健康檢查
# Version: 2.0.0 (2025-05-19)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
CONTAINER=openwrt
XRAY_PORT=12346

echo "================================================"
echo "  xray TProxy 健康檢查 v2.0.0"
echo "================================================"
echo ""

ALL_PASS=true

# ─── Docker ────────────────────────────────────────────────────
echo "--- Docker ---"
if [ -f "$DOCKER" ] || DOCKER=$(which docker 2>/dev/null); then
    pass "Docker binary: $DOCKER"
else
    fail "Docker not found"
    ALL_PASS=false
fi

# ─── Container ─────────────────────────────────────────────────
echo "--- Container ---"
if $DOCKER ps -q -f name="$CONTAINER" 2>/dev/null | grep -q .; then
    pass "Container '$CONTAINER' running"

    PRIV=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
    [ "$PRIV" = "true" ] && pass "Privileged" || { warn "Not privileged"; ALL_PASS=false; }

    RESTART=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
    [ "$RESTART" = "always" ] && pass "Restart: always" || warn "Restart: $RESTART"
else
    fail "Container not running"
    ALL_PASS=false
fi

# ─── xray Process ──────────────────────────────────────────────
echo "--- xray ---"
XRAY_PID=$($DOCKER exec "$CONTAINER" pidof xray 2>/dev/null || echo "")
if [ -n "$XRAY_PID" ]; then
    pass "xray running (PID: $XRAY_PID)"

    if $DOCKER exec "$CONTAINER" netstat -tlnp 2>/dev/null | grep -q ":$XRAY_PORT "; then
        pass "Listening on :$XRAY_PORT"
    else
        fail "Not listening on :$XRAY_PORT"
        ALL_PASS=false
    fi
else
    fail "xray not running"
    ALL_PASS=false
fi

# ─── Config ───────────────────────────────────────────────────
echo "--- Config ---"
if $DOCKER exec "$CONTAINER" test -f /etc/xray/config.json 2>/dev/null; then
    pass "Config exists"
    DOMAIN_COUNT=$($DOCKER exec "$CONTAINER" grep -c "domain:" /etc/xray/config.json 2>/dev/null || echo 0)
    pass "Domain rules: $DOMAIN_COUNT"

    # Check critical fields
    FOLLOW=$($DOCKER exec "$CONTAINER" grep -c "followRedirect" /etc/xray/config.json 2>/dev/null || echo 0)
    SNIFF=$($DOCKER exec "$CONTAINER" grep -c "sniffing" /etc/xray/config.json 2>/dev/null || echo 0)
    [ "$FOLLOW" -gt 0 ] && pass "followRedirect: configured" || { fail "followRedirect missing"; ALL_PASS=false; }
    [ "$SNIFF" -gt 0 ] && pass "sniffing: configured" || { fail "sniffing missing"; ALL_PASS=false; }
else
    fail "Config missing"
    ALL_PASS=false
fi

# ─── iptables ──────────────────────────────────────────────────
echo "--- iptables ---"
XRAY_CHAIN=$(iptables -t nat -L XRAY -n 2>/dev/null || echo "")
if echo "$XRAY_CHAIN" | grep -q "REDIRECT"; then
    pass "XRAY chain exists"

    PKTS=$(echo "$XRAY_CHAIN" | grep "dpt:443" | awk '{print $1}' | head -1)
    if [ -n "$PKTS" ] && [ "$PKTS" != "0" ]; then
        pass "Port 443 redirect: $PKTS packets"
    else
        warn "No packets redirected yet (normal if no traffic)"
    fi
else
    fail "XRAY chain missing"
    ALL_PASS=false
fi

# QUIC block
if iptables -L FORWARD -n 2>/dev/null | grep -q "udp dpt:443 DROP"; then
    pass "QUIC blocked"
else
    warn "QUIC not blocked"
fi

# ─── Proxy 連接（最關鍵）────────────────────────────────────────
echo "--- Proxy 連接（最關鍵）---"
PROXY_CONN=$(netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v "192.168" | head -5 || echo "")
if [ -n "$PROXY_CONN" ]; then
    pass "Proxy connections active:"
    echo "$PROXY_CONN" | while read line; do
        echo "    $line"
    done
else
    fail "No proxy connections (xray not connected to server)"
    warn "Run: $DOCKER exec $CONTAINER cat /tmp/xray.log"
    ALL_PASS=false
fi

# ─── 重啟持久化 ────────────────────────────────────────────────
echo "--- Persistence ---"
if [ -f "$RC_LOCAL" ] && grep -q "xray run" "$RC_LOCAL" 2>/dev/null; then
    pass "rc.local configured"
else
    fail "rc.local not configured"
    ALL_PASS=false
fi

# ─── Summary ──────────────────────────────────────────────────
echo ""
echo "================================================"
if [ "$ALL_PASS" = true ]; then
    echo "  全部檢查通過 ✓"
else
    echo "  有檢查失敗，見上面 [FAIL]"
fi
echo "================================================"
echo ""
echo "測試（從 WiFi 設備）:"
echo "  curl https://ip.sb          # 顯示 proxy IP"
echo "  curl https://chatgpt.com    # 成功 load"
echo ""
echo "Debug:"
echo "  $DOCKER exec $CONTAINER cat /tmp/xray.log"
echo "  netstat -tnp | grep xray | grep ESTABLISHED | grep -v 192.168"
