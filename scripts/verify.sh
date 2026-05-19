#!/bin/sh
#
# verify.sh - xray transparent proxy 健康檢查
# Version: 2.1.0 (2026-05-19)
#
# 用法:
#   ./verify.sh [router_ip] [ssh_password]
# 示例:
#   ./verify.sh 192.168.1.59 qwerty66
#
# 注意: 從 Mac 執行，通過 SSH 檢查路由器狀態

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

ROUTER_IP="${1:-192.168.1.59}"
SSH_PASS="${2:-}"
SSH_OPTS="-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=10"
DOCKER="/mnt/docker_disk/mi_docker/docker-binaries/docker"
CONTAINER=openwrt
XRAY_PORT=12346

usage() {
    echo "用法: $0 [router_ip] [ssh_password]"
    echo "示例: $0 192.168.1.59 qwerty66"
    exit 1
}

[ -z "$SSH_PASS" ] && usage

echo "================================================"
echo "  xray TProxy 健康檢查 v2.1.0"
echo "================================================"
echo ""

ALL_PASS=true

# ─── SSH 測試 ─────────────────────────────────────────────────
echo "--- SSH 連接 ---"
if sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "echo ok" >/dev/null 2>&1; then
    pass "SSH 連接正常: root@$ROUTER_IP"
else
    fail "SSH 連接失敗"
    exit 1
fi

# ─── Docker ────────────────────────────────────────────────────
echo "--- Docker ---"
DOCKER_TEST=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "[ -f '$DOCKER' ] && echo ok" 2>/dev/null)
if [ "$DOCKER_TEST" = "ok" ]; then
    pass "Docker binary: $DOCKER"
else
    fail "Docker not found at $DOCKER"
    ALL_PASS=false
fi

# ─── Container ─────────────────────────────────────────────────
echo "--- Container ---"
CONTAINER_RUNNING=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER ps -q -f name='$CONTAINER'" 2>/dev/null)
if [ -n "$CONTAINER_RUNNING" ]; then
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
XRAY_PID=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER pidof xray 2>/dev/null" 2>/dev/null || echo "")
if [ -n "$XRAY_PID" ]; then
    pass "xray running (PID: $XRAY_PID)"

    LISTENING=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER netstat -tlnp 2>/dev/null | grep -c ':$XRAY_PORT '" 2>/dev/null || echo "0")
    if [ "$LISTENING" -gt 0 ]; then
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
CONFIG_EXISTS=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER test -f /etc/xray/config.json && echo ok" 2>/dev/null)
if [ "$CONFIG_EXISTS" = "ok" ]; then
    pass "Config exists"

    # Check critical fields exist in deployed config
    FOLLOW=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER grep -c 'followRedirect' /etc/xray/config.json 2>/dev/null" || echo "0")
    SNIFF=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER grep -c 'sniffing' /etc/xray/config.json 2>/dev/null" || echo "0")
    DOMAIN_STRAT=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "$DOCKER exec $CONTAINER grep -c 'domainStrategy' /etc/xray/config.json 2>/dev/null" || echo "0")

    [ "$FOLLOW" -gt 0 ] && pass "followRedirect: configured" || { fail "followRedirect missing"; ALL_PASS=false; }
    [ "$SNIFF" -gt 0 ] && pass "sniffing: configured" || { fail "sniffing missing"; ALL_PASS=false; }
    [ "$DOMAIN_STRAT" -gt 0 ] && pass "domainStrategy: configured" || { warn "domainStrategy missing (routing may not work for IPs)"; }
else
    fail "Config missing"
    ALL_PASS=false
fi

# ─── iptables ──────────────────────────────────────────────────
echo "--- iptables ---"
XRAY_CHAIN=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "iptables -t nat -L XRAY -n 2>/dev/null" 2>/dev/null || echo "")
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
QUIC_BLOCK=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "iptables -L FORWARD -n 2>/dev/null | grep -c 'udp dpt:443 DROP'" 2>/dev/null || echo "0")
if [ "$QUIC_BLOCK" -gt 0 ]; then
    pass "QUIC blocked"
else
    warn "QUIC not blocked"
fi

# ─── Proxy 連接（最關鍵）────────────────────────────────────────
echo "--- Proxy 連接（最關鍵）---"
PROXY_CONN=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v '192.168'" 2>/dev/null || echo "")
if [ -n "$PROXY_CONN" ]; then
    pass "Proxy connections active:"
    echo "$PROXY_CONN" | while read line; do
        echo "    $line"
    done
else
    fail "No proxy connections (xray not connected to server)"
    warn "Run: ssh root@$ROUTER_IP '$DOCKER exec $CONTAINER cat /tmp/xray.log'"
    ALL_PASS=false
fi

# ─── 重啟持久化 ────────────────────────────────────────────────
echo "--- Persistence ---"
RC_LOCAL_CHECK=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "grep -c 'xray run' /etc/rc.local 2>/dev/null || echo 0")
if [ "$RC_LOCAL_CHECK" -gt 0 ]; then
    pass "rc.local configured"
else
    warn "rc.local may not have xray auto-start"
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
echo "  ssh root@$ROUTER_IP '$DOCKER exec $CONTAINER cat /tmp/xray.log'"
echo "  ssh root@$ROUTER_IP 'netstat -tnp | grep xray | grep ESTABLISHED | grep -v 192.168'"
