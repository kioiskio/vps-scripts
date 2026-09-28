#!/bin/bash
# n8n 一键安装脚本（kio-dev / Ubuntu / root）
# 用法：curl -fsSL <gist raw url> | bash
set -e

# 1. Docker（没有才装）
if ! command -v docker >/dev/null 2>&1; then
  echo ">> 安装 Docker..."
  apt-get update -qq
  apt-get install -y -qq docker.io
  systemctl enable --now docker
fi

# 2. 启动 n8n（只监听本机，不直接暴露公网）
N8N_PASS=$(head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)
docker volume create n8n_data >/dev/null 2>&1 || true
docker rm -f n8n >/dev/null 2>&1 || true
echo ">> 拉取并启动 n8n（第一次会下载镜像，稍等）..."
docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=true \
  -e N8N_BASIC_AUTH_USER=admin \
  -e N8N_BASIC_AUTH_PASSWORD="$N8N_PASS" \
  -v n8n_data:/home/node/.n8n \
  docker.n8n.io/n8nio/n8n >/dev/null

# 3. 等 n8n 就绪
for i in $(seq 1 30); do
  curl -sf -o /dev/null http://127.0.0.1:5678/ && break
  sleep 2
done

# 4. cloudflared 隧道暴露到公网
pkill -f "cloudflared tunnel --url http://localhost:5678" 2>/dev/null || true
rm -f /root/n8n-tunnel.log
nohup cloudflared tunnel --url http://localhost:5678 >/root/n8n-tunnel.log 2>&1 &
URL=""
for i in $(seq 1 15); do
  sleep 2
  URL=$(grep -o 'https://[^ ]*trycloudflare.com' /root/n8n-tunnel.log 2>/dev/null | head -1)
  [ -n "$URL" ] && break
done

echo ""
echo "================ n8n 安装完成 ================"
echo "访问地址: ${URL:-没抓到，请看 /root/n8n-tunnel.log}"
echo "用户名: admin"
echo "密码: $N8N_PASS"
echo "（密码只显示一次，请记下来）"
echo "=============================================="
