# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

Raspberry Pi WiFi hotspot + Captive Portal that displays hardware configuration when a client connects. The `deploy/` directory is a self-contained bundle meant to be copied to a fresh Pi, then `sudo bash deploy/deploy.sh` provisions everything.

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

## Source vs Deploy — Critical Workflow

- `api/server.py` and `www/index.html` — **source files** (edit these during development)
- `deploy/files/server.py`, `deploy/files/index.html`, `deploy/files/test.html` — **deployment copies** (shipped to Pi)
- `deploy/templates/*.tpl` — dnsmasq/nginx config templates with `{{VAR}}` placeholders, rendered by `deploy.sh` via `sed`; hostapd config is written inline (heredoc)
- `deploy.sh` (root) — thin shim that just `exec`s `deploy/deploy.sh`

**After editing `api/` or `www/`, sync to `deploy/files/`:**
```bash
cp api/server.py deploy/files/
cp www/index.html deploy/files/
cp www/test.html deploy/files/
```
The deploy script does NOT copy from `api/` or `www/` — it only uses `deploy/files/`.

The entire `deploy/` directory is designed to be scp'd to a fresh Pi as the only thing that needs transferring.

## Deploying

```bash
# Basic
sudo bash deploy/deploy.sh --ssid MyHotspot --password MyPass123

# With all options
sudo bash deploy/deploy.sh --hostname mypi --ssid MyHotspot --password MyPass123 --ip 192.168.4.1 --interface wlan0 --channel 7

# Via environment variables
sudo DEPLOY_HOSTNAME=mypi DEPLOY_SSID=MyHotspot bash deploy/deploy.sh
```

| Param | Env Var | Default | Description |
|-------|---------|---------|-------------|
| `--hostname` | `$DEPLOY_HOSTNAME` | auto-detect | Device hostname |
| `--ssid` | `$DEPLOY_SSID` | `PiHotspot` | WiFi SSID |
| `--password` | `$DEPLOY_PASSWORD` | (none) | WiFi password (empty = open) |
| `--ip` | `$DEPLOY_HOTSPOT_IP` | `192.168.4.1` | Hotspot IP |
| `--user` | `$DEPLOY_USER` | `$SUDO_USER` | API server run-as user |
| `--project-dir` | `$DEPLOY_PROJECT_DIR` | `/home/$user/zw` | Install location |
| `--interface` | `$DEPLOY_INTERFACE` | `wlan0` | WiFi interface |
| `--channel` | `$DEPLOY_CHANNEL` | `7` | WiFi channel |

## Deploy Script Phases

1. **System check** — reads `/etc/os-release`, `/sys/firmware/devicetree/base/model`, verifies wlan0 exists
2. **Package install** — `nginx hostapd dnsmasq libssl3t64 iproute2` via apt
3. **SSL cert** — self-signed x509 at `/etc/ssl/private/captive.{crt,key}` (10-year, skips if exists)
4. **NetworkManager release** — writes `/etc/NetworkManager/conf.d/unmanage-wlan0.conf` to free wlan0
5. **Config generation** — writes hostapd config inline (heredoc), renders dnsmasq/nginx templates via `sed`
6. **File deploy** — copies `deploy/files/*` to `DEPLOY_PROJECT_DIR`
7. **hostapd unmask + home dir fix** — `systemctl unmask hostapd`, `chmod o+x ~user` for www-data traversal
8. **systemd services** — creates `api-server.service` and `hotspot-start.service` inline (not templated)
9. **Service startup** — restarts all 5 services, verifies AP mode and API

## API

- `GET /api/hardware` — static hardware info (CPU, memory, storage, OS, network)
- `GET /api/info` — runtime state (hostname, uptime, CPU temp, memory/disk usage, client IP)

Both return JSON with `Access-Control-Allow-Origin: *`. API server is pure Python 3 stdlib (`http.server`), binds `127.0.0.1:8080`, logs suppressed (`log_message` no-op).

## Captive Portal

dnsmasq uses `address=/#/192.168.4.1` to wildcard-resolve ALL DNS queries to the Pi. nginx serves platform detection endpoints on both HTTP and HTTPS:

| Platform | URL | Response |
|----------|-----|----------|
| iOS | `/hotspot-detect.html` | Returns full index.html HTML (triggers browser popup) |
| Android | `/generate_204` | HTTP 204 |
| Windows | `/connecttest.txt` | `Success` |
| Windows | `/ncsi.txt` | `Microsoft NCSI` |

## CPU Support

Hardcoded in `server.py` (both `api/` and `deploy/files/` must stay in sync):

| Device | Chip | CPU part | Core |
|--------|------|----------|------|
| Pi 5 | BCM2712 | `0xd0b` | Cortex-A76 |
| Pi 4 | BCM2711 | `0xd08` | Cortex-A72 |

`get_chip()` uses a board revision set (`bcm2712_boards`) to distinguish Pi 5: `{'d05', 'e05', 'c06', 'd06', 'e06', 'c07', 'd07', 'e07'}`. Add new parts to `part_map` and board codes to `bcm2712_boards` when supporting new models.

## Troubleshooting

- **wlan0 type=managed (not AP)** — hostapd started but interface not in AP mode. Fix: `systemctl restart hostapd.service`, wait 2s, verify `iw dev wlan0 info` shows `type AP`
- **dnsmasq bind error** — system dnsmasq already running. hotspot-start.service does NOT start dnsmasq (only network/NAT)
- **No SSID visible** — restart hostapd.service; check `iw dev wlan0 info`
- **NAT not working** — nft rules duplicated. Fix: `nft flush ruleset`, restart hotspot-start.service
- **hostapd masked** — `systemctl unmask hostapd.service` (deploy.sh handles this, but manual fix may be needed)
- **403 on web page** — user home dir not world-executable. Fix: `chmod o+x ~$user` (deploy.sh handles this)
- **Source/deploy out of sync** — always `diff` or `cp` from `api/`/`www/` to `deploy/files/` after edits

## Claude Code Skill

`.claude/skills/pi-hotspot.md` contains the deployment skill. Claude Code auto-loads it when deploying. It standardizes: validate environment → run deploy → verify 5 services → report.

## Language

UI text and deploy script output are in Chinese (zh-CN). The HTML page title is "硬件配置", JavaScript uses `zh-CN` locale for dates. API responses use English keys.
