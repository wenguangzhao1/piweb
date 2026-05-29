# 树莓派 WiFi 热点 + 硬件配置展示

树莓派 WiFi 热点 + Captive Portal，连接后自动弹出设备硬件配置展示页面。

## 一键部署

将本项目拷贝到新树莓派，运行：

```bash
sudo bash deploy.sh --ssid MyHotspot --password MyPass123
```

脚本会自动完成：安装系统包、生成 SSL 证书、配置热点、部署项目、安装服务、启动服务。

### 参数

| 参数 | 环境变量 | 默认值 | 说明 |
|------|----------|--------|------|
| `--hostname` | `$DEPLOY_HOSTNAME` | 自动检测 | 主机名 |
| `--ssid` | `$DEPLOY_SSID` | `PiHotspot` | WiFi 名称 |
| `--password` | `$DEPLOY_PASSWORD` | 8 位随机 | WiFi 密码 |
| `--ip` | `$DEPLOY_HOTSPOT_IP` | `192.168.4.1` | 热点 IP |
| `--user` | `$DEPLOY_USER` | `$SUDO_USER` | 运行 API 的用户 |
| `--project-dir` | `$DEPLOY_PROJECT_DIR` | `/home/$user/zw` | 项目目录 |

### 使用方式

```bash
# 基本用法
sudo bash deploy.sh --ssid MyHotspot

# 完整参数
sudo bash deploy.sh --hostname mypi --ssid MyHotspot --password MyPass123 --ip 192.168.4.1

# 环境变量
sudo DEPLOY_HOSTNAME=mypi DEPLOY_SSID=MyHotspot bash deploy.sh

# 从 URL 下载执行（需提前托管 deploy.sh）
curl -sSL https://example.com/deploy.sh | sudo bash /dev/stdin --ssid MyHotspot

# 查看帮助
bash deploy.sh --help
```

### 获取脚本

- **git clone**：`git clone <repo> && cd zw && sudo bash deploy.sh --ssid MyHotspot`
- **scp**：`scp -r zw/ pi@<ip>:/home/pi/ && ssh pi@<ip> 'sudo bash /home/pi/zw/deploy.sh'`
- **curl**：将 deploy.sh 托管到可访问的 URL，一行命令执行

部署完成后连接 WiFi，浏览器打开 `http://192.168.4.1` 即可看到硬件配置页面。

---

## 架构

```
客户端 ──(WiFi)──▶ wlan0 (192.168.4.1)
                        │
              hostapd + dnsmasq
              (热点 + DHCP + DNS 通配)
                        │
              nginx (80/443) ──▶ /api/* → 127.0.0.1:8080
                        │                    │
              静态页面             python3 server.py
              (index.html)              (HTTP API)
                        │
              eth0 ──(NAT)──▶ 互联网
```

## 文件结构

```
/home/msj/zw/
├── deploy.sh          # 一键部署脚本（自包含，嵌入所有配置）
├── api/server.py      # Python3 HTTP API（无需外部依赖）
├── www/index.html     # 硬件配置展示首页
└── www/test.html      # 连通性测试页
```

## API 接口

### `GET /api/hardware` — 硬件配置

返回设备硬件信息（静态，重启后不变）：

```json
{
  "model": "Raspberry Pi 5 Model B Rev 1.1",
  "revision": "b04171",
  "serial": "<设备序列号>",
  "cpu": { "chip": "BCM2712", "cores": 4, "model": "Cortex-A76", "architecture": "AArch64 (ARMv8)" },
  "memory": { "total_kb": 2059008, "total": "2.0 GB" },
  "storage": [{ "name": "nvme0n1", "size": "238.5G", "type": "disk", "partitions": [...] }],
  "os": { "name": "Debian GNU/Linux 13 (trixie)", "kernel": "6.12.75+rpt-rpi-2712" },
  "network": { "eth0": { "state": "UP", "addrs": ["192.168.1.12/24"] }, "wlan0": { ... } }
}
```

### `GET /api/info` — 实时状态

返回运行时数据：

```json
{
  "hostname": "<主机名>",
  "uptime": "1d 2h 35m",
  "memory": "739/2010 MB",
  "disk": "7.4G",
  "cpu_temp": "52.9 °C",
  "client_ip": "192.168.4.5"
}
```

## 手动部署参考

> 推荐使用 `deploy.sh` 一键部署。以下仅为脚本内部逻辑的详细说明，供排查问题或手动操作参考。

