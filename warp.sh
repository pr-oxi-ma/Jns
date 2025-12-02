#!/bin/bash
set -e

echo "==============================="
echo "  Cloudflare WARP Installer"
echo "==============================="
sleep 1

echo "[1/8] Updating system..."
apt update -y
apt install -y wireguard resolvconf curl wget

echo "[2/8] Downloading wgcf..."
WGCF_URL="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_2.2.19_linux_amd64"
wget -O /usr/local/bin/wgcf $WGCF_URL
chmod +x /usr/local/bin/wgcf

echo "[3/8] Registering WARP account..."
yes | wgcf register || true

echo "[4/8] Generating WireGuard profile..."
wgcf generate

echo "[5/8] Installing WireGuard config..."
mv wgcf-profile.conf /etc/wireguard/wgcf.conf

echo "[6/8] Patching WireGuard config..."
cat >> /etc/wireguard/wgcf.conf <<EOF

# Routing Fix
PostUp = ip -6 route replace default dev %i
PostDown = ip -6 route del default dev %i

# DNS
DNS = 2606:4700:4700::1111
EOF

echo "[7/8] Creating rotation script..."
cat > /usr/local/bin/warp-rotate.sh <<EOF
#!/bin/bash
systemctl stop wg-quick@wgcf
sleep 2
systemctl start wg-quick@wgcf
echo "Rotated WARP IPv6 at \$(date)" >> /var/log/warp-rotate.log
EOF
chmod +x /usr/local/bin/warp-rotate.sh

echo "[8/8] Enabling WARP..."
systemctl enable wg-quick@wgcf
systemctl start wg-quick@wgcf

echo "Setting up 12-hour rotation (cron)..."
(crontab -l 2>/dev/null; echo "0 */12 * * * /usr/local/bin/warp-rotate.sh") | crontab -

echo "==========================================="
echo "   🎉 Installation Completed!"
echo "==========================================="
echo ""
echo "Check IPv6:"
echo "  curl -6 https://ifconfig.co"
echo ""
echo "Rotation log:"
echo "  cat /var/log/warp-rotate.log"
echo ""
