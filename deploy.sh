#!/usr/bin/env bash
# ============================================================
# 树莓派 WiFi 热点 + 硬件配置展示 — 一键部署脚本
#
# 使用方式:
#   sudo bash deploy.sh --hostname mypi --ssid MyHotspot --password mypass
#   sudo bash deploy.sh --ssid MyHotspot
#   curl -sSL <url> | sudo bash /dev/stdin --ssid MyHotspot
#
# 参数 (CLI 或环境变量):
#   --hostname   DEPLOY_HOSTNAME    主机名 (默认: 自动检测)
#   --ssid       DEPLOY_SSID        WiFi 名称 (默认: PiHotspot)
#   --password   DEPLOY_PASSWORD    WiFi 密码 (默认: 8 位随机)
#   --ip         DEPLOY_HOTSPOT_IP  热点 IP (默认: 192.168.4.1)
#   --user       DEPLOY_USER        运行用户 (默认: $SUDO_USER)
#   --project-dir DEPLOY_PROJECT_DIR 项目目录 (默认: /home/$user/zw)
# ============================================================
set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ---------- 参数解析 ----------
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-}"
DEPLOY_SSID="${DEPLOY_SSID:-PiHotspot}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-}"
DEPLOY_HOTSPOT_IP="${DEPLOY_HOTSPOT_IP:-192.168.4.1}"
DEPLOY_USER="${DEPLOY_USER:-${SUDO_USER:-pi}}"
DEPLOY_PROJECT_DIR="${DEPLOY_PROJECT_DIR:-/home/${DEPLOY_USER}/zw}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    DEPLOY_HOSTNAME="$2";    shift 2 ;;
    --ssid)        DEPLOY_SSID="$2";        shift 2 ;;
    --password)    DEPLOY_PASSWORD="$2";    shift 2 ;;
    --ip)          DEPLOY_HOTSPOT_IP="$2";  shift 2 ;;
    --user)        DEPLOY_USER="$2";        shift 2 ;;
    --project-dir) DEPLOY_PROJECT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "用法: sudo bash deploy.sh [--hostname H] [--ssid SSID] [--password PASS] [--ip IP] [--user U] [--project-dir DIR]"
      echo ""
      echo "选项:"
      echo "  --hostname   主机名 (默认: 自动检测)"
      echo "  --ssid       WiFi 名称 (默认: PiHotspot)"
      echo "  --password   WiFi 密码 (默认: 8 位随机)"
      echo "  --ip         热点 IP (默认: 192.168.4.1)"
      echo "  --user       运行用户 (默认: \$SUDO_USER)"
      echo "  --project-dir 项目目录 (默认: /home/\$user/zw)"
      echo "  -h, --help   显示帮助"
      exit 0
      ;;
    *) die "未知参数: $1 (使用 -h 查看帮助)" ;;
  esac
done

# ---------- 默认值处理 ----------
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-$(hostname)}"
# 开放热点，无需密码

if [[ -z "$DEPLOY_USER" ]]; then
  die "无法确定运行用户，请使用 --user 指定"
fi

DEPLOY_PROJECT_DIR="${DEPLOY_PROJECT_DIR%/}"
PROJECT_DIR=$(dirname "$DEPLOY_PROJECT_DIR")
PROJECT_NAME=$(basename "$DEPLOY_PROJECT_DIR")

# ---------- 权限检查 ----------
if [[ $EUID -ne 0 ]]; then
  die "请使用 sudo 运行此脚本 (sudo bash deploy.sh)"
fi

# ---------- 系统检查 ----------
info "检查系统环境..."
if [[ ! -f /etc/os-release ]]; then
  warn "无法检测操作系统，继续尝试..."
else
  . /etc/os-release
  case "${ID:-}" in
    debian|raspbian|ubuntu|rpi) ok "系统: ${PRETTY_NAME:-$ID}" ;;
    *) warn "非 Debian 系系统 (ID=$ID)，可能不兼容" ;;
  esac
fi

if [[ ! -d /proc/device-tree ]] && [[ ! -f /sys/firmware/devicetree/base/model ]]; then
  warn "未检测到树莓派设备树，请确认是树莓派设备"
fi

