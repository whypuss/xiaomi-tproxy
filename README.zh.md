# Xiaomi 路由器透明代理 (xray-core)

在小米 AX3600/AX3200/AX1800/AX9000 路由器（OpenWrt 底層 MiWiFi 系統）上，用 Docker 執行 xray-core 實現透明代理。所有 WiFi 裝置**無需任何設定**，即可自動使用代理存取 AI 服務（ChatGPT、Claude、Gemini 等），其他網站直接連線。

## 功能特色

- **用戶端零設定** — WiFi 連上即可，不用裝任何 App 或改代理設定
- **AI 服務路由** — ChatGPT、Claude、Gemini、DeepSeek、Perplexity、Copilot、Grok 等
- **SNI 偵測分流** — xray 偵測 TLS 連線的 SNI 域名，自動判斷是否走代理
- **QUIC 阻斷** — 阻擋 UDP 443，強制手機 App 降級為 TCP，確保進代理
- **重啟持久化** — `/etc/rc.local` 開機自動啟動 xray + 套用 iptables
- **IPv6 支援** — 完整 ip6tables 規則
- **Docker 隔離** — xray 跑在容器內，不影響路由器韌體

## 架構

```
┌──────────────────────────────────────────────────────────────────────┐
│  Xiaomi 路由器 (OpenWrt 底層)                                        │
│                                                                      │
│  ┌─────────┐    iptables PREROUTING    ┌───────────────────────┐    │
│  │  WiFi   │─── TCP 80/443 ────────▶  │  Docker Container     │    │
│  │  裝置   │                          │  ┌─────────────────┐  │    │
│  │ (LAN)   │◀── 回應 ────────────────│  │  xray-core       │  │    │
│  └─────────┘                          │  │  :12346          │  │    │
│                                        │  └─────────────────┘  │    │
│                                        └───────────────────────┘    │
│                                              │                      │
│                                              ▼                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  xray 路由                                                     │   │
│  │                                                                │   │
│  │  SNI 偵測 → Domain/IP 匹配                                     │   │
│  │    ├─ AI 域名 → VLESS+WS+TLS 代理 (YOUR_SERVER:443)           │   │
│  │    └─ 其他 → 直連 (freedom outbound)                          │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## 前置需求

- **路由器**: Xiaomi AX3600 / AX1800 / AX3200 / AX9000（已開啟 SSH）
- **Docker**: 路由器上已安裝 MiWiFi Docker 插件
- **Docker 容器**: 已建立 OpenWrt 容器（需 `--network host --privileged`）
- **代理節點**: 一個 VLESS+WS+TLS 協定的代理訂閱連結

> 如果還沒開啟 SSH，請參考小米路由器開啟 SSH 的官方方法（綁定 MiWiFi 帳號後可取得 root 密碼）。

## 完整安裝步驟

### 步驟 1：建立 Docker 容器

```bash
# 登入路由器
ssh root@192.168.31.1

# 檢查 Docker 是否存在
# MiWiFi 的 Docker 在非標準路徑
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

# 確認 Docker 能執行
$DOCKER info

# 拉取 OpenWrt 映像並建立容器（只需執行一次）
$DOCKER run -d \
  --name openwrt \
  --network host \
  --privileged \
  --pid host \
  --ipc host \
  --restart always \
  openwrt/rootfs:latest
```

**為什麼需要這些參數？**

| 參數 | 原因 |
|------|------|
| `--network host` | 容器共用宿主網路，xray 才能直接收 LAN 流量 |
| `--privileged` | 賦予 NET_ADMIN 能力，容器內才能操作 iptables（雖然我們在宿主機操作） |
| `--pid host` | 共用 process namespace，方便除錯 |
| `--ipc host` | 共用 IPC namespace |
| `--restart always` | 路由器重啟後自動啟動容器 |

### 步驟 2：容器內安裝 xray-core

```bash
# 進入容器
$DOCKER exec -it openwrt sh

# 更新套件源（如果預設源失效，需手動設定）
cat > /etc/opkg/customfeeds.conf << "EOF"
src/gz openwrt_base https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/base
src/gz openwrt_packages https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/packages
src/gz openwrt_luci https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/luci
EOF

opkg update
opkg install xray-core

# 確認安裝成功
xray version
# 應該顯示: Xray 1.8.6 or later

