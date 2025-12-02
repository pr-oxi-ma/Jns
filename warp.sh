#!/usr/bin/env bash
set -euo pipefail

# Improved Cloudflare WARP installer (Dual-stack aware)
# Debian 10/11/12 compatible
# Run as root (sudo)

WGCF_BIN="/usr/local/bin/wgcf"
WGCF_VER="2.2.19"   # fallback version - change if you want a newer release
WGCF_URL="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${WGCF_VER}_linux_amd64"
WGCF_ACCOUNT="/root/wgcf-account.toml"
WGCF_PROFILE="/root/wgcf-profile.conf"
WG_CONF="/etc/wireguard/wgcf.conf"
ROTATE_SCRIPT="/usr/local/bin/warp-rotate.sh"
ROTATE_LOG="/var/log/warp-rotate.log"

echo "=== Cloudflare WARP Dual-Stack Installer ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

echo "[1/8] Installing prerequisites..."
apt update -y
apt install -y wireguard resolvconf curl wget iproute2 ca-certificates

echo "[2/8] Downloading wgcf..."
if [ ! -x "$WGCF_BIN" ]; then
  wget -q -O "$WGCF_BIN" "$WGCF_URL" || {
    echo "wgcf download failed. Trying github generic latest redirect..."
    wget -q -O "$WGCF_BIN" "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${WGCF_VER}_linux_amd64"
  }
  chmod +x "$WGCF_BIN"
fi

echo "[3/8] Registering WARP account (non-interactive)..."
# keep a local copy of account/profile in root so user can inspect them
cd /root
# wgcf register can fail if rate-limited; allow it to continue if account exists
if [ ! -f "$WGCF_ACCOUNT" ]; then
  # non-interactive register (sends yes to prompt where appropriate)
  yes | $WGCF_BIN register || true
fi

if [ ! -f "$WGCF_ACCOUNT" ]; then
  echo "wgcf account file not found after register. Check /root for wgcf-account.toml"
  ls -l /root/wgcf*.toml || true
  echo "Abort."
  exit 1
fi

echo "[4/8] Generating WireGuard profile..."
$WGCF_BIN generate || true

if [ ! -f "$WGCF_PROFILE" ]; then
  echo "Profile not found at $WGCF_PROFILE — aborting."
  ls -l /root || true
  exit 1
fi

echo "[5/8] Installing WireGuard config..."
mkdir -p /etc/wireguard
mv -f "$WGCF_PROFILE" "$WG_CONF"
chmod 600 "$WG_CONF"

echo "[6/8] Detecting host networking capabilities..."
# Detect IPv4 / IPv6 connectivity (use public endpoints)
HAS_IPV4=0
HAS_IPV6=0
if curl -4 -s --max-time 5 https://ifconfig.co >/dev/null; then HAS_IPV4=1; fi
if curl -6 -s --max-time 5 https://ifconfig.co >/dev/null; then HAS_IPV6=1; fi

echo "Host IPv4 connectivity: $HAS_IPV4"
echo "Host IPv6 connectivity: $HAS_IPV6"

echo "[7/8] Patching wgcf config for dual-stack routing & DNS..."
# We'll ensure AllowedIPs is full-tunnel and add PostUp/PostDown hooks
# Backup original
cp -f "$WG_CONF" "${WG_CONF}.bak.$(date +%s)"

# Ensure AllowedIPs contains both families (full-tunnel)
# Replace or append AllowedIPs line
if grep -q "^AllowedIPs" "$WG_CONF"; then
  sed -i 's/^AllowedIPs.*/AllowedIPs = 0.0.0.0\/0, ::\/0/' "$WG_CONF"
else
  sed -i '/\[Peer\]/a AllowedIPs = 0.0.0.0/0, ::/0' "$WG_CONF"
fi

# Ensure DNS present in [Interface]
if ! grep -q "^DNS" "$WG_CONF"; then
  sed -i "/^\[Interface\]/a DNS = 1.1.1.1, 2606:4700:4700::1111" "$WG_CONF"
