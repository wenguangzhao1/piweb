---
name: pi-hotspot
description: Deploy WiFi hotspot + hardware info display to a Raspberry Pi
---

Deploy a WiFi hotspot with captive portal and hardware configuration display page to a Raspberry Pi.

## Steps

1. **Validate environment** — verify it's a Raspberry Pi with wlan0, is Debian-based
2. **Run deploy** — execute `sudo bash deploy/deploy.sh` with parameters
3. **Verify** — check all 5 services are active (hostapd, dnsmasq, hotspot-start, api-server, nginx)
4. **Report** — print SSID, IP, and access URL

## Parameters

| Param | Default | Description |
|-------|---------|-------------|
| `--ssid` | PiHotspot | WiFi SSID |
| `--password` | (none) | WiFi password (empty = open network) |
| `--ip` | 192.168.4.1 | Hotspot IP |
| `--hostname` | (auto-detect) | Device hostname |
| `--user` | $SUDO_USER | API server run-as user |
| `--project-dir` | /home/$user/zw | Install location |

## Architecture

```
Client ──(WiFi wlan0)──▶ hostapd + dnsmasq (192.168.4.1)
                              │
                         nginx (:80/:443)
                              ├── static: / → index.html (hardware display)
                              └── proxy:  /api/* → 127.0.0.1:8080 (server.py)
                              │
                         eth0 ──(NAT)──▶ 互联网
```

## Service Checklist

- [ ] `hostapd.service` — WiFi AP on wlan0
- [ ] `dnsmasq.service` — DHCP + wildcard DNS (captive portal)
- [ ] `hotspot-start.service` — IP assignment, IP forwarding, NAT rules
- [ ] `api-server.service` — Python HTTP API on 127.0.0.1:8080
- [ ] `nginx` — static files + API proxy, captive portal detection pages

## Common Issues

- **wlan0 type=managed (not AP)** — kill hostapd, bring down wlan0, restart hostapd.service
- **dnsmasq bind error** — system dnsmasq already running; hotspot-start.service must NOT start dnsmasq itself
- **No SSID visible** — hostapd started but interface not in AP mode; restart hostapd.service
- **NAT not working** — nft rules duplicated; flush and re-add

## Deploy Command

```bash
sudo bash deploy/deploy.sh --ssid <SSID> --password <PASS> [--ip <IP>] [--hostname <HOST>]
```

## Post-deploy Verification

```bash
# All 5 services must be active
systemctl is-active hostapd.service dnsmasq.service hotspot-start.service api-server.service nginx.service

# wlan0 should have IP and be in AP mode
ip addr show wlan0    # 192.168.4.1/24
iw dev wlan0 info     # type AP

# API and web UI
curl -s http://localhost/api/hardware | python3 -m json.tool | head -10
curl -s http://localhost/ | head -5
```
