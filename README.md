# VPS Net Traffic Panel

A simple real-time VPS network traffic panel based on **vnStat**, **Nginx** and **Python**.

It provides:

- Live download / upload bandwidth (Mbps)
- Today's usage (download / upload / total, in GB)
- Billing period usage (custom billing day)
- Hourly stats (last 24 hours)
- Daily stats (last 14 days)
- Monthly stats (last 12 months)
- Optional **HTTPS** support with your own certificate

> 中文说明：这是一个基于 vnStat + Nginx + Python 的 VPS 实时流量面板，支持实时带宽、今日流量、计费周期流量，以及按小时 / 按天 / 按月的统计展示。适合自用 VPS 监控带宽和用量。

---

## Features

- 🧠 Auto-detect default network interface (can be overridden manually)
- 📊 Real-time bandwidth from `/sys/class/net/*/statistics`
- 📈 Historical usage via `vnstat --json`
- 📅 Custom billing day (1–28)
- 🌐 Nginx static dashboard + JSON API (`traffic.json`)
- 🔐 Optional HTTPS (with your own cert)
- 🛠️ One-click installer (`install_net_panel.sh`)

---

## Requirements

The installer will automatically install:

- nginx  
- vnstat  
- python3  

Supported OS:

- Ubuntu 20.04 / 22.04 / 24.04  
- Debian-based systems (generally compatible)

---

## Installation

### **Option 1 — Clone the repo**

```bash
git clone https://github.com/wwintj/vps-net-traffic-panel.git
cd vps-net-traffic-panel
chmod +x install_net_panel.sh
sudo ./install_net_panel.sh
```

The installer will ask:

1. Network interface (default auto-detected, e.g. `eth0`)
2. Billing cycle day (default `9`)
3. Whether to enable HTTPS (optional)

---

### **Option 2 — One-line install with wget**

```bash
wget -O install_net_panel.sh https://raw.githubusercontent.com/wwintj/vps-net-traffic-panel/main/install_net_panel.sh \
  && chmod +x install_net_panel.sh \
  && sudo ./install_net_panel.sh
```

---

## Accessing the Panel

**HTTP:**

```
http://<server-ip>/
```

**HTTPS（如果启用了）:**

```
https://<your-domain>/
```

The dashboard includes:

- Server spec card  
- Live bandwidth  
- Today's usage  
- Billing period usage  
- Hourly / daily / monthly tables  

---

## Configuration

Main config file:

```
/etc/net_panel.conf
```

Example:

```ini
IFACE=eth0
BILLING_DAY=14
```

---

## Systemd Service

Service file:

```
/etc/systemd/system/net-panel.service
```

Commands:

```bash
sudo systemctl restart net-panel.service
sudo systemctl status net-panel.service
journalctl -u net-panel.service -f
```

---

## File Structure

After installation:

| File | Description |
|------|-------------|
| `/usr/local/bin/net_panel.py` | Python exporter (realtime + vnStat → traffic.json) |
| `/etc/net_panel.conf` | Panel config |
| `/var/www/html/index.html` | Dashboard UI |
| `/var/www/html/traffic.json` | Runtime data |
| `/etc/nginx/sites-available/net-panel.conf` | Nginx site config (HTTPS optional) |

---

## How It Works

1. `vnstat` collects hourly/daily/monthly stats.
2. `net_panel.py`:
   - Reads live RX/TX from `/sys/class/net/<iface>/statistics`
   - Converts **bytes → GB** using `1024^3`
   - Collects hourly/daily/monthly stats from `vnstat --json`
   - Writes to `/var/www/html/traffic.json`
3. `index.html` updates the dashboard every second.

---

## License

MIT License – see the LICENSE file.

---

## Author

Developed by **[@wwintj](https://github.com/wwintj)**.

欢迎提交 PR 或 Issue！
