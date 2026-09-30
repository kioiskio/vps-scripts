#!/usr/bin/env python3
"""
cx-monitor.py — Hetzner CX33/CX43 Helsinki 库存监控 + 自动建机

铁律（写死在代码里）：
  - 只新建一台 CX43（kio-dev-3）。绝不碰 kio-dev-2（不升级/不降级/不改任何设置）。
  - 绝不删除任何服务器、快照、Primary IP。
  - 价格/规格与预期明显不符 → 停手并通知。
  - 只有 hover 二次验证确认为"有货"才下单；页面结构识别失败 → 只记录+通知，不下单。

配置：/root/.cx-monitor/config.json（0600）
日志：/root/.cx-monitor/check.log
"""
import json, os, sys, time, urllib.request, urllib.error

WORKDIR = "/root/.cx-monitor"
CFG_PATH = os.path.join(WORKDIR, "config.json")
LOG_PATH = os.path.join(WORKDIR, "check.log")

EXPECTED = {"name": "cx43", "cores": 8, "memory_gb": 16, "disk_gb": 160,
            "price_monthly": 18.49, "location": "hel1", "new_name": "kio-dev-3"}
DRY_RUN = "--dry-run" in sys.argv

def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")

def api(cfg, method, path, body=None):
    req = urllib.request.Request(
        "https://api.hetzner.cloud" + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {cfg['api_token']}",
                 "Content-Type": "application/json"},
        method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"API {method} {path} -> HTTP {e.code}: {e.read()[:300]}")

def notify(cfg, text):
    if not (cfg.get("telegram_token") and cfg.get("telegram_chat_id")):
        log("TG未配置，跳过通知")
        return
    try:
        urllib.request.urlopen(urllib.request.Request(
            f"https://api.telegram.org/bot{cfg['telegram_token']}/sendMessage",
            data=json.dumps({"chat_id": cfg["telegram_chat_id"], "text": text}).encode(),
            headers={"Content-Type": "application/json"}), timeout=20)
        log("TG通知已发")
    except Exception as e:
        log(f"TG通知失败: {e}")

def throttled(cfg, key, hours=24):
    now = time.time()
    if now - cfg["state"].get(key, 0) < hours * 3600:
        return False
    cfg["state"][key] = now
    return True

def save_cfg(cfg):
    json.dump(cfg, open(CFG_PATH, "w"), indent=2)
    os.chmod(CFG_PATH, 0o600)

# ---------- 库存检查（Playwright 常驻登录态） ----------
def check_stock():
    """返回 (cx33_ok, cx43_ok, note)。任一环节识别失败则抛异常。"""
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            os.path.join(WORKDIR, "profile"), headless=True,
            args=["--disable-blink-features=AutomationControlled"])
        pg = ctx.new_page()
        try:
            pg.goto("https://console.hetzner.com/", timeout=60000)
            pg.wait_for_timeout(3000)
            if "login" in pg.url or "accounts.hetzner.com" in pg.url:
                raise RuntimeError("SESSION_LOST")
            # 进建机页：优先直接 URL，不行再点
            pg.goto("https://console.hetzner.com/servers/add", timeout=60000)
            pg.wait_for_timeout(4000)
            if "add" not in pg.url and "server" not in pg.url.lower():
                # 回退：点界面
                for sel in ['a[href*="servers/add"]', 'button:has-text("Add Server")',
                            'a:has-text("Add Server")']:
                    if pg.locator(sel).count():
                        pg.locator(sel).first.click(); pg.wait_for_timeout(4000); break
            # 选 Helsinki
            clicked = False
            for sel in ['text=Helsinki', '[data-testid*="hel1" i]', 'text=hel1']:
                loc = pg.locator(sel).first
                if loc.count():
                    loc.click(); clicked = True; pg.wait_for_timeout(2500); break
            if not clicked:
                pg.screenshot(path=os.path.join(WORKDIR, "last-check.png"))
                raise RuntimeError("找不到 Helsinki 选项，页面结构可能变了")
            result, note = {}, "ok"
            for plan in ("CX33", "CX43"):
                row = None
                for sel in [f'text={plan}', f'[data-testid*="{plan.lower()}" i]']:
                    loc = pg.locator(sel).first
                    if loc.count():
                        row = loc; break
                if row is None:
                    pg.screenshot(path=os.path.join(WORKDIR, "last-check.png"))
                    raise RuntimeError(f"找不到 {plan} 行，页面结构可能变了")
                row.hover()
                pg.wait_for_timeout(900)
                # hover 验证：出现 Not available tooltip = 没货
                tip = pg.locator('text=Not available. Please choose another location or type.')
                unavailable = tip.count() > 0
                # 辅助信号：disabled / aria-disabled
                try:
                    dis = row.evaluate(
                        "el => el.closest('[disabled],[aria-disabled=\"true\"],.disabled') !== null")
                except Exception:
                    dis = False
                result[plan] = (not unavailable) and (not dis)
                log(f"{plan}: hover无缺货提示={not unavailable} 非禁用={not dis} -> {'有货' if result[plan] else '无货'}")
            pg.screenshot(path=os.path.join(WORKDIR, "last-check.png"))
            return result["CX33"], result["CX43"], note
        finally:
            ctx.close()

