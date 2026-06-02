---
name: xiaomi-tproxy
version: "2.4.0"
description: AX9000 透明代理部署 — Xray inside Docker, domain-based routing
---

# SKILL.md — AX9000 透明代理坑點手冊（實測版）

## 已知坑點（全部實測確認）

### 1. `setsid` 喺 container 內唔存在
```
sh: setsid: not found
```
- container `sulinggg/openwrt:rpi4` 冇 `setsid`
- **解决:** 用 `docker exec -d` 代替，`docker exec -d` 本身已 detached

### 2. Container 網絡係 `--network=host`
- `docker inspect openwrt --format "{{.HostConfig.NetworkMode}}"` 返回 `host`
- 所以 `docker exec -d openwrt xray` 係喺 host 層面運行 xray，唔係隔離喺 container 內
- **解决:** 唔需要喺 container 入面另外運行 xray，直接用 `docker exec -d` 喺 host 跑就得

### 3. 兩個 xray 撞車
- 如果同時有 host-level xray 和 container-level xray，會有衝突
- **解决:** `killall -9 xray` 清理晒所有舊进程，先重新部署

### 4. `domainStrategy: "IPIfNonMatch"` 缺失
- 預設 routing 只匹配域名，唔匹配 IP；用 `IPIfNonMatch` 令已係 IP 嘅 connection 先比對 domain rule，唔 match 先用內置 DNS resolve
- **解决:** config 的 routing 部分一定要加 `"domainStrategy": "IPIfNonMatch"`
- 注意: `"Always"` 會強制將每個 IP 反查做域名，喺 transparent proxy 場景（多數 connection 入到嚟已經係 IP）好耗資源 — **唔好用** `Always`

### 5. `scp` 失敗
```
ash: /usr/libexec/sftp-server: not found
```
- AX9000 的 OpenWrt 冇 sftp-server
- **解决:** 用 `base64 + SSH` 傳送 config（deploy.sh 內已默認使用）

### 6. ash heredoc 變量替換
- `cat > /tmp/config.json << EOF` → ash 會替換 `${VAR}` `$VAR`
- **解决:** 用 `"EOF"`（加引號），或 `docker cp`

### 7. Log 輸出捕獲
- `docker exec -d ... > /tmp/xray.log` 唔 work（stdout 唔係 xray 的 stdout）
- Xray 內置 `output` 欄位喺呢個版本唔 work
- **解决:** 調試時用 `curl -v` 直接測試 proxy 連接，生產環境唔需要 log

### 8. 跨網段 SSH
- Mac (192.168.1.x) → ASUS → AX9000 WAN (192.168.1.59)
- ASUS 防火牆 block `192.168.31.1` SSH
- **解决:** 用 `ssh root@192.168.1.59`

### 9. Docker binary 路徑
- AX9000 Docker: `/mnt/docker_disk/mi_docker/docker-binaries/docker`
- 唔係 `docker`（唔喺 PATH）
- **解决:** 每次 SSH 後 `DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker`

### 10. [YOUR_SERVER_DOMAIN] DNS
- 解析到 `[Cloudflare CDN IP]`（CDN 通用 IP，唔係真實 origin）— 係正常！
- xray WebSocket + TLS 通過 Cloudflare CDN 正常連接
- **唔好** 胡亂 hardcode 其他 IP

### 11. xray 內存累積（1GB+ leak）
- 預設每個 connection 512KB buffer pool，長時間運行可累積 1GB+ RSS
- **解决:** 加 `policy.levels.0.bufferSize: 4` 將每 connection buffer 減到 4KB
- 預期效果: 1.265GB → ~30MB（減 97%）

### 12. fd limit 1024 爆 (accept4: too many open files)
- xray 預設 1024 fd，LAN client 一波訪問就爆
- log 出現 `failed to accepted raw connections > accept tcp [::]:12346: accept4: too many open files`
- **解决:** `docker exec` 加 `--ulimit nofile=65535:65535` 設 container 內 fd 上限
- 注意: host 嘅 `ulimit -n` 唔會 inheritance 入 container 內 xray，必須 docker exec 設