# ---------- 安装依赖 ----------
info "安装系统包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
for pkg in nginx hostapd dnsmasq libssl3t64 iproute2; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "$pkg 已安装"
  else
    apt-get install -y -qq "$pkg" >/dev/null 2>&1 && ok "已安装 $pkg" || warn "$pkg 安装失败，继续..."
  fi
done

# ---------- 释放 wlan0 控制权 ----------
info "配置 NetworkManager 忽略 wlan0..."
nmcli dev set wlan0 managed no 2>/dev/null || true
cat > /etc/NetworkManager/conf.d/unmanage-wlan0.conf << 'NMEOF'
[device-wlan0]
match-device=interface-name:wlan0
unmanaged=1
NMEOF
systemctl reload NetworkManager 2>/dev/null || true
ok "wlan0 已从 NetworkManager 释放"

# ---------- 生成 SSL 证书 ----------
SSL_DIR="/etc/ssl/private"
if [[ ! -f "$SSL_DIR/captive.crt" ]] || [[ ! -f "$SSL_DIR/captive.key" ]]; then
  info "生成自签 SSL 证书..."
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$SSL_DIR/captive.key" \
    -out "$SSL_DIR/captive.crt" \
    -subj "/CN=${DEPLOY_HOSTNAME}" 2>/dev/null
  ok "SSL 证书已生成"
else
  ok "SSL 证书已存在"
fi

# ---------- 写 hostapd 配置 ----------
info "配置 WiFi 热点..."
cat > /etc/hostapd/hostapd.conf << HOSTAPDEOF
interface=wlan0
driver=nl80211
ssid=${DEPLOY_SSID}
hw_mode=g
channel=7
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
HOSTAPDEOF

# 确保 DAEMON_CONF 已设置
if grep -q '^DAEMON_CONF' /etc/default/hostapd 2>/dev/null; then
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

# ---------- 写 dnsmasq 配置 ----------
HOTSPOT_SUBNET="${DEPLOY_HOTSPOT_IP%.*}"
cat > /etc/dnsmasq.conf << DNSMASQEOF
interface=wlan0
dhcp-range=${HOTSPOT_SUBNET}.2,${HOTSPOT_SUBNET}.20,255.255.255.0,24h
dhcp-option=3,${DEPLOY_HOTSPOT_IP}
dhcp-option=6,${DEPLOY_HOTSPOT_IP}
server=8.8.8.8
address=/#/${DEPLOY_HOTSPOT_IP}
DNSMASQEOF

# ---------- 部署项目文件 ----------
info "部署项目到 ${DEPLOY_PROJECT_DIR}..."
mkdir -p "${DEPLOY_PROJECT_DIR}/api" "${DEPLOY_PROJECT_DIR}/www"

# --- server.py ---
cat > "${DEPLOY_PROJECT_DIR}/api/server.py" << 'PYEOF'
#!/usr/bin/env python3
import json, subprocess, socket, os
from http.server import HTTPServer, BaseHTTPRequestHandler

def run(cmd):
    return subprocess.check_output(cmd, shell=True).decode().strip()

def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except:
        return ''

def parse_cpuinfo():
    info = {}
    cores = 0
    revision = ''
    try:
        for line in open('/proc/cpuinfo'):
            if line.startswith('processor'):
                cores += 1
            elif line.startswith('BogoMIPS'):
                info['bogo_mips'] = line.split(':')[1].strip()
            elif line.startswith('CPU part'):
                part = line.split(':')[1].strip()
                part_map = {'0xd0b': 'Cortex-A76', '0xd08': 'Cortex-A72'}
                info['cpu_model'] = part_map.get(part, 'Unknown')
            elif line.startswith('CPU implementer'):
                impl = line.split(':')[1].strip()
                impl_map = {'0x41': 'ARM'}
                info['cpu_arch'] = impl_map.get(impl, 'Unknown')
            elif line.startswith('Revision'):
                revision = line.split(':')[1].strip()
    except:
        pass
    info['cores'] = cores
    info['revision'] = revision
    return info

def get_chip(model, revision):
    bcm2712_boards = {'d05', 'e05', 'c06', 'd06', 'e06', 'c07', 'd07', 'e07'}
    board = revision[:3].lower() if revision else ''
    if board in bcm2712_boards or '5 Model' in model:
        return 'BCM2712'
    return 'BCM2711'