# ---------- 建机（走 Cloud API，确定性强） ----------
def ensure_kio_dev_3(cfg):
    st = api(cfg, "GET", f"/v1/server_types?name={EXPECTED['name']}")
    types = st.get("server_types", [])
    if not types:
        raise RuntimeError("API 里找不到 cx43 类型")
    t = types[0]
    if not (t["cores"] == 8 and int(t["memory"]) == 16 and int(t["disk"]) == 160):
        raise RuntimeError(f"cx43 规格变了: {t['cores']}c/{t['memory']}G/{t['disk']}G，停手")
    price = None
    for pr in t.get("prices", []):
        if pr.get("location") == EXPECTED["location"]:
            price = float(pr["price_monthly"]["gross"]); break
    log(f"cx43 Helsinki 月价 gross={price}")
    if price is None or abs(price - EXPECTED["price_monthly"]) > 1.0:
        raise RuntimeError(f"价格异常({price})，停手待确认")

    # 幂等：kio-dev-3 已存在就不建
    ex = api(cfg, "GET", f"/v1/servers?name={EXPECTED['new_name']}")
    if ex.get("servers"):
        s = ex["servers"][0]
        log(f"kio-dev-3 已存在(id={s['id']}, status={s['status']})，不再重复建")
        return s

    body = {"name": EXPECTED["new_name"], "server_type": "cx43",
            "location": EXPECTED["location"], "image": cfg["image"],
            "ssh_keys": [cfg["ssh_key"]], "labels": {"purpose": "dev"}}
    if cfg.get("firewall_id"):
        body["firewalls"] = [{"firewall": cfg["firewall_id"]}]
    log(f"下单建机: {body}")
    r = api(cfg, "POST", "/v1/servers", body)
    srv = r["server"]
    log(f"已创建 id={srv['id']}，等 running…")
    for _ in range(60):
        s = api(cfg, "GET", f"/v1/servers/{srv['id']}")["server"]
        if s["status"] == "running":
            ip = (s.get("public_net") or {}).get("ipv4", {}).get("ip")
            log(f"running，IPv4={ip}")
            return s
        time.sleep(10)
    raise RuntimeError("建机超时（10分钟未 running），请人工检查")

def main():
    cfg = json.load(open(CFG_PATH))
    log("=== 开始检查 ===")
    try:
        cx33, cx43, _ = check_stock()
    except RuntimeError as e:
        if str(e) == "SESSION_LOST":
            log("登录态失效")
            if throttled(cfg, "last_session_notify"):
                notify(cfg, "Hetzner 监控：console 登录态掉了，需要重新登录。请在 VPS 上跑：\n"
                            "python3 /root/.cx-monitor/relogin.py\n（会提示输入账号密码）")
                save_cfg(cfg)
            return 2
        log(f"检查失败: {e}")
        if throttled(cfg, "last_check_fail_notify"):
            notify(cfg, f"Hetzner 监控：库存页识别失败（{e}），本次未下单。截图在 VPS 的 /root/.cx-monitor/last-check.png")
            save_cfg(cfg)
        return 1

    if cx43:
        log("CX43 Helsinki 有货")
        if DRY_RUN:
            log("DRY-RUN：演习模式，不下单")
            notify(cfg, "Hetzner 监控自检：CX43 Helsinki 有货（演习模式，未下单）。"
                         "确认无误后，取消演习即可按授权自动建机。")
            return 0
        log("按授权自动建机")
        try:
            s = ensure_kio_dev_3(cfg)
            ip = (s.get("public_net") or {}).get("ipv4", {}).get("ip")
            notify(cfg,
                f"✅ kio-dev-3 已建成并 running\n"
                f"CX43 · 8 vCPU / 16GB / 160GB · Helsinki\n"
                f"IP：{ip}\n"
                f"现在两台同时计费：kio-dev-2 $7.09 + kio-dev-3 $18.49\n"
                f"Hermes/数据迁不迁移、旧机器何时退役，你定。")
            cfg["state"]["done"] = True
            save_cfg(cfg)
        except RuntimeError as e:
            log(f"建机中止: {e}")
            notify(cfg, f"Hetzner 监控：CX43 有货但建机中止——{e}")
        return 0

    if cx33:
        log("CX43 无货，CX33 有货")
        if throttled(cfg, "last_cx33_notify"):
            notify(cfg, "Hetzner 监控：CX43 依然无货，CX33 有货（按你的意思只通知、不自动买）。")
            save_cfg(cfg)
    else:
        log("CX33 / CX43 都无货，保持安静")
    return 0

if __name__ == "__main__":
    sys.exit(main())
