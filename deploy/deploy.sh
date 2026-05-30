#!/usr/bin/env bash
# ============================================================
# 树莓派 WiFi 热点 + 硬件配置展示 — 一键部署脚本
#
# 使用方式:
#   sudo bash deploy/deploy.sh --ssid MyHotspot
#   sudo bash deploy/deploy.sh --hostname mypi --ssid MyHotspot --password MyPass123
#
# 参数:
#   --hostname    DEPLOY_HOSTNAME     主机名 (默认: 自动检测)
#   --ssid        DEPLOY_SSID         WiFi 名称 (默认: PiHotspot)
#   --password    DEPLOY_PASSWORD     WiFi 密码 (默认: 开放网络)
#   --ip          DEPLOY_HOTSPOT_IP   热点 IP (默认: 192.168.4.1)
#   --user        DEPLOY_USER         运行用户 (默认: $SUDO_USER)
#   --project-dir DEPLOY_PROJECT_DIR  项目目录 (默认: /home/$user/zw)
# ============================================================
set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ---------- 脚本目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# ---------- 参数解析 ----------
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-}"
DEPLOY_SSID="${DEPLOY_SSID:-PiHotspot}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-}"
DEPLOY_HOTSPOT_IP="${DEPLOY_HOTSPOT_IP:-192.168.4.1}"
DEPLOY_USER="${DEPLOY_USER:-${SUDO_USER:-pi}}"
DEPLOY_PROJECT_DIR="${DEPLOY_PROJECT_DIR:-/home/${DEPLOY_USER}/zw}"
DEPLOY_INTERFACE="${DEPLOY_INTERFACE:-wlan0}"
DEPLOY_CHANNEL="${DEPLOY_CHANNEL:-7}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    DEPLOY_HOSTNAME="$2";    shift 2 ;;
    --ssid)        DEPLOY_SSID="$2";        shift 2 ;;
    --password)    DEPLOY_PASSWORD="$2";    shift 2 ;;
    --ip)          DEPLOY_HOTSPOT_IP="$2";  shift 2 ;;
    --user)        DEPLOY_USER="$2";        shift 2 ;;
    --project-dir) DEPLOY_PROJECT_DIR="$2"; shift 2 ;;
    --interface)   DEPLOY_INTERFACE="$2";   shift 2 ;;
    --channel)     DEPLOY_CHANNEL="$2";     shift 2 ;;
    -h|--help)
      echo "用法: sudo bash deploy/deploy.sh [--hostname H] [--ssid SSID] [--password PASS] [--ip IP]"
      echo ""
      echo "选项:"
      echo "  --hostname   主机名 (默认: 自动检测)"
      echo "  --ssid       WiFi 名称 (默认: PiHotspot)"
      echo "  --password   WiFi 密码 (默认: 开放网络)"
      echo "  --ip         热点 IP (默认: 192.168.4.1)"
      echo "  --user       运行用户 (默认: \$SUDO_USER)"
      echo "  --project-dir 项目目录 (默认: /home/\$user/zw)"
      echo "  --interface  WiFi 接口 (默认: wlan0)"
      echo "  --channel    WiFi 信道 (默认: 7)"
      echo "  -h, --help   显示帮助"
      exit 0
      ;;
    *) die "未知参数: $1 (使用 -h 查看帮助)" ;;
  esac
done

# ---------- 默认值处理 ----------
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-$(hostname)}"

if [[ -z "$DEPLOY_USER" ]]; then
  die "无法确定运行用户，请使用 --user 指定"
fi

# ---------- 权限检查 ----------
if [[ $EUID -ne 0 ]]; then
  die "请使用 sudo 运行此脚本 (sudo bash deploy/deploy.sh)"
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

if [[ ! -f /sys/firmware/devicetree/base/model && ! -d /proc/device-tree ]]; then
  warn "未检测到树莓派设备树，请确认是树莓派设备"
else
  model_name=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0' || echo "Unknown")
  ok "设备: $model_name"
fi

if ! ip link show "$DEPLOY_INTERFACE" &>/dev/null; then
  die "找不到网络接口 $DEPLOY_INTERFACE"
fi
ok "WiFi 接口: $DEPLOY_INTERFACE"

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

# ---------- 释放 wlan0 控制权 ----------
info "配置 NetworkManager 忽略 $DEPLOY_INTERFACE..."
nmcli dev set "$DEPLOY_INTERFACE" managed no 2>/dev/null || true
cat > /etc/NetworkManager/conf.d/unmanage-wlan0.conf << NMEOF
[device-wlan0]
match-device=interface-name:${DEPLOY_INTERFACE}
unmanaged=1
NMEOF
systemctl reload NetworkManager 2>/dev/null || true
ok "$DEPLOY_INTERFACE 已从 NetworkManager 释放"

