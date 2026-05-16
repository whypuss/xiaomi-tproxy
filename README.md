# Xiaomi Router Transparent Proxy (xray-core)

Set up transparent proxy on Xiaomi/AX3600 routers (OpenWrt-based MiWiFi firmware) using Docker xray-core. All WiFi devices automatically get proxied access to AI services - no per-device configuration needed.

## Features

- **Zero-config for clients** - All WiFi devices automatically proxied via iptables REDIRECT
- **AI service routing** - ChatGPT, Claude, Gemini, DeepSeek, Perplexity, Copilot, Grok and more
- **SNI sniffing** - xray detects TLS SNI to route specific domains through the proxy
- **IP fallback** - IP-based routing rules when SNI sniffing unavailable
- **QUIC blocking** - UDP 443 blocked to force mobile app TCP fallback (ensures proxy capture)
- **Reboot persistence** - `/etc/rc.local` auto-starts xray and re-applies iptables
- **IPv6 support** - Separate ip6tables rules for completeness
- **Docker-based** - xray runs in a container, isolated from router firmware

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Xiaomi Router (OpenWrt-based)                                      │
│                                                                     │
│  ┌─────────┐    iptables PREROUTING    ┌──────────────────────┐    │
│  │  WiFi    │─── TCP 80/443 ────────▶  │  Docker Container    │    │
│  │  Devices │                          │  ┌────────────────┐  │    │
│  │  (LAN)   │◀── response ────────────│  │  xray-core      │  │    │
│  └─────────┘                          │  │  :12346         │  │    │
│                                        │  └────────────────┘  │    │
│                                        └──────────────────────┘    │
│                                              │                     │
│                                              ▼                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  xray Routing                                                  │  │
│  │                                                                │  │
│  │  SNI sniffing → Domain/IP matching                             │  │
│  │    ├─ AI domains → VLESS+WS+TLS proxy (YOUR_SERVER:443)       │  │
│  │    └─ Other → Direct (freedom outbound)                       │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

> **中文版**: [README.zh.md](README.zh.md)

## Prerequisites

- **Router**: Xiaomi AX3600 / AX1800 / AX3200 / AX9000 with MiWiFi OpenWrt-based firmware (SSH enabled)
- **Docker**: Running on the router (`/mnt/docker_disk/mi_docker/docker-binaries/docker`)
- **Docker container**: OpenWrt-based container with `--network host --privileged` flags
- **Proxy subscription**: A VLESS+WS+TLS proxy URL (e.g., `vless://UUID@SERVER:PORT?path=/&host=SERVER#name`)

> If SSH is not enabled, activate it via the official MiWiFi method (bind your MiWiFi account to get the root password).

## Quick Start

### 1. Container Setup (one-time)

```bash
ssh root@192.168.31.1
DOCKER=/mnt/docker_disk/mi_docker/docker-binaries/docker

# Create the container
$DOCKER run -d \
  --name openwrt \
  --network host \
  --privileged \
  --pid host \
  --ipc host \
  --restart always \
  openwrt/rootfs:latest

# Install xray-core inside the container
$DOCKER exec openwrt opkg update
$DOCKER exec openwrt opkg install xray-core

# Verify xray is installed
$DOCKER exec openwrt xray version
```

> If `opkg update` fails due to outdated feeds, download xray binary directly:
> ```bash
> $DOCKER exec openwrt wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64.zip
> $DOCKER exec openwrt unzip -d /usr/bin /tmp/xray.zip xray
> $DOCKER exec openwrt chmod +x /usr/bin/xray
> ```

### 2. Configure xray

Edit `config/xray-config.json` with your VLESS node details, then deploy:

```bash
# Copy config into container
$DOCKER cp config/xray-config.json openwrt:/etc/xray/config.json

# Verify
$DOCKER exec openwrt ls -la /etc/xray/config.json
```

Or use the interactive setup script which parses a VLESS URL:

```bash
sh scripts/setup.sh
# Paste your vless://UUID@SERVER:PORT?path=/... URL when prompted
```

### 3. Start and Verify xray

```bash
# Start xray
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json
sleep 2

# Verify it's listening
$DOCKER exec openwrt netstat -tlnp | grep xray
# Should show: LISTEN :::12346

# Test the proxy node works (check server location)
$DOCKER exec openwrt sh -c "curl -s --max-time 10 https://ipinfo.io/json" | grep -E "ip|country|city"
# Should show your proxy server's IP and location (must be US/JP/EU for Claude)
```

