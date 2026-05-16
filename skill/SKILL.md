---
name: xiaomi-tproxy
description: >-
  Set up transparent proxy on Xiaomi routers (OpenWrt-based firmware) using Docker xray-core.
  Routes AI services (ChatGPT, Claude, Gemini, DeepSeek, Perplexity, etc.) through a VLESS+WS+TLS proxy,
  while all other traffic goes direct. No per-device configuration needed.
license: MIT
compatibility: opencode
metadata:
  router: Xiaomi AX3600 / AX1800 / AX3200 / AX9000 (MiWiFi OpenWrt-based)
  proxy: xray-core 1.8.6+ / VLESS+WS+TLS
  container: Docker with --network host --privileged
  ports: "12346 (transparent), iptables REDIRECT 80/443"
---

## Architecture

```
iPhone/PC → Router(iptables PREROUTING) → xray:12346 → SNI sniffing
  ├─ AI domains matched → VLESS proxy
  └─ All other traffic → direct
```

## Quick Commands

### Deploy xray config
```bash
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker
$DOCKER cp xray-config.json openwrt:/etc/xray/config.json
```

### Apply iptables
```bash
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
```

### Start xray
```bash
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json
```

### Restart xray
```bash
$DOCKER exec openwrt killall xray
sleep 1
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json
```

### Check status
```bash
# xray listening
$DOCKER exec openwrt netstat -tlnp | grep xray

# iptables counters
iptables -t nat -L XRAY -n -v

# active proxy connections
$DOCKER exec openwrt netstat -tnp | grep xray | grep -v LISTEN
```

## Proxied Domains

- keyword: chatgpt, claude, anthropic, openai, google-ai, gemini
- domain: chatgpt.com, openai.com, api.openai.com, openaicom.imgix.net
- domain: claude.ai, platform.claude.ai, code.claude.ai, anthropic.com, api.anthropic.com
- domain: aistudio.google.com, ai.google.dev, makersuite.google.com, googleapis.com
- domain: bard.google.com, gemini.google.com
- domain: copilot.microsoft.com, deepseek.com, perplexity.ai, x.com, grok.com
- domain: notebooklm.google.com, ip.sb, ipinfo.io

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| All traffic direct | Check domainStrategy and sniffing config |
| iptables permission denied | Container needs `--privileged` |
| QUIC bypass | `iptables -I FORWARD -p udp --dport 443 -j DROP` |
| Region error (Claude) | Proxy server location not supported - check ipinfo.io |
| No packets redirected | Check `iptables -t nat -L XRAY -n -v` counters |
| Mobile app bypass | QUIC/UDP likely - add DROP rule above |

## Important Paths

- Container config: `/etc/xray/config.json`
- Host persistence: `/etc/rc.local`
- Docker binary: `/mnt/docker_disk/mi_docker/docker-binaries/docker`
- xray listening: port 12346 (transparent proxy inbound)

## Verification

From a WiFi device:
```bash
curl https://ip.sb    # Should show proxy server IP, not your WAN IP
```
