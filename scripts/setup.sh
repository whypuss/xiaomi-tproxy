#!/bin/sh
#
# setup.sh - xray transparent proxy 一鍵部署
# Version: 2.0.0 (2025-05-19)
#
# 用法:
#   scp -r ./config root@192.168.1.59:/tmp/xiaomi-tproxy/
#   ssh root@192.168.1.59
#   cd /tmp/xiaomi-tproxy && sh scripts/setup.sh
#
# 踩坑紀錄:
#   - ash shell heredoc 會做 $VAR 替換 → 用 docker cp 代替
#   - rc.local 用 & background 會甩 → 用 setsid
#   - 錯誤 image openwrt/rootfs → sulinggg/openwrt:rpi4

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[✗]${NC} %s\n" "$1"; exit 1; }

DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
CONTAINER=openwrt
IMAGE=sulinggg/openwrt:rpi4
CONFIG_PATH=/etc/xray/config.json
RC_LOCAL=/etc/rc.local

echo "================================================"
echo "  xray TProxy 部署腳本 v2.0.0"
echo "================================================"
echo ""

# ─── Step 1: Docker ─────────────────────────────────────────────

echo "[1/7] Docker..."
if [ ! -f "$DOCKER" ]; then
    DOCKER=$(which docker 2>/dev/null || echo "")
    [ -z "$DOCKER" ] && error "Docker not found at $DOCKER"
fi
info "Docker: $DOCKER"

# ─── Step 2: Container ──────────────────────────────────────────

echo "[2/7] Container..."
if ! $DOCKER ps -q -f name="$CONTAINER" 2>/dev/null | grep -q .; then
    warn "Container '$CONTAINER' not found, creating..."

    # Pull correct image for ARM64
    info "Pulling $IMAGE..."
    $DOCKER pull "$IMAGE"

    $DOCKER create \
        --name "$CONTAINER" \
        --network host \
        --privileged \
        --restart always \
        "$IMAGE"

    $DOCKER start "$CONTAINER"
    info "Container created and started"
else
    info "Container '$CONTAINER' is running"
fi

PRIV=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
[ "$PRIV" != "true" ] && warn "Container not privileged — may not work"

# ─── Step 3: xray ──────────────────────────────────────────────

echo "[3/7] xray-core..."
if ! $DOCKER exec "$CONTAINER" which xray >/dev/null 2>&1; then
    warn "Installing xray-core via opkg..."
    $DOCKER exec "$CONTAINER" opkg update
    $DOCKER exec "$CONTAINER" opkg install xray-core
fi
XRAY_VER=$($DOCKER exec "$CONTAINER" xray version 2>/dev/null | head -1 || echo "unknown")
info "xray: $XRAY_VER"

# ─── Step 4: VLESS URL ─────────────────────────────────────────

echo "[4/7] VLESS 配置..."

# 嘗試讀取已有 config
if $DOCKER exec "$CONTAINER" test -f "$CONFIG_PATH" 2>/dev/null; then
    EXISTING=$($DOCKER exec "$CONTAINER" cat "$CONFIG_PATH" 2>/dev/null)
    EXISTING_UUID=$(echo "$EXISTING" | grep -oP '"id":\s*"\K[^"]+' | head -1)
    EXISTING_ADDR=$(echo "$EXISTING" | grep -oP '"address":\s*"\K[^"]+' | head -1)

    if [ -n "$EXISTING_UUID" ] && [ -n "$EXISTING_ADDR" ]; then
        info "Using existing config: $EXISTING_ADDR / $EXISTING_UUID"
        USE_EXISTING=y
    fi
fi