### 1. 系统准备

- Debian 13 (trixie) arm64（或 Debian Bookworm）
- 安装依赖：`apt install nginx hostapd dnsmasq`
- SSL 自签证书：
  ```bash
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/ssl/private/captive.key \
    -out /etc/ssl/private/captive.crt \
    -subj "/CN=<主机名>"
  ```

### 2. 部署项目代码

```bash
# 默认安装到 /home/<user>/zw/
mkdir -p /home/<user>/zw/{api,www}
# 将 api/server.py 放入 <project-dir>/api/
# 将 www/index.html 和 www/test.html 放入 <project-dir>/www/
```

### 3. 配置 WiFi 热点

**/etc/hostapd/hostapd.conf**
```
interface=wlan0
driver=nl80211
ssid=<你的 SSID>
hw_mode=g
channel=7
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=<你的密码>
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
```

**/etc/dnsmasq.conf**
```
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
dhcp-option=3,192.168.4.1
dhcp-option=6,192.168.4.1
server=8.8.8.8
address=/#/192.168.4.1    # 通配 DNS → Captive Portal
```

**/etc/default/hostapd** 设置 `DAEMON_CONF="/etc/hostapd/hostapd.conf"`。

### 4. 配置 nginx

将 `/etc/nginx/sites-available/default` 替换为以下配置，关键点是：
- 根目录指向 `<project-dir>/www`
- `/api/` 反代到 `127.0.0.1:8080`
- Captive Portal 专用路径：`/hotspot-detect.html`、`/generate_204`、`/connecttest.txt`、`/ncsi.txt`
- 443 端口 SSL 配置同上

### 5. systemd 服务

**/etc/systemd/system/api-server.service**
```ini
[Unit]
Description=API Server for Hotspot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<user>
WorkingDirectory=<project-dir>/api
ExecStart=/usr/bin/python3 <project-dir>/api/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```
`systemctl enable api-server.service && systemctl start api-server.service`

**/etc/systemd/system/hotspot-start.service**
```ini
[Unit]
Description=Start WiFi Hotspot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rfkill unblock wifi && ip link set wlan0 up && hostapd -B /etc/hostapd/hostapd.conf && sleep 1 && dnsmasq && echo 1 > /proc/sys/net/ipv4/ip_forward && nft add table ip nat 2>/dev/null && nft add chain ip nat postrouting "{ type nat hook postrouting priority 100; policy accept; }" && nft add rule ip nat postrouting oifname "eth0" masquerade && nft add chain ip nat forward "{ type filter hook forward priority 0; policy accept; }" && nft add rule ip nat forward iifname "wlan0" accept && nft add rule ip nat forward oifname "wlan0" ct state established,related accept'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
`systemctl enable hotspot-start.service && systemctl start hotspot-start.service`

**nginx**：`systemctl enable nginx && systemctl restart nginx`

## Captive Portal 原理

| 平台 | 检测 URL | 响应 |
|------|----------|------|
| iOS | `/hotspot-detect.html` | 返回完整 HTML 页面（触发弹出浏览器） |
| Android | `/generate_204` | HTTP 204（表示正常联网） |
| Windows | `/connecttest.txt` | `Success` |
| Windows | `/ncsi.txt` | `Microsoft NCSI` |

配合 dnsmasq `address=/#/192.168.4.1` 通配 DNS，任何域名请求都会被路由到本机 nginx。

## 自定义配置

使用 `deploy.sh` 时，以下参数通过命令行传入，无需修改源码：

| 变量 | deploy.sh 参数 | 默认值 |
|------|---------------|--------|
| 主机名 | `--hostname` | 自动检测 |
| SSID | `--ssid` | `PiHotspot` |
| WiFi 密码 | `--password` | 8 位随机 |
| 热点 IP | `--ip` | `192.168.4.1` |
| 运行用户 | `--user` | `$SUDO_USER` |

### CPU 型号

`server.py` 中硬编码了 CPU 信息，需要支持不同型号时修改源码：

| 设备 | 芯片 | CPU part | 核心 |
|------|------|----------|------|
| Pi 5 | BCM2712 | `0xd0b` | Cortex-A76 |
| Pi 4 | BCM2711 | `0xd08` | Cortex-A72 |

修改位置：`api/server.py` 的 `part_map` 和 `"chip"` 字段。
