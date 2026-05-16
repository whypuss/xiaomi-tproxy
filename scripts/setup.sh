#!/bin/sh
#
# setup.sh - One-click setup for Xiaomi Router Transparent Proxy
#
# Usage:
#   On the router (SSH): sh setup.sh
#   Remotely: curl -sL https://...setup.sh | ssh root@192.168.31.1 sh
#
# This script:
#   1. Checks prerequisites (Docker, container, xray-core)
#   2. Creates xray config from VLESS URL
#   3. Starts xray
#   4. Applies iptables rules
#   5. Adds rules to rc.local for persistence
#   6. Verifies the setup

set -e

# ─── Configuration ──────────────────────────────────────────────────

ROUTER_LAN="192.168.31.0/24"
XRAY_PORT="12346"
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
CONTAINER="openwrt"
CONFIG_PATH="/etc/xray/config.json"
RC_LOCAL="/etc/rc.local"

# ─── Colors for output ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[✗]${NC} %s\n" "$1"; exit 1; }

# ─── Prerequisites Check ────────────────────────────────────────────

echo "================================================"
echo "  Xiaomi Router Transparent Proxy Setup"
echo "================================================"
echo ""

# Check Docker
echo "[1/7] Checking Docker..."
if [ ! -f "$DOCKER" ]; then
    # Try alternate locations
    DOCKER=$(which docker 2>/dev/null || echo "")
    if [ -z "$DOCKER" ]; then
        error "Docker not found! Expected at /mnt/docker_disk/mi_docker/docker-binaries/docker"
    fi
fi
info "Docker found: $DOCKER"

# Check container
echo "[2/7] Checking container..."
CONTAINER_EXISTS=$($DOCKER ps -q -f name="$CONTAINER" 2>/dev/null)
if [ -z "$CONTAINER_EXISTS" ]; then
    error "Container '$CONTAINER' not running. Create it with:
  $DOCKER run -d --name $CONTAINER \\
    --network host \\
    --privileged \\
    --pid host \\
    --ipc host \\
    --restart always \\
    openwrt/rootfs:latest"
fi
info "Container '$CONTAINER' is running"

