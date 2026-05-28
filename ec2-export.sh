#!/bin/bash
set -e

OUT="$HOME/ec2-export-$(date +%F-%H%M)"
mkdir -p "$OUT"

echo "Exporting server config to $OUT"

# -------- System ----------
OS=$(lsb_release -rs 2>/dev/null || echo "unknown")
DISTRO=$(lsb_release -is 2>/dev/null || echo "Ubuntu")
HOST=$(hostname)

# -------- Versions ----------
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
NODE_VERSION=$(node -v 2>/dev/null | sed 's/v//' || echo "")
PYTHON_VERSION=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "")

# -------- Database detection ----------
DB="none"

if command -v mysql >/dev/null; then
    DB="mysql"
elif command -v mariadb >/dev/null; then
    DB="mariadb"
elif command -v psql >/dev/null; then
    DB="postgresql"
fi

# -------- PM2 detection ----------
PM2="false"
if command -v pm2 >/dev/null; then
    PM2="true"
fi

# -------- Supervisor detection ----------
SUPERVISOR="false"
if systemctl is-active supervisor >/dev/null 2>&1; then
    SUPERVISOR="true"
fi

# -------- Swap detection ----------
SWAP=$(swapon --show | wc -l)

# -------- Find apps ----------
LARAVEL_APPS=$(find /var/www -name artisan 2>/dev/null | sed 's|/artisan||')
NODE_APPS=$(find /var/www -name package.json 2>/dev/null | xargs -n1 dirname)
PYTHON_APPS=$(find /var/www -name requirements.txt 2>/dev/null | xargs -n1 dirname)

# -------- Save config JSON ----------
cat > "$OUT/server-config.json" <<EOF
{
  "hostname": "$HOST",
  "distro": "$DISTRO",
  "ubuntu_version": "$OS",
  "php_version": "$PHP_VERSION",
  "node_version": "$NODE_VERSION",
  "python_version": "$PYTHON_VERSION",
  "database": "$DB",
  "pm2": $PM2,
  "supervisor": $SUPERVISOR,
  "swap_enabled": $([ "$SWAP" -gt 0 ] && echo true || echo false)
}
EOF

# Save app paths
echo "$LARAVEL_APPS" > "$OUT/laravel-apps.txt"
echo "$NODE_APPS" > "$OUT/node-apps.txt"
echo "$PYTHON_APPS" > "$OUT/python-apps.txt"

# Export nginx
sudo cp -r /etc/nginx "$OUT/"

# Export PHP config
sudo cp -r /etc/php "$OUT/" 2>/dev/null || true

# Export supervisor
sudo cp -r /etc/supervisor "$OUT/" 2>/dev/null || true

# Export systemd
sudo cp -r /etc/systemd/system "$OUT/systemd" 2>/dev/null || true

# Export crons
crontab -l > "$OUT/user-cron.txt" 2>/dev/null || true
sudo crontab -l > "$OUT/root-cron.txt" 2>/dev/null || true

# Export SSL paths
sudo cp -r /etc/letsencrypt "$OUT/" 2>/dev/null || true

# PHP modules
php -m > "$OUT/php-modules.txt" 2>/dev/null || true

# Package list
dpkg --get-selections > "$OUT/packages.txt"

tar -czf "$OUT.tar.gz" "$OUT"

echo ""
echo "DONE"
echo "Archive:"
echo "$OUT.tar.gz"
