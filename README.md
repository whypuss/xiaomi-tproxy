# AX9000 透明代理部署教程

**使用官方開發版固件不刷第三方固件，docker部署。

**適用型號:** 小米 AX9000（Linux 4.9, ARM64, Docker）<br>
**最後更新:** 2026-05-19<br>
**狀態:** ✅ 實測通過 — Xray 透明代理正常運行，WiFi clients 流量行 proxy<br>
**最新 commit:** `3c53c24`

> 🤖 **AI Agent 部署提示詞（複製呢段）：**
> ```
> Clone https://github.com/whypuss/xiaomi-tproxy
> Read README.md (Chinese) or README.en.md (English) first
> Follow the "部署流程" section — setup.sh first (one time), then deploy.sh
> Router: root@192.168.1.59
> ```

---

**實測確認:**
- Xray → proxy server (`172.67.144.125:443`) ESTABLISHED ✅
- WiFi clients (`192.168.31.x`) → xray port 12346 → proxy ✅
- `domainStrategy: "Always"` 確保 IP 級別 routing ✅

---

## 網絡架構

```
Mac (192.168.1.x) → ASUS WiFi (192.168.1.1) → AX9000 WAN (192.168.1.59)
                                                        ↓
                                              AX9000 LAN (192.168.31.1)
                                                        ↓
                                              Docker container (openwrt)
                                                        ↓
                                              Xray 透明代理
```

Mac SSH 登入：**`ssh root@192.168.1.59`**（跨網段，唔用 192.168.31.1）

---

## 前置需求

- AX9000 已安裝 Docker（`sulinggg/openwrt:rpi4` image）
- Xray 已下載並放進 container（見 Step 1）
- Geo 數據文件已下載（見 Step 2）

---

## 部署流程（必讀）

```
第一步（一次性）：setup.sh  — 喺路由器上行一次，建立完整環境
         ↓
第二步（每次更新）：deploy.sh — 喺 Mac 上面行，改 config 之後用
```

**setup.sh 一次性建立：**
- Docker + container
- xray binary (wget)
- geo files (wget + symlink)
- iptables 規則
- rc.local 開機自動

**deploy.sh 之後無限次用：**
- 讀取 config/xray-config.json
- base64 + SSH 上傳（唔用 scp）
- killall xray + 重啟

---

## 快速部署（第二步）

```bash
# 喺本機（Mac）執行，自動完成所有步驟
./scripts/deploy.sh 192.168.1.59 qwerty66
```

---

## 完整部署（第一步）

如果你從未喺呢個 AX9000 上面部署過，先行 setup.sh：

```bash
# SSH 入路由器
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa

# 喺路由器上面 clone repo
cd /tmp && git clone https://github.com/whypuss/xiaomi-tproxy.git
cd xiaomi-tproxy

# 一次性環境搭建
sh scripts/setup.sh
```

---

## 手動部署（完整步驟）

### Step 1：確認 Xray 版本

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa

DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER exec openwrt xray version
```

預期輸出：`Xray 26.x.x (go1.26.x linux/arm64)`

如果 `xray: not found`，下載 binary：

```bash
$DOCKER exec openwrt sh -c "
    cd /tmp
    wget -q https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-arm64-v8.zip
    unzip -o Xray-linux-arm64-v8.zip
    mv xray /usr/bin/xray
    chmod +x /usr/bin/xray
"
```

### Step 2：下載 Geo 文件

```bash
$DOCKER exec openwrt sh -c "
    cd /tmp
    wget -q https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    ln -sf /tmp/geoip.dat /usr/bin/geoip.dat
    ln -sf /tmp/geosite.dat /usr/bin/geosite.dat
"
```

**注意：** Xray working directory 係 `/usr/bin/`，所以 geo files 要放 `/tmp/` 再 symlink 去 `/usr/bin/`。

### Step 3：寫入 Xray Config

**方法 A（推薦）：用 base64 寫入，避免 ash shell 變量替換問題**

喺本機 Mac 執行：

```bash
CONFIG_B64=$(cat config/xray-config.json | base64)
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    echo "'"$CONFIG_B64"'" | base64 -d > /tmp/xray-config.json
    $DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json
'
```

**方法 B：如果 SCP 有反應（取決於 OpenWrt 版本）**

```bash
scp -o HostKeyAlgorithms=+ssh-rsa config/xray-config.json root@192.168.1.59:/tmp/
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    $DOCKER cp /tmp/xray-config.json openwrt:/etc/xray/config.json
'
```

> ⚠️ 部分 AX9000 OpenWrt 版本冇 `sftp-server`，SCP 會失敗。請用方法 A。

### Step 4：啟動 Xray

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

    # Kill 舊程序（如有）
    $DOCKER exec openwrt killall xray 2>/dev/null || true
    sleep 1

    # 用 docker exec -d 啟動（已 detached，唔需要 setsid）
    $DOCKER exec -d openwrt xray run -c /etc/xray/config.json >/tmp/xray.log 2>&1 &

    # 等 5 秒
    sleep 5

    # 確認已啟動
    $DOCKER exec openwrt cat /tmp/xray.log | head -5
'
```

預期輸出：
```
Xray 26.x.x (Xray, Penetrates Everything.) ...
[Info] infra/conf/serial: Reading config: /etc/xray/config.json
```