# Check container has privileged mode
PRIVILEGED=$($DOCKER inspect "$CONTAINER" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
if [ "$PRIVILEGED" != "true" ]; then
    error "Container '$CONTAINER' is not privileged. Recreate with --privileged"
fi
info "Container is privileged"

# Check/install xray-core
echo "[3/7] Checking xray-core..."
XRAY_EXISTS=$($DOCKER exec "$CONTAINER" which xray 2>/dev/null || echo "")
if [ -z "$XRAY_EXISTS" ]; then
    warn "xray-core not found in container. Installing..."
    $DOCKER exec "$CONTAINER" opkg update
    $DOCKER exec "$CONTAINER" opkg install xray-core
    info "xray-core installed"
else
    info "xray-core found: $XRAY_EXISTS"
fi

# ─── xray Configuration ──────────────────────────────────────────────

echo "[4/7] Checking xray configuration..."
XRAY_UUID=""
XRAY_SERVER=""

# Try to extract from existing config
if $DOCKER exec "$CONTAINER" test -f "$CONFIG_PATH" 2>/dev/null; then
    XRAY_UUID=$($DOCKER exec "$CONTAINER" grep -o '"id": *"[^"]*"' "$CONFIG_PATH" 2>/dev/null | head -1 | cut -d'"' -f4)
    XRAY_SERVER=$($DOCKER exec "$CONTAINER" grep -o '"address": *"[^"]*"' "$CONFIG_PATH" 2>/dev/null | head -1 | cut -d'"' -f4)
fi

if [ -z "$XRAY_UUID" ] || [ -z "$XRAY_SERVER" ]; then
    # Prompt for VLESS URL
    echo ""
    warn "No valid xray config found."
    echo "Please enter your VLESS subscription URL:"
    printf "VLESS_URL: "
    read VLESS_URL

    # Parse VLESS URL
    XRAY_UUID=$(echo "$VLESS_URL" | grep -oP '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})' | head -1)
    XRAY_SERVER=$(echo "$VLESS_URL" | sed 's|.*@\([^:]*\):.*|\1|')
    XRAY_PORT=$(echo "$VLESS_URL" | grep -oP ':\K\d+(?=/)' | head -1)
    XRAY_PATH=$(echo "$VLESS_URL" | grep -oP 'path=\K[^&]+' | head -1)
    [ -z "$XRAY_PATH" ] && XRAY_PATH="/"
    XRAY_HOST=$(echo "$VLESS_URL" | grep -oP 'host=\K[^&]+' | head -1)
    [ -z "$XRAY_HOST" ] && XRAY_HOST="$XRAY_SERVER"

    if [ -z "$XRAY_UUID" ] || [ -z "$XRAY_SERVER" ]; then
        error "Could not parse VLESS URL. Check format: vless://UUID@SERVER:PORT?path=/&host=SERVER#name"
    fi
    info "Parsed: server=$XRAY_SERVER port=${XRAY_PORT:-443} uuid=$XRAY_UUID path=$XRAY_PATH"
fi

# Write config
echo "[5/7] Writing xray config..."

$DOCKER exec "$CONTAINER" sh -c "cat > $CONFIG_PATH << 'CONF_EOF'
{
  \"log\": { \"loglevel\": \"warning\" },
  \"inbounds\": [
    {
      \"port\": $XRAY_PORT,
      \"protocol\": \"dokodemo-door\",
      \"settings\": { \"network\": \"tcp\", \"followRedirect\": true },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\", \"tls\"] },
      \"tag\": \"transparent\"
    }
  ],
  \"outbounds\": [
    {
      \"protocol\": \"vless\",
      \"settings\": {
        \"vnext\": [{
          \"address\": \"${XRAY_SERVER}\",
          \"port\": ${XRAY_PORT:-443},
          \"users\": [{ \"id\": \"${XRAY_UUID}\", \"encryption\": \"none\" }]
        }]
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"tls\",
        \"wsSettings\": {
          \"path\": \"${XRAY_PATH}\",
          \"headers\": { \"Host\": \"${XRAY_HOST}\" }
        },
        \"tlsSettings\": {
          \"serverName\": \"${XRAY_HOST}\",
          \"allowInsecure\": false
        }
      },
      \"tag\": \"proxy\"
    },
    { \"protocol\": \"freedom\", \"tag\": \"direct\" }
  ],
  \"routing\": {
    \"domainStrategy\": \"IPOnDemand\",
    \"rules\": [
      { \"type\": \"field\", \"domain\": [
        \"keyword:chatgpt\",
        \"keyword:claude\",
        \"keyword:anthropic\",
        \"keyword:openai\",
        \"keyword:google-ai\",
        \"keyword:gemini\",
        \"domain:chatgpt.com\",
        \"domain:openai.com\",
        \"domain:api.openai.com\",
        \"domain:openaicom.imgix.net\",
        \"domain:claude.ai\",
        \"domain:platform.claude.ai\",
        \"domain:code.claude.ai\",
        \"domain:anthropic.com\",
        \"domain:api.anthropic.com\",
        \"domain:aistudio.google.com\",
        \"domain:ai.google.dev\",
        \"domain:makersuite.google.com\",
        \"domain:googleapis.com\",
        \"domain:bard.google.com\",
        \"domain:gemini.google.com\",
        \"domain:copilot.microsoft.com\",
        \"domain:deepseek.com\",
        \"domain:perplexity.ai\",
        \"domain:x.com\",
        \"domain:grok.com\",
        \"domain:notebooklm.google.com\",
        \"domain:ip.sb\",
        \"domain:ipinfo.io\"
      ], \"outboundTag\": \"proxy\" },
      { \"type\": \"field\", \"network\": \"tcp\", \"outboundTag\": \"direct\" }
    ]
  }
}
CONF_EOF"

info "Config written to container:$CONFIG_PATH"

# ─── Start xray ──────────────────────────────────────────────────────

echo "[6/7] Starting xray..."

# Kill existing xray
$DOCKER exec "$CONTAINER" killall xray 2>/dev/null || true
sleep 1

