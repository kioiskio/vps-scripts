#!/usr/bin/env python3
"""relogin.py — Hetzner console 登录态掉了时，手动重登（密码仅本次使用，不存盘）。"""
import getpass, os, sys

WORKDIR = "/root/.cx-monitor"

def main():
    email = input("Hetzner 账号邮箱: ").strip()
    password = getpass.getpass("密码: ")
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
                pg.locator('input[type="email"]').first.fill(email)
                pg.locator('input[type="password"]').first.fill(password)
                pg.locator('button[type="submit"]').first.click()
                pg.wait_for_timeout(4000)
                codes = pg.locator('input[name*="code" i], input[name*="otp" i], input[autocomplete="one-time-code"]')
                if codes.count() > 0:
                    codes.first.fill(input("两步验证码: ").strip())
                    pg.locator('button[type="submit"]').first.click()
                    pg.wait_for_timeout(4000)
                pg.wait_for_url("**/console.hetzner.com/**", timeout=30000)
            assert "console.hetzner.com" in pg.url and "login" not in pg.url
            print("登录成功，会话已保存")
        finally:
            ctx.close()

if __name__ == "__main__":
    sys.exit(main())
