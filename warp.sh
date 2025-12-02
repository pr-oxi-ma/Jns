#!/bin/bash

echo "=== Installing WireGuard and dependencies ==="
apt update -y
apt install -y wireguard resolvconf curl

echo "=== Downloading wgcf ==="
wget -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_amd64
chmod +x /usr/local/bin/wgcf

echo "=== Registering WARP Account ==="
yes | wgcf register

echo "=== Generating WireGuard config ==="
wgcf generate
mv wgcf-profile.conf /etc/wireguard/wgcf.conf

echo "=== Applying IPv6-only routing fix ==="
sed -i 's/AllowedIPs = .*/AllowedIPs = ::\/0/' /etc/wireguard/wgcf.conf

# Add PostUp/PostDown after [Interface]
sed -i '/^\[Interface\]/a PostUp = ip -6 route add ::/0 dev wgcf\nPostDown = ip -6 route del ::/0 dev wgcf' /etc/wireguard/wgcf.conf

echo "=== Bringing up wgcf interface ==="
wg-quick up wgcf

echo "=== Checking IPv6 ==="
curl -6 https://ifconfig.co || echo "IPv6 check failed"

echo "=== DONE ==="
echo "Your server now has IPv6 via Cloudflare WARP 🎉"
