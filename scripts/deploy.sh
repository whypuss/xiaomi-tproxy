#!/bin/sh
#
# deploy.sh - Deploy xiaomi-tproxy config to router from local machine
#
# Usage:
#   ./deploy.sh [router_ip] [ssh_password]
#
# Defaults:
#   router_ip: 192.168.31.1
#   ssh_password: (prompts if not provided)

set -e

ROUTER_IP="${1:-192.168.31.1}"
SSH_PASS="${2:-}"

echo "Deploying to router at $ROUTER_IP..."

# Check for sshpass
if [ ! -x "$(command -v sshpass)" ]; then
    echo "sshpass not found. Install it: brew install sshpass (macOS) / apt install sshpass (Linux)"
    exit 1
fi

# Get password if not provided
if [ -z "$SSH_PASS" ]; then
    printf "Router SSH password: "
    read -s SSH_PASS
    echo ""
fi

SSH_OPTS="-o StrictHostKeyChecking=no -oHostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=10"

# Deploy config
echo "Deploying xray config..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    mkdir -p /tmp/tproxy-deploy
' 2>/dev/null

sshpass -p "$SSH_PASS" scp $SSH_OPTS config/xray-config.json "root@$ROUTER_IP:/tmp/tproxy-deploy/" 2>/dev/null

sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@$ROUTER_IP" "
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    \$DOCKER cp /tmp/tproxy-deploy/xray-config.json openwrt:/etc/xray/config.json
    \$DOCKER exec openwrt killall xray 2>/dev/null || true
    sleep 1
    \$DOCKER exec -d openwrt xray run -c /etc/xray/config.json 2>/dev/null
    echo 'xray restarted'
" 2>/dev/null

echo "Deploy complete!"