# Start xray in background
$DOCKER exec -d "$CONTAINER" xray run -c "$CONFIG_PATH" 2>/dev/null
sleep 2

# Verify xray is running
XRAY_PID=$($DOCKER exec "$CONTAINER" pidof xray 2>/dev/null || echo "")
if [ -z "$XRAY_PID" ]; then
    error "xray failed to start. Check config: $DOCKER exec $CONTAINER xray run -c $CONFIG_PATH"
fi
info "xray running (PID: $XRAY_PID, port: $XRAY_PORT)"

# ─── iptables Rules ──────────────────────────────────────────────────

echo "[7/7] Applying iptables rules..."

# IPv4
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d "$ROUTER_LAN" -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports $XRAY_PORT
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports $XRAY_PORT
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
info "IPv4 iptables rules applied"

# IPv6 (best-effort)
ip6tables -t nat -N XRAY6 2>/dev/null || true
ip6tables -t nat -F XRAY6 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fe80::/10 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fd00::/8 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -p tcp -j REDIRECT --to-ports $XRAY_PORT 2>/dev/null || true
ip6tables -t nat -A PREROUTING -p tcp -j XRAY6 2>/dev/null || true
ip6tables -I FORWARD -p udp --dport 443 -j DROP 2>/dev/null || true
info "IPv6 iptables rules applied (best-effort)"

# ─── Reboot Persistence ──────────────────────────────────────────────

echo ""
echo "Setting up reboot persistence..."

cat > "$RC_LOCAL" << EOF
# Xiaomi Router Transparent Proxy - auto-start on boot
# Added by setup.sh on $(date)

$DOCKER exec $CONTAINER xray run -c $CONFIG_PATH &

sleep 3

# IPv4 transparent proxy
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d $ROUTER_LAN -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports $XRAY_PORT
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports $XRAY_PORT
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP

# IPv6 transparent proxy (best-effort)
ip6tables -t nat -N XRAY6 2>/dev/null || true
ip6tables -t nat -F XRAY6 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fe80::/10 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -d fd00::/8 -j RETURN 2>/dev/null || true
ip6tables -t nat -A XRAY6 -p tcp -j REDIRECT --to-ports $XRAY_PORT 2>/dev/null || true
ip6tables -t nat -A PREROUTING -p tcp -j XRAY6 2>/dev/null || true
ip6tables -I FORWARD -p udp --dport 443 -j DROP 2>/dev/null || true

exit 0
EOF

info "Reboot persistence added to $RC_LOCAL"

# ─── Verification ────────────────────────────────────────────────────

echo ""
echo "================================================"
echo "  Verification"
echo "================================================"
echo ""

# Check iptables
echo "iptables -t nat -L XRAY -n -v"
iptables -t nat -L XRAY -n -v
echo ""

# Check xray listening
echo "xray listening ports:"
$DOCKER exec "$CONTAINER" netstat -tlnp 2>/dev/null | grep xray || echo "(no xray listening)"
echo ""

# Test proxy
echo "Testing proxy (ip.sb via iptables redirects)..."
echo "Note: This only works from LAN devices, not from the router itself."
echo "From a WiFi device, run: curl https://ip.sb"
echo ""

echo "================================================"
echo "  Setup Complete!"
echo "================================================"
echo ""
echo "xray is running on port $XRAY_PORT in container '$CONTAINER'"
echo "All WiFi devices now get transparent proxy for AI services."
echo ""
echo "Quick test from any WiFi device:"
echo "  curl https://ip.sb          # Should show proxy IP"
echo "  curl https://chatgpt.com    # Should work"
echo ""
echo "To check status:"
echo "  ssh root@192.168.31.1"
echo "  iptables -t nat -L XRAY -n -v"
echo "  $DOCKER exec $CONTAINER netstat -tlnp | grep xray"
echo ""
echo "To view xray logs:"
echo "  $DOCKER exec $CONTAINER sh -c 'xray run -c $CONFIG_PATH > /tmp/x.log 2>&1 &'"
echo "  $DOCKER exec $CONTAINER cat /tmp/x.log"