# ---------- 生成 hostapd 配置 ----------
info "配置 WiFi 热点..."
WPA_CONFIG=""
if [[ -n "$DEPLOY_PASSWORD" ]]; then
  WPA_CONFIG=$(cat << 'WPA'
wpa=2
wpa_passphrase={{PASSWORD}}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
WPA
)
  WPA_CONFIG="${WPA_CONFIG//\{\{PASSWORD\}\}/$DEPLOY_PASSWORD}"
fi

sed \
  -e "s|{{INTERFACE}}|${DEPLOY_INTERFACE}|g" \
  -e "s|{{SSID}}|${DEPLOY_SSID}|g" \
  -e "s|{{CHANNEL}}|${DEPLOY_CHANNEL}|g" \
  -e "s|{{WPA_CONFIG}}|${WPA_CONFIG}|g" \
  "${TEMPLATES_DIR}/hostapd.conf.tpl" > /etc/hostapd/hostapd.conf

# 确保 DAEMON_CONF 已设置
if grep -q '^DAEMON_CONF' /etc/default/hostapd 2>/dev/null; then
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

HOTSPOT_SUBNET="${DEPLOY_HOTSPOT_IP%.*}"
sed \
  -e "s|{{INTERFACE}}|${DEPLOY_INTERFACE}|g" \
  -e "s|{{DHCP_START}}|${HOTSPOT_SUBNET}.2|g" \
  -e "s|{{DHCP_END}}|${HOTSPOT_SUBNET}.20|g" \
  -e "s|{{SUBNET_MASK}}|255.255.255.0|g" \
  -e "s|{{DHCP_LEASE}}|24h|g" \
  -e "s|{{GATEWAY_IP}}|${DEPLOY_HOTSPOT_IP}|g" \
  -e "s|{{UPSTREAM_DNS}}|8.8.8.8|g" \
  "${TEMPLATES_DIR}/dnsmasq.conf.tpl" > /etc/dnsmasq.conf

# ---------- 部署项目文件 ----------
info "部署项目到 ${DEPLOY_PROJECT_DIR}..."
mkdir -p "${DEPLOY_PROJECT_DIR}/api" "${DEPLOY_PROJECT_DIR}/www"

cp "${FILES_DIR}/server.py" "${DEPLOY_PROJECT_DIR}/api/server.py"
cp "${FILES_DIR}/index.html" "${DEPLOY_PROJECT_DIR}/www/index.html"
cp "${FILES_DIR}/test.html" "${DEPLOY_PROJECT_DIR}/www/test.html"

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_PROJECT_DIR}"
ok "项目已部署到 ${DEPLOY_PROJECT_DIR}"

# ---------- 配置 nginx ----------
info "配置 nginx..."
sed \
  -e "s|{{PROJECT_DIR}}|${DEPLOY_PROJECT_DIR}|g" \
  -e "s|{{SSL_CERT}}|/etc/ssl/private/captive.crt|g" \
  -e "s|{{SSL_KEY}}|/etc/ssl/private/captive.key|g" \
  "${TEMPLATES_DIR}/nginx.conf.tpl" > /etc/nginx/sites-available/default

ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && ok "nginx 配置有效" || warn "nginx 配置可能有问题"

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
# 注意：不在此处启动 hostapd/dnsmasq，由系统服务统一管理
cat > /etc/systemd/system/hotspot-start.service << HSEOF
[Unit]
Description=Start WiFi Hotspot
After=network-online.target hostapd.service dnsmasq.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'rfkill unblock wifi && nmcli dev set ${DEPLOY_INTERFACE} managed no 2>/dev/null || true && ip link set ${DEPLOY_INTERFACE} up && ip addr add ${DEPLOY_HOTSPOT_IP}/24 dev ${DEPLOY_INTERFACE} 2>/dev/null || true && echo 1 > /proc/sys/net/ipv4/ip_forward && nft add table ip nat 2>/dev/null || true && nft add chain ip nat postrouting "{ type nat hook postrouting priority 100; policy accept; }" 2>/dev/null || true && nft add rule ip nat postrouting oifname "eth0" masquerade 2>/dev/null || true && nft add chain ip nat forward "{ type filter hook forward priority 0; policy accept; }" 2>/dev/null || true && nft add rule ip nat forward iifname "${DEPLOY_INTERFACE}" accept 2>/dev/null || true && nft add rule ip nat forward oifname "${DEPLOY_INTERFACE}" ct state established,related accept 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
HSEOF

