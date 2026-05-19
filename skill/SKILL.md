---
name: xiaomi-tproxy
version: "2.0.0"
description: >
  Set up xray-core transparent proxy on Xiaomi routers (OpenWrt-based MiWiFi firmware).
  Routes AI service traffic through a VLESS+WS+TLS proxy via Docker container.
  No per-device configuration needed — all WiFi clients auto-proxied.
license: MIT
compatibility: opencode
metadata:
  router: Xiaomi AX9000 / AX3600 / AX3200 / AX1800 (MiWiFi OpenWrt-based)
  proxy: xray-core (via openwrt opkg, built-in) / VLESS+WS+TLS
  container: sulinggg/openwrt:rpi4 (ARM64), --network host --privileged
  ports: "12346 transparent proxy, iptables REDIRECT 80/443"
---

## 版本紀錄

- **v2.0.0** (2025-05-19): 全面重寫，基於 AX9000 實戰踩坑經驗
  - Image: `openwrt/rootfs:latest` → `sulinggg/openwrt:rpi4` (ARM64 支援)
  - 移除 ash shell heredoc 部署，改用 `docker cp`
  - rc.local 用 `setsid` 代替 `&` background
  - 新增 Cloudflare CDN DNS 坑點說明
  - 確認 `jp.xlin.eu.cc` 直連可用（HTTP 400 = 正常）
  - 確認 Mac ASUS WiFi 跨網段 SSH 方法

## 已知坑點（部署前必讀）

### 1. Cloudflare CDN DNS 問題 ⚠️ 最關鍵
```
jp.xlin.eu.cc → 172.67.144.125 (Cloudflare CDN)
                可能被 block 或 DNS 污染
```
- 如果 container 內 `wget jp.xlin.eu.cc` 失敗（Connection refused）
- 改用 server IP（`nslookup jp.xlin.eu.cc 8.8.8.8` 查眞實 IP）
- 在 xray config `address` 填 IP，同時 `serverName`/`Host` header 填 domain

### 2. ARM64 Image 選錯
- ❌ `openwrt/rootfs:latest` — x86_64 only，不支援 ARM64
- ✅ `sulinggg/openwrt:rpi4` — ARM64 相容

### 3. ash shell heredoc 變量替換
- Router ash shell 會替換 `$VAR` 和反引號
- 不要用 heredoc 寫 config，改用 `docker cp`

### 4. rc.local `&` Background 問題
- ❌ `$DOCKER exec openwrt xray run ... &` — SSH session 斷了 xray 也斷
- ✅ `setsid $DOCKER exec -d openwrt xray run ...` — 真正 daemonize

### 5. Mac SSH 跨網段
- Mac 在 ASUS WiFi (192.168.1.x)，AX9000 是 192.168.1.59
- ✅ `ssh root@192.168.1.59`（ASUS → AX9000 WAN）
- ❌ `ssh root@192.168.31.1`（Mac ping 唔到）

### 6. proxy server 連接驗證
- `curl -s --connect-timeout 5 -k -o /dev/null -w "HTTP:%{http_code}" https://jp.xlin.eu.cc`
- HTTP 400/301/302 = server 正常
- HTTP 000 = 完全連唔到，檢查 firewall 或換 IP

## 快速部署（已有一鍵腳本）

```bash
# 在 router SSH 執行
scp -r ./config root@192.168.1.59:/tmp/xiaomi-tproxy/
ssh root@192.168.1.59
  cd /tmp/xiaomi-tproxy
  sh scripts/setup.sh
  # 貼上 VLESS URL
```

## 核心部署步驟（無 setup.sh 時）

### Step 1: 建立容器（只用一次）
```bash
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

# 拉取正確 image（ARM64）
$DOCKER pull sulinggg/openwrt:rpi4

# 建立容器
$DOCKER create \
  --name openwrt \
  --network host \
  --privileged \
  --restart always \
  sulinggg/openwrt:rpi4

$DOCKER start openwrt
```

### Step 2: 寫 xray config（用 docker cp）
```bash
# 在本機編輯 config，確定：
#   address = jp.xlin.eu.cc 或 實際 IP
#   serverName = jp.xlin.eu.cc
#   Host header = jp.xlin.eu.cc

DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER cp config/xray-config.json openwrt:/etc/xray/config.json
```

### Step 3: 啟動 xray
```bash
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

# 確認 xray 在 container 內存在
$DOCKER exec openwrt which xray
# 如果不存在，安裝：
$DOCKER exec openwrt opkg update
$DOCKER exec openwrt opkg install xray-core

# 啟動（log 重定向到文件）
$DOCKER exec -d openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/xray.log 2>&1"
sleep 3

# 驗證
$DOCKER exec openwrt netstat -tlnp | grep 12346
$DOCKER exec openwrt cat /tmp/xray.log
```

### Step 4: 確認 proxy 連接成功
```bash
# 關鍵：xray 必須有到 proxy server 的 ESTABLISHED 連接
netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v "192.168"

# 應該看到 jp.xlin.eu.cc (或其 IP) :443 ESTABLISHED
# 如果係 TIME_WAIT 或完全冇，xray 未連上 server
```

### Step 5: iptables 規則
```bash
# 創建 XRAY chain
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY

# QUIC 阻斷（強制 mobile app 行 TCP）
iptables -I FORWARD -p udp --dport 443 -j DROP
```

### Step 6: rc.local 持久化
```bash
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
setsid $DOCKER exec -d openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/xray.log 2>&1"
sleep 3
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
exit 0
RCEOF
chmod +x /etc/rc.local
```

## 驗證方法

```bash
# 從 WiFi 設備測試（必須係 31 網段）
curl https://ip.sb          # 顯示 proxy IP
curl https://chatgpt.com    # 成功 load

# Router 上睇 log
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER exec openwrt cat /tmp/xray.log | grep -E "proxy|direct|Error"

# 睇有幾多 packets 行咗 proxy
iptables -t nat -L XRAY -n -v
```

## xray config 關鍵欄位說明

```json
{
  "inbounds": [{
    "port": 12346,
    "protocol": "dokodemo-door",
    "settings": { "network": "tcp", "followRedirect": true },  // ← 透明代理必備
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }  // ← SNI 嗅探
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "jp.xlin.eu.cc", "port": 443,
        "users": [{ "id": "UUID", "encryption": "none" }] }] },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "wsSettings": { "path": "/", "headers": { "Host": "jp.xlin.eu.cc" } },  // ← Host header 必填
      "tlsSettings": { "serverName": "jp.xlin.eu.cc", "allowInsecure": false }
    }
  }]
}
```

## 常見問題

| 問題 | 解決 |
|------|------|
| xray log 全是 direct | 檢查 domain routing rules，確認有 matching keyword/domain |
| container 連唔到 proxy server | 試 hardcoded IP；檢查 firewall |
| 透明代理唔 work | 確認 `followRedirect: true` + `sniffing: enabled` |
| router 重啟後失效 | 檢查 rc.local 有正確寫入 + chmod +x |
| WiFi client timeout | 確認 iptables XRAY chain 有 packets (非零 counter) |
