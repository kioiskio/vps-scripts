#!/usr/bin/env bash
# install-cx-monitor.sh — Hetzner CX33/CX43 Helsinki 库存监控（一键安装）
#
# 用法（在 kio-dev-2 的 root shell 里执行，保持终端可交互）：
#   curl -fsSL -o /tmp/install-cx-monitor.sh \
#     https://raw.githubusercontent.com/kioiskio/vps-scripts/main/install-cx-monitor.sh \
#     && sudo bash /tmp/install-cx-monitor.sh
#
# 做什么：
#   1. 装 Playwright + headless Chromium（常驻登录态，不会像别人的浏览器那样被整机替换丢掉）
#   2. 交互式一次性登录 console.hetzner.com（密码只用这一次，不存盘）
#   3. 用 Cloud API token 读取 kio-dev-2 的镜像/SSH key/防火墙，写进配置
#   4. 装 systemd timer，每小时查一次 Helsinki 的 CX33 / CX43 库存（hover 二次验证）
#   5. CX43 有货 → 按既定授权自动建 kio-dev-3（8vCPU/16G/160G，价格核对 $18.49），绝不碰 kio-dev-2
#   6. 关键事件经已有的 Hermes Telegram bot 通知
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "请用 root 跑：sudo bash $0"; exit 1; fi

WORKDIR=/root/.cx-monitor
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"

echo "==> 1/6 安装 Playwright + Chromium 依赖"
apt-get update -qq
apt-get install -y -qq python3-pip python3-venv >/dev/null
python3 -m venv "$WORKDIR/venv"
VPY="$WORKDIR/venv/bin/python3"
"$VPY" -m pip install -q playwright httpx
"$VPY" -m playwright install --only-shell chromium 2>&1 | tail -1
"$VPY" -m playwright install-deps chromium 2>&1 | tail -1 || true

echo "==> 2/6 配置 Hetzner Cloud API token"
echo "    去 console.hetzner.com → 顶部头像/账户 → Security → API tokens → Generate API token"
echo "    权限选 Read & write（建服务器需要写权限），名字随便填比如 cx-monitor"
read -rsp "    粘贴 API token: " API_TOKEN; echo
if ! curl -fsS -H "Authorization: Bearer $API_TOKEN" https://api.hetzner.cloud/v1/servers >/dev/null; then
  echo "    token 无效或没权限，退出。请重跑本脚本。"; exit 1
fi
echo "    token 有效"

echo "==> 3/6 读取 kio-dev-2 的配置（镜像 / SSH key / 防火墙）"
SRV_JSON=$(curl -fsS -H "Authorization: Bearer $API_TOKEN" "https://api.hetzner.cloud/v1/servers?name=kio-dev-2")
SRV_ID=$(echo "$SRV_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['servers'][0]['id'])")
IMAGE=$(echo "$SRV_JSON" | python3 -c "import json,sys; s=json.load(sys.stdin)['servers'][0]; print(s['image']['name'] or s['image']['id'])")
echo "    kio-dev-2: id=$SRV_ID image=$IMAGE"

