# Xiaomi Router Transparent Proxy (xray-core)

**Version: 2.1.0** | 2026-05-19

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

## Deployment Flow

```
Step 1 (ONE TIME):  Run setup.sh ON THE ROUTER
                     → Sets up Docker, xray binary, geo files, iptables, rc.local

Step 2 (EVERY TIME): Run deploy.sh FROM YOUR MAC
                     → Updates config (deploy.sh uses SSH, no scp)
```

## Quick Deploy (Step 1 — One Time Only)

SSH into the router, then run setup.sh:

```bash
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa

# On the router:
scp -r ./config ./scripts root@192.168.1.59:/tmp/xiaomi-tproxy/
# OR clone the repo directly on router:
cd /tmp && git clone https://github.com/whypuss/xiaomi-tproxy.git
cd xiaomi-tproxy
sh scripts/setup.sh
```

setup.sh will:
1. Check Docker + container (sulinggg/openwrt:rpi4)
2. Download xray binary (v26.3.27) via wget
3. Download geo files (geoip.dat + geosite.dat)
4. Ask for VLESS URL (or reuse existing config)
5. Write config via `docker cp` (avoids ash heredoc issues)
6. Start xray via `docker exec -d` (no setsid needed — it's already detached)
7. Apply iptables rules (REDIRECT 80/443 → 12346)
8. Write rc.local for boot persistence

## Update Config (Step 2 — After Initial Setup)

From your Mac:

```bash
git clone https://github.com/whypuss/xiaomi-tproxy.git
cd xiaomi-tproxy

# Edit config/xray-config.json first (change VLESS node, proxy domains)
# Then deploy:
./scripts/deploy.sh 192.168.1.59 qwerty66
```

deploy.sh uses base64 + SSH (NOT scp — AX9000 lacks sftp-server).

## Verify

```bash
# Health check from Mac:
./scripts/verify.sh 192.168.1.59 qwerty66

# Must see ESTABLISHED connection to proxy server:
ssh root@192.168.1.59 -o HostKeyAlgorithms=+ssh-rsa \
  'netstat -tnp | grep xray | grep ESTABLISHED | grep -v 192.168'
```

**From WiFi device:**
```bash
curl https://ip.sb          # Shows proxy IP
curl https://chatgpt.com    # Should load
```

## Key Pitfalls (v2.1.0 — All Tested)

| Issue | Fix |
|-------|-----|
| `setsid` not found in container | Use `docker exec -d` (already detached) |
| `scp` fails — no sftp-server | Use base64 + SSH (deploy.sh handles this) |
| ash heredoc `$VAR` substitution | Use `docker cp` instead |
| domain routing only matches domains, not IPs | Add `"domainStrategy": "Always"` to config |
| Mac cross-subnet SSH to 192.168.31.1 blocked | Use `ssh root@192.168.1.59` (WAN IP) |
| Two xray processes collide | `killall -9 xray` before deploying |
| jp.xlin.eu.cc resolves to Cloudflare CDN | Normal — xray uses SNI, not hardcoded IP |

## File Structure

```
xiaomi-tproxy/
├── AGENTS.md              # Quick start for AI agents
├── README.md              # Chinese tutorial
├── README.en.md           # This file
├── config/
│   ├── xray-config.json   # Main config — edit VLESS node + proxy domains
│   └── rc.local           # Boot persistence template
├── scripts/
│   ├── setup.sh           # ONE-TIME: Run on router, sets up entire environment
│   ├── deploy.sh          # Update config from Mac (uses SSH)
│   └── verify.sh          # Health check from Mac (uses SSH)
└── skill/
    └── SKILL.md           # Agent skill (10 tested pitfalls)
```

## Customize Proxy Domains

Edit `config/xray-config.json`, find the `domains` array in `routing.rules[0]`, add/remove domains, then run deploy.sh.