### 13. IPv6 outgoing 被 firewall block → xray outbound 100% 失敗
- AX9000 IPv6 outgoing 默認 block（用 `ping6 2606:4700:...` 確認 `sendto: Permission denied`）
- 但 xray Go resolver 預設 IPv6 first (RFC 6724)，會 dial IPv6 address，撞牆
- 症狀: xray log 出現 `dial tcp [2606:...]:443: connect: permission denied`，outbound ESTABLISHED = 0，proxy 完全唔 work
- **解决:** xray config 頂層加：
  ```json
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  }
  ```
  強制 xray 內置 resolver 只用 IPv4，跳過 IPv6 dial

### 14. `dns.servers` 必須顯式設
- 用咗 `queryStrategy: UseIPv4` 一定要配合顯式 `servers` 陣列
- xray 唔會 fall back 落 system DNS（唔似 Go 默認）
- 唔寫 `servers` 嘅話 `queryStrategy` 設定會被忽略，仲用緊 Go 默認 IPv6-first
- **解决:** 上面坑點 13 嘅 json block 一定要包含 `servers` 兩條 entry（最少 1 條 IPv4）
- 推薦: Cloudflare `1.1.1.1` + Google `8.8.8.8` 互補

### 15. `domain:X` rule 係 subdomain match (唔係 exact match)
- xray 嘅 `domain:googleapis.com` 唔淨係 match `googleapis.com`，**會 match 所有 `*.googleapis.com`** 子域
- 真實 case: 寫咗 `domain:googleapis.com` 想 catch Gemini API (`generativelanguage.googleapis.com`)，**意外 catch 咗 `youtube.googleapis.com`**
- 症狀: YouTube / 其他 Google 服務 喺手機出 YouTube backend API 期間被 proxy 出去 (Cloudflare 任何cast IP 喺 IP geo database 顯示外國)
- 路由器端 routing log 唔易即時發現 (info level log 容易被 warning 級別遮蔽)
- **解决:** 用**精準 endpoint** 而唔係 broad parent domain：
  - ❌ `domain:googleapis.com` (catch 所有子域)
  - ✅ `domain:generativelanguage.googleapis.com` (只 catch Gemini API)
  - ✅ `domain:aiplatform.googleapis.com` (Vertex AI)
- 設計 routing rule 嘅原則: **bottom-up 唔係 top-down**，由 specific service endpoint 開始加
- xray 仲有 `domainprefix:` 為前綴 match (e.g. `domainprefix:youtube` 會 match `youtube.com` / `youtube.googleapis.com`)，用之前確認 syntax

---

## 部署命令

```bash
cd ~/.kimaki/projects/xiaomi-tproxy
./scripts/deploy.sh 192.168.1.59 [ROUTER_PASSWORD]
```

## 驗證命令

```bash
# 確認 proxy 連接
netstat -tnp | grep xray | grep ESTABLISHED | grep -v "192.168"
# 預期: [ROUTER_LAN_IP]:xxxx -> [Cloudflare CDN IP]:443 ESTABLISHED

# 確認 xray 運行
ps | grep xray | grep -v grep

# 確認 port 12346 監聽
netstat -tlnp | grep 12346

# 確認 xray 內存（裝咗 bufferSize: 4 應該 < 100MB）
XPID=$(pidof xray | awk '{print $1}')
[ -n "$XPID" ] && cat /proc/$XPID/status | grep VmRSS

# 確認 xray fd 上限（裝咗 --ulimit 應該 = 65535）
[ -n "$XPID" ] && cat /proc/$XPID/limits | grep "open files"
```

## 調整 Proxy 域名清單

編輯 `config/xray-config.json` 的 `domains` 陣列，，然後：
```bash
./scripts/deploy.sh 192.168.1.59 [ROUTER_PASSWORD]
```
