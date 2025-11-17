# VPS Net Traffic Panel

A simple real-time VPS network traffic panel based on **vnStat**, **Nginx** and **Python**.  
It displays:

- Live download / upload speed (Mbps)
- Today's usage (download / upload / total, in GB)
- Billing period usage (custom billing day)
- Hourly stats (last 24 hours)
- Daily stats (last 14 days)
- Monthly stats (last 12 months)

Supports optional **HTTPS** with your own certificate.

---

## Features

- 🧠 Auto-detect default network interface (you can override manually)
- 📊 Real-time bandwidth from `/sys/class/net/*/statistics`
- 📈 Historical stats via `vnstat --json`
- 📅 Custom billing day (e.g. every month on the 9th or 14th)
- 🌐 Nginx static page + JSON API (`traffic.json`)
- 🔐 Optional HTTPS with existing SSL certificate
- 🛠️ One-click installer: `install_net_panel.sh`

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (tested on Ubuntu 24, should work on Debian-based systems)
- Root access
- Packages (installer will auto-install):
  - `nginx`
  - `vnstat`
  - `python3`

---

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/wwintj/vps-net-traffic-panel.git
cd vps-net-traffic-panel

# 2. Make the installer executable
chmod +x install_net_panel.sh

# 3. Run the installer as root
sudo ./install_net_panel.sh
