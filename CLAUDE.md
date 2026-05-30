# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Raspberry Pi WiFi hotspot + Captive Portal that displays hardware configuration when a client connects. The project deploys to a Pi via a single `sudo bash deploy/deploy.sh` command.

## Architecture

```
Client ──(WiFi wlan0)──▶ hostapd + dnsmasq (192.168.4.1)
                              │
                         nginx (:80/:443)
                              ├── static: / → www/index.html (hardware display)
                              └── proxy:  /api/* → 127.0.0.1:8080 (api/server.py)
                              │
                         eth0 ──(NAT)──▶ internet
```

Five systemd services: `hostapd`, `dnsmasq`, `hotspot-start`, `api-server`, `nginx`.

## Source vs Deploy

- `api/server.py` and `www/index.html` — **source files** (edit these)
- `deploy/files/server.py` and `deploy/files/index.html` — **deployment copies** (copied by deploy.sh to target Pi)
- After modifying `api/` or `www/`, sync to `deploy/files/` with `cp api/server.py deploy/files/` and `cp www/index.html deploy/files/`
- `deploy/templates/*.tpl` — nginx/hostapd/dnsmasq config templates with `{{VAR}}` placeholders, rendered by `deploy/deploy.sh`
- `deploy.sh` (root) — thin shim that calls `deploy/deploy.sh`

## Deploying

```bash
# Basic (from the Pi itself or via scp then ssh)
sudo bash deploy/deploy.sh --ssid MyHotspot --password MyPass123

# With all options
sudo bash deploy/deploy.sh --hostname mypi --ssid MyHotspot --password MyPass123 --ip 192.168.4.1
```

Requires `sudo` and a Debian-based Raspberry Pi OS. Dependencies installed automatically: `nginx hostapd dnsmasq libssl3t64 iproute2`.

## API

- `GET /api/hardware` — static hardware info (CPU, memory, storage, OS, network)
- `GET /api/info` — runtime state (hostname, uptime, CPU temp, memory/disk usage)

The API server is pure Python 3 stdlib (`http.server`), no pip packages needed. Binds on `127.0.0.1:8080`.

## Captive Portal

dnsmasq uses `address=/#/192.168.4.1` to wildcard-resolve all DNS queries to the Pi. nginx serves detection pages:
- iOS: `/hotspot-detect.html` → returns index.html
- Android: `/generate_204` → 204
- Windows: `/connecttest.txt` → "Success", `/ncsi.txt` → "Microsoft NCSI"

## CPU Support

Hardcoded in `server.py` (both `api/` and `deploy/files/`):

| Device | Chip | CPU part | Core |
|--------|------|----------|------|
| Pi 5 | BCM2712 | `0xd0b` | Cortex-A76 |
| Pi 4 | BCM2711 | `0xd08` | Cortex-A72 |

`get_chip()` in `server.py` also uses a board revision set (`bcm2712_boards`) to distinguish Pi 5 boards. Add new parts to `part_map` and board codes to `bcm2712_boards` when supporting new models.

## Claude Code Skill

`.claude/skills/pi-hotspot.md` contains a deployment skill that Claude Code auto-loads. It standardizes the deploy workflow: validate → run → verify → report.