# 離開容器
exit
```

> **注意**: `aarch64_cortex-a53` 是 AX3600 的架構。如果你的路由器是不同 CPU（如 AX9000），請先 `uname -m` 確認。
>
> 如果 opkg feeds 失效，可改用直接下載 binary：
> ```bash
> wget -O /tmp/xray-linux-arm64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64.zip
> unzip -d /usr/bin /tmp/xray-linux-arm64.zip xray
> chmod +x /usr/bin/xray
> ```

### 步驟 3：設定 xray 設定檔

編輯 `config/xray-config.json`，填入你的 VLESS 節點資訊：

```json
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "你的伺服器位址",    // ← 修改這裡
          "port": 443,                    // ← 修改這裡（通常是 443）
          "users": [{
            "id": "你的UUID",            // ← 修改這裡
            "encryption": "none"
          }]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "path": "/",                    // ← 修改這裡（通常是 /）
          "headers": {
            "Host": "你的伺服器位址"      // ← 修改這裡（通常是伺服器位址）
          }
        },
        "tlsSettings": {
          "serverName": "你的伺服器位址", // ← 修改這裡
          "allowInsecure": false
        }
      },
      "tag": "proxy"
    }
  ]
}
```

也可以使用 setup.sh 一鍵安裝，它會自動解析 VLESS URL：

```bash
# 把 config/xray-config.json 複製到路由器後執行 setup.sh
# 或直接在路由器上執行：
sh scripts/setup.sh
# 然後貼上你的 vless://... URL
```

### 步驟 4：部署設定檔到容器

```bash
# 複製設定檔到容器
$DOCKER cp config/xray-config.json openwrt:/etc/xray/config.json

# 確認檔案存在
$DOCKER exec openwrt ls -la /etc/xray/config.json
```

### 步驟 5：啟動 xray

```bash
# 第一次啟動
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json

# 確認有在監聽
sleep 2
$DOCKER exec openwrt netstat -tlnp | grep xray
# 應該顯示: LISTEN  :::12346

# 如果沒看到，檢查錯誤
$DOCKER exec openwrt sh -c "xray run -c /etc/xray/config.json"
# 看輸出訊息判斷問題
```

### 步驟 6：測試代理節點是否可用

在容器內啟用 SOCKS5 測試埠（臨時）：

```bash
# 用一個含 SOCKS inbound 的設定來測試
# 或直接從容器內 curl 測試
$DOCKER exec openwrt sh -c "
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' https://www.google.com
"
# 應該回傳 200 或 302

# 測試節點位置
$DOCKER exec openwrt sh -c "
  curl -s --max-time 10 https://ipinfo.io/json | grep -E 'ip|country|city'
"
# 確認顯示的 IP 是你的代理節點 IP，位置在支援 Claude 的區域（US/JP/EU）
```

### 步驟 7：套用 iptables 規則

```bash
# 建立 XRAY 自訂鏈
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null

# 繞過內網流量（路由器自己的 LAN 不走代理）
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN

# 將 HTTP/HTTPS 重新導向到 xray
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346

# 套用到所有進站 TCP 流量
iptables -t nat -A PREROUTING -p tcp -j XRAY

# 阻斷 QUIC（UDP 443），強制手機 App 走 TCP
iptables -I FORWARD -p udp --dport 443 -j DROP

# IPv6（可選，如果 LAN 有 IPv6）
ip6tables -t nat -N XRAY6 2>/dev/null
ip6tables -t nat -F XRAY6 2>/dev/null
ip6tables -t nat -A XRAY6 -d fe80::/10 -j RETURN 2>/dev/null
ip6tables -t nat -A XRAY6 -d fd00::/8 -j RETURN 2>/dev/null
ip6tables -t nat -A XRAY6 -p tcp -j REDIRECT --to-ports 12346 2>/dev/null
ip6tables -t nat -A PREROUTING -p tcp -j XRAY6 2>/dev/null
ip6tables -I FORWARD -p udp --dport 443 -j DROP 2>/dev/null

# 驗證
iptables -t nat -L XRAY -n -v
# 應該顯示:
# Chain XRAY (1 references)
# pkts bytes target     prot opt in     out     source         destination
#    0     0 RETURN     all  --  *      *       0.0.0.0/0      192.168.31.0/24
#    0     0 REDIRECT   tcp  --  *      *       0.0.0.0/0      0.0.0.0/0      tcp dpt:80 redir ports 12346
#    0     0 REDIRECT   tcp  --  *      *       0.0.0.0/0      0.0.0.0/0      tcp dpt:443 redir ports 12346
```

### 步驟 8：設定重啟持久化

```bash
# 備份原始 rc.local
cp /etc/rc.local /etc/rc.local.bak

