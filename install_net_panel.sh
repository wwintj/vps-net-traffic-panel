#!/usr/bin/env bash
set -e

echo "================ VPS 流量面板一键安装 ================="
echo "本脚本将安装：nginx、vnstat、Python 采集脚本、systemd 服务和首页面板。"
echo "适用系统：Ubuntu 24（其他 Debian/Ubuntu 也基本通用）。"
echo

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 账号运行本脚本：sudo bash install_net_panel.sh"
  exit 1
fi

# 自动检测默认网卡
DEFAULT_IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
  DEFAULT_IFACE="eth0"
fi

echo "检测到默认网卡为：$DEFAULT_IFACE"
read -p "如需使用其他网卡，请在此输入（直接回车表示使用 $DEFAULT_IFACE）: " USER_IFACE
IFACE="${USER_IFACE:-$DEFAULT_IFACE}"
echo "最终使用的网卡：$IFACE"
echo

# 计费日（每月几号）
read -p "请输入每月统计结算日（1-28，直接回车默认 9 号）: " BILLING_DAY
if [ -z "$BILLING_DAY" ]; then
  BILLING_DAY=9
fi

# 简单校验
if ! echo "$BILLING_DAY" | grep -E '^[0-9]+$' >/dev/null; then
  echo "计费日必须是数字。"
  exit 1
fi
if [ "$BILLING_DAY" -lt 1 ] || [ "$BILLING_DAY" -gt 28 ]; then
  echo "计费日必须在 1~28 之间。"
  exit 1
fi

echo "计费日已设置为：每月 $BILLING_DAY 号"
echo

echo ">>> 更新系统并安装依赖：nginx、vnstat、python3 ..."
apt update -y
apt install -y nginx vnstat python3

echo ">>> 初始化 vnstat 网卡：$IFACE"
vnstat -u -i "$IFACE" || true
systemctl enable --now vnstat

echo ">>> 写入配置文件 /etc/net_panel.conf ..."
cat >/etc/net_panel.conf <<EOF
# VPS 流量面板配置
IFACE=$IFACE
BILLING_DAY=$BILLING_DAY
EOF

echo ">>> 创建/覆盖 Python 采集脚本 /usr/local/bin/net_panel.py ..."
cat >/usr/local/bin/net_panel.py << 'EOF'
#!/usr/bin/env python3
import time
import json
import subprocess
from pathlib import Path
from datetime import datetime, date

WEB_ROOT = Path("/var/www/html")
OUTPUT_FILE = WEB_ROOT / "traffic.json"
CONF_FILE = Path("/etc/net_panel.conf")


def load_config():
    """
    从 /etc/net_panel.conf 读取配置：
    IFACE=xxx
    BILLING_DAY=9
    """
    iface = None
    billing_day = 9
    if not CONF_FILE.exists():
        return {"iface": None, "billing_day": billing_day}

    try:
        content = CONF_FILE.read_text(encoding="utf-8")
    except Exception:
        return {"iface": None, "billing_day": billing_day}

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("IFACE"):
            parts = line.split("=", 1)
            if len(parts) == 2:
                iface = parts[1].strip()
        elif line.startswith("BILLING_DAY"):
            parts = line.split("=", 1)
            if len(parts) == 2:
                try:
                    d = int(parts[1].strip())
                    if 1 <= d <= 28:
                        billing_day = d
                except ValueError:
                    pass
    return {"iface": iface, "billing_day": billing_day}


def get_default_iface():
    """
    自动检测默认路由对应的主网卡
    """
    try:
        result = subprocess.run(
            ["bash", "-lc", "ip -o -4 route show to default | awk '{print $5}'"],
            capture_output=True,
            text=True,
            check=True,
        )
        iface = result.stdout.strip()
        if iface:
            return iface
    except Exception:
        pass
    # 兜底
    return "eth0"


def read_bytes(iface: str):
    """
    从 /sys/class/net/... 读取当前总收发字节数（自开机以来累积）
    """
    base = Path(f"/sys/class/net/{iface}/statistics")
    rx_path = base / "rx_bytes"
    tx_path = base / "tx_bytes"
    with rx_path.open() as f:
        rx = int(f.read().strip())
    with tx_path.open() as f:
        tx = int(f.read().strip())
    return rx, tx


