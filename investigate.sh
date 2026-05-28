#!/bin/bash

# =============================================================================
# investigate.sh — Run this on your OLD server
# Scans your environment and produces a migration manifest
# =============================================================================

set -e

OUTPUT_DIR="./migration_output"
REPORT="$OUTPUT_DIR/migration_report.txt"
MANIFEST="$OUTPUT_DIR/manifest.json"

mkdir -p "$OUTPUT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
info()   { echo -e "${BLUE}[→]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }

divider() { echo "" >> "$REPORT"; echo "========================================" >> "$REPORT"; echo "  $1" >> "$REPORT"; echo "========================================" >> "$REPORT"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        SERVER INVESTIGATION TOOL         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

> "$REPORT"
echo "SERVER MIGRATION REPORT" >> "$REPORT"
echo "Generated: $(date)" >> "$REPORT"
echo "Hostname:  $(hostname)" >> "$REPORT"
echo "User:      $(whoami)" >> "$REPORT"


# =============================================================================
# 1. OS INFO
# =============================================================================
divider "1. OPERATING SYSTEM"
info "Gathering OS info..."

OS_NAME=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
KERNEL=$(uname -r)
ARCH=$(uname -m)

echo "OS:        $OS_NAME" >> "$REPORT"
echo "Kernel:    $KERNEL" >> "$REPORT"
echo "Arch:      $ARCH" >> "$REPORT"
log "OS: $OS_NAME"


# =============================================================================
# 2. PHP
# =============================================================================
divider "2. PHP"
info "Scanning PHP..."

PHP_VERSION=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "not found")
PHP_INI=$(php --ini 2>/dev/null | grep "Loaded Configuration" | awk '{print $NF}')
PHP_EXTENSIONS=$(php -m 2>/dev/null | grep -v '\[' | sort | tr '\n' ',' | sed 's/,$//')
PHP_FPM_POOLS=$(find /etc/php -name "*.conf" -path "*/fpm/pool.d/*" 2>/dev/null | tr '\n' ',')

echo "PHP Version:    $PHP_VERSION" >> "$REPORT"
echo "PHP INI:        $PHP_INI" >> "$REPORT"
echo "Extensions:     $PHP_EXTENSIONS" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- PHP FPM Pools ---" >> "$REPORT"
if [ -n "$PHP_FPM_POOLS" ]; then
    for pool in $(find /etc/php -name "*.conf" -path "*/fpm/pool.d/*" 2>/dev/null); do
        echo "  $pool" >> "$REPORT"
    done
else
    echo "  (none found)" >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "--- Key php.ini settings ---" >> "$REPORT"
if [ -n "$PHP_INI" ] && [ -f "$PHP_INI" ]; then
    for key in upload_max_filesize post_max_size memory_limit max_execution_time max_input_time date.timezone; do
        val=$(php -r "echo ini_get('$key');" 2>/dev/null)
        echo "  $key = $val" >> "$REPORT"
    done
fi

log "PHP $PHP_VERSION — extensions captured"


# =============================================================================
# 3. NGINX
# =============================================================================
divider "3. NGINX"
info "Scanning Nginx..."

NGINX_VERSION=$(nginx -v 2>&1 | awk -F'/' '{print $2}' || echo "not found")
echo "Nginx Version: $NGINX_VERSION" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- Server Blocks (sites-enabled) ---" >> "$REPORT"

VHOSTS_DIR="/etc/nginx/sites-enabled"
if [ -d "$VHOSTS_DIR" ]; then
    for site in "$VHOSTS_DIR"/*; do
        echo "" >> "$REPORT"
        echo "  [$site]" >> "$REPORT"
        # Extract key fields only (server_name, root, listen, proxy_pass)
        grep -E '^\s*(server_name|root|listen|proxy_pass|fastcgi_pass|index)' "$site" 2>/dev/null | sed 's/^/    /' >> "$REPORT" || true
    done
    # Copy full vhost configs
    mkdir -p "$OUTPUT_DIR/nginx"
    cp -r "$VHOSTS_DIR"/* "$OUTPUT_DIR/nginx/" 2>/dev/null || true
    log "Nginx vhosts copied to migration_output/nginx/"
else
    echo "  sites-enabled directory not found" >> "$REPORT"
    warn "Could not find /etc/nginx/sites-enabled"
fi


# =============================================================================
# 4. SSL / CERTBOT
# =============================================================================
divider "4. SSL / CERTBOT"
info "Scanning SSL certificates..."

CERTBOT_VERSION=$(certbot --version 2>&1 || echo "not found")
echo "Certbot: $CERTBOT_VERSION" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- Certificates ---" >> "$REPORT"

if command -v certbot &>/dev/null; then
    certbot certificates 2>/dev/null >> "$REPORT" || echo "  (could not list certs — try running as root)" >> "$REPORT"
    log "Certbot certificates listed"
else
    echo "  Certbot not found" >> "$REPORT"
    warn "Certbot not installed or not in PATH"
fi


# =============================================================================
# 5. NODE / NPM
# =============================================================================
divider "5. NODE / NPM / NVM"
info "Scanning Node environment..."

NODE_VERSION=$(node -v 2>/dev/null || echo "not found")
NPM_VERSION=$(npm -v 2>/dev/null || echo "not found")
NVM_VERSION=$(nvm --version 2>/dev/null || echo "not installed")
GLOBAL_PACKAGES=$(npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/^/  /' || echo "  (none)")

echo "Node:    $NODE_VERSION" >> "$REPORT"
echo "NPM:     $NPM_VERSION" >> "$REPORT"
echo "NVM:     $NVM_VERSION" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- Global NPM Packages ---" >> "$REPORT"
echo "$GLOBAL_PACKAGES" >> "$REPORT"

log "Node $NODE_VERSION / NPM $NPM_VERSION"


# =============================================================================
# 6. PYTHON
# =============================================================================
divider "6. PYTHON"
info "Scanning Python..."

PYTHON3_VERSION=$(python3 --version 2>/dev/null || echo "not found")
PIP3_VERSION=$(pip3 --version 2>/dev/null | awk '{print $2}' || echo "not found")
GLOBAL_PY_PACKAGES=$(pip3 list --format=columns 2>/dev/null | tail -n +3 | sed 's/^/  /' || echo "  (none)")

echo "Python3: $PYTHON3_VERSION" >> "$REPORT"
echo "Pip3:    $PIP3_VERSION" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- Global Python Packages ---" >> "$REPORT"
echo "$GLOBAL_PY_PACKAGES" >> "$REPORT"

log "Python $PYTHON3_VERSION"


# =============================================================================
# 7. COMPOSER
# =============================================================================
divider "7. COMPOSER"
info "Scanning Composer..."

COMPOSER_VERSION=$(composer --version 2>/dev/null | awk '{print $3}' || echo "not found")
echo "Composer: $COMPOSER_VERSION" >> "$REPORT"
log "Composer $COMPOSER_VERSION"


# =============================================================================
# 8. SUPERVISOR
# =============================================================================
divider "8. SUPERVISOR"
info "Scanning Supervisor..."

SUPERVISOR_VERSION=$(supervisord --version 2>/dev/null || echo "not found")
echo "Supervisor: $SUPERVISOR_VERSION" >> "$REPORT"
echo "" >> "$REPORT"
echo "--- Supervisor Programs ---" >> "$REPORT"

SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
if [ -d "$SUPERVISOR_CONF_DIR" ]; then
    for conf in "$SUPERVISOR_CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        echo "  [$conf]" >> "$REPORT"
        grep -E '^\s*(command|directory|user|autostart|numprocs)' "$conf" 2>/dev/null | sed 's/^/    /' >> "$REPORT" || true
        echo "" >> "$REPORT"
    done
    mkdir -p "$OUTPUT_DIR/supervisor"
    cp "$SUPERVISOR_CONF_DIR"/*.conf "$OUTPUT_DIR/supervisor/" 2>/dev/null || true
    log "Supervisor configs copied to migration_output/supervisor/"
else
    echo "  No supervisor configs found at $SUPERVISOR_CONF_DIR" >> "$REPORT"
    warn "Supervisor not configured or not installed"
fi

# Also check supervisorctl status
if command -v supervisorctl &>/dev/null; then
    echo "" >> "$REPORT"
    echo "--- Active Supervisor Status ---" >> "$REPORT"
    supervisorctl status 2>/dev/null >> "$REPORT" || echo "  (unable to get status)" >> "$REPORT"
fi


# =============================================================================
# 9. CRON JOBS
# =============================================================================
divider "9. CRON JOBS"
info "Scanning cron jobs..."

echo "--- Current User Crontab ---" >> "$REPORT"
crontab -l 2>/dev/null >> "$REPORT" || echo "  (no crontab for $(whoami))" >> "$REPORT"

echo "" >> "$REPORT"
echo "--- Root Crontab ---" >> "$REPORT"
sudo crontab -l 2>/dev/null >> "$REPORT" || echo "  (no root crontab or no sudo access)" >> "$REPORT"

echo "" >> "$REPORT"
echo "--- /etc/cron.d/ entries ---" >> "$REPORT"
if [ -d /etc/cron.d ]; then
    ls /etc/cron.d/ 2>/dev/null | sed 's/^/  /' >> "$REPORT"
fi

# Save crontab
crontab -l 2>/dev/null > "$OUTPUT_DIR/crontab_user.txt" || echo "(empty)" > "$OUTPUT_DIR/crontab_user.txt"
log "Cron jobs captured"


# =============================================================================
# 10. SYSTEMD SERVICES (custom ones only)
# =============================================================================
divider "10. SYSTEMD SERVICES (custom)"
info "Scanning custom systemd services..."

echo "--- Custom services in /etc/systemd/system/ ---" >> "$REPORT"
CUSTOM_SERVICES=$(find /etc/systemd/system/ -maxdepth 1 -name "*.service" ! -name "*.wants" 2>/dev/null)
if [ -n "$CUSTOM_SERVICES" ]; then
    for svc in $CUSTOM_SERVICES; do
        echo "  $svc" >> "$REPORT"
    done
    mkdir -p "$OUTPUT_DIR/systemd"
    find /etc/systemd/system/ -maxdepth 1 -name "*.service" -exec cp {} "$OUTPUT_DIR/systemd/" \; 2>/dev/null || true
    log "Custom systemd services copied"
else
    echo "  (none found)" >> "$REPORT"
    log "No custom systemd services found"
fi


# =============================================================================
# 11. ENVIRONMENT FILES
# =============================================================================
divider "11. LARAVEL APP & .ENV FILES"
info "Scanning for Laravel apps and .env files..."

echo "--- Laravel apps found ---" >> "$REPORT"
# Common locations
for base in /var/www /home /srv /opt; do
    if [ -d "$base" ]; then
        find "$base" -maxdepth 4 -name "artisan" 2>/dev/null | while read artisan; do
            app_dir=$(dirname "$artisan")
            echo "  $app_dir" >> "$REPORT"
            if [ -d "$app_dir/.git" ]; then
                GIT_REMOTE=$(git -C "$app_dir" remote get-url origin 2>/dev/null || echo "no remote configured")
                GIT_BRANCH=$(git -C "$app_dir" branch --show-current 2>/dev/null || echo "unknown")
                echo "    → Git remote: $GIT_REMOTE" >> "$REPORT"
                echo "    → Git branch: $GIT_BRANCH" >> "$REPORT"
            else
                echo "    → Git: not a git repo" >> "$REPORT"
            fi
            if [ -f "$app_dir/.env" ]; then
                echo "    → .env found (NOT copying — handle manually)" >> "$REPORT"
                warn ".env found at $app_dir/.env — copy this manually to new server"
            fi
            if [ -f "$app_dir/composer.json" ]; then
                APP_NAME=$(grep '"name"' "$app_dir/composer.json" | head -1 | awk -F'"' '{print $4}')
                echo "    → composer.json: $APP_NAME" >> "$REPORT"
            fi
        done
    fi
done

log "Laravel app scan complete"


# =============================================================================
# 12. FIREWALL / OPEN PORTS
# =============================================================================
divider "12. FIREWALL & OPEN PORTS"
info "Scanning firewall and ports..."

echo "--- UFW Status ---" >> "$REPORT"
sudo ufw status verbose 2>/dev/null >> "$REPORT" || echo "  (ufw not available or no sudo)" >> "$REPORT"

echo "" >> "$REPORT"
echo "--- Listening Ports ---" >> "$REPORT"
ss -tlnp 2>/dev/null >> "$REPORT" || netstat -tlnp 2>/dev/null >> "$REPORT" || echo "  (ss/netstat not available)" >> "$REPORT"

log "Firewall and ports captured"


# =============================================================================
# 13. INSTALLED APT PACKAGES (manually installed)
# =============================================================================
divider "13. MANUALLY INSTALLED APT PACKAGES"
info "Capturing manually installed packages..."

echo "--- Explicitly installed packages ---" >> "$REPORT"
apt-mark showmanual 2>/dev/null | sort | sed 's/^/  /' >> "$REPORT" || echo "  (apt-mark not available)" >> "$REPORT"

log "APT packages captured"


# =============================================================================
# 14. UPLOADER APP (Python service)
# =============================================================================
divider "14. UPLOADER APP"
info "Scanning uploader service..."

UPLOADER_DIR="/var/www/uploader"
UPLOADER_SERVICE="/etc/systemd/system/uploader.service"

echo "--- uploader.service ---" >> "$REPORT"
if [ -f "$UPLOADER_SERVICE" ]; then
    cat "$UPLOADER_SERVICE" >> "$REPORT"
    mkdir -p "$OUTPUT_DIR/uploader"
    cp "$UPLOADER_SERVICE" "$OUTPUT_DIR/uploader/uploader.service"
    log "uploader.service copied"
else
    echo "  (uploader.service not found at $UPLOADER_SERVICE)" >> "$REPORT"
    warn "uploader.service not found"
fi

echo "" >> "$REPORT"
echo "--- main.py ---" >> "$REPORT"
if [ -f "$UPLOADER_DIR/main.py" ]; then
    cat "$UPLOADER_DIR/main.py" >> "$REPORT"
    cp "$UPLOADER_DIR/main.py" "$OUTPUT_DIR/uploader/main.py"
    log "main.py copied"
else
    echo "  (main.py not found at $UPLOADER_DIR/main.py)" >> "$REPORT"
    warn "main.py not found"
fi

echo "" >> "$REPORT"
echo "--- uploader pip dependencies ---" >> "$REPORT"
if [ -f "$UPLOADER_DIR/venv/bin/pip" ]; then
    "$UPLOADER_DIR/venv/bin/pip" freeze 2>/dev/null >> "$REPORT"
    "$UPLOADER_DIR/venv/bin/pip" freeze 2>/dev/null > "$OUTPUT_DIR/uploader/requirements.txt"
    log "uploader requirements.txt generated"
elif [ -f "$UPLOADER_DIR/requirements.txt" ]; then
    cat "$UPLOADER_DIR/requirements.txt" >> "$REPORT"
    cp "$UPLOADER_DIR/requirements.txt" "$OUTPUT_DIR/uploader/requirements.txt"
    log "uploader requirements.txt copied"
else
    echo "  (no venv or requirements.txt found)" >> "$REPORT"
    warn "Could not determine uploader Python dependencies"
fi

echo "" >> "$REPORT"
echo "--- uploader .env / config ---" >> "$REPORT"
if [ -f "$UPLOADER_DIR/.env" ]; then
    echo "  .env found (NOT copying — handle manually)" >> "$REPORT"
    warn ".env found at $UPLOADER_DIR/.env — copy this manually to new server"
else
    echo "  (no .env found in $UPLOADER_DIR)" >> "$REPORT"
fi


# =============================================================================
# 15. PHP EXTENSION GAP (7.4 vs 8.2)
# =============================================================================
divider "15. PHP EXTENSION GAP (7.4 vs 8.2)"
info "Checking PHP extension gap between 7.4 and 8.2..."

PHP74_EXTS=$(php7.4 -m 2>/dev/null | grep -v '\[' | sort)
PHP82_EXTS=$(php8.2 -m 2>/dev/null | grep -v '\[' | sort)

echo "--- Extensions in PHP 7.4 but missing in PHP 8.2 ---" >> "$REPORT"
if [ -n "$PHP74_EXTS" ] && [ -n "$PHP82_EXTS" ]; then
    MISSING=$(comm -23 <(echo "$PHP74_EXTS") <(echo "$PHP82_EXTS"))
    if [ -n "$MISSING" ]; then
        echo "$MISSING" | sed 's/^/  /' >> "$REPORT"
        warn "Some PHP 7.4 extensions are not installed on PHP 8.2 — see report section 15"
    else
        echo "  (none — PHP 8.2 has all extensions that 7.4 has)" >> "$REPORT"
    fi
else
    echo "  (could not compare — one or both PHP versions not available via CLI)" >> "$REPORT"
    echo "" >> "$REPORT"
    echo "--- PHP 7.4 installed packages (from apt) ---" >> "$REPORT"
    dpkg -l 'php7.4-*' 2>/dev/null | grep '^ii' | awk '{print "  "$2}' >> "$REPORT" || echo "  (none)" >> "$REPORT"
    echo "" >> "$REPORT"
    echo "--- PHP 8.2 installed packages (from apt) ---" >> "$REPORT"
    dpkg -l 'php8.2-*' 2>/dev/null | grep '^ii' | awk '{print "  "$2}' >> "$REPORT" || echo "  (none)" >> "$REPORT"
fi

log "PHP extension gap check complete"


# =============================================================================
# BUILD manifest.json
# =============================================================================
info "Building manifest.json..."

cat > "$MANIFEST" <<EOF
{
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "os": "$OS_NAME",
  "php": {
    "version": "$PHP_VERSION",
    "ini": "$PHP_INI",
    "extensions": "$(php -m 2>/dev/null | grep -v '\[' | sort | tr '\n' ' ')"
  },
  "nginx": {
    "version": "$NGINX_VERSION"
  },
  "node": {
    "version": "$NODE_VERSION",
    "npm": "$NPM_VERSION",
    "nvm": "$NVM_VERSION"
  },
  "python": {
    "version": "$PYTHON3_VERSION",
    "pip": "$PIP3_VERSION"
  },
  "composer": {
    "version": "$COMPOSER_VERSION"
  },
  "certbot": {
    "version": "$CERTBOT_VERSION"
  }
}
EOF

log "manifest.json created"


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║               INVESTIGATION COMPLETE                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Output directory: $OUTPUT_DIR/"
echo ""
echo "  Files generated:"
echo "    ✔  migration_report.txt   — Human-readable summary"
echo "    ✔  manifest.json          — Machine-readable config"
echo "    ✔  nginx/                 — Nginx vhost configs"
echo "    ✔  supervisor/            — Supervisor configs"
echo "    ✔  systemd/               — Custom service files"
echo "    ✔  crontab_user.txt       — Cron jobs"
echo "    ✔  uploader/              — main.py, requirements.txt, uploader.service"
echo ""
echo "  Next steps:"
echo "    1. Review migration_report.txt carefully"
echo "    2. Copy migration_output/ to your new server"
echo "    3. Manually copy your .env files"
echo "    4. Run setup.sh on the new server"
echo ""
