---
name: xiaomi-tproxy
version: "2.2.0"
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

### 4. `domainStrategy: "Always"` 缺失
- 舊版 routing 只匹配域名，唔匹配 IP
- **解决:** config 的 routing 部分一定要加 `"domainStrategy": "Always"`

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
