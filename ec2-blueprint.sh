#!/bin/bash
set -e

OUT="$HOME/ec2-blueprint"
mkdir -p "$OUT"

echo "[1/6] Detecting system..."

OS=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME)
KERNEL=$(uname -r)

PHP_VER=$(php -v 2>/dev/null | head -n1 || echo "none")
NODE_VER=$(node -v 2>/dev/null || echo "none")
PY_VER=$(python3 --version 2>/dev/null || echo "none")

echo "[2/6] Collecting services..."

systemctl list-unit-files --state=enabled > "$OUT/enabled-services.txt"
systemctl list-units --type=service --state=running > "$OUT/running-services.txt"

echo "[3/6] Detecting apps..."

find /var/www -name artisan 2>/dev/null | sed 's|/artisan||' > "$OUT/laravel.txt"
find /var/www -name package.json 2>/dev/null | xargs -n1 dirname > "$OUT/node.txt"
find /var/www -name requirements.txt 2>/dev/null | xargs -n1 dirname > "$OUT/python.txt"

echo "[4/6] Extracting nginx domain map..."

sudo grep -R "server_name" /etc/nginx/sites-enabled 2>/dev/null > "$OUT/nginx-domains.txt"

echo "[5/6] Collecting system config..."

dpkg --get-selections > "$OUT/packages.txt"
php -m > "$OUT/php-modules.txt" 2>/dev/null || true
crontab -l > "$OUT/cron-user.txt" 2>/dev/null || true
sudo crontab -l > "$OUT/cron-root.txt" 2>/dev/null || true

echo "[6/6] Writing final blueprint JSON..."

cat > "$OUT/blueprint.json" <<EOF
{
  "os": "$OS",
  "kernel": "$KERNEL",
  "php": "$PHP_VER",
  "node": "$NODE_VER",
  "python": "$PY_VER"
}
EOF

tar -czf "$OUT.tar.gz" -C "$OUT" .

echo "DONE → $OUT.tar.gz"
