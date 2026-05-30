# 树莓派 WiFi 热点 + 硬件配置展示

树莓派 WiFi 热点 + Captive Portal，连接后自动弹出设备硬件配置展示页面。

## 一键部署

将本项目拷贝到新树莓派，运行：

```bash
sudo bash deploy/deploy.sh --ssid MyHotspot --password MyPass123
```

脚本会自动完成：安装系统包、生成 SSL 证书、配置热点、部署项目、安装服务、启动服务。

### 参数

| 参数 | 环境变量 | 默认值 | 说明 |
|------|----------|--------|------|
| `--hostname` | `$DEPLOY_HOSTNAME` | 自动检测 | 主机名 |
| `--ssid` | `$DEPLOY_SSID` | `PiHotspot` | WiFi 名称 |
| `--password` | `$DEPLOY_PASSWORD` | (none) | WiFi 密码（空=开放网络） |
| `--ip` | `$DEPLOY_HOTSPOT_IP` | `192.168.4.1` | 热点 IP |
| `--user` | `$DEPLOY_USER` | `$SUDO_USER` | 运行 API 的用户 |
| `--project-dir` | `$DEPLOY_PROJECT_DIR` | `/home/$user/zw` | 项目目录 |
| `--interface` | `$DEPLOY_INTERFACE` | `wlan0` | WiFi 接口 |
| `--channel` | `$DEPLOY_CHANNEL` | `7` | WiFi 信道 |

### 使用方式

```bash
# 基本用法
sudo bash deploy/deploy.sh --ssid MyHotspot

# 完整参数
sudo bash deploy/deploy.sh --hostname mypi --ssid MyHotspot --password MyPass123 --ip 192.168.4.1

# 环境变量
sudo DEPLOY_HOSTNAME=mypi DEPLOY_SSID=MyHotspot bash deploy/deploy.sh

# 兼容入口（旧版调用方式仍支持）
sudo bash deploy.sh --ssid MyHotspot
```

部署完成后连接 WiFi，浏览器打开 `http://192.168.4.1` 即可看到硬件配置页面。

---

## 架构

```
客户端 ──(WiFi wlan0)──▶ hostapd + dnsmasq (192.168.4.1)
                              │
                         nginx (:80/:443)
                              ├── static: / → index.html (硬件配置页)
                              └── proxy:  /api/* → 127.0.0.1:8080 (server.py)
                              │
                         eth0 ──(NAT)──▶ 互联网
```

### 服务清单

| 服务 | 端口 | 说明 |
|------|------|------|
| `hostapd.service` | - | WiFi AP，广播 SSID |
| `dnsmasq.service` | UDP 67/53 | DHCP + DNS 通配（Captive Portal） |
| `hotspot-start.service` | - | wlan0 IP、IP 转发、NAT 规则 |
| `api-server.service` | 127.0.0.1:8080 | Python HTTP API |
| `nginx` | 80/443 | 静态文件 + API 反代 |

## 文件结构

```
/home/msj/zw/
├── .claude/
│   └── skills/
│       └── pi-hotspot.md      # Claude Code Skill 定义
├── deploy/                    # 自包含部署包
│   ├── deploy.sh              # 一键部署脚本
│   ├── files/
│   │   ├── server.py          # API 服务器
│   │   ├── index.html         # 硬件配置页
│   │   └── test.html          # 连通性测试
│   └── templates/
│       ├── hostapd.conf.tpl   # 热点配置模板
│       ├── dnsmasq.conf.tpl   # DHCP 配置模板
│       └── nginx.conf.tpl     # Web 服务器配置模板
├── api/
│   └── server.py              # 源码（部署源文件）
├── www/
│   ├── index.html             # UI 页面（部署源文件）
│   └── test.html              # 测试页
├── deploy.sh                  # 兼容入口 → deploy/deploy.sh
├── README.md
└── .gitignore
```

## API 接口

### `GET /api/hardware` — 硬件配置

返回设备硬件信息（静态）：

```json
{
  "model": "Raspberry Pi 5 Model B Rev 1.0",
  "serial": "708ffe5dbe43a1d8",
  "cpu": { "chip": "BCM2712", "cores": 4, "model": "Cortex-A76", "architecture": "AArch64 (ARMv8)" },
  "memory": { "total_kb": 8251776, "total": "7.9 GB" },
  "storage": [...],
  "os": { "name": "Debian GNU/Linux 13 (trixie)", "kernel": "6.18.29+rpt-rpi-2712" },
  "network": { "eth0": { "state": "UP", "addrs": ["192.168.1.13/24"] } }
}
```

### `GET /api/info` — 实时状态

返回运行时数据：

```json
{
  "hostname": "smp5b05",
  "uptime": "0d 0h 8m",
  "memory": "887/8058 MB",
  "disk": "33G",
  "cpu_temp": "58.4 °C",
  "client_ip": "192.168.4.5"
}
```

## Claude Code Skill

在部署到新树莓派时，Claude Code 会自动加载 `.claude/skills/pi-hotspot.md` 中的 skill 定义，按照标准化流程执行部署和验证。

## Captive Portal 原理

| 平台 | 检测 URL | 响应 |
|------|----------|------|
| iOS | `/hotspot-detect.html` | 返回完整 HTML（触发弹出浏览器） |
| Android | `/generate_204` | HTTP 204 |
| Windows | `/connecttest.txt` | `Success` |
| Windows | `/ncsi.txt` | `Microsoft NCSI` |

配合 dnsmasq `address=/#/192.168.4.1` 通配 DNS，任何域名请求都会被路由到本机 nginx。

## 排查问题

### wlan0 没有广播 SSID

```bash
# 检查 wlan0 是否为 AP 模式
iw dev wlan0 info   # 应显示 type AP

# 如果是 managed 模式，重启 hostapd
sudo systemctl restart hostapd.service
sleep 2
iw dev wlan0 info
```

### dnsmasq 启动失败

系统 dnsmasq 可能已占用端口。`hotspot-start.service` 不再重复启动 dnsmasq，只负责网络和 NAT 配置。

### NAT 不通

```bash
# 检查 IP 转发
cat /proc/sys/net/ipv4/ip_forward   # 应为 1

# 检查 NAT 规则
sudo nft list table ip nat

# 清理并重建
sudo nft flush ruleset
# 然后重启 hotspot-start.service
sudo systemctl restart hotspot-start.service
```

### CPU 型号支持

`server.py` 中硬编码了 CPU 信息，扩展时修改：

| 设备 | 芯片 | CPU part | 核心 |
|------|------|----------|------|
| Pi 5 | BCM2712 | `0xd0b` | Cortex-A76 |
| Pi 4 | BCM2711 | `0xd08` | Cortex-A72 |

修改位置：`api/server.py` 的 `part_map` 和 `get_chip()` 函数。