### 4. Apply iptables Rules

```bash
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
```

### 5. Enable on Reboot

Add to `/etc/rc.local` (see `config/rc.local` for full template):

```bash
$DOCKER exec openwrt xray run -c /etc/xray/config.json &
sleep 3
iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY 2>/dev/null
iptables -t nat -A XRAY -d 192.168.31.0/24 -j RETURN
iptables -t nat -A XRAY -p tcp --dport 80 -j REDIRECT --to-ports 12346
iptables -t nat -A XRAY -p tcp --dport 443 -j REDIRECT --to-ports 12346
iptables -t nat -A PREROUTING -p tcp -j XRAY
iptables -I FORWARD -p udp --dport 443 -j DROP
```

### 6. Verify from WiFi Device

```bash
# Should show your proxy server IP (not your home WAN IP)
curl https://ip.sb

# AI services should load
curl -I https://chatgpt.com
curl -I https://claude.ai
```

## Configuration

### xray Config (`config/xray-config.json`)

The xray configuration uses:

- **dokodemo-door inbound** with `followRedirect: true` on port 12346 for transparent proxy
- **VLESS+WS+TLS outbound** to the proxy server
- **freedom outbound** for direct traffic
- **Domain routing** with keyword and domain suffix matching
- **IP routing** fallback for when SNI sniffing unavailable
- **SNI sniffing** with `destOverride: ["http", "tls"]`

### Routing Rules

```
keyword:chatgpt       → proxy    (domain contains "chatgpt")
keyword:claude        → proxy    (domain contains "claude")
keyword:anthropic     → proxy    (domain contains "anthropic")
keyword:openai        → proxy    (domain contains "openai")
keyword:google-ai     → proxy    (domain contains "google-ai")
keyword:gemini        → proxy    (domain contains "gemini")

domain:chatgpt.com    → proxy    (exact + subdomains)
domain:openai.com     → proxy
domain:claude.ai      → proxy
domain:anthropic.com  → proxy
domain:platform.claude.ai → proxy
domain:code.claude.ai → proxy
domain:api.anthropic.com  → proxy
domain:aistudio.google.com → proxy
domain:googleapis.com → proxy
domain:gemini.google.com  → proxy
domain:deepseek.com   → proxy
domain:perplexity.ai  → proxy
domain:copilot.microsoft.com → proxy
domain:x.com          → proxy
domain:grok.com       → proxy
domain:notebooklm.google.com → proxy
domain:ip.sb          → proxy
domain:ipinfo.io      → proxy

network: tcp          → direct   (catch-all for everything else)
```

### Customizing Domains

Edit the `domain` array in the routing rules section of `config/xray-config.json`:

```json
{
  "type": "field",
  "domain": [
    "domain:new-ai-service.com",
    "keyword:new-keyword"
  ],
  "outboundTag": "proxy"
}
```

Then restart xray:

```bash
docker exec openwrt killall xray
docker exec -d openwrt xray run -c /etc/xray/config.json
```

## Files

```
xiaomi-tproxy/
├── README.md                    # This file
├── config/
│   ├── xray-config.json         # xray configuration (edit this)
│   └── rc.local                 # /etc/rc.local template for persistence
├── scripts/
│   ├── setup.sh                 # One-click setup on router
│   ├── deploy.sh                # Deploy from local machine to router
│   └── verify.sh                # Verification and diagnostics
├── skill/
│   └── SKILL.md                 # OpenCode agent skill definition
└── AGENTS.md                    # This project's AGENTS.md
```

## Troubleshooting

### iptables "Operation not permitted"

The container must run with `--privileged` flag. If you see this error:

```
iptables: Operation not permitted
```

Ensure the container was created with:

```bash
docker run -d --name openwrt --network host --privileged --pid host --ipc host --restart always openwrt/rootfs:latest
```

### All traffic goes DIRECT (none through proxy)

Check that xray is routing correctly:

```bash
docker exec openwrt sh -c "xray run -c /etc/xray/config.json > /tmp/xray-debug.log 2>&1" &
# Access a proxy domain from a client, then check:
docker exec openwrt grep "-> proxy" /tmp/xray-debug.log
```

If no `-> proxy` entries, the domain sniffing might not match. Ensure your domain list is correct and `sniffing.enabled: true`.