# 防火墙：找挂了 kio-dev-2 的那个
FW_ID=$(curl -fsS -H "Authorization: Bearer $API_TOKEN" https://api.hetzner.cloud/v1/firewalls | \
  python3 -c "
import json,sys
sid=$SRV_ID
for fw in json.load(sys.stdin)['firewalls']:
    for r in fw.get('resources',[]):
        if r.get('type')=='server' and r.get('server',{}).get('id')==sid:
            print(fw['id']); raise SystemExit
print('')")
[[ -n "$FW_ID" ]] && echo "    firewall id=$FW_ID" || echo "    未发现挂载的防火墙，新机器将不挂防火墙"

# SSH key：用 authorized_keys 跟 API 列出的 key 做匹配
SSH_KEY_NAME=$(CX_API_TOKEN="$API_TOKEN" python3 - <<'PYEOF'
import json,os,urllib.request
token=os.environ["CX_API_TOKEN"]
req=urllib.request.Request("https://api.hetzner.cloud/v1/ssh_keys",
    headers={"Authorization":f"Bearer {token}"})
keys=json.load(urllib.request.urlopen(req))["ssh_keys"]
auth=open("/root/.ssh/authorized_keys").read().split()
found=""
for k in keys:
    parts=k["public_key"].split()
    if len(parts)>=2 and parts[1] in auth:
        found=k["name"]; break
print(found)
PYEOF
)
[[ -n "$SSH_KEY_NAME" ]] && echo "    ssh key=$SSH_KEY_NAME" || { echo "    没匹配到 SSH key，退出"; exit 1; }

echo "==> 4/6 一次性登录 console.hetzner.com（密码仅本次使用，不存盘）"
read -rp "    Hetzner 账号邮箱: " H_EMAIL
read -rsp "    密码: " H_PASS; echo
CX_H_EMAIL="$H_EMAIL" CX_H_PASS="$H_PASS" "$VPY" - "$WORKDIR" <<'PYEOF'
import os, sys
from playwright.sync_api import sync_playwright
workdir = sys.argv[1]
email, password = os.environ["CX_H_EMAIL"], os.environ["CX_H_PASS"]
with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(workdir + "/profile", headless=True,
        args=["--disable-blink-features=AutomationControlled"])
    pg = ctx.new_page()
    pg.goto("https://console.hetzner.com/", timeout=60000)
    pg.wait_for_timeout(3000)
    if "login" in pg.url or "accounts.hetzner.com" in pg.url:
        pg.locator('input[type="email"]').first.fill(email)
        pg.locator('input[type="password"]').first.fill(password)
        pg.locator('button[type="submit"]').first.click()
        pg.wait_for_timeout(4000)
        # 可能的 2FA
        code_inputs = pg.locator('input[name*="code" i], input[name*="otp" i], input[autocomplete="one-time-code"]')
        if code_inputs.count() > 0:
            code = input("    检测到两步验证，请输入验证码: ").strip()
            code_inputs.first.fill(code)
            pg.locator('button[type="submit"]').first.click()
            pg.wait_for_timeout(4000)
        pg.wait_for_url("**/console.hetzner.com/**", timeout=30000)
    assert "console.hetzner.com" in pg.url and "login" not in pg.url, "登录失败，请重跑"
    print("    登录成功，会话已保存到常驻 profile")
    ctx.close()
PYEOF

echo "==> 5/6 配置 Telegram 通知（复用 Hermes bot）"
TG_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' /root/.hermes/.env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
TG_CHAT=""
if [[ -n "$TG_TOKEN" ]]; then
  for i in 1 2 3; do
    TG_CHAT=$(curl -fsS "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" | \
      python3 -c "
import json,sys
ids=[]
try:
  for u in json.load(sys.stdin).get('result',[]):
    m=u.get('message') or {}
    c=m.get('chat') or {}
    if c.get('type')=='private': ids.append(str(c['id']))
except Exception: pass
print(ids[-1] if ids else '')" 2>/dev/null)
    [[ -n "$TG_CHAT" ]] && break
    read -rp "    没找到聊天记录：请先给你的 bot 发任意一条消息，然后回车: " _
  done
fi
[[ -n "$TG_CHAT" ]] && echo "    Telegram 通知目标 chat_id=$TG_CHAT" || echo "    跳过 Telegram 通知（只写日志）"

# 写配置（0600），密钥走环境变量，不进 argv
CX_API_TOKEN="$API_TOKEN" CX_TG_TOKEN="$TG_TOKEN" "$VPY" - "$WORKDIR" "$IMAGE" "$SSH_KEY_NAME" "$FW_ID" "$TG_CHAT" <<'PYEOF'
import json,os,sys
w, image, key, fw, tg_chat = sys.argv[1:6]
token = os.environ["CX_API_TOKEN"]
tg_token = os.environ.get("CX_TG_TOKEN") or None
cfg = {"api_token": token, "image": image, "ssh_key": key,
       "firewall_id": int(fw) if fw else None,
       "telegram_token": tg_token or None, "telegram_chat_id": tg_chat or None,
       "create_url": None, "state": {"last_cx33_notify": 0, "last_session_notify": 0}}
p = os.path.join(w, "config.json")
json.dump(cfg, open(p, "w"), indent=2)
os.chmod(p, 0o600)
print("    配置已写入（0600）")
PYEOF
unset API_TOKEN H_PASS

echo "==> 6/6 下载监控脚本 + 写入 systemd 定时任务"
RAW=https://raw.githubusercontent.com/kioiskio/vps-scripts/main
curl -fsSL -o "$WORKDIR/cx-monitor.py" "$RAW/cx-monitor.py"
curl -fsSL -o "$WORKDIR/relogin.py"  "$RAW/relogin.py"
chmod 700 "$WORKDIR/cx-monitor.py" "$WORKDIR/relogin.py"
VPY="$WORKDIR/venv/bin/python3"

cat > /etc/systemd/system/cx-monitor.service <<EOF
[Unit]
Description=Hetzner CX33/CX43 Helsinki stock check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$VPY $WORKDIR/cx-monitor.py
EOF

cat > /etc/systemd/system/cx-monitor.timer <<EOF
[Unit]
Description=Hourly Hetzner CX stock check

[Timer]
OnCalendar=*-*-* *:08:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
echo "    定时任务已写入（先不启用，等演习通过）"

echo "==> 首次试运行（演习模式：只查库存，绝不下单）"
if "$VPY" "$WORKDIR/cx-monitor.py" --dry-run; then
  systemctl enable --now cx-monitor.timer
  echo "    演习通过，定时任务已启用（每小时 :08 跑一次）"
else
  echo "    演习没通过，定时任务未启用。请看上方日志排查，或重跑本脚本。"
  exit 1
fi
echo
echo "完成。日志：$WORKDIR/check.log ；截图：$WORKDIR/last-check.png"
