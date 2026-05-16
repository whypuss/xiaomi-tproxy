# xiaomi-tproxy

A transparent proxy system for Xiaomi routers (OpenWrt-based firmware) that routes AI service traffic through a VLESS+WS+TLS proxy using xray-core in Docker.

All WiFi devices on the LAN automatically get proxied access to ChatGPT, Claude, Gemini, DeepSeek, Perplexity, and more - no per-device configuration needed.

## Quick Links

- [README](README.md) - Full documentation
- [config/xray-config.json](config/xray-config.json) - xray configuration template
- [config/rc.local](config/rc.local) - Reboot persistence template
- [scripts/setup.sh](scripts/setup.sh) - One-click setup script
- [scripts/verify.sh](scripts/verify.sh) - Verification and diagnostics

## Architecture

```
iPhone/PC → Router(iptables REDIRECT) → xray:12346 → SNI sniffing
  ├─ AI domains → VLESS proxy (Tokyo/JP)
  └─ Other → direct
```

## Prerequisites

- Xiaomi AX3600/AX3200/AX1800/AX9000 with MiWiFi OpenWrt-based firmware
- SSH enabled on router (root@192.168.31.1)
- Docker container with `--network host --privileged` flags
- xray-core installed in container
- VLESS+WS+TLS proxy subscription

## Quick Start

```bash
# Clone and deploy
git clone https://github.com/whypuss/xiaomi-tproxy.git
cd xiaomi-tproxy

# Copy config, edit with your VLESS details
vim config/xray-config.json

# Run setup on router
ssh root@192.168.31.1
./scripts/setup.sh
```

## Domain Routing

| Group | Domains |
|-------|---------|
| OpenAI | chatgpt.com, openai.com, api.openai.com, openaicom.imgix.net |
| Claude/Anthropic | claude.ai, platform.claude.ai, code.claude.ai, anthropic.com, api.anthropic.com |
| Google AI | aistudio.google.com, ai.google.dev, makersuite.google.com, googleapis.com, bard.google.com, gemini.google.com |
| Other AI | copilot.microsoft.com, deepseek.com, perplexity.ai, x.com, grok.com, notebooklm.google.com |
| IP check | ip.sb, ipinfo.io |
| Keywords | chatgpt, claude, anthropic, openai, google-ai, gemini |

## Troubleshooting

See [README.md - Troubleshooting](README.md#troubleshooting) for common issues including QUIC bypass, iptables permissions, and region restrictions.
