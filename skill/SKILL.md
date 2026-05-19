---
name: xiaomi-tproxy
version: "2.0.1"
description: AX9000 透明代理部署 — Xray inside Docker, domain-based routing
---

# SKILL.md — AX9000 透明代理坑點手冊

## 已知坑點

### 1. SCP 失敗（最常見）
```
ash: /usr/libexec/sftp-server: not found
scp: Connection closed
```
- AX9000 的 OpenWrt 冇編入 sftp-server
- **解决:** 用 `base64 + SSH` 傳送 config，或 `docker cp` 直接拷入 container

### 2. ash heredoc 變量替換
- `cat > /tmp/config.json << EOF` → ash 會替換 `${VAR}` `$VAR`
- **解决:** 用 `cat > /tmp/config.json << "EOF"`（加引號），或 `docker cp`

### 3. `&` 背景執行被 SIGHUP kill
- SSH 斷開後 background job 收到 SIGHUP，xray 停止
- **解决:** 用 `setsid xray run ... &` 完全 detach from TTY

### 4. Xray geo files 路徑
- xray binary 在 `/usr/bin/xray`，working directory 係 `/usr/bin/`
- xray 搵 `geoip.dat` 時係相對於 working directory
- **解决:** `ln -sf /tmp/geoip.dat /usr/bin/geoip.dat`（symlink 到 `/usr/bin/`）

### 5. 路由域名前加 `domainStrategy: "Always"`
- 舊版 routing 只匹配域名，唔匹配 IP
- **解决:** config 的 routing 部分加 `"domainStrategy": "Always"`

### 6. 跨網段 SSH
- Mac (192.168.1.x) → ASUS → AX9000 WAN (192.168.1.59)
- ASUS 防火牆 block 192.168.31.1 SSH
- **解决:** 用 `192.168.1.59`，唔用 `192.168.31.1`

### 7. Docker binary 路徑
- AX9000 Docker socket: `/mnt/docker_disk/mi_docker/docker-binaries/docker`
- 唔係 `docker`（唔喺 PATH）
- **解决:** 每次 SSH 進去後 `DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker`

### 8. jp.xlin.eu.cc DNS
- 解析到 `172.67.144.125`（Cloudflare CDN）— 呢個係正常！
- **唔好** 胡亂 hardcode 其他 IP，xray WebSocket + TLS 通過 Cloudflare CDN 正常運作