# 編輯 rc.local（參考 config/rc.local）
vi /etc/rc.local
```

在 `exit 0` 之前加入（或使用專案中的 `config/rc.local`）：

```bash
# 啟動 xray（容器 restart policy 為 always，所以容器已在跑）
/mnt/docker_disk/mi_docker/docker-binaries/docker exec openwrt xray run -c /etc/xray/config.json &

sleep 3

# iptables 規則（同上）
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
```

### 步驟 9：驗證

從 WiFi 裝置測試：

```bash
# 檢查代理 IP（應該顯示節點 IP，不是你家的寬頻 IP）
curl https://ip.sb

# 檢查各大 AI 網站
curl -I https://chatgpt.com
curl -I https://claude.ai
curl -I https://gemini.google.com
curl -I https://deepseek.com

# 確認一般網站正常
curl -I https://www.baidu.com    # 應該直連，速度快
curl -I https://www.google.com   # 可能走代理也可能直連
```

在路由器上監控：

```bash
# 查看 xray 即時連線
$DOCKER exec openwrt netstat -tnp | grep xray | grep -v LISTEN

# 查看 iptables 計數器（確認有流量在走）
iptables -t nat -L XRAY -n -v

# 查看 xray 路由決策（需要開啟 debug log）
$DOCKER exec -d openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/debug.log 2>&1"
$DOCKER exec openwrt grep "-> proxy" /tmp/debug.log    # 應該看到 proxy 路由
$DOCKER exec openwrt grep "-> direct" /tmp/debug.log   # 應該看到直連路由
```

## 路由規則說明

```
keyword:chatgpt       → 走代理   (域名含有 "chatgpt" 的都走)
keyword:claude        → 走代理   (域名含有 "claude")
keyword:anthropic     → 走代理   (域名含有 "anthropic")
keyword:openai        → 走代理   (域名含有 "openai")
keyword:google-ai     → 走代理   (域名含有 "google-ai")
keyword:gemini        → 走代理   (域名含有 "gemini")

domain:chatgpt.com    → 走代理   (精確匹配 + 子域名)
domain:openai.com     → 走代理
domain:claude.ai      → 走代理
domain:anthropic.com  → 走代理
domain:platform.claude.ai → 走代理
domain:code.claude.ai → 走代理
domain:api.anthropic.com  → 走代理
domain:aistudio.google.com → 走代理
domain:googleapis.com → 走代理   (Claude App 依賴 Google API)
domain:gemini.google.com  → 走代理
domain:deepseek.com   → 走代理
domain:perplexity.ai  → 走代理
domain:copilot.microsoft.com → 走代理
domain:x.com          → 走代理
domain:grok.com       → 走代理
domain:notebooklm.google.com → 走代理
domain:ip.sb          → 走代理   (用來確認代理 IP)
domain:ipinfo.io      → 走代理   (用來確認代理 IP)

network: tcp          → 直連     (以上都沒匹配到的 TCP 全部直連)
```

### 如何新增域名

編輯 `config/xray-config.json` 的 `domain` 陣列：

```json
{ "type": "field", "domain": [
    "domain:新的-ai-服務.com",
    "keyword:新關鍵字"
], "outboundTag": "proxy" }
```

重新啟動 xray：

```bash
$DOCKER exec openwrt killall xray
sleep 1
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json
```

## 檔案結構

```
xiaomi-tproxy/
├── README.md                    # 英文文件
├── README.zh.md                 # 中文文件（本檔案）
├── config/
│   ├── xray-config.json         # xray 設定檔（需修改後使用）
│   └── rc.local                 # /etc/rc.local 重啟持久化範本
├── scripts/
│   ├── setup.sh                 # 一鍵安裝腳本（自動解析 VLESS URL）
│   ├── deploy.sh                # 從本機佈署到路由器
│   └── verify.sh                # 健康檢查腳本
├── skill/
│   └── SKILL.md                 # OpenCode agent skill 定義
└── AGENTS.md                    # AGENTS.md
```

## 故障排除

### iptables 出現 "Operation not permitted"

容器缺少權限。確認是用以下參數建立的：

```bash
$DOCKER run -d --name openwrt \
  --network host \
  --privileged \
  --pid host \
  --ipc host \
  --restart always \
  openwrt/rootfs:latest