### Step 5：驗證 Proxy 連接

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v 192.168
'
```

預期輸出（範例）：
```
tcp  0  0  192.168.1.59:4xxxx  172.67.144.125:443  ESTABLISHED  xray
```

`172.67.144.125` 係 `jp.xlin.eu.cc` 的 Cloudflare CDN IP，呢個係正常！Xray 通過 Cloudflare CDN 連接代理伺服器，TLS 完整加密。

### Step 6：測試透明代理（AI 網站）

喺 AX9000 WiFi 下的設備（192.168.31.x）打開瀏覽器，訪問 `chatgpt.com`

然後 check xray log：

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
    $DOCKER exec openwrt cat /tmp/xray.log | grep "transparent -> proxy" | tail -5
'
```

預期輸出：
```
from 192.168.31.x:xxxxx accepted tcp:142.250.x.x:443 [transparent -> proxy]
from 192.168.31.x:xxxxx accepted tcp:216.239.x.x:443 [transparent -> proxy]
```

`[transparent -> proxy]` = 行緊代理 ✅  
`[transparent -> direct]` = 直連（呢啲 IP 未匹配 domain rule）

---

## 持久化（重啟後自動啟動）

將啟動命令寫入 rc.local：

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa '
    DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

    cat > /etc/rc.local << "RCEOF"
#!/bin/sh
sleep 10
$DOCKER start openwrt 2>/dev/null || true
sleep 5
$DOCKER exec -d openwrt sh -c "setsid xray run -c /etc/xray/config.json > /tmp/xray.log 2>&1"
exit 0
RCEOF

    chmod +x /etc/rc.local
'
```

---

## 常見問題

### Q: `[透明代理 -> 直接]` 全部都係 direct，proxy 規則未生效？

1. 確認 config 有 `"domainStrategy": "Always"`（關鍵！）
2. 確認 domain list 包含目標網站
3. 確認 proxy outbound 有正確的 VLESS 設定
4. 執行 `docker exec openwrt cat /tmp/xray.log | grep error` 檢查錯誤

### Q: `netstat` 冇顯示到 proxy server 連接？

1. 等 10-15 秒，xray 建立連接需要時間
2. 確認 xray 正在運行：`docker exec openwrt ps | grep xray`
3. 檢查 xray log：`docker exec openwrt cat /tmp/xray.log | grep -i error`

### Q: `jp.xlin.eu.cc` DNS 解析到 `172.67.144.125`，呢個係正常的嗎？

係正常的。`jp.xlin.eu.cc` 使用 Cloudflare CDN，CDN IP 係 `172.67.144.125`，Xray 通過 WebSocket + TLS 連接呢個 IP，Cloudflare 負責路由到眞實代理伺服器。唔好胡亂 hardcode 其他 IP。

### Q: SSH 連接 `192.168.31.1` timeout？

Mac 喺 ASUS WiFi 網段（192.168.1.x），ASUS 防火牆會 block 跨網段 SSH。改用 `192.168.1.59`（AX9000 WAN IP）。

### Q: `scp` 失敗？

AX9000 的 OpenWrt 預設冇 `sftp-server`，SCP 會失敗。請用 `deploy.sh` 內的 base64 + SSH 方法。

### Q: ash shell heredoc 寫入 config.json 失敗？

ash 會替換 heredoc 內的 `${VAR}` 和 `$VAR`。用 `cat > file << "EOF"`（引號包住 EOF）避免替換，或者用 `docker cp` 方法。

### Q: Xray 重啟後連接断咗？

用 `docker exec -d` 代替 `&` 背景執行。`docker exec -d` 本身已 detached from TTY，SSH 斷開後 xray 繼續運行。唔需要 `setsid`（container 冇呢個指令）。

---

## 文件結構

```
xiaomi-tproxy/
├── README.md              ← 本教程
├── AGENTS.md              ← Agent 上下文
├── skill/
│   └── SKILL.md           ← 坑點清單（部署前必讀）
├── config/
│   ├── xray-config.json   ← Xray 配置（修改呢個）
│   └── rc.local           ← 路由器開機腳本
└── scripts/
    ├── deploy.sh          ← 一鍵部署（推薦）
    ├── setup.sh           ← 首次環境安裝
    └── verify.sh          ← 驗證腳本
```

---

## 代理的網站列表

| 類別 | 域名 |
|------|------|
| ChatGPT | chatgpt.com, openai.com, api.openai.com |
| Claude | claude.ai, platform.claude.ai, anthropic.com, api.anthropic.com |
| Gemini | gemini.google.com, aistudio.google.com, ai.google.dev, googleapis.com |
| DeepSeek | deepseek.com |
| Perplexity | perplexity.ai |
| X AI | x.ai, x.com |
| Grok | groq.com |
| 其他 | bard.google.com, notebooklm.google.com, copilot.microsoft.com |
| 關鍵字 | chatgpt, claude, anthropic, openai, google-ai, gemini |

---

## 配置自定義

編輯 `config/xray-config.json` 中的：

| 欄位 | 說明 |
|------|------|
| `address` | 代理伺服器域名（如 `jp.xlin.eu.cc`） |
| `port` | 代理伺服器端口（通常 `443`） |
| `id` | VLESS UUID |
| `path` | WebSocket 路徑 |
| `Host` / `serverName` | TLS ServerName，須與 address 相同 |
| `domains` | 代理的域名列表 |

修改後執行 `./scripts/deploy.sh 192.168.1.59 qwerty66` 重新部署。
