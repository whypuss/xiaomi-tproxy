#!/bin/sh
#
# deploy.sh - 部署 xray config 到 AX9000 並重啟
#
# 用法:
#   ./deploy.sh [router_ip] [ssh_password]
#
# 示例:
#   ./deploy.sh 192.168.1.59 qwerty66
#
# 注意: Mac + ASUS WiFi → AX9000 跨網段時用 192.168.1.59
#       同一網段時用 192.168.31.1

set -e

ROUTER_IP="${1:-192.168.31.1}"
SSH_PASS="${2:-}"
SSH_OPTS="-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=10"
DOCKER="/mnt/docker_disk/mi_docker/docker-binaries/docker"

usage() {
    echo "用法: $0 [router_ip] [ssh_password]"
    echo "示例: $0 192.168.1.59 qwerty66"
    exit 1
}

[ -z "$SSH_PASS" ] && usage

echo "==> 測試連接..."
if ! sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "echo ok" >/dev/null 2>&1; then
    echo "❌ SSH 連接失敗: root@$ROUTER_IP"
    exit 1
fi
echo "✓ 連接正常"

echo "==> 讀取 config..."
CONFIG_B64=$(cat config/xray-config.json | base64)
B64_LEN=${#CONFIG_B64}
echo "   config 大小: ${B64_LEN} bytes"

echo "==> 上傳 config（base64 + SSH）..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    echo "'"$CONFIG_B64"'" | base64 -d > /tmp/xray-config.json
    COPY_LEN=$(wc -c < /tmp/xray-config.json)
    echo "   上傳成功: ${COPY_LEN} bytes"
    $DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json
    echo "   已拷入 container"
'

echo "==> 重啟 xray..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

    $DOCKER exec openwrt killall xray 2>/dev/null; true
    sleep 2

    # docker exec -d 本身已 detached，唔需要 setsid/nohup
    $DOCKER exec -d openwrt xray run -c /etc/xray/config.json >/tmp/xray.log 2>&1

    sleep 8

    echo "==> xray 啟動 log:"
    $DOCKER exec openwrt cat /tmp/xray.log 2>/dev/null | grep -v "^$" | head -6
'

echo ""
echo "==> 驗證 proxy 連接..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" '
    CONN=$(netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v "192.168" | wc -l)
    echo "   外部 ESTABLISHED 連接: ${CONN}"

    PROXY_IP=$(netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v "192.168" | head -1 | awk "{print \$5}" | cut -d: -f1)
    if [ -n "$PROXY_IP" ]; then
        echo "   proxy IP: ${PROXY_IP}"
    fi

    PROXY_LOG=$($DOCKER exec openwrt cat /tmp/xray.log 2>/dev/null | grep "transparent -> proxy" | tail -1)
    if [ -n "$PROXY_LOG" ]; then
        echo "   最近 proxy 路由: ${PROXY_LOG}"
    fi
'

echo ""
echo "✓ 部署完成"
echo "   測試: 喺 AX9000 WiFi 設備打開 chatgpt.com"