def get_arch():
    try:
        arch = run('uname -m').strip()
        arch_map = {'aarch64': 'AArch64 (ARMv8)', 'armv7l': 'ARMv7', 'armv6l': 'ARMv6', 'x86_64': 'x86_64'}
        return arch_map.get(arch, arch)
    except:
        return 'Unknown'

def get_hardware():
    cpu_info = parse_cpuinfo()
    model = (read_file('/proc/device-tree/model') or 'Unknown').replace('\x00', '')
    serial = ''
    try:
        for line in open('/proc/cpuinfo'):
            if line.startswith('Serial'):
                serial = line.split(':')[1].strip()
                break
    except:
        pass

    mem_kb = int(read_file('/proc/meminfo').split('\n')[0].split(':')[1].strip().split()[0])
    mem_gb = mem_kb / 1024 / 1024

    kernel = read_file('/proc/version').split(' ')[2] if read_file('/proc/version') else 'Unknown'

    os_name = 'Unknown'
    try:
        for line in read_file('/etc/os-release').split('\n'):
            if line.startswith('PRETTY_NAME='):
                os_name = line.split('=', 1)[1].strip('"')
                break
    except:
        pass

    storage_devices = []
    try:
        lsblk = run("lsblk -J -o NAME,SIZE,TYPE,MOUNTPOINT")
        data = json.loads(lsblk)
        for dev in data.get('blockdevices', []):
            dtype = dev.get('type', '')
            if dtype == 'disk':
                s = {'name': dev['name'], 'size': dev['size'], 'type': dtype}
                children = []
                for child in dev.get('children', []):
                    children.append({'name': child['name'], 'size': child['size'], 'mountpoint': child.get('mountpoint', '')})
                s['partitions'] = children
                storage_devices.append(s)
    except:
        pass

    interfaces = {}
    try:
        for line in run("ip -br addr show").split('\n'):
            parts = line.split()
            if len(parts) >= 3:
                iface = parts[0]
                if iface != 'lo':
                    interfaces[iface] = {
                        'state': parts[1],
                        'addrs': [p for p in parts[2:] if '/' in p]
                    }
    except:
        pass

    revision = cpu_info.get('revision', '')

    data = {
        "model": model,
        "revision": revision,
        "serial": serial,
        "cpu": {
            "chip": get_chip(model, revision),
            "cores": cpu_info.get('cores', 0),
            "model": cpu_info.get('cpu_model', 'Unknown'),
            "architecture": get_arch(),
            "bogo_mips": cpu_info.get('bogo_mips', 'Unknown'),
        },
        "memory": {
            "total_kb": mem_kb,
            "total": f"{mem_gb:.1f} GB",
        },
        "storage": storage_devices,
        "os": {
            "name": os_name,
            "kernel": kernel,
        },
        "network": interfaces,
    }
    return data

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/info':
            hostname = run('hostname')
            uptime_s = float(run("cut -d. -f1 /proc/uptime"))
            days, rem = divmod(int(uptime_s), 86400)
            hours, rem = divmod(rem, 3600)
            mins, _ = divmod(rem, 60)
            uptime_str = f"{days}d {hours}h {mins}m"

            mem = run("free -m | awk 'NR==2{printf \"%.0f/%.0f MB\", $3, $2}'")
            disk = run("df -h / | awk 'NR==2{print $3}'")

            try:
                temp_c = float(run("cat /sys/class/thermal/thermal_zone0/temp")) / 1000
                temp_str = f"{temp_c:.1f} °C"
            except:
                temp_str = "N/A"

            client_ip = self.client_address[0]

            data = {
                "hostname": hostname,
                "uptime": uptime_str,
                "memory": mem,
                "disk": disk,
                "cpu_temp": temp_str,
                "client_ip": client_ip,
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        elif self.path == '/api/hardware':
            data = get_hardware()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"not found"}')

    def log_message(self, fmt, *args):
        pass

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 8080), Handler)
    print('API server running on :8080')
    server.serve_forever()
PYEOF

