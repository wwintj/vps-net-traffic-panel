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
- 📅 Custom billing day (e.g. every month on the 9th or 14th)
- 🌐 Nginx static dashboard + JSON data (`traffic.json`)
- 🔐 Optional HTTPS with existing SSL certificate
- 🛠️ One-click installer: `install_net_panel.sh`

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (tested on Ubuntu 24; should work on other Debian-based systems)
- Root access to the VPS
- The installer will automatically install:
  - `nginx`
  - `vnstat`
  - `python3`

---

## Installation

### Option 1: Clone the repo

```bash
# 1. Clone this repo
git clone https://github.com/wwintj/vps-net-traffic-panel.git
cd vps-net-traffic-panel

# 2. Make the installer executable
chmod +x install_net_panel.sh

# 3. Run the installer as root
sudo ./install_net_panel.sh
