# Xiaomi 路由器透明代理 (xray-core)

**Version: 2.0.0** | 2025-05-19

在小米 AX9000/AX3600/AX3200/AX1800 路由器（OpenWrt 底層 MiWiFi 系統）上，用 Docker 執行 xray-core 實現透明代理。所有 WiFi 裝置**無需任何設定**，自動透過代理存取 AI 服務。

## 功能

- **零設定** — WiFi 連上即可，唔洗 App 或代理設定
- **AI 服務路由** — ChatGPT、Claude、Gemini、DeepSeek、Perplexity、X AI、Grok 等
- **SNI 偵測分流** — xray 從 TLS handshake 拎 domain，自動判斷行代理定直連
- **QUIC 阻斷** — 阻擋 UDP 443，強制手機 App 行 TCP
- **重啟持久化** — `/etc/rc.local` 開機自動啟動

## 架構

```
WiFi 設備 (31網段)
    ↓ TCP 80/443
Router iptables PREROUTING → XRAY chain → REDIRECT :12346
    ↓
xray dokodemo-door (sniffing enabled)
    ↓ SNI 域名匹配
    ├─ AI domains → VLESS+WS+TLS proxy (jp.xlin.eu.cc:443)
    └─ 其他 → direct
```

## 前置需求

- Xiaomi AX3600/AX1800/AX3200/AX9000（已開啟 SSH）
- Docker (MiWiFi Docker 插件)
- VLESS+WS+TLS 代理節點

## 一鍵部署

```bash
# 把專案拷到 router
scp -r ./config root@192.168.1.59:/tmp/xiaomi-tproxy/

# SSH 到 router（Mac + ASUS WiFi 用 192.168.1.59）
ssh root@192.168.1.59

# 執行部署
cd /tmp/xiaomi-tproxy
sh scripts/setup.sh
# 貼上 vless://... URL
```

## 手動部署（無 setup.sh）

```bash
# 1. 建立容器（ARM64）
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER pull sulinggg/openwrt:rpi4
$DOCKER create --name openwrt --network host --privileged --restart always sulinggg/openwrt:rpi4
$DOCKER start openwrt

# 2. 安裝 xray（如果容器內冇）
$DOCKER exec openwrt opkg update
$DOCKER exec openwrt opkg install xray-core

# 3. 寫 config（本機編輯後 docker cp）
#    編輯 config/xray-config.json，填入 YOUR_SERVER_DOMAIN_OR_IP 和 YOUR_UUID
$DOCKER cp config/xray-config.json openwrt:/etc/xray/config.json

# 4. 啟動 xray
$DOCKER exec -d openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/xray.log 2>&1"
sleep 3

# 5. iptables
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP

# 6. 持久化
cp config/rc.local /etc/rc.local && chmod +x /etc/rc.local
```

## xray config 關鍵欄位

```json
{
  "inbounds": [{
    "port": 12346,
    "protocol": "dokodemo-door",
    "settings": { "network": "tcp", "followRedirect": true },  // ← 透明代理必備
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }  // ← SNI 嗅探
  }]
}
```

- `followRedirect: true` — 接受 iptables REDIRECT 過嚟嘅流量
- `sniffing: enabled` — 從 TLS handshake 拎原始域名
- `domainStrategy` — 建議唔好加，預設行為最穩定

## 驗證

```bash
# Router 上睇 proxy 連接（關鍵！）
netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v 192.168

# 必須見到 jp.xlin.eu.cc (或佢 IP) :443 ESTABLISHED

# 睇 xray log
DOCKER exec openwrt cat /tmp/xray.log

# iptables counter
iptables -t nat -L XRAY -n -v

# 自動健康檢查
sh scripts/verify.sh
```

**從 WiFi 設備測試：**
```bash
curl https://ip.sb          # 顯示 proxy IP
curl https://chatgpt.com    # 成功 load
```

## 踩坑清單（部署前必讀）

| 坑 | 解決 |
|----|------|
| Cloudflare CDN DNS 搞唔掂 | hardcode server IP，`nslookup jp.xlin.eu.cc 8.8.8.8` |
| `openwrt/rootfs:latest` 行唔到 | 用 `sulinggg/openwrt:rpi4` |
| ash shell heredoc 變量替換 | 用 `docker cp` 唔用 heredoc |
| rc.local `&` background 甩 | 用 `setsid` |
| Mac SSH 跨網段 timeout | `ssh root@192.168.1.59`，唔係 `192.168.31.1` |
| proxy 連接係 TIME_WAIT | xray 未成功連上 server，檢查 IP/UUID/path |

## 路由規則

```
AI domains (keyword + domain) → proxy
all other TCP → direct
```

| 格式 | 例子 | 匹配 |
|------|------|------|
| `keyword:chatgpt` | `keyword:chatgpt` | 子字串匹配 |
| `domain:chatgpt.com` | `domain:chatgpt.com` | 域名尾綴 + 子域名 |
| `network: tcp` | `network: tcp` | 所有 TCP 行 direct |

## License

MIT