# --- index.html ---
# 使用占位符 + sed 替换实现变量注入
cat > "${DEPLOY_PROJECT_DIR}/www/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>__DEPLOY_HOSTNAME__ - 硬件配置</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
            color: #e0e0e0;
            min-height: 100vh;
            padding: 24px 16px 40px;
        }
        .container { max-width: 640px; margin: 0 auto; }
        .header { text-align: center; margin-bottom: 28px; }
        .header h1 { font-size: 1.8em; color: #fff; margin-bottom: 4px; }
        .header .model { color: #8ecfff; font-size: 1.05em; }
        .section {
            background: rgba(255,255,255,0.06);
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 16px;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.08);
        }
        .section h2 {
            font-size: 1em; color: #8ecfff; margin-bottom: 14px;
            display: flex; align-items: center; gap: 8px;
        }
        .row {
            display: flex; justify-content: space-between;
            padding: 8px 0;
            border-bottom: 1px solid rgba(255,255,255,0.04);
        }
        .row:last-child { border-bottom: none; }
        .row .label { color: #999; font-size: 0.9em; }
        .row .value {
            color: #fff; font-weight: 600; font-size: 0.95em;
            text-align: right; max-width: 55%; word-break: break-all;
        }
        .badge {
            display: inline-block; padding: 2px 8px;
            border-radius: 6px; font-size: 0.8em; font-weight: 600;
        }
        .badge-green { background: rgba(76,175,80,0.2); color: #4caf50; }
        .badge-blue { background: rgba(142,207,255,0.15); color: #8ecfff; }
        .status-dot {
            display: inline-block; width: 8px; height: 8px;
            border-radius: 50%; margin-right: 4px; vertical-align: middle;
        }
        .status-up { background: #4caf50; box-shadow: 0 0 6px #4caf50; }
        .status-down { background: #f44336; box-shadow: 0 0 6px #f44336; }
        .error {
            color: #f44336; text-align: center; padding: 20px;
            background: rgba(244,67,54,0.1); border-radius: 8px; margin: 16px 0;
        }
        footer { text-align: center; color: #555; font-size: 0.8em; margin-top: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>__DEPLOY_HOSTNAME__</h1>
            <div class="model" id="model">加载中...</div>
        </div>

        <div id="content" style="display:none">
            <div class="section">
                <h2>&#x1F50C; 处理器</h2>
                <div class="row"><span class="label">芯片</span><span class="value" id="cpu-chip">-</span></div>
                <div class="row"><span class="label">核心</span><span class="value" id="cpu-cores">-</span></div>
                <div class="row"><span class="label">架构</span><span class="value" id="cpu-arch">-</span></div>
            </div>
            <div class="section">
                <h2>&#x1F4BE; 内存与存储</h2>
                <div class="row"><span class="label">内存</span><span class="value" id="mem-total">-</span></div>
                <div class="row"><span class="label">存储</span><span class="value" id="storage-list">-</span></div>
            </div>
            <div class="section">
                <h2>&#x1F310; 网络</h2>
                <div class="row"><span class="label">以太网</span><span class="value" id="net-eth">-</span></div>
                <div class="row"><span class="label">WiFi 热点</span><span class="value" id="net-wlan">-</span></div>
            </div>
            <div class="section">
                <h2>&#x2699; 系统信息</h2>
                <div class="row"><span class="label">操作系统</span><span class="value" id="os-name">-</span></div>
                <div class="row"><span class="label">内核版本</span><span class="value" id="os-kernel">-</span></div>
                <div class="row"><span class="label">序列号</span><span class="value" id="serial">-</span></div>
                <div class="row"><span class="label">设备编号</span><span class="value" id="revision">-</span></div>
            </div>
            <div class="section">
                <h2>&#x23F1; 实时状态</h2>
                <div class="row"><span class="label">运行时间</span><span class="value" id="rt-uptime">-</span></div>
                <div class="row"><span class="label">CPU 温度</span><span class="value" id="rt-temp">-</span></div>
                <div class="row"><span class="label">内存使用</span><span class="value" id="rt-mem">-</span></div>
                <div class="row"><span class="label">磁盘使用</span><span class="value" id="rt-disk">-</span></div>
            </div>
        </div>

        <div id="error" class="error" style="display:none"></div>
    </div>

    <footer>&#x2713; __DEPLOY_HOSTNAME__ 热点服务运行中 &mdash; <span id="clock"></span></footer>

    <script>
        document.getElementById('clock').textContent = new Date().toLocaleString('zh-CN');

        async function load() {
            try {
                const [hw, info] = await Promise.all([
                    fetch('/api/hardware').then(r => r.json()),
                    fetch('/api/info').then(r => r.json())
                ]);

                document.getElementById('model').textContent = hw.model;
                document.getElementById('cpu-chip').textContent = hw.cpu.chip;
                document.getElementById('cpu-cores').textContent = hw.cpu.cores + ' 核 ' + hw.cpu.model;
                document.getElementById('cpu-arch').textContent = hw.cpu.architecture;
                document.getElementById('mem-total').textContent = hw.memory.total;
                var storEl = document.getElementById('storage-list');
                storEl.innerHTML = hw.storage.filter(function(s) {
                    return s.type === 'disk' && s.name.indexOf('zram') !== 0;
                }).map(function(s) {
                    var parts = (s.partitions || []).map(function(p) {
                        var mp = p.mountpoint || '';
                        return p.name + ' ' + p.size +
                            (mp ? ' <span class="badge badge-blue">' + mp + '</span>' : '');
                    }).join(' ');
                    return s.name + ' ' + s.size + ' ' + parts;
                }).join('<br>');

                var eth = hw.network['eth0'] || {};
                document.getElementById('net-eth').innerHTML =
                    '<span class="status-dot ' + (eth.state === 'UP' ? 'status-up' : 'status-down') + '"></span> ' +
                    (eth.addrs ? eth.addrs.filter(function(a) { return a.indexOf('.') !== -1; }).join(', ') : '-') +
                    (eth.state === 'UP' ? ' <span class="badge badge-green">UP</span>' : '');

                var wlan = hw.network['wlan0'] || {};
                document.getElementById('net-wlan').innerHTML =
                    '<span class="status-dot ' + (wlan.state === 'UP' ? 'status-up' : 'status-down') + '"></span> ' +
                    (wlan.addrs ? wlan.addrs.join(', ') : '-') +
                    (wlan.state === 'UP' ? ' <span class="badge badge-green">UP</span>' : '');

                document.getElementById('os-name').textContent = hw.os.name;
                document.getElementById('os-kernel').textContent = hw.os.kernel;
                document.getElementById('serial').textContent = hw.serial || '-';
                document.getElementById('revision').textContent = hw.revision || '-';
                document.getElementById('rt-uptime').textContent = info.uptime;
                document.getElementById('rt-temp').textContent = info.cpu_temp;
                document.getElementById('rt-mem').textContent = info.memory;
                document.getElementById('rt-disk').textContent = info.disk;
                document.getElementById('content').style.display = 'block';
            } catch(e) {
                document.getElementById('error').textContent = '加载失败: ' + e.message;
                document.getElementById('error').style.display = 'block';
            }
        }
        load();
    </script>
</body>
</html>
HTMLEOF

# 替换占位符
sed -i "s/__DEPLOY_HOSTNAME__/${DEPLOY_HOSTNAME}/g" "${DEPLOY_PROJECT_DIR}/www/index.html"

# --- test.html ---
cat > "${DEPLOY_PROJECT_DIR}/www/test.html" << 'TESTEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>测试页</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, "Segoe UI", sans-serif;
            background: #1a1a2e; color: #e0e0e0;
            display: flex; align-items: center; justify-content: center;
            min-height: 100vh; padding: 20px;
        }
        .box { text-align: center; background: rgba(255,255,255,0.05); border-radius: 16px; padding: 40px; max-width: 400px; width: 100%; }
        h1 { color: #4caf50; margin-bottom: 12px; }
        p { color: #aaa; margin-bottom: 20px; }
        a { color: #8ecfff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="box">
        <h1>测试成功</h1>
        <p>页面已正确加载，热点连接正常。</p>
        <a href="/">返回首页</a>
    </div>
</body>
</html>
TESTEOF

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_PROJECT_DIR}"
ok "项目已部署到 ${DEPLOY_PROJECT_DIR}"

# ---------- 配置 nginx ----------
info "配置 nginx..."
cat > /etc/nginx/sites-available/default << NGINXEOF
# HTTP server
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root ${DEPLOY_PROJECT_DIR}/www;
    index index.html;

    # iOS captive portal detection
    location = /hotspot-detect.html {
        default_type text/plain;
        add_header X-Redirect-Reason "Captive Portal";
        try_files /index.html =404;
    }

    # Android connectivity check
    location = /generate_204 {
        return 204;
    }

    # Windows connectivity check
    location = /connecttest.txt {
        return 200 "Success\r\n";
    }

    # Microsoft NCSI
    location = /ncsi.txt {
        return 200 "Microsoft NCSI";
    }

    # Static files
    location / {
        try_files \$uri \$uri/ =404;
    }

    # API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

# HTTPS server
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;

    ssl_certificate ${SSL_DIR}/captive.crt;
    ssl_certificate_key ${SSL_DIR}/captive.key;

    root ${DEPLOY_PROJECT_DIR}/www;
    index index.html;

    location = /hotspot-detect.html {
        default_type text/plain;
        try_files /index.html =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF

# 确保 nginx 启用了 sites-available/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
ok "nginx 已配置"

# ---------- 安装 systemd 服务 ----------
info "安装 systemd 服务..."

# api-server.service
cat > /etc/systemd/system/api-server.service << SVCEOF
[Unit]
Description=API Server for ${DEPLOY_HOSTNAME} Hotspot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${DEPLOY_PROJECT_DIR}/api
ExecStart=/usr/bin/python3 ${DEPLOY_PROJECT_DIR}/api/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

# hotspot-start.service
cat > /etc/systemd/system/hotspot-start.service << HSEOF
[Unit]
Description=Start WiFi Hotspot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rfkill unblock wifi && nmcli dev set wlan0 managed no 2>/dev/null || true && ip link set wlan0 up && hostapd -B /etc/hostapd/hostapd.conf && sleep 1 && dnsmasq && echo 1 > /proc/sys/net/ipv4/ip_forward && nft add table ip nat 2>/dev/null && nft add chain ip nat postrouting "{ type nat hook postrouting priority 100; policy accept; }" 2>/dev/null && nft add rule ip nat postrouting oifname "eth0" masquerade 2>/dev/null && nft add chain ip nat forward "{ type filter hook forward priority 0; policy accept; }" 2>/dev/null && nft add rule ip nat forward iifname "wlan0" accept 2>/dev/null && nft add rule ip nat forward oifname "wlan0" ct state established,related accept 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
HSEOF

# ---------- 启用服务 ----------
info "启用并启动服务..."
systemctl enable api-server.service 2>/dev/null && ok "api-server.service 已启用"
systemctl enable hotspot-start.service 2>/dev/null && ok "hotspot-start.service 已启用"
systemctl enable nginx 2>/dev/null && ok "nginx 已启用"

systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null && ok "nginx 已启动"
systemctl start api-server.service 2>/dev/null && ok "api-server 已启动"
systemctl start hotspot-start.service 2>/dev/null && ok "热点已启动"

# ---------- 设置主机名 ----------
if [[ "$DEPLOY_HOSTNAME" != "$(hostname)" ]]; then
  info "设置主机名为 ${DEPLOY_HOSTNAME}..."
  hostnamectl set-hostname "${DEPLOY_HOSTNAME}" 2>/dev/null || {
    echo "${DEPLOY_HOSTNAME}" > /etc/hostname
    sed -i "s/127.0.1.1.*/127.0.1.1\t${DEPLOY_HOSTNAME}/" /etc/hosts
    ok "主机名已设置为 ${DEPLOY_HOSTNAME} (重启生效)"
  }
fi

# ---------- 部署完成 ----------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  部署完成！${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "  ${CYAN}WiFi 热点:${NC}"
echo -e "    SSID:     ${BOLD}${DEPLOY_SSID}${NC}"
echo -e "    密码:     ${BOLD}无 (开放网络)${NC}"
echo -e "    热点 IP:  ${BOLD}${DEPLOY_HOTSPOT_IP}${NC}"
echo ""
echo -e "  ${CYAN}服务状态:${NC}"
echo -e "    nginx:       $(systemctl is-active nginx 2>/dev/null || echo '未运行')"
echo -e "    api-server:  $(systemctl is-active api-server.service 2>/dev/null || echo '未运行')"
echo -e "    hotspot:     $(systemctl is-active hotspot-start.service 2>/dev/null || echo '未运行')"
echo ""
echo -e "  ${CYAN}访问地址:${NC}"
echo -e "    http://${DEPLOY_HOTSPOT_IP}"
echo -e "    http://${DEPLOY_HOSTNAME}.local"
echo ""
echo -e "  ${YELLOW}注意: 首次部署可能需要重启才能完全生效${NC}"
echo ""
