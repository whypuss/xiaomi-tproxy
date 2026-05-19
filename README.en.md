# Xiaomi Router Transparent Proxy (xray-core)

**Version: 2.0.0** | 2025-05-19

One-command transparent proxy on Xiaomi AX9000/AX3600/AX3200/AX1800 routers. All WiFi devices automatically route AI services through a VLESS+WS+TLS proxy — no per-device setup needed.

## Features

- **Zero-config clients** — just connect to WiFi
- **AI routing** — ChatGPT, Claude, Gemini, DeepSeek, Perplexity, X AI, Grok
- **SNI sniffing** — extracts domain from TLS handshake for routing decisions
- **QUIC blocking** — forces mobile apps to TCP
- **Boot persistence** — via `/etc/rc.local`

## Architecture

```
WiFi client (31 subnet)
    ↓ TCP 80/443
Router iptables PREROUTING → XRAY chain → REDIRECT :12346
    ↓
xray dokodemo-door (sniffing enabled)
    ↓ SNI domain match
    ├─ AI domains → VLESS+WS+TLS proxy
    └─ other → direct
```

## Quick Deploy

```bash
scp -r ./config root@192.168.1.59:/tmp/xiaomi-tproxy/
ssh root@192.168.1.59
  cd /tmp/xiaomi-tproxy
  sh scripts/setup.sh
  # paste VLESS URL
```

## Key Pitrfalls (v2.0.0)

| Issue | Fix |
|-------|-----|
| Wrong image `openwrt/rootfs:latest` | Use `sulinggg/openwrt:rpi4` |
| ash shell heredoc `$VAR` substitution | Use `docker cp` instead |
| rc.local `&` process dies on SSH disconnect | Use `setsid` |
| Cloudflare CDN DNS inside container | Hardcode server IP |
| Mac cross-subnet SSH fails | Use `ssh root@192.168.1.59` |

## Verify

```bash
# Must see ESTABLISHED connection to proxy server
netstat -tnp 2>/dev/null | grep xray | grep ESTABLISHED | grep -v 192.168

# xray log
DOCKER exec openwrt cat /tmp/xray.log

# Auto check
sh scripts/verify.sh
```

**From WiFi device:**
```bash
curl https://ip.sb          # Shows proxy IP
curl https://chatgpt.com    # Should load
```

## File Structure

```
xiaomi-tproxy/
├── AGENTS.md
├── README.md / README.en.md
├── config/
│   ├── xray-config.json   # Template — edit with your node details
│   └── rc.local           # Boot persistence template
├── scripts/
│   ├── setup.sh           # One-click deploy
│   ├── deploy.sh          # Push config from local machine
│   └── verify.sh          # Health check
└── skill/
    └── SKILL.md           # Agent skill (deployment steps + pitfalls)
```
