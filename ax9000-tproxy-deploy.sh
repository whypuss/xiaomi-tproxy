#!/bin/bash
#
# ax9000-tproxy-deploy.sh
# 一鍵部署 AX9000 xray 透明代理（唔郁現有 repo）
#
# 用法:
#   chmod +x ax9000-tproxy-deploy.sh
#   ./ax9000-tproxy-deploy.sh
#

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ROUTER_IP=""
ROUTER_SSH_PASS=""
VLESS_URL=""
PROXY_DOMAINS=""

# ─── 工具函數 ────────────────────────────────────────────────────
ask() {
    printf "${CYAN}[►]${NC} %s: " "$1"
    read ANSWER
}

confirm() {
    printf "${YELLOW}[?]%s (y/n)${NC} " "$1"
    read -n 1 REPLY; echo
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && echo "已取消" && exit 0
}

info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[✗]${NC} %s\n" "$1"; exit 1; }

ssh_cmd() {
    sshpass -p "$ROUTER_SSH_PASS" ssh -o StrictHostKeyChecking=no \
        -o HostKeyAlgorithms=+ssh-rsa "root@$ROUTER_IP" "$1" 2>/dev/null
}

# ─── Step 0: 準備 ────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  AX9000 xray 透明代理 一鍵部署"
echo "================================================"
echo ""
echo "呢個腳本會："
echo "  1. 確認路由器 SSH 連接"
echo "  2. Clone xiaomi-tproxy repo"
echo "  3. 生成 config（你的節點 + 代理網站）"
echo "  4. 部署並啟動 xray"
echo ""
confirm "繼續？"

# ─── Step 1: 收集資訊 ────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 1：路由器 SSH"
echo "================================================"
echo ""

ask "路由器 IP（默認 192.168.31.1）"
ROUTER_IP="${ANSWER:-192.168.31.1}"

ask "SSH 密碼"
ROUTER_SSH_PASS="$ANSWER"

echo ""
echo "================================================"
echo "  Step 2：節點設定"
echo "================================================"
echo ""
echo "粘貼你的 VLESS URL（vless://...）"
echo "（可以從你的機場帳戶複製）"
printf "${CYAN}[►]${NC} VLESS URL: "
read VLESS_URL

if [[ ! "$VLESS_URL" =~ ^vless:// ]]; then
    error "VLESS URL 必須以 vless:// 開頭"
fi

echo ""
echo "================================================"
echo "  Step 3：代理網站"
echo "================================================"
echo ""
echo "輸入要行代理的網站域名（逗號分隔）"
echo "示例: chatgpt.com,claude.ai,gemini.google.com"
printf "${CYAN}[►]${NC} 代理網站: "
read PROXY_DOMAINS

if [ -z "$PROXY_DOMAINS" ]; then
    warn "未提供代理網站，將使用默認 AI 網站"
    PROXY_DOMAINS="chatgpt.com,openai.com,claude.ai,anthropic.com,gemini.google.com,deepseek.com,perplexity.ai,x.ai"
fi

info "代理網站: $PROXY_DOMAINS"

# ─── Step 4: 解析 VLESS URL ─────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 4：解析節點"
echo "================================================"
echo ""

UUID=$(echo "$VLESS_URL" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
SERVER=$(echo "$VLESS_URL" | sed 's|.*@||' | cut -d: -f1)
PORT=$(echo "$VLESS_URL" | grep -oP ':\K\d+(?=/)' | head -1 || echo "443")
PATH=$(echo "$VLESS_URL" | grep -oP 'path=\K[^&]+' | head -1 || echo "/")
HOST=$(echo "$VLESS_URL" | grep -oP 'host=\K[^&]+' | head -1 || echo "$SERVER")

if [ -z "$UUID" ] || [ -z "$SERVER" ]; then
    error "無法解析 VLESS URL，請檢查格式"
fi

info "Server: $SERVER:$PORT"
info "UUID: $UUID"
info "Path: $PATH"

# ─── Step 5: 確認部署計劃 ────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 5：部署確認"
echo "================================================"
echo ""
echo "即將執行："
echo "  路由器:     $ROUTER_IP"
echo "  節點:       $SERVER:$PORT"
echo "  UUID:       $UUID"
echo "  代理網站:   $PROXY_DOMAINS"
echo ""
confirm "確認部署？"

# ─── Step 6: SSH 連接測試 ────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 6：SSH 連接測試"
echo "================================================"
echo ""

if ssh_cmd "echo ok" | grep -q "ok"; then
    info "SSH 連接成功"
else
    error "SSH 連接失敗，請檢查 IP 和密碼"
fi

# ─── Step 7: Clone repo ──────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 7：Clone Repo"
echo "================================================"
echo ""

EXISTING=$(ssh_cmd "ls /tmp/xiaomi-tproxy 2>/dev/null && echo exists")
if [ "$EXISTING" = "exists" ]; then
    info "Repo 已存在，跳過 clone"
else
    info "Clone xiaomi-tproxy repo..."
    ssh_cmd "cd /tmp && rm -rf xiaomi-tproxy && git clone https://github.com/whypuss/xiaomi-tproxy.git"
    info "Clone 完成"
fi

# ─── Step 8: 生成 config ─────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 8：生成 Config"
echo "================================================"
echo ""

# 構建 domains JSON 陣列
DOMAIN_JSON=""
IFS=',' read -ra DOMAINS <<< "$PROXY_DOMAINS"
for d in "${DOMAINS[@]}"; do
    d=$(echo "$d" | xargs)  # trim whitespace
    DOMAIN_JSON="$DOMAIN_JSON\"domain:$d\", "
done
DOMAIN_JSON="${DOMAIN_JSON%, }"

CONFIG_JSON="{
  \"log\": { \"loglevel\": \"warning\" },
  \"inbounds\": [
    {
      \"port\": 12346,
      \"listen\": \"0.0.0.0\",
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
          \"address\": \"$SERVER\",
          \"port\": $PORT,
          \"users\": [{ \"id\": \"$UUID\", \"encryption\": \"none\" }]
        }]
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"tls\",
        \"wsSettings\": {
          \"path\": \"$PATH\",
          \"headers\": { \"Host\": \"$HOST\" }
        },
        \"tlsSettings\": {
          \"serverName\": \"$HOST\",
          \"allowInsecure\": false
        }
      },
      \"tag\": \"proxy\"
    },
    { \"protocol\": \"freedom\", \"tag\": \"direct\" },
    { \"protocol\": \"block\", \"tag\": \"block\" }
  ],
  \"routing\": {
    \"domainStrategy\": \"Always\",
    \"rules\": [
      {
        \"type\": \"field\",
        \"outboundTag\": \"proxy\",
        \"domains\": [$DOMAIN_JSON]
      },
      { \"type\": \"field\", \"network\": \"tcp\", \"outboundTag\": \"direct\" }
    ]
  }
}"