```

如果已存在但沒加 `--privileged`，只能砍掉重建。

### 所有流量都走直連 (direct)，沒有走代理

```bash
# 開啟 debug 模式檢查
$DOCKER exec -d openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/debug.log 2>&1"
# 從 WiFi 裝置存取一個 AI 網站
$DOCKER exec openwrt grep "sniffed domain" /tmp/debug.log
$DOCKER exec openwrt grep "taking detour" /tmp/debug.log
```

如果沒有 `sniffed domain`，表示 SNI 偵測失敗。可能原因：
- 連線已經建立（瀏覽器 keep-alive），關掉瀏覽器重開
- 網站使用 ECH (Encrypted Client Hello)，SNI 被加密
- domain 列表有誤

### Mobile App 繞過代理（QUIC/HTTP3）

現代 App 常用 QUIC (UDP 443) 加速，繞過 TCP 層的 iptables 規則：

```
iptables -I FORWARD -p udp --dport 443 -j DROP
```

這會強制 App 降級為 TCP/HTTP2，就會被我們的代理攔截。

**副作用**：某些 Google 服務（如 YouTube）的 QUIC 加速會失效。權衡之下，為了代理穩定，建議開啟。

### Claude App 顯示「地區不支援」

表示代理節點的 IP 所在地區 Claude 不支援。檢查：

```bash
# 從容器內測試（需要 SOCKS 測試埠）
curl --socks5-hostname 127.0.0.1:12347 https://ipinfo.io/json

# 確認 country 欄位是 US / JP / GB / KR / EU 等支援區域
```

解決方法：更換代理節點到支援的區域。

### 硬體加速 (ECM/NSS) 繞過 iptables

小米路由器使用 Qualcomm 硬體加速（ECM/NSS），可能讓已建立的連線繞過 iptables。但 REDIRECT 發生在 TCP 三次握手的 SYN 封包（在硬體加速生效前），所以新連線應該正常。

如果發現流量異常少：

```bash
# 檢查 ECM 設定
cat /etc/config/ecm
# 如果 acceleration_engine 設為 auto，改成 off 可停用硬體加速
# 但不建議，會影響路由效能
```

### Docker binary 找不到

如果 `$DOCKER` 路徑不對，嘗試：

```bash
# 搜尋 docker binary
find / -name docker -type f 2>/dev/null

# 或直接用 PATH 裡的
docker ps
```

### xray 設定檔 JSON 格式錯誤

```bash
# 測試 JSON 語法
$DOCKER exec openwrt xray run -c /etc/xray/config.json
# 如果有錯誤會直接顯示

# 常見錯誤：
# - JSON 結尾少了逗號
# - 中文字元用了全形符號
# - 引號沒跳脫
```

## 原理說明

### iptables REDIRECT 流程

```
用戶端 SYN → 路由器 PREROUTING chain
    ↓
XRAY chain 檢查:
    ├─ 目標是 192.168.31.0/24? → RETURN (繞過)
    ├─ 目標 port 80? → REDIRECT to 127.0.0.1:12346
    └─ 目標 port 443? → REDIRECT to 127.0.0.1:12346
    ↓
xray dokodemo-door 收到連線
    ↓
使用 SO_ORIGINAL_DST 取得原始目標
    ↓
SNI 嗅探 (TLS handshake 或 HTTP Host header)
    ↓
匹配路由規則:
    ├─ AI 域名 → VLESS outbound (加密傳輸到代理伺服器)
    └─ 其他 → freedom outbound (直接連線)
```

### 為什麼不會產生循環（Loop Prevention）

xray 代理出去的連線（到 `YOUR_SERVER:443`）是從**容器內部發起**的，走的是 OUTPUT chain，不是 PREROUTING。我們的 iptables 規則只掛在 PREROUTING 上，所以 xray 自己的連線不會被重新導向回來。

### 重啟後會怎樣

1. 路由器開機 → Docker daemon 啟動 → `restart: always` 的自動啟動容器
2. `/etc/rc.local` 執行 → `docker exec openwrt xray run ...` 啟動 xray
3. `sleep 3` 等待網路就緒
4. iptables 規則重新套用
5. 透明代理恢復運作

## License

MIT
