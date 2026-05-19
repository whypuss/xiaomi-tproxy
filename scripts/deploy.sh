#!/bin/sh
#
# deploy.sh - 從本機部署 config 到 router
# Version: 2.0.0 (2025-05-19)
#
# 用法:
#   ./deploy.sh [router_ip] [ssh_password]
#
# 注意: Mac + ASUS WiFi → AX9000 跨網段時用 192.168.1.59
#       同一網段時用 192.168.31.1

set -e

ROUTER_IP="${1:-192.168.31.1}"
SSH_PASS="${2:-}"

echo "Deploying to router at $ROUTER_IP..."

if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not found. Install: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi

if [ -z "$SSH_PASS" ]; then
    printf "Router SSH password: "
    read -s SSH_PASS
    echo ""
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=10"

# 測試連接
echo "Testing connection..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "echo ok" >/dev/null 2>&1 || {
    echo "SSH failed to $ROUTER_IP"
    exit 1
}

# 部署 - 用 base64 避免 ash heredoc 變量替換
echo "Copying config via SSH (not scp - router lacks sftp-server)..."
CONFIG_B64=$(cat config/xray-config.json | base64)
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    echo "'"$CONFIG_B64"'" | base64 -d > /tmp/xray-config.json
    $DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json
'

echo "Restarting xray..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    \$DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json
    \$DOCKER exec openwrt killall xray 2>/dev/null || true
    sleep 1
    setsid \$DOCKER exec -d openwrt sh -c 'xray run -c /etc/xray/config.json > /tmp/xray.log 2>&1'
    sleep 3
    \$DOCKER exec openwrt cat /tmp/xray.log | tail -5
    netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v 192.168
" 2>/dev/null

echo "Done."