fi

# Add PostUp/PostDown to set default routes through wgcf interface
# We will add smart PostUp/PostDown that adapt to ipv4/ipv6 presence

POSTUP=$(cat <<'EOF'
# PostUp: add default routes via this interface (replace)
# IPv4 default via interface (if host had or via WARP)
ip -4 route replace default dev %i || true
# IPv6 default via interface
ip -6 route replace default dev %i || true
# Bring up IPv6 sysctl forwarding to be safe
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
EOF
)

POSTDOWN=$(cat <<'EOF'
# PostDown: remove default routes via this interface
ip -4 route del default dev %i 2>/dev/null || true
ip -6 route del default dev %i 2>/dev/null || true
EOF
)

# Remove existing PostUp/PostDown if present
sed -i '/^PostUp/d' "$WG_CONF" || true
sed -i '/^PostDown/d' "$WG_CONF" || true

# Append PostUp/PostDown under [Interface]
awk -v post="$POSTUP" -v postd="$POSTDOWN" '
  BEGIN{p=0}
  /^\[Interface\]/{print; p=1; next}
  p==1 && NF==0 { print post; print postd; p=2; next }
  { print }
  END { if(p==1) { print post; print postd } }
' "$WG_CONF" > "${WG_CONF}.tmp" && mv -f "${WG_CONF}.tmp" "$WG_CONF"

# Ensure permissions
chmod 600 "$WG_CONF"

echo "[8/8] Enable & start WireGuard, create rotation script & cron..."

# Enable and start
systemctl enable wg-quick@wgcf >/dev/null 2>&1 || true
systemctl restart wg-quick@wgcf

# Rotation script (restart wg-quick to refresh addresses)
cat > "$ROTATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e
SYSTEMD_NAME="wg-quick@wgcf"
echo "$(date -Iseconds) - rotating WARP" >> /var/log/warp-rotate.log
systemctl restart $SYSTEMD_NAME
sleep 3
# Log new addresses (both v4 & v6) for review
ip -4 addr show dev wgcf >> /var/log/warp-rotate.log 2>&1 || true
ip -6 addr show dev wgcf >> /var/log/warp-rotate.log 2>&1 || true
echo "$(date -Iseconds) - rotation complete" >> /var/log/warp-rotate.log
EOF
chmod +x "$ROTATE_SCRIPT"
touch "$ROTATE_LOG"
chown root:root "$ROTATE_LOG"
chmod 600 "$ROTATE_LOG"

# Add cron entry if not present
CRON_ENTRY="0 */12 * * * $ROTATE_SCRIPT >/dev/null 2>&1"
# ensure crontab exists and add if missing
(crontab -l 2>/dev/null | grep -Fv "$ROTATE_SCRIPT" || true; echo "$CRON_ENTRY") | crontab -

echo ""
echo "=== Completed installation ==="
echo "Configuration file: $WG_CONF (backup in ${WG_CONF}.bak*)"
echo "Rotation script: $ROTATE_SCRIPT (logs to $ROTATE_LOG)"
echo ""

echo "Diagnostics (live check):"
echo "- wg-quick status:"
wg show || true
echo ""
echo "- Public IPv4 (via curl -4 if reachable):"
curl -4 --fail -s https://ifconfig.co || echo "IPv4 check failed or not available"
echo ""
echo "- Public IPv6 (via curl -6 if reachable):"
curl -6 --fail -s https://ifconfig.co || echo "IPv6 check failed or not available"
echo ""
echo "To view rotation log:"
echo "  sudo cat $ROTATE_LOG"
echo ""
echo "If you need the profile/regenerated account, find them in /root (wgcf-account.toml, wgcf-profile.conf backup)."
echo ""
echo "If anything fails, restore the original config:"
echo "  sudo mv ${WG_CONF}.bak.* $WG_CONF && systemctl restart wg-quick@wgcf"
echo ""
echo "Done."
