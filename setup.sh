#!/bin/bash

# =============================================================================
# setup.sh — Run this on your NEW server
# Reads migration_output/ and sets up your environment from scratch
# =============================================================================

set -e

MIGRATION_DIR="./migration_output"
MANIFEST="$MIGRATION_DIR/manifest.json"
LOG_FILE="./setup_log.txt"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1" | tee -a "$LOG_FILE"; }
info()   { echo -e "${BLUE}[→]${NC} $1" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
err()    { echo -e "${RED}[✘]${NC} $1" | tee -a "$LOG_FILE"; }
section(){ echo "" | tee -a "$LOG_FILE"; echo -e "${BLUE}━━━ $1 ━━━${NC}" | tee -a "$LOG_FILE"; }

# Run a command as the deploy user (not root)
# Usage: as_user "cd /var/www/app && composer install"
as_user() { sudo -u "$DEPLOY_USER" bash -c "$1"; }

# Detect deploy user early (SUDO_USER is set when using sudo)
DEPLOY_USER=${SUDO_USER:-ubuntu}

# Helper to parse manifest.json without jq dependency
parse_manifest() {
    grep "\"$1\"" "$MANIFEST" | head -1 | awk -F'"' '{print $4}'
}

> "$LOG_FILE"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          SERVER SETUP TOOL               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# =============================================================================
# PRE-FLIGHT CHECKS
# Run ALL checks first — fix everything before proceeding
# =============================================================================
section "PRE-FLIGHT CHECKS"

PREFLIGHT_FAILED=0

fail() { err "$1"; PREFLIGHT_FAILED=1; }
pass() { log "$1"; }

# --- 1. Must run as sudo ---
if [ "$EUID" -ne 0 ]; then
    fail "Not running as root — re-run with: sudo bash setup.sh"
else
    pass "Running as root"
fi

# --- 2. migration_output/ exists ---
if [ ! -d "$MIGRATION_DIR" ]; then
    fail "migration_output/ not found — copy it to this server first"
else
    pass "migration_output/ found"
fi

# --- 3. manifest.json exists ---
if [ ! -f "$MANIFEST" ]; then
    fail "manifest.json not found at $MANIFEST"
else
    pass "manifest.json found"
fi

# Stop here if critical files missing — everything below depends on them
if [ "$PREFLIGHT_FAILED" -eq 1 ]; then
    echo ""
    err "Pre-flight failed — fix the errors above and re-run"
    exit 1
fi

# --- Parse manifest now that we know it exists ---
PHP_VER=$(grep '"php"' -A2 "$MANIFEST" | grep '"version"' | awk -F'"' '{print $4}')
NODE_VER=$(grep '"node"' -A2 "$MANIFEST" | grep '"version"' | awk -F'"' '{print $4}' | sed 's/^v//')
PYTHON_VER=$(grep '"python"' -A2 "$MANIFEST" | grep '"version"' | awk -F'"' '{print $4}' | awk '{print $2}')
PHP_MAJOR=$(echo "$PHP_VER" | cut -d'.' -f1,2)

# --- 4. migration_output sub-folders and files ---
[ -d "$MIGRATION_DIR/nginx" ]           && pass "nginx/ configs found"          || fail "nginx/ folder missing in migration_output/"
[ -f "$MIGRATION_DIR/crontab_user.txt" ] && pass "crontab_user.txt found"        || fail "crontab_user.txt missing in migration_output/"
[ -d "$MIGRATION_DIR/uploader" ]         && pass "uploader/ folder found"        || warn "uploader/ folder missing — uploader setup will be skipped"
[ -f "$MIGRATION_DIR/uploader/main.py" ] && pass "uploader/main.py found"        || warn "uploader/main.py missing"
[ -f "$MIGRATION_DIR/uploader/requirements.txt" ] && pass "uploader/requirements.txt found" || warn "uploader/requirements.txt missing"
[ -f "$MIGRATION_DIR/uploader/uploader.service" ] && pass "uploader/uploader.service found" || warn "uploader/uploader.service missing"

# --- 5. Required tools available on this server ---
for tool in curl git python3 add-apt-repository; do
    if command -v "$tool" &>/dev/null; then
        pass "Tool available: $tool"
    else
        fail "Tool missing: $tool — run: apt-get install -y ${tool/add-apt-repository/software-properties-common}"
    fi
done

# --- 6. SSH agent forwarding (only needed for SSH remotes) ---
# Detect if any remotes use SSH (git@) vs HTTPS
GIT_USES_SSH=0
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    if grep -q "→ Git remote: git@" "$MIGRATION_DIR/migration_report.txt" 2>/dev/null; then
        GIT_USES_SSH=1
    fi
fi

if [ "$GIT_USES_SSH" -eq 1 ]; then
    if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        pass "SSH agent forwarding active (required for SSH git remotes)"
    else
        fail "SSH agent not forwarded — reconnect with: ssh -A ubuntu@$(hostname -I | awk '{print $1}')"
    fi

    # Test GitHub SSH auth only when using SSH remotes
    if command -v git &>/dev/null; then
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
            pass "GitHub SSH authentication successful"
        else
            fail "Cannot authenticate with GitHub — check your SSH key is added to github.com"
        fi
    fi
else
    pass "Git remotes use HTTPS — SSH agent forwarding not required"
fi

# --- 7. Test each git remote is reachable ---
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    # Deduplicate remotes before testing
    while IFS= read -r remote; do
        remote=$(echo "$remote" | xargs)
        [ -z "$remote" ] && continue
        if git ls-remote "$remote" HEAD &>/dev/null 2>&1; then
            pass "Git remote reachable: $remote"
        else
            fail "Git remote NOT reachable: $remote — check credentials/permissions"
        fi
    done < <(grep "→ Git remote:" "$MIGRATION_DIR/migration_report.txt" | awk -F'remote: ' '{print $2}' | grep -v "no remote configured" | sort -u)
fi

# --- 9. Disk space check (rough: 2GB minimum free on /) ---
FREE_KB=$(df / | tail -1 | awk '{print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))
if [ "$FREE_GB" -ge 2 ]; then
    pass "Disk space OK: ${FREE_GB}GB free on /"
else
    fail "Low disk space: only ${FREE_GB}GB free on / — need at least 2GB"
fi

# --- 10. Ports 80 and 443 not blocked by unexpected process ---
for port in 80 443; do
    PROC=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}')
    if [ -z "$PROC" ]; then
        pass "Port $port is free"
    else
        warn "Port $port already in use by: $PROC — Nginx will take over"
    fi
done

# --- 11. DEPLOY_USER exists ---
DEPLOY_USER=${SUDO_USER:-ubuntu}
if id "$DEPLOY_USER" &>/dev/null; then
    pass "Deploy user exists: $DEPLOY_USER"
else
    fail "Deploy user '$DEPLOY_USER' not found — create with: adduser $DEPLOY_USER"
fi

# --- Summary ---
echo ""
if [ "$PREFLIGHT_FAILED" -eq 1 ]; then
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    err "Pre-flight FAILED — fix all [✘] errors above first"
    err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi

info "Will install: PHP $PHP_MAJOR + 7.4, Node $NODE_VER, Python $PYTHON_VER"
info "Deploy user:  $DEPLOY_USER"
echo ""
read -p "  All checks passed — proceed with setup? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "  Aborted."
    exit 0
fi


# =============================================================================
# 1. SYSTEM UPDATE
# =============================================================================
section "1. SYSTEM UPDATE"
info "Updating apt..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git unzip zip software-properties-common \
    apt-transport-https ca-certificates gnupg lsb-release supervisor \
    ffmpeg ghostscript
log "System updated and base tools installed (incl. ffmpeg, ghostscript)"


# =============================================================================
# 2. PHP
# =============================================================================
section "2. PHP $PHP_MAJOR"
info "Installing PHP $PHP_MAJOR from ondrej/php PPA..."

if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y ppa:ondrej/php 2>/dev/null
    apt-get update -qq
    log "ondrej/php PPA added"
else
    log "ondrej/php PPA already present — skipping"
fi

# Core packages
apt-get install -y -qq \
    php${PHP_MAJOR} \
    php${PHP_MAJOR}-fpm \
    php${PHP_MAJOR}-cli \
    php${PHP_MAJOR}-common

# Install extensions from manifest
PHP_EXTENSIONS=$(grep '"extensions"' "$MANIFEST" | awk -F'"' '{print $4}')
info "Installing PHP extensions from manifest..."

# Install PHP 8.2 extensions — combining manifest extensions + known gap from section 15
EXTENSION_MAP="bcmath bz2 curl gd gmp igbinary imagick intl ldap mbstring memcache memcached mongodb msgpack mysql mysqli mysqlnd opcache pdo pdo-mysql pdo-sqlite readline redis soap sqlite3 tokenizer tidy xml xmlrpc xsl zip pspell"

info "Installing PHP $PHP_MAJOR extensions..."
for ext in $EXTENSION_MAP; do
    PKG="php${PHP_MAJOR}-${ext}"
    if apt-cache show "$PKG" &>/dev/null 2>&1; then
        apt-get install -y -qq "$PKG" 2>/dev/null && log "  + $PKG" || warn "  Could not install $PKG"
    fi
done

# Also install any extensions listed in the PHP extension gap section of the report
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    info "Installing PHP $PHP_MAJOR extensions from gap report..."
    while IFS= read -r ext; do
        ext=$(echo "$ext" | xargs | tr '[:upper:]' '[:lower:]')
        [ -z "$ext" ] && continue
        PKG="php${PHP_MAJOR}-${ext}"
        if apt-cache show "$PKG" &>/dev/null 2>&1; then
            if ! php${PHP_MAJOR} -m 2>/dev/null | grep -qi "$ext"; then
                apt-get install -y -qq "$PKG" 2>/dev/null && log "  + $PKG (from gap)" || warn "  Could not install $PKG"
            fi
        fi
    done < <(grep -A50 "PHP EXTENSION GAP" "$MIGRATION_DIR/migration_report.txt"               | grep -A50 "missing in PHP 8.2"               | grep "^  [a-z]"               | sed 's/^[[:space:]]*//')
fi

# Restore php.ini tweaks if we have a report
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    info "Restoring key php.ini settings..."
    PHP_INI="/etc/php/${PHP_MAJOR}/fpm/php.ini"
    PHP_CLI_INI="/etc/php/${PHP_MAJOR}/cli/php.ini"

    while IFS= read -r line; do
        key=$(echo "$line" | awk -F'=' '{print $1}' | xargs)
        val=$(echo "$line" | awk -F'=' '{print $2}' | xargs)
        if [ -n "$key" ] && [ -n "$val" ]; then
            sed -i "s|^;\?${key}\s*=.*|${key} = ${val}|" "$PHP_INI" 2>/dev/null || true
            sed -i "s|^;\?${key}\s*=.*|${key} = ${val}|" "$PHP_CLI_INI" 2>/dev/null || true
        fi
    done < <(grep -A20 "Key php.ini settings" "$MIGRATION_DIR/migration_report.txt" 2>/dev/null | grep " = " | sed 's/^[[:space:]]*//')
fi

systemctl enable php${PHP_MAJOR}-fpm
systemctl is-active --quiet php${PHP_MAJOR}-fpm && systemctl reload php${PHP_MAJOR}-fpm || systemctl start php${PHP_MAJOR}-fpm
log "PHP $PHP_MAJOR installed and FPM running"

# =============================================================================
# 2b. PHP 7.4 (required for legacy app: api.mylandlordheaven.com)
# =============================================================================
section "2b. PHP 7.4 (legacy)"
info "Installing PHP 7.4..."

apt-get install -y -qq \
    php7.4 \
    php7.4-fpm \
    php7.4-cli \
    php7.4-common

# Install same extensions that were on old server
PHP74_EXTENSIONS="bcmath curl fpm gd imagick intl json ldap mbstring memcached mysql opcache pspell readline redis soap sqlite3 tidy xml xmlrpc xsl zip"
for ext in $PHP74_EXTENSIONS; do
    PKG="php7.4-${ext}"
    if apt-cache show "$PKG" &>/dev/null 2>&1; then
        apt-get install -y -qq "$PKG" 2>/dev/null && log "  + php7.4-$ext" || warn "  Could not install php7.4-$ext"
    fi
done

# Apply same php.ini settings to 7.4
PHP74_INI="/etc/php/7.4/fpm/php.ini"
PHP74_CLI_INI="/etc/php/7.4/cli/php.ini"
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    while IFS= read -r line; do
        key=$(echo "$line" | awk -F'=' '{print $1}' | xargs)
        val=$(echo "$line" | awk -F'=' '{print $2}' | xargs)
        if [ -n "$key" ] && [ -n "$val" ]; then
            sed -i "s|^;\\?${key}\\s*=.*|${key} = ${val}|" "$PHP74_INI" 2>/dev/null || true
            sed -i "s|^;\\?${key}\\s*=.*|${key} = ${val}|" "$PHP74_CLI_INI" 2>/dev/null || true
        fi
    done < <(grep -A20 "Key php.ini settings" "$MIGRATION_DIR/migration_report.txt" 2>/dev/null | grep " = " | sed 's/^[[:space:]]*//')
fi

systemctl enable php7.4-fpm
systemctl is-active --quiet php7.4-fpm && systemctl reload php7.4-fpm || systemctl start php7.4-fpm
log "PHP 7.4 installed and FPM running"



# =============================================================================
# 3. COMPOSER
# =============================================================================
section "3. COMPOSER"
info "Installing Composer..."

if ! command -v composer &>/dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    log "Composer installed"
else
    log "Composer already installed"
fi


# =============================================================================
# 4. NODE / NPM
# =============================================================================
section "4. NODE $NODE_VER / NPM"
info "Installing Node via NVM..."

# Install NVM — idempotent
export NVM_DIR="/root/.nvm"
if [ ! -d "$NVM_DIR" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    log "NVM installed"
else
    log "NVM already installed — skipping"
fi

# Load NVM
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install correct Node version — idempotent
NODE_MAJOR=$(echo "$NODE_VER" | cut -d'.' -f1)
if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -gt 0 ] 2>/dev/null; then
    if nvm ls "$NODE_VER" 2>/dev/null | grep -q "$NODE_VER"; then
        log "Node $NODE_VER already installed — skipping"
        nvm use "$NODE_VER" 2>/dev/null || true
    else
        nvm install "$NODE_VER" 2>/dev/null || nvm install "lts/*"
        nvm use "$NODE_VER" 2>/dev/null || nvm use "lts/*"
    fi
    nvm alias default "$NODE_VER" 2>/dev/null || nvm alias default "lts/*"
else
    nvm ls "lts/*" &>/dev/null || nvm install "lts/*"
    nvm alias default "lts/*"
fi

# Make node/npm globally accessible
NODE_BIN=$(nvm which current 2>/dev/null)
ln -sf "$NODE_BIN" /usr/local/bin/node 2>/dev/null || true
NPM_BIN=$(dirname "$NODE_BIN")/npm
ln -sf "$NPM_BIN" /usr/local/bin/npm 2>/dev/null || true

log "Node $(node -v) installed"


# =============================================================================
# 5. PYTHON
# =============================================================================
section "5. PYTHON"
info "Installing Python..."

apt-get install -y -qq python3 python3-pip python3-venv python3-dev

# Install global packages from manifest
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    info "Restoring global Python packages..."
    while IFS= read -r line; do
        pkg=$(echo "$line" | awk '{print $1}')
        ver=$(echo "$line" | awk '{print $2}')
        [ -z "$pkg" ] && continue
        pip3 install --break-system-packages "${pkg}==${ver}" 2>/dev/null \
            || pip3 install --break-system-packages "$pkg" 2>/dev/null \
            || warn "  Could not install Python package: $pkg"
    done < <(grep -A200 "Global Python Packages" "$MIGRATION_DIR/migration_report.txt" \
              | grep -v "Global Python" | grep -v "===" | grep -v "^$" \
              | grep -v "\-\-\-" | head -50 | sed 's/^[[:space:]]*//')
fi

log "Python $(python3 --version) installed"


# =============================================================================
# 6. NGINX
# =============================================================================
section "6. NGINX"
info "Installing Nginx..."

apt-get install -y -qq nginx
systemctl enable nginx
systemctl is-active --quiet nginx || systemctl start nginx

# Restore vhost configs from old server
NGINX_BACKUP="$MIGRATION_DIR/nginx"
if [ -d "$NGINX_BACKUP" ]; then
    info "Restoring Nginx vhost configs..."
    for conf in "$NGINX_BACKUP"/*; do
        [ -f "$conf" ] || continue
        fname=$(basename "$conf")
        cp "$conf" "/etc/nginx/sites-available/$fname"
        ln -sf "/etc/nginx/sites-available/$fname" "/etc/nginx/sites-enabled/$fname" 2>/dev/null || true
        log "  Restored: $fname"
    done

    # Only update php-fpm socket paths for sites NOT explicitly using php7.4
    for conf in /etc/nginx/sites-enabled/*; do
        if ! grep -q "php7.4-fpm" "$conf" 2>/dev/null; then
            sed -i "s|php[0-9]\.[0-9]-fpm|php${PHP_MAJOR}-fpm|g" "$conf" 2>/dev/null || true
        fi
    done

    # Remove default if real sites exist
    SITE_COUNT=$(ls /etc/nginx/sites-enabled/ | grep -v "^default$" | wc -l)
    if [ "$SITE_COUNT" -gt 0 ]; then
        rm -f /etc/nginx/sites-enabled/default
        log "Removed default Nginx site"
    fi

    nginx -t && systemctl reload nginx && log "Nginx reloaded with restored configs"
else
    warn "No nginx backup found at $NGINX_BACKUP — configure manually"
fi


# =============================================================================
# 7. CERTBOT / SSL
# =============================================================================
section "7. CERTBOT / SSL"
info "Installing Certbot..."

apt-get install -y -qq certbot python3-certbot-nginx
log "Certbot installed"

# Extract domains from old report and prompt
if [ -f "$MIGRATION_DIR/migration_report.txt" ]; then
    DOMAINS=$(grep -A50 "CERTBOT" "$MIGRATION_DIR/migration_report.txt" \
              | grep "Domains:" | awk -F': ' '{print $2}' | head -5)
    if [ -n "$DOMAINS" ]; then
        echo ""
        warn "Domains from old server: $DOMAINS"
        warn "After DNS is pointed to this server, run:"
        echo ""
        echo "    sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com"
        echo ""
    fi
fi

log "Certbot ready — run manually after DNS cutover"


# =============================================================================
# 8. SUPERVISOR
# =============================================================================
section "8. SUPERVISOR"
info "Restoring Supervisor configs..."

SUPERVISOR_BACKUP="$MIGRATION_DIR/supervisor"
if [ -d "$SUPERVISOR_BACKUP" ] && ls "$SUPERVISOR_BACKUP"/*.conf &>/dev/null 2>&1; then
    cp "$SUPERVISOR_BACKUP"/*.conf /etc/supervisor/conf.d/
    supervisorctl reread
    # Only update (start) programs that are not already running
    supervisorctl update 2>/dev/null || true
    log "Supervisor programs restored"
    supervisorctl status 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE" || true
else
    warn "No supervisor configs found — skipping"
fi


# =============================================================================
# 9. CRON JOBS
# =============================================================================
section "9. CRON JOBS"
info "Restoring cron jobs..."

CRON_FILE="$MIGRATION_DIR/crontab_user.txt"
if [ -f "$CRON_FILE" ] && ! grep -q "^(empty)" "$CRON_FILE"; then
    EXISTING_CRON=$(crontab -l 2>/dev/null | md5sum)
    NEW_CRON=$(md5sum < "$CRON_FILE")
    if [ "$EXISTING_CRON" = "$NEW_CRON" ]; then
        log "Cron jobs already up to date — skipping"
    else
        crontab "$CRON_FILE"
        log "Cron jobs restored"
        crontab -l | sed 's/^/  /' | tee -a "$LOG_FILE"
    fi
else
    warn "No cron jobs to restore"
fi


# =============================================================================
# 10. SYSTEMD CUSTOM SERVICES
# =============================================================================
section "10. SYSTEMD CUSTOM SERVICES"
info "Restoring custom systemd services..."

SYSTEMD_BACKUP="$MIGRATION_DIR/systemd"

# AWS/EC2-specific services — must NOT be copied to Hetzner
SYSTEMD_BLACKLIST=(
    "snap.amazon-ssm-agent.amazon-ssm-agent.service"
    "ec2-hibinit-agent.service"
    "hibagent.service"
    "chronyd.service"
    "iscsi.service"
    "vmtoolsd.service"
    "dbus-org.freedesktop.ModemManager1.service"
    "dbus-org.freedesktop.resolve1.service"
    "syslog.service"
)

is_blacklisted() {
    local name="$1"
    for bl in "${SYSTEMD_BLACKLIST[@]}"; do
        [ "$name" = "$bl" ] && return 0
    done
    return 1
}

if [ -d "$SYSTEMD_BACKUP" ] && ls "$SYSTEMD_BACKUP"/*.service &>/dev/null 2>&1; then
    NEEDS_RELOAD=0
    for svc in "$SYSTEMD_BACKUP"/*.service; do
        name=$(basename "$svc")
        if is_blacklisted "$name"; then
            warn "  Skipping AWS/EC2-specific service: $name"
            continue
        fi
        dest="/etc/systemd/system/$name"
        if [ ! -f "$dest" ] || ! diff -q "$svc" "$dest" &>/dev/null; then
            cp "$svc" "$dest"
            NEEDS_RELOAD=1
            log "  Installed service: $name"
        else
            log "  Service unchanged: $name — skipping"
        fi
    done
    [ "$NEEDS_RELOAD" -eq 1 ] && systemctl daemon-reload
    # Enable only non-blacklisted services
    for svc in "$SYSTEMD_BACKUP"/*.service; do
        name=$(basename "$svc")
        is_blacklisted "$name" && continue
        systemctl enable "$name" 2>/dev/null || true
    done
else
    warn "No custom systemd services found — skipping"
fi


# =============================================================================
# 11. FIREWALL
# =============================================================================
section "11. FIREWALL (UFW)"
info "Configuring UFW firewall..."

apt-get install -y -qq ufw
if ufw status | grep -q "Status: active"; then
    log "UFW already active — skipping reset to avoid dropping SSH"
    ufw allow ssh 2>/dev/null || true
    ufw allow 'Nginx Full' 2>/dev/null || true
else
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 'Nginx Full'   # 80 + 443
    ufw --force enable
    log "UFW configured: SSH + Nginx Full (80/443) open"
fi

warn "Review your firewall rules if you had custom ports:"
warn "  Check migration_report.txt → FIREWALL section"




# =============================================================================
# 12. UPLOADER APP (Python service)
# =============================================================================
section "12. UPLOADER APP"
info "Setting up uploader Python service..."

UPLOADER_SRC="$MIGRATION_DIR/uploader"
UPLOADER_DEST="/var/www/uploader"

# Uploader runs as www-data (as defined in uploader.service)
UPLOADER_OWNER="www-data"

if [ -d "$UPLOADER_SRC" ]; then
    mkdir -p "$UPLOADER_DEST"
    chown "$UPLOADER_OWNER:$UPLOADER_OWNER" "$UPLOADER_DEST"

    # Copy app files and set correct ownership
    if [ -f "$UPLOADER_SRC/main.py" ]; then
        cp "$UPLOADER_SRC/main.py" "$UPLOADER_DEST/main.py"
        chown "$UPLOADER_OWNER:$UPLOADER_OWNER" "$UPLOADER_DEST/main.py"
        log "main.py copied (owned by $UPLOADER_OWNER)"
    fi

    # Create venv and install dependencies as www-data — idempotent
    if [ -f "$UPLOADER_SRC/requirements.txt" ]; then
        if [ ! -d "$UPLOADER_DEST/venv" ]; then
            sudo -u "$UPLOADER_OWNER" python3 -m venv "$UPLOADER_DEST/venv"
            log "Python venv created (owned by $UPLOADER_OWNER)"
        else
            log "Python venv already exists — skipping creation"
        fi
        sudo -u "$UPLOADER_OWNER" "$UPLOADER_DEST/venv/bin/pip" install --upgrade pip -q
        sudo -u "$UPLOADER_OWNER" "$UPLOADER_DEST/venv/bin/pip" install -r "$UPLOADER_SRC/requirements.txt" -q
        log "Uploader dependencies installed/updated"
    else
        warn "No requirements.txt found — venv not created, install dependencies manually"
    fi

    # Restore systemd service — only reload if changed
    if [ -f "$UPLOADER_SRC/uploader.service" ]; then
        DEST_SVC="/etc/systemd/system/uploader.service"
        if [ ! -f "$DEST_SVC" ] || ! diff -q "$UPLOADER_SRC/uploader.service" "$DEST_SVC" &>/dev/null; then
            cp "$UPLOADER_SRC/uploader.service" "$DEST_SVC"
            systemctl daemon-reload
            log "uploader.service installed/updated"
        else
            log "uploader.service unchanged — skipping"
        fi
        systemctl enable uploader 2>/dev/null || true
        warn "uploader.service enabled but NOT started — copy .env first, then: systemctl start uploader"
    fi

    warn "Remember to copy .env to $UPLOADER_DEST before starting the service"
    warn "Required .env keys: S3_BUCKET_NAME, AWS_REGION, AWS_ACCESS_KEY, AWS_SECRET_KEY"
else
    warn "No uploader backup found at $UPLOADER_SRC — set up manually"
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  SETUP COMPLETE ✔                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Log saved to: setup_log.txt"
echo ""
echo "  ┌─ REMAINING MANUAL STEPS ──────────────────────────────┐"
echo "  │                                                        │"
echo "  │  NOTE: Run app commands as $DEPLOY_USER, NOT root      │"
echo "  │                                                        │"
echo "  │  1. Clone your Laravel repo(s):                        │"
echo "  │     sudo -u $DEPLOY_USER git clone \                  │"
echo "  │       git@github.com:you/app.git /var/www/prod        │"
echo "  │                                                        │"
echo "  │  2. Copy .env file(s) manually                        │"
echo "  │     (NOT automated for security reasons)              │"
echo "  │                                                        │"
echo "  │  3. Run per-app setup as $DEPLOY_USER:                 │"
echo "  │     sudo -u $DEPLOY_USER bash -c \                    │"
echo "  │       'cd /var/www/prod &&                            │"
echo "  │        composer install --no-dev --optimize &&        │"
echo "  │        npm install && npm run build &&                │"
echo "  │        php artisan key:generate &&                    │"
echo "  │        php artisan migrate &&                         │"
echo "  │        php artisan storage:link &&                    │"
echo "  │        php artisan config:cache &&                    │"
echo "  │        php artisan route:cache'                       │"
echo "  │                                                        │"
echo "  │  4. Set permissions:                                   │"
echo "  │     chown -R $DEPLOY_USER:www-data /var/www/app       │"
echo "  │     chmod -R 775 /var/www/app/storage                 │"
echo "  │     chmod -R 775 /var/www/app/bootstrap/cache         │"
echo "  │                                                        │"
echo "  │  5. Point DNS to this server                           │"
echo "  │                                                        │"
echo "  │  6. Run Certbot after DNS propagates:                  │"
echo "  │     certbot --nginx -d yourdomain.com                 │"
echo "  │                                                        │"
echo "  └────────────────────────────────────────────────────────┘"
echo ""
