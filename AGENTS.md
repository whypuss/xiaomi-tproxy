# xiaomi-tproxy

xray-core transparent proxy for Xiaomi routers (AX9000/AX3600/AX3200/AX1800).

**Version: 2.0.0** (2025-05-19)

## 快速開始

```bash
# 部署到 router
scp -r ./config root@192.168.1.59:/tmp/xiaomi-tproxy/
ssh root@192.168.1.59
  cd /tmp/xiaomi-tproxy
  sh scripts/setup.sh
  # 貼上 VLESS URL
```

## 踩坑紀錄（v2.0.0）

- ❌ `openwrt/rootfs:latest` — x86_64 only，ARM64 路由器要 `sulinggg/openwrt:rpi4`
- ❌ ash shell heredoc 會替換 `$VAR` — 用 `docker cp` 代替
- ❌ rc.local `&` background — SSH 斷了 xray 也死，要 `setsid`
- ⚠️ Cloudflare CDN DNS 問題 — container 可能解析到被牆的 IP，試 hardcoded IP
- ⚠️ Mac ASUS WiFi 跨網段 — SSH 用 `192.168.1.59`，唔係 `192.168.31.1`

## 架構

```
WiFi client (31網段) → iptables REDIRECT → xray:12346 → SNI sniffing
                                                   ├─ AI domains → VLESS proxy
                                                   └─ other → direct
```

## 關鍵檔案

- `skill/SKILL.md` — Agent skill（部署流程 + 坑點）
- `scripts/setup.sh` — 一鍵部署 script
- `scripts/deploy.sh` — 從本機更新 config
- `scripts/verify.sh` — 健康檢查
- `config/xray-config.json` — xray config 範本
- `config/rc.local` — 開機持久化範本