def human_rate_mbps(bps: float):
    """
    比特/秒 -> (Mbps 数值, 带单位字符串)
    """
    mbps = max(bps / 1024 / 1024, 0.0)
    if mbps >= 1:
        return mbps, f"{mbps:.2f} Mbps"
    else:
        kbps = mbps * 1024
        return mbps, f"{kbps:.2f} Kbps"


def bytes_to_gb(bytes_value: int) -> float:
    """
    字节 -> GB（GiB）
    ⚠️ vnstat --json 里 traffic.*[].rx/tx 是 bytes，不是 MiB。
    """
    return bytes_value / 1024 / 1024 / 1024


def compute_vnstat_stats(iface: str, billing_day: int):
    """
    从 vnstat --json 读取：
    - 今日流量
    - 计费周期流量
    - 按小时（近 24 小时）
    - 按天（近 14 天）
    - 按月（近 12 个月）
    """
    try:
        result = subprocess.run(
            ["vnstat", "--json", "-i", iface],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
    except Exception as e:
        return {
            "error": f"vnstat error: {e}",
            "today": None,
            "period": None,
            "hourly": [],
            "daily": [],
            "monthly": [],
        }

    interfaces = data.get("interfaces", [])
    if not interfaces:
        return {
            "error": "vnstat: no interface data",
            "today": None,
            "period": None,
            "hourly": [],
            "daily": [],
            "monthly": [],
        }

    traffic = interfaces[0].get("traffic", {})
    days = traffic.get("day", [])
    hours = traffic.get("hour", [])
    months = traffic.get("month", [])

    today = date.today()

    # ------- 今日流量（JSON 里的 rx/tx 是字节） -------
    today_rx_bytes = 0
    today_tx_bytes = 0

    for d in days:
        dt_info = d.get("date", {})
        try:
            d_date = date(
                dt_info.get("year", 1970),
                dt_info.get("month", 1),
                dt_info.get("day", 1),
            )
        except Exception:
            continue

        if d_date == today:
            today_rx_bytes = d.get("rx", 0)
            today_tx_bytes = d.get("tx", 0)
            break

    today_rx_gb = bytes_to_gb(today_rx_bytes)
    today_tx_gb = bytes_to_gb(today_tx_bytes)
    today_total_gb = today_rx_gb + today_tx_gb

    today_stats = {
        "rx_gb": round(today_rx_gb, 3),
        "tx_gb": round(today_tx_gb, 3),
        "total_gb": round(today_total_gb, 3),
    }

    # ------- 计费周期 -------
    if today.day >= billing_day:
        period_start = date(today.year, today.month, billing_day)
    else:
        # 上个月
        if today.month == 1:
            year = today.year - 1
            month = 12
        else:
            year = today.year
            month = today.month - 1
        period_start = date(year, month, billing_day)
    period_end = today

    period_rx_bytes = 0
    period_tx_bytes = 0

    for d in days:
        dt_info = d.get("date", {})
        try:
            d_date = date(
                dt_info.get("year", 1970),
                dt_info.get("month", 1),
                dt_info.get("day", 1),
            )
        except Exception:
            continue

        if period_start <= d_date <= period_end:
            period_rx_bytes += d.get("rx", 0)
            period_tx_bytes += d.get("tx", 0)

    period_rx_gb = bytes_to_gb(period_rx_bytes)
    period_tx_gb = bytes_to_gb(period_tx_bytes)
    period_total_gb = period_rx_gb + period_tx_gb

    period_stats = {
        "billing_day": billing_day,
        "from": period_start.isoformat(),
        "to": period_end.isoformat(),
        "rx_gb": round(period_rx_gb, 3),
        "tx_gb": round(period_tx_gb, 3),
        "total_gb": round(period_total_gb, 3),
    }

    # ------- 按小时（近 24 条） -------
    hourly_list = []
    for h in hours:
        dt_info = h.get("date", {})
        tm_info = h.get("time", {})
        try:
            d_date = date(
                dt_info.get("year", 1970),
                dt_info.get("month", 1),
                dt_info.get("day", 1),
            )
            hour = tm_info.get("hour", 0)
            dt_full = datetime(d_date.year, d_date.month, d_date.day, hour)
        except Exception:
            continue

        rx_bytes = h.get("rx", 0)
        tx_bytes = h.get("tx", 0)
        rx_gb = bytes_to_gb(rx_bytes)
        tx_gb = bytes_to_gb(tx_bytes)
        total_gb = rx_gb + tx_gb

        hourly_list.append({
            "datetime": dt_full.isoformat(timespec="minutes"),
            "label": dt_full.strftime("%Y-%m-%d %H:00"),
            "rx_gb": round(rx_gb, 4),
            "tx_gb": round(tx_gb, 4),
            "total_gb": round(total_gb, 4),
        })

    hourly_list.sort(key=lambda x: x["datetime"])
    hourly_list = hourly_list[-24:]  # 近 24 条

    # ------- 按天（近 14 天） -------
    daily_list = []
    for d in days:
        dt_info = d.get("date", {})
        try:
            d_date = date(
                dt_info.get("year", 1970),
                dt_info.get("month", 1),
                dt_info.get("day", 1),
            )
        except Exception:
            continue

        rx_bytes = d.get("rx", 0)
        tx_bytes = d.get("tx", 0)
        rx_gb = bytes_to_gb(rx_bytes)
        tx_gb = bytes_to_gb(tx_bytes)
        total_gb = rx_gb + tx_gb

        daily_list.append({
            "date": d_date.isoformat(),
            "rx_gb": round(rx_gb, 3),
            "tx_gb": round(tx_gb, 3),
            "total_gb": round(total_gb, 3),
        })

    daily_list.sort(key=lambda x: x["date"])
    daily_list = daily_list[-14:]  # 近 14 天

    # ------- 按月（近 12 个月） -------
    monthly_list = []
    for m in months:
        dt_info = m.get("date", {})
        try:
            year = dt_info.get("year", 1970)
            month = dt_info.get("month", 1)
            label = f"{year:04d}-{month:02d}"
        except Exception:
            continue

        rx_bytes = m.get("rx", 0)
        tx_bytes = m.get("tx", 0)
        rx_gb = bytes_to_gb(rx_bytes)
        tx_gb = bytes_to_gb(tx_bytes)
        total_gb = rx_gb + tx_gb

        monthly_list.append({
            "month": label,
            "rx_gb": round(rx_gb, 3),
            "tx_gb": round(tx_gb, 3),
            "total_gb": round(total_gb, 3),
        })

    monthly_list.sort(key=lambda x: x["month"])
    monthly_list = monthly_list[-12:]

    return {
        "error": None,
        "today": today_stats,
        "period": period_stats,
        "hourly": hourly_list,
        "daily": daily_list,
        "monthly": monthly_list,
    }


def main():
    WEB_ROOT.mkdir(parents=True, exist_ok=True)

    cfg = load_config()
    iface = cfg.get("iface") or get_default_iface()
    billing_day = cfg.get("billing_day", 9)

    try:
        prev_rx, prev_tx = read_bytes(iface)
    except FileNotFoundError:
        data = {
            "error": f"Interface {iface} not found. Edit /etc/net_panel.conf or net_panel.py.",
            "timestamp": int(time.time()),
        }
        OUTPUT_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return

    # 初始写入一份空数据
    OUTPUT_FILE.write_text(
        json.dumps(
            {
                "iface": iface,
                "rx_mbps": 0,
                "tx_mbps": 0,
                "rx_human": "0 Mbps",
                "tx_human": "0 Mbps",
                "timestamp": int(time.time()),
                "billing_day": billing_day,
                "today": None,
                "period": None,
                "hourly": [],
                "daily": [],
                "monthly": [],
                "stats_error": None,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    last_stats_time = 0
    stats_cache = {
        "today": None,
        "period": None,
        "hourly": [],
        "daily": [],
        "monthly": [],
        "error": None,
    }

    while True:
        time.sleep(1)

        # 实时速率
        try:
            rx, tx = read_bytes(iface)
        except FileNotFoundError:
            data = {
                "error": f"Interface {iface} no longer available.",
                "timestamp": int(time.time()),
            }
            OUTPUT_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            continue

        interval = 1
        rx_rate_bps = (rx - prev_rx) * 8 / interval
        tx_rate_bps = (tx - prev_tx) * 8 / interval
        prev_rx, prev_tx = rx, tx

        rx_mbps, rx_str = human_rate_mbps(rx_rate_bps)
        tx_mbps, tx_str = human_rate_mbps(tx_rate_bps)

        now = time.time()
        # 每 10 秒刷新一次统计
        if now - last_stats_time > 10:
            cfg = load_config()
            billing_day = cfg.get("billing_day", billing_day)
            iface_conf = cfg.get("iface")
            if iface_conf:
                iface = iface_conf
            stats_cache = compute_vnstat_stats(iface, billing_day)
            last_stats_time = now

        payload = {
            "iface": iface,
            "rx_mbps": round(rx_mbps, 4),
            "tx_mbps": round(tx_mbps, 4),
            "rx_human": rx_str,
            "tx_human": tx_str,
            "timestamp": int(time.time()),
            "billing_day": billing_day,
            "today": stats_cache.get("today"),
            "period": stats_cache.get("period"),
            "hourly": stats_cache.get("hourly", []),
            "daily": stats_cache.get("daily", []),
            "monthly": stats_cache.get("monthly", []),
            "stats_error": stats_cache.get("error"),
        }

        try:
            OUTPUT_FILE.write_text(
                json.dumps(payload, ensure_ascii=False),
                encoding="utf-8",
            )
        except Exception:
            # 文件写入失败就跳过，下一轮再写
            pass


if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/net_panel.py

echo ">>> 创建/覆盖 systemd 服务 /etc/systemd/system/net-panel.service ..."
cat >/etc/systemd/system/net-panel.service <<EOF
[Unit]
Description=VPS Real-time traffic and stats exporter
After=network-online.target vnstat.service

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /usr/local/bin/net_panel.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now net-panel.service

echo ">>> 创建网站目录 /var/www/html 并写入首页 index.html ..."
mkdir -p /var/www/html
cat >/var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <title>VPS 实时流量面板</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: #0f172a;
      color: #e5e7eb;
      margin: 0;
      padding: 0;
      display: flex;
      justify-content: center;
      align-items: flex-start;
      min-height: 100vh;
    }
    .container {
      width: 100%;
      max-width: 1200px;
      padding: 24px 16px 40px;
    }
    h1 {
      margin: 0 0 6px;
      font-size: 26px;
      text-align: center;
    }
    .subtitle {
      text-align: center;
      font-size: 13px;
      color: #9ca3af;
      margin-bottom: 20px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 16px;
      margin-bottom: 24px;
    }
    @media (max-width: 900px) {
      .grid {
        grid-template-columns: 1fr;
      }
    }
    .card {
      background: rgba(15, 23, 42, 0.95);
      border-radius: 18px;
      padding: 16px 18px 14px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
      border: 1px solid rgba(148, 163, 184, 0.3);
    }
    .card-title {
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: .08em;
      color: #9ca3af;
      margin-bottom: 6px;
    }
    .value {
      font-size: 22px;
      font-weight: 600;
    }
    .desc {
      font-size: 12px;
      color: #9ca3af;
      margin-top: 4px;
      line-height: 1.4;
    }
    .highlight {
      color: #4ade80;
    }
    .error { color: #f97373; }
    .muted { color: #9ca3af; font-size: 12px; }
    h2 {
      font-size: 18px;
      margin: 16px 0 6px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 12px;
    }
    th, td {
      padding: 6px 8px;
      border-bottom: 1px solid rgba(148, 163, 184, 0.25);
      text-align: left;
    }
    th {
      font-weight: 500;
      color: #9ca3af;
    }
    tbody tr:hover {
      background: rgba(30, 64, 175, 0.3);
    }
    .footer {
      margin-top: 16px;
      font-size: 11px;
      text-align: center;
      color: #6b7280;
    }
    code {
      background: rgba(15,23,42,0.8);
      padding: 1px 3px;
      border-radius: 4px;
      font-size: 11px;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>VPS 实时流量与统计面板</h1>
    <div class="subtitle">
      实时速率 + 今日概览 + 按小时 / 按天 / 按月汇总
    </div>

    <!-- 汇总：实时 + 今日 + 计费周期 -->
    <div class="grid">
      <div class="card">
        <div class="card-title">服务器配置</div>
        <div class="value">
          2 Cores / 2 GB RAM
        </div>
        <div class="desc">
          Swap: 1024 MB&nbsp;&nbsp;|&nbsp;&nbsp;Disk: 40 GB
        </div>
      </div>

      <div class="card">
        <div class="card-title">实时下行 (Download)</div>
        <div id="rx" class="value highlight">--</div>
        <div class="desc">当前从公网下载到服务器的实时速度</div>
      </div>

      <div class="card">
        <div class="card-title">实时上行 (Upload)</div>
        <div id="tx" class="value highlight">--</div>
        <div class="desc">当前从服务器上传到公网的实时速度</div>
      </div>

      <div class="card">
        <div class="card-title">今日概览</div>
        <div id="today-total" class="value">--</div>
        <div class="desc">
          下行：<span id="today-rx">--</span> GB &nbsp;&nbsp; 上行：<span id="today-tx">--</span> GB<br />
          单位：GB
        </div>
      </div>

      <div class="card">
        <div class="card-title">计费周期流量</div>
        <div id="period-total" class="value">--</div>
        <div class="desc">
          周期：<span id="period-range">--</span><br />
          下行：<span id="period-rx">--</span> GB &nbsp;&nbsp; 上行：<span id="period-tx">--</span> GB
        </div>
      </div>

      <div class="card">
        <div class="card-title">网卡 & 更新时间</div>
        <div id="iface" class="value">--</div>
        <div class="desc" id="updated">等待数据...</div>
        <div class="desc muted" id="stats-error"></div>
      </div>
    </div>

    <!-- 按小时 -->
    <h2>按小时统计（近 24 小时）</h2>
    <div class="card">
      <table>
        <thead>
          <tr>
            <th>时间</th>
            <th>下行 (GB)</th>
            <th>上行 (GB)</th>
            <th>合计 (GB)</th>
          </tr>
        </thead>
        <tbody id="tbody-hourly">
          <tr><td colspan="4">加载中...</td></tr>
        </tbody>
      </table>
    </div>

    <!-- 按天 -->
    <h2>按天统计（近 14 天）</h2>
    <div class="card">
      <table>
        <thead>
          <tr>
            <th>日期</th>
            <th>下行 (GB)</th>
            <th>上行 (GB)</th>
            <th>合计 (GB)</th>
          </tr>
        </thead>
        <tbody id="tbody-daily">
          <tr><td colspan="4">加载中...</td></tr>
        </tbody>
      </table>
    </div>

    <!-- 按月 -->
    <h2>按月统计（近 12 个月）</h2>
    <div class="card">
      <table>
        <thead>
          <tr>
            <th>月份</th>
            <th>下行 (GB)</th>
            <th>上行 (GB)</th>
            <th>合计 (GB)</th>
          </tr>
        </thead>
        <tbody id="tbody-monthly">
          <tr><td colspan="4">加载中...</td></tr>
        </tbody>
      </table>
    </div>

    <div class="footer">
      实时速率每秒刷新，统计数据每 10 秒从 vnStat 更新。<br />
      网卡与计费日可在 <code>/etc/net_panel.conf</code> 中调整（IFACE / BILLING_DAY）。
    </div>
  </div>

  <script>
    function renderTable(tbodyId, rows, cols) {
      const tbody = document.getElementById(tbodyId);
      if (!rows || rows.length === 0) {
        tbody.innerHTML = '<tr><td colspan="' + cols + '">暂无数据</td></tr>';
        return;
      }
      const html = rows.map(r => {
        return '<tr>' +
          '<td>' + r[0] + '</td>' +
          '<td>' + r[1] + '</td>' +
          '<td>' + r[2] + '</td>' +
          '<td>' + r[3] + '</td>' +
        '</tr>';
      }).join('');
      tbody.innerHTML = html;
    }

    async function fetchTraffic() {
      try {
        const res = await fetch('traffic.json?_=' + Date.now(), { cache: 'no-store' });
        if (!res.ok) {
          throw new Error('HTTP ' + res.status);
        }
        const data = await res.json();

        if (data.error) {
          document.getElementById('rx').textContent = 'Error';
          document.getElementById('tx').textContent = 'Error';
          document.getElementById('iface').textContent = '错误';
          document.getElementById('updated').textContent = data.error;
          document.getElementById('rx').classList.add('error');
          document.getElementById('tx').classList.add('error');
          return;
        }

        // 实时速率
        document.getElementById('rx').textContent = data.rx_human || (data.rx_mbps + ' Mbps');
        document.getElementById('tx').textContent = data.tx_human || (data.tx_mbps + ' Mbps');
        document.getElementById('iface').textContent = data.iface || '--';

        const ts = data.timestamp ? new Date(data.timestamp * 1000) : new Date();
        document.getElementById('updated').textContent =
          '最后更新：' + ts.toLocaleString();

        const statsError = data.stats_error;
        if (statsError) {
          document.getElementById('stats-error').textContent = '统计信息：' + statsError;
        } else {
          document.getElementById('stats-error').textContent = '';
        }

        // 今日概览
        if (data.today) {
          document.getElementById('today-total').textContent = (data.today.total_gb ?? '--') + ' GB';
          document.getElementById('today-rx').textContent = data.today.rx_gb ?? '--';
          document.getElementById('today-tx').textContent = data.today.tx_gb ?? '--';
        }

        // 计费周期
        if (data.period) {
          document.getElementById('period-total').textContent = (data.period.total_gb ?? '--') + ' GB';
          document.getElementById('period-rx').textContent = data.period.rx_gb ?? '--';
          document.getElementById('period-tx').textContent = data.period.tx_gb ?? '--';
          document.getElementById('period-range').textContent =
            (data.period.from || '?') + ' ~ ' + (data.period.to || '?') +
            '（每月 ' + (data.billing_day || data.period.billing_day || '?') + ' 号结算）';
        }

        // 按小时
        const hourly = (data.hourly || []).map(h => [
          h.label || h.datetime || '',
          h.rx_gb ?? 0,
          h.tx_gb ?? 0,
          h.total_gb ?? 0
        ]);
        renderTable('tbody-hourly', hourly, 4);

        // 按天
        const daily = (data.daily || []).map(d => [
          d.date || '',
          d.rx_gb ?? 0,
          d.tx_gb ?? 0,
          d.total_gb ?? 0
        ]);
        renderTable('tbody-daily', daily, 4);

        // 按月
        const monthly = (data.monthly || []).map(m => [
          m.month || '',
          m.rx_gb ?? 0,
          m.tx_gb ?? 0,
          m.total_gb ?? 0
        ]);
        renderTable('tbody-monthly', monthly, 4);

      } catch (e) {
        document.getElementById('updated').textContent = '无法获取数据：' + e.message;
      }
    }

    fetchTraffic();
    setInterval(fetchTraffic, 1000);
  </script>
</body>
</html>
EOF

echo
echo ">>> 是否要为面板配置 HTTPS（使用你已有的 SSL 证书）？"
read -p "启用 HTTPS? (y/N): " ENABLE_HTTPS

if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
  echo
  read -p "请输入面板访问域名（例如 panel.example.com）: " PANEL_DOMAIN

  # 默认证书路径
  read -p "请输入 SSL 证书文件路径 [默认: /root/cert.crt]: " SSL_CERT
  SSL_CERT=${SSL_CERT:-/root/cert.crt}

  read -p "请输入 SSL 私钥文件路径 [默认: /root/private.key]: " SSL_KEY
  SSL_KEY=${SSL_KEY:-/root/private.key}

  if [ -z "$PANEL_DOMAIN" ]; then
    echo "域名不能为空，暂不配置 HTTPS，仅使用 HTTP。"
    systemctl restart nginx
  else
    echo ">>> 写入 Nginx 站点配置 /etc/nginx/sites-available/net-panel.conf ..."
    cat >/etc/nginx/sites-available/net-panel.conf <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /traffic.json {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
    }
}
EOF

    echo ">>> 启用 net-panel 站点，关闭默认站点 ..."
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/net-panel.conf /etc/nginx/sites-enabled/net-panel.conf

    echo ">>> 检查 Nginx 配置 ..."
    nginx -t

    echo ">>> 重新加载 Nginx ..."
    systemctl reload nginx

    echo
    echo "================ 安装完成（HTTPS 已启用） ================"
    echo "现在可以通过：https://${PANEL_DOMAIN}"
    echo "访问 VPS 实时流量与统计面板。"
    echo "====================================================="
    exit 0
  fi
else
  echo "不启用 HTTPS，仅使用 HTTP。"
  systemctl restart nginx
fi

echo
echo "================ 安装完成（HTTP 模式） ================="
echo "现在你可以在浏览器访问：http://你的服务器IP"
echo "查看 VPS 实时流量与统计面板。"
echo
echo "如需之后启用 HTTPS，可重新运行本脚本，或手动编辑 Nginx 配置。"
echo "==================================================="
