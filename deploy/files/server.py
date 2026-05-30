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

    # Parse storage from lsblk
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

    # Network interfaces
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