info "Config 已生成"

# 寫入並上傳
B64=$(echo "$CONFIG_JSON" | base64)
ssh_cmd "echo '$B64' | base64 -d > /tmp/xray-config.json"

DOCKER=$(ssh_cmd "echo \$DOCKER | head -1")
if [ -z "$DOCKER" ]; then
    DOCKER="/mnt/docker_disk/mi_docker/docker-binaries/docker"
fi

ssh_cmd "$DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json"
info "Config 已拷入 container"

# ─── Step 9: 部署 xray ───────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 9：啟動 xray"
echo "================================================"
echo ""

ssh_cmd "$DOCKER exec openwrt killall xray 2>/dev/null; sleep 1; $DOCKER exec -d openwrt xray run -c /etc/xray/config.json >/tmp/xray.log 2>&1"
sleep 8

XRAY_PID=$(ssh_cmd "$DOCKER exec openwrt pidof xray 2>/dev/null" || echo "")
if [ -n "$XRAY_PID" ]; then
    info "xray 已啟動 (PID: $XRAY_PID)"
else
    warn "xray 可能未啟動，檢查 log: $DOCKER exec openwrt cat /tmp/xray.log"
fi

# ─── Step 10: 驗證 ───────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Step 10：驗證"
echo "================================================"
echo ""

sleep 3

PROXY_CONN=$(ssh_cmd "netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v '192.168'" || echo "")
if [ -n "$PROXY_CONN" ]; then
    info "代理連接成功！"
    echo "$PROXY_CONN" | while read line; do
        echo "    $line"
    done
else
    warn "尚無 ESTABLISHED 連接（可能需要等幾秒或有流量觸發）"
    echo "喺 WiFi 設備訪問 chatgpt.com 測試"
fi

# ─── 完成 ────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  部署完成！"
echo "================================================"
echo ""
echo "測試：喺 AX9000 WiFi 設備訪問 chatgpt.com"
echo ""
echo "管理指令："
echo "  禁用代理: ssh root@$ROUTER_IP 'iptables -t nat -F XRAY'"
echo "  查看狀態: ssh root@$ROUTER_IP '$DOCKER exec openwrt netstat -tnp | grep xray'"
echo "  查看日誌: ssh root@$ROUTER_IP '$DOCKER exec openwrt cat /tmp/xray.log'"
echo ""