### LAN devices bypassing proxy (QUIC/HTTP3)

Modern apps use QUIC (UDP 443) which bypasses TCP iptables rules:

```
iptables -I FORWARD -p udp --dport 443 -j DROP
```

This forces apps to fall back to TCP/HTTP2, which gets caught by our proxy.

### Hardware Offload (ECM/NSS) Skipping iptables

Xiaomi routers with Qualcomm chipsets use hardware acceleration (ECM/NSS) that can bypass iptables for established connections. The REDIRECT happens on the first SYN packet before offload kicks in, so new connections should work. If persistent issues occur:

```bash
cat /etc/config/ecm  # Check if acceleration_engine is enabled
```

### Docker binary not found

The default path is `/mnt/docker_disk/mi_docker/docker-binaries/docker`. Search for it:

```bash
find / -name docker -type f 2>/dev/null
```

If it's in your PATH already, just use `docker` directly.

### VLESS URL not parsed correctly

The setup script accepts URLs in this format:

```
vless://UUID@SERVER:PORT?path=/somepath&host=SERVER.com#name
```

Manually extract values if parsing fails:

| Field | How to find | Example |
|-------|-------------|---------|
| UUID | After `vless://`, before `@` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| Server | After `@`, before `:` | `your-server.com` |
| Port | After `:`, before `/` | `443` |
| Path | After `path=` | `/` (or `/websocket`) |
| Host | After `host=` | Usually same as Server |

Then edit `config/xray-config.json` directly.

### xray config JSON errors

```bash
# Validate syntax
$DOCKER exec openwrt xray run -c /etc/xray/config.json
# Errors print to stdout

# Common issues:
# - Trailing comma after last array element
# - Unescaped quotes in heredoc
# - Wrong server address / port
```

### "Claude only available in certain regions"

This means the proxy server IP is geolocated to a region where Claude isn't available.

**Test with a SOCKS port (temporary):**

Add a SOCKS inbound to your xray config for testing:

```json
{
  "port": 12347,
  "protocol": "socks",
  "settings": { "auth": "noauth", "udp": true },
  "tag": "socks-test"
}
```

Then restart xray and test:

```bash
$DOCKER exec openwrt killall xray
$DOCKER exec -d openwrt xray run -c /etc/xray/config.json
sleep 2
$DOCKER exec openwrt sh -c "curl -s --socks5-hostname 127.0.0.1:12347 https://ipinfo.io/json" | grep -E "ip|country|city"
```

If `country` is not `US`, `JP`, `GB`, `KR`, or an EU country, your proxy server is in an unsupported region. Change your proxy subscription.

(Remove the SOCKS inbound after testing - it's an open proxy otherwise.)

### Active xray connections show but no data transfer

Some mobile apps (especially on iOS) use certificate pinning. The transparent proxy doesn't break TLS (it forwards the raw connection), so this shouldn't be an issue. If specific apps don't work, they may be using:

- ECH (Encrypted Client Hello) - SNI is encrypted, xray can't sniff
- Custom protocols over non-standard ports
- VPN/Tor built into the app

## How It Works

### iptables REDIRECT

The iptables `nat` table's PREROUTING chain intercepts all incoming TCP traffic on ports 80 and 443 and redirects it to xray's local port 12346:

```bash
iptables -t nat -A PREROUTING -p tcp -j XRAY
```

The XRAY chain:
1. **Returns** traffic destined for `192.168.31.0/24` (local subnet bypass)
2. **Redirects** port 80 and 443 to `127.0.0.1:12346`

### xray Transparent Proxy

xray's `dokodemo-door` inbound with `followRedirect: true`:
1. Uses `SO_ORIGINAL_DST` to recover the original destination from the REDIRECT
2. Sniffs the TLS SNI or HTTP Host header
3. Matches against routing rules (domain + IP)
4. Routes through the appropriate outbound (proxy or direct)

### Loop Prevention

xray's proxy outbound connections to the remote server are locally-generated (via OUTPUT chain), not forwarded (via PREROUTING). Since iptables rules are only in PREROUTING, xray's own outbound connections are NOT redirected back to xray. No special loop prevention needed.

## Reboot Persistence

The `/etc/rc.local` script on the host automatically:

1. Starts xray in the container
2. Waits for network interfaces
3. Applies iptables rules (IPv4 + IPv6)
4. Blocks QUIC traffic

See `config/rc.local` for the full template.

## License

MIT