# ---------- 启用并启动服务 ----------
info "启用并启动服务..."
systemctl daemon-reload

systemctl enable api-server.service 2>/dev/null && ok "api-server.service 已启用"
systemctl enable hotspot-start.service 2>/dev/null && ok "hotspot-start.service 已启用"
systemctl enable nginx 2>/dev/null && ok "nginx 已启用"

systemctl restart nginx 2>/dev/null && ok "nginx 已重启" || warn "nginx 重启失败"
systemctl start api-server.service 2>/dev/null && ok "api-server 已启动" || warn "api-server 启动失败"

# 重启 hostapd 确保 wlan0 进入 AP 模式
systemctl restart hostapd.service 2>/dev/null && ok "hostapd 已重启" || warn "hostapd 重启失败"
systemctl restart dnsmasq.service 2>/dev/null && ok "dnsmasq 已重启" || warn "dnsmasq 重启失败"

sleep 2
systemctl start hotspot-start.service 2>/dev/null && ok "热点网络配置已应用" || warn "热点网络配置失败"

# ---------- 验证部署 ----------
info "验证部署..."
errors=0

check_service() {
  local status
  status=$(systemctl is-active "$1" 2>/dev/null)
  if [[ "$status" == "active" ]]; then
    ok "$1: active"
  else
    warn "$1: $status (预期: active)"
    ((errors++)) || true
  fi
}

check_service hostapd.service
check_service dnsmasq.service
check_service hotspot-start.service
check_service api-server.service
check_service nginx.service

# 检查 wlan0 是否为 AP 模式
if iw dev "$DEPLOY_INTERFACE" info 2>/dev/null | grep -q "type AP"; then
  ok "$DEPLOY_INTERFACE: AP 模式"
else
  warn "$DEPLOY_INTERFACE 不是 AP 模式，尝试重启 hostapd..."
  systemctl restart hostapd.service
  sleep 2
  if iw dev "$DEPLOY_INTERFACE" info 2>/dev/null | grep -q "type AP"; then
    ok "$DEPLOY_INTERFACE: AP 模式 (重启后)"
  else
    warn "$DEPLOY_INTERFACE 仍未进入 AP 模式"
    ((errors++)) || true
  fi
fi

# 检查 wlan0 IP
if ip addr show "$DEPLOY_INTERFACE" 2>/dev/null | grep -q "$DEPLOY_HOTSPOT_IP"; then
  ok "$DEPLOY_INTERFACE IP: $DEPLOY_HOTSPOT_IP"
else
  warn "$DEPLOY_INTERFACE 缺少 IP $DEPLOY_HOTSPOT_IP"
  ((errors++)) || true
fi

# 检查 API
if curl -s http://localhost/api/hardware >/dev/null 2>&1; then
  ok "API 响应正常"
else
  warn "API 无响应"
  ((errors++)) || true
fi

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
if [[ -n "$DEPLOY_PASSWORD" ]]; then
  echo -e "    密码:     ${BOLD}${DEPLOY_PASSWORD}${NC}"
else
  echo -e "    密码:     ${BOLD}无 (开放网络)${NC}"
fi
echo -e "    热点 IP:  ${BOLD}${DEPLOY_HOTSPOT_IP}${NC}"
echo ""
echo -e "  ${CYAN}服务状态:${NC}"
echo -e "    nginx:       $(systemctl is-active nginx 2>/dev/null || echo '未运行')"
echo -e "    hostapd:     $(systemctl is-active hostapd.service 2>/dev/null || echo '未运行')"
echo -e "    dnsmasq:     $(systemctl is-active dnsmasq.service 2>/dev/null || echo '未运行')"
echo -e "    hotspot:     $(systemctl is-active hotspot-start.service 2>/dev/null || echo '未运行')"
echo -e "    api-server:  $(systemctl is-active api-server.service 2>/dev/null || echo '未运行')"
echo ""
echo -e "  ${CYAN}访问地址:${NC}"
echo -e "    http://${DEPLOY_HOTSPOT_IP}"
echo -e "    http://${DEPLOY_HOSTNAME}.local"
echo ""
if [[ $errors -gt 0 ]]; then
  echo -e "  ${YELLOW}警告: ${errors} 项验证未通过，请检查上方日志${NC}"
else
  echo -e "  ${GREEN}全部验证通过${NC}"
fi
echo ""