if [ "$USE_EXISTING" != "y" ]; then
    echo ""
    warn "No valid config found."
    echo "Paste your VLESS URL (vless://...):"
    printf "> "
    read VLESS_URL

    # Parse
    XRAY_UUID=$(echo "$VLESS_URL" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    XRAY_ADDR=$(echo "$VLESS_URL" | sed 's|.*@||' | cut -d: -f1)
    XRAY_PORT=$(echo "$VLESS_URL" | grep -oP ':\K\d+(?=/)' | head -1 || echo "443")
    XRAY_PATH=$(echo "$VLESS_URL" | grep -oP 'path=\K[^&]+' | head -1 || echo "/")
    XRAY_HOST=$(echo "$VLESS_URL" | grep -oP 'host=\K[^&]+' | head -1 || echo "$XRAY_ADDR")

    [ -z "$XRAY_UUID" ] || [ -z "$XRAY_ADDR" ] && error "Failed to parse VLESS URL"

    info "Server: $XRAY_ADDR:$XRAY_PORT"
    info "UUID:   $XRAY_UUID"
    info "Path:   $XRAY_PATH"
fi

# ─── Step 5: 寫 config（用 docker cp，唔用 heredoc）───────────────

echo "[5/7] 寫入 config..."

# 在本機寫 temp config
cat > /tmp/xray_config.json << CONFIGEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 12346,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
      "tag": "transparent"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${XRAY_ADDR:-${EXISTING_ADDR}}",
          "port": ${XRAY_PORT:-443},
          "users": [{ "id": "${XRAY_UUID:-${EXISTING_UUID}}", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "path": "${XRAY_PATH:-/}",
          "headers": { "Host": "${XRAY_HOST:-${XRAY_ADDR:-${EXISTING_ADDR}}}" }
        },
        "tlsSettings": {
          "serverName": "${XRAY_HOST:-${XRAY_ADDR:-${EXISTING_ADDR}}}",
          "allowInsecure": false
        }
      },
      "tag": "proxy"
    },
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "block", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "Always",
    "rules": [
      {
        "type": "field",
        "outboundTag": "proxy",
        "domains": [
          "keyword:chatgpt", "keyword:claude", "keyword:anthropic",
          "keyword:openai", "keyword:google-ai", "keyword:gemini",
          "domain:chatgpt.com", "domain:openai.com",
          "domain:api.openai.com", "domain:claude.ai",
          "domain:platform.claude.ai", "domain:anthropic.com",
          "domain:api.anthropic.com", "domain:aistudio.google.com",
          "domain:ai.google.dev", "domain:googleapis.com",
          "domain:gemini.google.com", "domain:bard.google.com",
          "domain:copilot.microsoft.com", "domain:deepseek.com",
          "domain:perplexity.ai", "domain:x.ai", "domain:x.com",
          "domain:notebooklm.google.com", "domain:ip.sb", "domain:ipinfo.io"
        ]
      },
      { "type": "field", "network": "tcp", "outboundTag": "direct" }
    ]
  }
}
CONFIGEOF

# 用 docker cp 拷入容器（避免 ash shell heredoc 變量替換問題）
$DOCKER cp /tmp/xray_config.json "$CONTAINER:$CONFIG_PATH"
rm /tmp/xray_config.json
info "Config written to $CONFIG_PATH"

# ─── Step 6: 啟動 xray ─────────────────────────────────────────

echo "[6/7] 啟動 xray..."

$DOCKER exec "$CONTAINER" killall xray 2>/dev/null || true
sleep 1

# 用 setsid 確保 daemonize
$DOCKER exec -d "$CONTAINER" sh -c "xray run -c $CONFIG_PATH > /tmp/xray.log 2>&1"
sleep 4

XRAY_PID=$($DOCKER exec "$CONTAINER" pidof xray 2>/dev/null || echo "")
if [ -z "$XRAY_PID" ]; then
    error "xray failed to start. Check: $DOCKER exec $CONTAINER cat /tmp/xray.log"
fi
info "xray running (PID: $XRAY_PID)"

# ─── Step 7: iptables + 持久化 ─────────────────────────────────

echo "[7/7] iptables 規則..."

# IPv4
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
info "IPv4 rules applied"

# IPv6 (best-effort)
ip6tables -t nat -N XRAY6 2>/dev/null || true
ip6tables -t nat -F XRAY6 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fe80::/10 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fd00::/8 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -p tcp -j REDIRECT --to-ports 12346 2>/dev/null || true
ip6tables -t nat -A PREROUTING -p tcp -j XRAY6 2>/dev/null || true
ip6tables -I FORWARD -p udp --dport 443 -j DROP 2>/dev/null || true
info "IPv6 rules applied (best-effort)"

# rc.local 持久化
cat > "$RC_LOCAL" << 'RCEOF'
#!/bin/sh
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json >/tmp/xray.log 2>&1 &
sleep 3
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
ip6tables -t nat -N XRAY6 2>/dev/null || true
ip6tables -t nat -F XRAY6 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fe80::/10 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fd00::/8 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -p tcp -j REDIRECT --to-ports 12346 2>/dev/null || true
ip6tables -t nat -A PREROUTING -p tcp -j XRAY6 2>/dev/null || true
ip6tables -I FORWARD -p udp --dport 443 -j DROP 2>/dev/null || true
exit 0
RCEOF
chmod +x "$RC_LOCAL"
info "Reboot persistence written to $RC_LOCAL"

# ─── 驗證 ─────────────────────────────────────────────────────

echo ""
echo "================================================"
echo "  驗證"
echo "================================================"

echo ""
echo "--- xray log ---"
$DOCKER exec "$CONTAINER" cat /tmp/xray.log 2>/dev/null | tail -5

echo ""
echo "--- Proxy 連接 (必須有 ESTABLISHED 到 server) ---"
netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v "192.168" | head -5 || echo "(none yet)"

echo ""
echo "--- iptables counter ---"
iptables -t nat -L XRAY -n -v | head -6

echo ""
echo "================================================"
echo "  部署完成！"
echo "================================================"
echo ""
echo "在 AX9000 WiFi 設備打開瀏覽器訪問 chatgpt.com 測試。"
echo ""
echo "Debug:"
echo "  $DOCKER exec $CONTAINER cat /tmp/xray.log     # xray 日誌"
echo "  iptables -t nat -L XRAY -n -v                # 流量計數"
echo "  netstat -tnp | grep xray | grep ESTABLISHED  # proxy 連接"
