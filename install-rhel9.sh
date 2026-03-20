#!/bin/bash
# =============================================================================
# FusionPBX + FreeSWITCH Complete Installation Script
# OS:   Red Hat Enterprise Linux 9.x (RHEL / Rocky / AlmaLinux)
# Arch: x86_64  AND  aarch64 (ARM64)  — both fully supported
# =============================================================================
#
# USAGE:
#   chmod +x install-rhel9.sh
#   sudo ./install-rhel9.sh
#
# No SignalWire token required — FreeSWITCH is compiled from the
# FusionPBX fork source (same as the official Debian/Ubuntu installer).
#
# Architecture differences handled automatically:
#   x86_64  — yasm/nasm assemblers available, mod_av video module enabled
#   aarch64 — yasm/nasm skipped (x86-only), mod_av disabled (no x86 codecs)
#
# WHAT THIS SCRIPT DOES:
#   1.  Fixes broken repos (removes broken cert-forensics repo)
#   2.  Updates the system
#   3.  Installs PostgreSQL 14 (PGDG official repo, arch-aware)
#   4.  Clones FusionPBX source from GitHub
#   5.  Generates self-signed SSL certificate
#   6.  Installs nginx (RHEL AppStream)
#   7.  Installs PHP 8.2 (Remi repo)
#   8.  Configures FirewallD with SIP/RTP ports
#   9.  Compiles FreeSWITCH from source (libks + sofia-sip + spandsp + FS)
#   10. Installs Fail2ban
#   11. Configures FusionPBX (DB schema, admin user, permissions)
#   12. Enables & starts all services
# =============================================================================

set -euo pipefail

# --- Colour helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]  $(date '+%H:%M:%S') $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]  $(date '+%H:%M:%S') $*${NC}"; }
error() { echo -e "${RED}[ERROR] $(date '+%H:%M:%S') $*${NC}" >&2; exit 1; }
step()  { echo ""; echo -e "${BLUE}══════════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  $*${NC}"; \
          echo -e "${BLUE}══════════════════════════════════════════════${NC}"; }

# --- Configuration (edit if needed) ------------------------------------------
SYSTEM_USERNAME="admin"
SYSTEM_PASSWORD="random"   # 'random' = auto-generate, or set a fixed value
DB_NAME="fusionpbx"
DB_USER="fusionpbx"
DB_PASSWORD="random"       # 'random' = auto-generate
PHP_VERSION="82"           # 80 | 81 | 82 | 83
PG_VERSION="14"
SWITCH_VERSION="1.10.12"   # FreeSWITCH version to build
SOFIA_VERSION="1.13.17"    # sofia-sip version to build

# Runtime variables (auto-detected below)
ARCH=""
OS_VER=""
IP_ADDR=""
PHP_FPM_SVC=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# STEP 0 – Pre-flight checks
# =============================================================================
step "STEP 0 – Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Must be run as root:  sudo ./install-rhel9.sh"

OS_ID=$(. /etc/os-release && echo "$ID")
OS_VER=$(. /etc/os-release && echo "$VERSION_ID" | cut -d. -f1)
ARCH=$(uname -m)
IP_ADDR=$(hostname -I | awk '{print $1}')

log "OS:   $OS_ID $OS_VER"
log "Arch: $ARCH"
log "IP:   $IP_ADDR"

[[ "$OS_VER" != "9" ]] && error "Requires RHEL/Rocky/AlmaLinux 9.x — detected: $OS_VER"
[[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]] && error "Unsupported arch: $ARCH"

log "Pre-flight checks passed."

# =============================================================================
# STEP 1 – Fix broken repos & update system
# =============================================================================
step "STEP 1 – Fix broken repositories & system update"

# Remove the broken CERT forensics repo (returns 404 on every dnf call)
if [[ -f /etc/yum.repos.d/cert-forensics-tools.repo ]]; then
    warn "Removing broken cert-forensics-tools repo"
    rm -f /etc/yum.repos.d/cert-forensics-tools.repo
fi

# Enable CodeReady Builder (needed for some -devel packages)
case "$OS_ID" in
    rhel)
        subscription-manager repos \
            --enable "codeready-builder-for-rhel-9-${ARCH}-rpms" 2>/dev/null || \
            warn "CRB enable failed — may already be enabled"
        ;;
    rocky|almalinux|centos)
        dnf config-manager --set-enabled crb -y 2>/dev/null || true
        ;;
esac

# EPEL 9
log "Installing EPEL..."
dnf install -y \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    2>/dev/null || dnf install -y epel-release 2>/dev/null || \
    log "EPEL already installed"

# dnf-utils (provides yum-config-manager)
dnf install -y dnf-utils 2>/dev/null || true

# System update
log "Updating system packages..."
dnf -y update

# Base utilities
log "Installing base utilities..."
dnf install -y \
    git wget curl vim htop net-tools openssl chrony at \
    libtiff-devel libtiff-tools ghostscript memcached

log "System update complete."

# ---- sngrep (SIP traffic monitor) ----
# Available as RPM in EPEL for x86_64; aarch64 has no binary — build from source
if ! command -v sngrep &>/dev/null; then
    dnf install -y sngrep 2>/dev/null && \
        log "sngrep installed via dnf." || {
        log "sngrep not in repos for $ARCH — building from source..."
        dnf install -y libpcap-devel ncurses-devel autoconf automake gcc make pcre2-devel 2>/dev/null || true
        cd /usr/local/src
        [[ -d sngrep ]] && rm -rf sngrep
        git clone https://github.com/irontec/sngrep.git sngrep
        cd sngrep
        ./bootstrap.sh
        ./configure --with-openssl --with-pcre2
        make -j"$(nproc)"
        make install
        ln -sf /usr/local/bin/sngrep /usr/bin/sngrep
        log "sngrep $(sngrep --version 2>&1 | head -1) installed from source."
    }
else
    log "sngrep already installed: $(sngrep --version 2>&1 | head -1)"
fi

# =============================================================================
# STEP 2 – Disable SELinux (permissive)
# =============================================================================
step "STEP 2 – Configure SELinux"

setenforce 0 2>/dev/null || warn "SELinux already permissive or not enforcing"
for f in /etc/selinux/config /etc/sysconfig/selinux; do
    [[ -f "$f" ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/g' "$f"
done
log "SELinux set to permissive."

# =============================================================================
# STEP 3 – PostgreSQL 14
# =============================================================================
step "STEP 3 – Install PostgreSQL $PG_VERSION"

# Use the PGDG repo URL with the correct EL version and architecture
PG_REPO_URL="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
log "Adding PGDG repo: EL-9-${ARCH}"
dnf install -y "$PG_REPO_URL" 2>/dev/null || log "PGDG repo already installed"

# Disable the system postgresql module to avoid version conflicts
dnf -qy module disable postgresql 2>/dev/null || true

dnf install -y \
    "postgresql${PG_VERSION}-server" \
    "postgresql${PG_VERSION}-contrib" \
    "postgresql${PG_VERSION}" \
    "postgresql${PG_VERSION}-libs"

# Initialise only if the data directory is empty
if [[ ! -f "/var/lib/pgsql/${PG_VERSION}/data/PG_VERSION" ]]; then
    log "Initialising PostgreSQL data directory..."
    "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb
fi

# Switch from 'ident' to 'md5' auth for localhost
PG_HBA="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
sed -i 's/\(host[[:space:]]*all[[:space:]]*all[[:space:]]*127\.0\.0\.1\/32[[:space:]]*\)ident/\1md5/' "$PG_HBA"
sed -i 's/\(host[[:space:]]*all[[:space:]]*all[[:space:]]*::1\/128[[:space:]]*\)ident/\1md5/'         "$PG_HBA"

systemctl daemon-reload
systemctl enable "postgresql-${PG_VERSION}"
systemctl start  "postgresql-${PG_VERSION}"

# Generate DB password
if [[ "$DB_PASSWORD" == "random" ]]; then
    set +o pipefail
    DB_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    set -o pipefail
fi

# Create roles and databases (idempotent)
cd /tmp
runuser -u postgres -- /usr/bin/psql -c \
    "SELECT 1 FROM pg_roles WHERE rolname='fusionpbx'" 2>/dev/null | grep -q 1 || \
    runuser -u postgres -- /usr/bin/psql -c \
    "CREATE ROLE fusionpbx WITH SUPERUSER LOGIN PASSWORD '$DB_PASSWORD';"

runuser -u postgres -- /usr/bin/psql -c \
    "SELECT 1 FROM pg_roles WHERE rolname='freeswitch'" 2>/dev/null | grep -q 1 || \
    runuser -u postgres -- /usr/bin/psql -c \
    "CREATE ROLE freeswitch WITH SUPERUSER LOGIN PASSWORD '$DB_PASSWORD';"

runuser -u postgres -- /usr/bin/psql -tc \
    "SELECT 1 FROM pg_database WHERE datname='fusionpbx'" 2>/dev/null | grep -q 1 || \
    runuser -u postgres -- /usr/bin/psql -c "CREATE DATABASE fusionpbx;"

runuser -u postgres -- /usr/bin/psql -tc \
    "SELECT 1 FROM pg_database WHERE datname='freeswitch'" 2>/dev/null | grep -q 1 || \
    runuser -u postgres -- /usr/bin/psql -c "CREATE DATABASE freeswitch;"

runuser -u postgres -- /usr/bin/psql -c "GRANT ALL PRIVILEGES ON DATABASE fusionpbx TO fusionpbx;"
runuser -u postgres -- /usr/bin/psql -c "GRANT ALL PRIVILEGES ON DATABASE freeswitch TO fusionpbx;"
runuser -u postgres -- /usr/bin/psql -c "GRANT ALL PRIVILEGES ON DATABASE freeswitch TO freeswitch;"
runuser -u postgres -- /usr/bin/psql -c "ALTER USER fusionpbx WITH PASSWORD '$DB_PASSWORD';"
runuser -u postgres -- /usr/bin/psql -c "ALTER USER freeswitch WITH PASSWORD '$DB_PASSWORD';"

log "PostgreSQL $PG_VERSION ready."

# =============================================================================
# STEP 4 – FusionPBX web source
# =============================================================================
step "STEP 4 – Clone FusionPBX"

if [[ ! -d /var/www/fusionpbx ]]; then
    git clone https://github.com/fusionpbx/fusionpbx.git /var/www/fusionpbx
else
    log "FusionPBX already present — pulling latest..."
    git -C /var/www/fusionpbx pull || warn "git pull failed, continuing with existing code"
fi
mkdir -p /var/cache/fusionpbx
log "FusionPBX source ready."

# =============================================================================
# STEP 5 – Self-signed SSL certificate
# =============================================================================
step "STEP 5 – Generate SSL certificate"

mkdir -p /etc/ssl/private /etc/ssl/certs
chmod 700 /etc/ssl/private

if [[ ! -f /etc/ssl/certs/nginx.crt ]]; then
    openssl req -x509 -nodes \
        -subj "/C=US/ST=State/O=FusionPBX/CN=$(hostname)" \
        -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/private/nginx.key \
        -out    /etc/ssl/certs/nginx.crt
    log "SSL certificate generated (valid 10 years)."
else
    log "SSL certificate already exists."
fi

# =============================================================================
# STEP 6 – nginx
# =============================================================================
step "STEP 6 – Install nginx"

dnf install -y nginx
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# FusionPBX vhost config
cat > /etc/nginx/sites-available/fusionpbx.conf << 'NGINX_VHOST'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/ssl/certs/nginx.crt;
    ssl_certificate_key /etc/ssl/private/nginx.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root  /var/www/fusionpbx;
    index index.php;
    client_max_body_size 80M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass         unix:/var/run/php-fpm/php-fpm.sock;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
        include              fastcgi_params;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires max;
        log_not_found off;
    }

    location ~ /\. { deny all; }
}
NGINX_VHOST

ln -sf /etc/nginx/sites-available/fusionpbx.conf /etc/nginx/sites-enabled/fusionpbx.conf

# Add sites-enabled include to nginx.conf once
if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
    sed -i '/include \/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*.conf;' \
        /etc/nginx/nginx.conf
fi

# Remove the default server block (conflicts with our vhost on port 80/443)
python3 - << 'PYEOF'
conf = "/etc/nginx/nginx.conf"
with open(conf) as f:
    lines = f.readlines()
out, depth, skip, skip_depth = [], 0, False, 0
for line in lines:
    s = line.strip()
    if not skip and s.startswith("server") and "{" in s:
        skip = True; skip_depth = depth
    if skip:
        depth += s.count("{") - s.count("}")
        if depth <= skip_depth:
            skip = False
        continue
    depth += s.count("{") - s.count("}")
    out.append(line)
with open(conf, "w") as f:
    f.writelines(out)
PYEOF

mkdir -p /var/log/nginx && chmod 755 /var/log/nginx
log "nginx installed."

# =============================================================================
# STEP 7 – PHP 8.x (Remi repo)
# =============================================================================
step "STEP 7 – Install PHP $PHP_VERSION"

# Remi release for EL9
dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-9.rpm" 2>/dev/null || \
    log "Remi repo already installed"

dnf module reset php -y 2>/dev/null || true
dnf module enable "php:remi-8.$(echo "$PHP_VERSION" | tail -c 2)" -y 2>/dev/null || true

dnf install -y \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-php-fpm" \
    "php${PHP_VERSION}-php-gd" \
    "php${PHP_VERSION}-php-pgsql" \
    "php${PHP_VERSION}-php-odbc" \
    "php${PHP_VERSION}-php-curl" \
    "php${PHP_VERSION}-php-imap" \
    "php${PHP_VERSION}-php-opcache" \
    "php${PHP_VERSION}-php-common" \
    "php${PHP_VERSION}-php-pdo" \
    "php${PHP_VERSION}-php-soap" \
    "php${PHP_VERSION}-php-xml" \
    "php${PHP_VERSION}-php-xmlrpc" \
    "php${PHP_VERSION}-php-cli" \
    "php${PHP_VERSION}-php-mbstring" \
    "php${PHP_VERSION}-php-process" 2>/dev/null || \
dnf install -y \
    php-fpm php-gd php-pgsql php-odbc php-curl php-imap \
    php-opcache php-common php-pdo php-soap php-xml \
    php-xmlrpc php-cli php-mbstring php-process

PHP_BIN=$(which "php${PHP_VERSION}" 2>/dev/null || \
          which php82 2>/dev/null || which php81 2>/dev/null || \
          which php80 2>/dev/null || which php 2>/dev/null)

# Create 'php' symlink — FusionPBX calls 'php' when writing XML configs to FreeSWITCH.
# Without this, saving extensions/dialplans silently fails.
if [[ -n "$PHP_BIN" && ! -x /usr/bin/php ]]; then
    ln -sf "$PHP_BIN" /usr/bin/php
    ln -sf "$PHP_BIN" /usr/local/bin/php
    log "Created 'php' symlink -> $PHP_BIN"
fi

PHP_INI=$("$PHP_BIN" --ini 2>/dev/null | grep "Loaded Configuration" | awk '{print $NF}' || true)
PHP_FPM_CONF=$(find /etc -name "www.conf" -path "*/php-fpm.d/*" 2>/dev/null | head -1 || true)
PHP_FPM_SVC=$(systemctl list-unit-files 2>/dev/null | \
    grep -E "php[0-9]+-php-fpm|php-fpm" | awk '{print $1}' | head -1 || echo "php-fpm")

TIMEZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

# php.ini
if [[ -n "$PHP_INI" && -f "$PHP_INI" ]]; then
    sed -i "s|;date.timezone =|date.timezone = $TIMEZ|g" "$PHP_INI"
    sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' "$PHP_INI"
fi

# PHP-FPM pool config
mkdir -p /var/run/php-fpm
if [[ -n "$PHP_FPM_CONF" && -f "$PHP_FPM_CONF" ]]; then
    sed -i "s|^listen = .*|listen = /var/run/php-fpm/php-fpm.sock|g" "$PHP_FPM_CONF"
    sed -i 's/;listen\.owner = .*/listen.owner = freeswitch/g' "$PHP_FPM_CONF"
    sed -i 's/;listen\.group = .*/listen.group = daemon/g'     "$PHP_FPM_CONF"
    sed -i 's/^listen\.owner = .*/listen.owner = freeswitch/g' "$PHP_FPM_CONF"
    sed -i 's/^listen\.group = .*/listen.group = daemon/g'     "$PHP_FPM_CONF"
    sed -i 's/^user = .*/user = freeswitch/g'                  "$PHP_FPM_CONF"
    sed -i 's/^group = .*/group = daemon/g'                    "$PHP_FPM_CONF"
    # Disable ACL override — when listen.acl_users is set it ignores listen.owner/group
    sed -i 's/^listen\.acl_users = .*/;listen.acl_users = apache/g' "$PHP_FPM_CONF"
    # Ensure socket mode allows nginx (running as freeswitch) to connect
    sed -i '/^;*listen\.mode/c\listen.mode = 0660' "$PHP_FPM_CONF" || \
        echo "listen.mode = 0660" >> "$PHP_FPM_CONF"
fi

mkdir -p /var/lib/php/session && chmod 770 /var/lib/php/session

# Fix Remi PHP session/opcache dirs — default group is 'apache' but PHP-FPM
# runs as freeswitch:daemon, so sessions can't be written → every request
# appears unauthenticated and all FusionPBX pages show empty.
for _dir in session opcache wsdlcache; do
    _path=$(find /var/opt/remi -type d -name "$_dir" 2>/dev/null | head -1)
    if [[ -n "$_path" ]]; then
        chown root:daemon "$_path"
        chmod 770 "$_path"
        log "Fixed permissions: $_path"
    fi
done
log "PHP $PHP_VERSION installed."

# =============================================================================
# STEP 8 – FirewallD
# =============================================================================
step "STEP 8 – Configure FirewallD"

systemctl enable --now firewalld 2>/dev/null || warn "firewalld not available"

firewall-cmd --permanent --zone=public --add-service=http  2>/dev/null || true
firewall-cmd --permanent --zone=public --add-service=https 2>/dev/null || true
firewall-cmd --permanent --zone=public \
    --add-port={5060,5061,5080,5081}/udp 2>/dev/null || true
firewall-cmd --permanent --zone=public \
    --add-port={5060,5061,5080,5081}/tcp 2>/dev/null || true
firewall-cmd --permanent --zone=public \
    --add-port=16384-32768/udp 2>/dev/null || true

for PROTO in udp tcp; do
    for PORTS in 5060:5061 5080:5081; do
        for STR in "friendly-scanner" "sipcli/" "VaxSIPUserAgent/"; do
            firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 \
                -p "$PROTO" --dport "$PORTS" \
                -m string --string "$STR" --algo bm -j DROP 2>/dev/null || true
        done
    done
done

firewall-cmd --reload 2>/dev/null || warn "firewall-cmd reload had issues"
log "FirewallD configured."

# =============================================================================
# STEP 9 – FreeSWITCH (compiled from source — no token needed)
# =============================================================================
# This matches how the official Debian/Ubuntu FusionPBX installer works:
# it builds FreeSWITCH from the FusionPBX GitHub fork rather than using
# SignalWire binary packages.
# =============================================================================
step "STEP 9 – Compile FreeSWITCH $SWITCH_VERSION from source"

# Create freeswitch system user FIRST (needed for chown later)
if ! id freeswitch &>/dev/null; then
    useradd -r -g daemon -d /var/lib/freeswitch -s /sbin/nologin freeswitch
    log "Created 'freeswitch' system user."
fi

# ---- Build dependencies (common to all architectures) ----
log "Installing FreeSWITCH build dependencies..."
dnf install -y \
    autoconf automake libtool gcc-c++ make cmake git wget \
    ncurses-devel libjpeg-devel libedit-devel \
    openssl-devel \
    sqlite-devel curl-devel pcre-devel pcre2-devel ldns-devel lame-devel lua-devel \
    "postgresql${PG_VERSION}-devel" libmemcached-awesome-devel libshout-devel mpg123-devel \
    speex-devel speexdsp-devel \
    libsndfile-devel libuuid-devel uuid-devel \
    expat-devel libxml2-devel \
    unixODBC-devel \
    libtiff-devel \
    python3 perl diffutils patch pkgconfig

# libuv-devel — package name varies by distro version
dnf install -y libuv-devel 2>/dev/null || \
    dnf install -y libuv1-devel 2>/dev/null || \
    warn "libuv-devel not found — FreeSWITCH will build without libuv"

# x86_64-only: yasm/nasm are x86 assemblers — not available/needed on aarch64
if [[ "$ARCH" == "x86_64" ]]; then
    log "Installing x86_64 assemblers (yasm, nasm)..."
    dnf install -y yasm nasm 2>/dev/null || \
        warn "yasm/nasm not available — video codec performance may be reduced"
else
    log "Skipping yasm/nasm (not applicable for $ARCH)"
fi

# Optional packages — failure is non-fatal on any architecture
dnf install -y libvpx-devel opus-devel gdbm-devel libdb-devel flac-devel \
    2>/dev/null || true

# Ensure locally compiled libraries (/usr/local/lib) are always found by ldconfig
# This is needed after building libks, sofia-sip, spandsp from source on both arches
if ! grep -qr '/usr/local/lib' /etc/ld.so.conf /etc/ld.so.conf.d/ 2>/dev/null; then
    echo "/usr/local/lib" > /etc/ld.so.conf.d/local-libs.conf
    log "Added /usr/local/lib to ldconfig search path"
fi
ldconfig

# Set PKG_CONFIG_PATH so ./configure can find headers/libs from locally built deps
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/pgsql-${PG_VERSION}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export C_INCLUDE_PATH="/usr/local/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="/usr/local/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
log "Build environment paths set for $ARCH"

# ---- 1. libks ----
if [[ ! -f /usr/local/include/libks/ks.h && ! -f /usr/include/libks/ks.h && \
      ! -f /usr/include/libks2/libks/ks.h ]] && \
      ! pkg-config --exists libks2 2>/dev/null; then
    log "Building libks..."
    cd /usr/src
    [[ -d libks ]] && rm -rf libks
    git clone https://github.com/signalwire/libks.git libks
    cd libks
    cmake . -DCMAKE_INSTALL_PREFIX=/usr
    make -j"$(nproc)"
    make install
    ldconfig && log "libks installed."
else
    log "libks already installed."
fi

# ---- 2. sofia-sip ----
if ! pkg-config --exists sofia-sip-ua 2>/dev/null; then
    log "Building sofia-sip $SOFIA_VERSION..."
    cd /usr/src
    [[ -d "sofia-sip-${SOFIA_VERSION}" ]] && rm -rf "sofia-sip-${SOFIA_VERSION}"
    wget -q "https://github.com/freeswitch/sofia-sip/archive/refs/tags/v${SOFIA_VERSION}.tar.gz" \
        -O "sofia-sip-${SOFIA_VERSION}.tar.gz"
    tar xzf "sofia-sip-${SOFIA_VERSION}.tar.gz"
    cd "sofia-sip-${SOFIA_VERSION}"
    sh autogen.sh
    ./configure
    make -j"$(nproc)"
    make install
    ldconfig
    log "sofia-sip installed."
else
    log "sofia-sip already installed."
fi

# ---- 3. spandsp ----
if ! pkg-config --exists spandsp 2>/dev/null; then
    log "Building spandsp..."
    cd /usr/src
    [[ -d spandsp ]] && rm -rf spandsp
    git clone https://github.com/freeswitch/spandsp.git spandsp
    cd spandsp
    # Use the known-good commit that works with FreeSWITCH 1.10
    git checkout 0d2e6ac65e0e8f53d652665a743015a88bf048d4 2>/dev/null || true
    sh autogen.sh
    ./configure
    make -j"$(nproc)"
    make install
    ldconfig
    log "spandsp installed."
else
    log "spandsp already installed."
fi

# ---- 4. FreeSWITCH ----
FS_SRC="/usr/src/freeswitch-${SWITCH_VERSION}"
if [[ ! -f /usr/bin/freeswitch ]]; then
    log "Cloning FreeSWITCH $SWITCH_VERSION (FusionPBX fork)..."
    cd /usr/src
    [[ -d "$FS_SRC" ]] && rm -rf "$FS_SRC"
    git clone https://github.com/fusionpbx/freeswitch.git "$FS_SRC"
    cd "$FS_SRC"
    git reset --hard origin/master && git clean -fdx

    ./bootstrap.sh -j

    # Enable extra modules (matching Debian installer — same on all arches)
    sed -i 's:#applications/mod_callcenter:applications/mod_callcenter:'  modules.conf
    sed -i 's:#applications/mod_cidlookup:applications/mod_cidlookup:'    modules.conf
    sed -i 's:#applications/mod_memcache:applications/mod_memcache:'      modules.conf
    sed -i 's:#applications/mod_nibblebill:applications/mod_nibblebill:'  modules.conf
    sed -i 's:#applications/mod_curl:applications/mod_curl:'              modules.conf
    sed -i 's:#applications/mod_translate:applications/mod_translate:'    modules.conf
    sed -i 's:#formats/mod_shout:formats/mod_shout:'                      modules.conf
    sed -i 's:#formats/mod_pgsql:formats/mod_pgsql:'                      modules.conf
    sed -i 's:#say/mod_say_es:say/mod_say_es:'                            modules.conf
    sed -i 's:#say/mod_say_fr:say/mod_say_fr:'                            modules.conf

    # Disable modules that need unavailable or optional deps (all arches)
    sed -i 's:applications/mod_signalwire:#applications/mod_signalwire:'  modules.conf
    sed -i 's:endpoints/mod_skinny:#endpoints/mod_skinny:'                modules.conf
    sed -i 's:endpoints/mod_verto:#endpoints/mod_verto:'                  modules.conf

    # aarch64-specific: disable video/codec modules that rely on x86 assembler
    # or have no ARM-optimised codec path in this build environment
    if [[ "$ARCH" == "aarch64" ]]; then
        log "Disabling video modules that need libav/ffmpeg (not available on aarch64 build)..."
        sed -i 's:^applications/mod_av:#applications/mod_av:'   modules.conf 2>/dev/null || true
        sed -i 's:^formats/mod_av:#formats/mod_av:'             modules.conf 2>/dev/null || true
        sed -i 's:^codecs/mod_vpx:#codecs/mod_vpx:'             modules.conf 2>/dev/null || true
        sed -i 's:^codecs/mod_h26x:#codecs/mod_h26x:'           modules.conf 2>/dev/null || true
    fi

    log "Configuring FreeSWITCH..."
    ./configure -C \
        --enable-portable-binary \
        --disable-dependency-tracking \
        --prefix=/usr \
        --localstatedir=/var \
        --sysconfdir=/etc \
        --with-openssl \
        --enable-core-pgsql-support

    log "Compiling FreeSWITCH (this takes 30-60 minutes)..."
    make -j"$(nproc)"
    make install
    make sounds-install
    make moh-install

    # Voicemail directory
    mkdir -p /var/lib/freeswitch/storage/voicemail

    log "FreeSWITCH compiled and installed."
else
    log "FreeSWITCH binary already exists at /usr/bin/freeswitch — skipping build."
fi

# Required directories
mkdir -p /etc/freeswitch /var/lib/freeswitch /var/log/freeswitch \
         /usr/share/freeswitch /var/run/freeswitch

# Copy FusionPBX FreeSWITCH config
if [[ -d /var/www/fusionpbx/app/switch/resources/conf ]]; then
    if [[ -d /etc/freeswitch && "$(ls -A /etc/freeswitch 2>/dev/null)" ]]; then
        TS=$(date +%s)
        mv /etc/freeswitch "/etc/freeswitch.orig.$TS" || true
    fi
    mkdir -p /etc/freeswitch
    cp -R /var/www/fusionpbx/app/switch/resources/conf/* /etc/freeswitch/
    log "Copied FusionPBX config to /etc/freeswitch/"
fi

# Protect music-on-hold from future package updates
if [[ -d /usr/share/freeswitch/sounds/music ]]; then
    mkdir -p /usr/share/freeswitch/sounds/temp
    find /usr/share/freeswitch/sounds/music -name '*000' \
        -exec mv {} /usr/share/freeswitch/sounds/temp/ \; 2>/dev/null || true
    mkdir -p /usr/share/freeswitch/sounds/music/default
    find /usr/share/freeswitch/sounds/temp -type f \
        -exec mv {} /usr/share/freeswitch/sounds/music/default/ \; 2>/dev/null || true
    rm -rf /usr/share/freeswitch/sounds/temp
fi

# Write systemd service file
# Note: CPUSchedulingPolicy=rr and IOSchedulingClass=realtime require
# real-time kernel capabilities. On bare-metal they are ideal for telephony;
# on VMs (especially aarch64) they can cause the service to fail to start.
# We detect virtualisation and use conservative scheduling for VMs.
IS_VM=false
if systemd-detect-virt -q 2>/dev/null; then
    IS_VM=true
    log "Virtual machine detected — using standard CPU/IO scheduling"
else
    log "Bare-metal detected — using real-time CPU/IO scheduling"
fi

if [[ "$IS_VM" == "true" ]]; then
    cat > /lib/systemd/system/freeswitch.service << 'FS_SERVICE'
[Unit]
Description=FreeSWITCH open-source telephony platform
After=syslog.target network.target local-fs.target postgresql.service

[Service]
Type=forking
PIDFile=/run/freeswitch/freeswitch.pid
Environment="DAEMON_OPTS=-nonat"
EnvironmentFile=-/etc/sysconfig/freeswitch
ExecStartPre=/bin/mkdir -p /var/run/freeswitch
ExecStartPre=/bin/chown -R freeswitch:daemon /var/run/freeswitch
ExecStart=/usr/bin/freeswitch -u freeswitch -g daemon -ncwait $DAEMON_OPTS
TimeoutSec=45s
Restart=always
User=root
Group=daemon
LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
UMask=0007

[Install]
WantedBy=multi-user.target
FS_SERVICE
else
    cat > /lib/systemd/system/freeswitch.service << 'FS_SERVICE'
[Unit]
Description=FreeSWITCH open-source telephony platform
After=syslog.target network.target local-fs.target postgresql.service

[Service]
Type=forking
PIDFile=/run/freeswitch/freeswitch.pid
Environment="DAEMON_OPTS=-nonat"
EnvironmentFile=-/etc/sysconfig/freeswitch
ExecStartPre=/bin/mkdir -p /var/run/freeswitch
ExecStartPre=/bin/chown -R freeswitch:daemon /var/run/freeswitch
ExecStart=/usr/bin/freeswitch -u freeswitch -g daemon -ncwait $DAEMON_OPTS
TimeoutSec=45s
Restart=always
User=root
Group=daemon
LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
LimitRTPRIO=infinity
LimitRTTIME=7000000
IOSchedulingClass=realtime
IOSchedulingPriority=2
CPUSchedulingPolicy=rr
CPUSchedulingPriority=89
UMask=0007

[Install]
WantedBy=multi-user.target
FS_SERVICE
fi

printf "DAEMON_OPTS=-nonat\n" > /etc/sysconfig/freeswitch

systemctl daemon-reload
systemctl enable freeswitch
log "FreeSWITCH service configured."

# =============================================================================
# STEP 10 – Fail2ban
# =============================================================================
step "STEP 10 – Install Fail2ban"

dnf install -y fail2ban fail2ban-systemd 2>/dev/null || \
    dnf install -y fail2ban 2>/dev/null || \
    warn "fail2ban not available"

if command -v fail2ban-server &>/dev/null; then
    mkdir -p /etc/fail2ban/filter.d
    F2B_SRC=""
    # Look for filter files in the fusionpbx-install.sh repo
    for d in \
        "$SCRIPT_DIR/resources/fail2ban" \
        "/usr/src/fusionpbx-install.sh/centos/resources/fail2ban" \
        "/usr/src/fusionpbx-install.sh/debian/resources/fail2ban"; do
        [[ -d "$d" ]] && F2B_SRC="$d" && break
    done
    if [[ -n "$F2B_SRC" ]]; then
        for f in freeswitch-dos.conf freeswitch-ip.conf freeswitch-404.conf \
                  freeswitch.conf fusionpbx.conf nginx-404.conf nginx-dos.conf; do
            [[ -f "$F2B_SRC/$f" ]] && cp "$F2B_SRC/$f" "/etc/fail2ban/filter.d/$f"
        done
        [[ -f "$F2B_SRC/jail.local" ]] && cp "$F2B_SRC/jail.local" /etc/fail2ban/jail.local
    fi
    systemctl enable fail2ban
    log "Fail2ban installed."
else
    warn "fail2ban binary not found — skipping."
fi

# =============================================================================
# STEP 11 – FusionPBX: database schema + admin user
# =============================================================================
step "STEP 11 – Configure FusionPBX"

if [[ "$SYSTEM_PASSWORD" == "random" ]]; then
    set +o pipefail
    SYSTEM_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    set -o pipefail
fi

export PGPASSWORD="$DB_PASSWORD"

# Write /etc/fusionpbx/config.conf
mkdir -p /etc/fusionpbx
CONF_TMPL=""
for d in \
    "$SCRIPT_DIR/resources/fusionpbx" \
    "/usr/src/fusionpbx-install.sh/centos/resources/fusionpbx" \
    "/usr/src/fusionpbx-install.sh/debian/resources/fusionpbx"; do
    [[ -f "$d/config.conf" ]] && CONF_TMPL="$d/config.conf" && break
done

if [[ -n "$CONF_TMPL" ]]; then
    cp "$CONF_TMPL" /etc/fusionpbx/config.conf
    sed -i "s|{database_host}|127.0.0.1|g"       /etc/fusionpbx/config.conf
    sed -i "s|{database_name}|$DB_NAME|g"         /etc/fusionpbx/config.conf
    sed -i "s|{database_username}|$DB_USER|g"     /etc/fusionpbx/config.conf
    sed -i "s|{database_password}|$DB_PASSWORD|g" /etc/fusionpbx/config.conf
else
    cat > /etc/fusionpbx/config.conf << FUSCONF
<?php
\$db_type     = 'pgsql';
\$db_host     = '127.0.0.1';
\$db_port     = '5432';
\$db_name     = '$DB_NAME';
\$db_username = '$DB_USER';
\$db_password = '$DB_PASSWORD';
FUSCONF
fi

PHP_BIN=$(which "php${PHP_VERSION}" 2>/dev/null || \
          which php82 2>/dev/null || which php81 2>/dev/null || \
          which php80 2>/dev/null || which php 2>/dev/null)
PSQL_BIN="/usr/pgsql-${PG_VERSION}/bin/psql"
[[ ! -x "$PSQL_BIN" ]] && PSQL_BIN=$(which psql)

log "PHP binary:  $PHP_BIN"
log "psql binary: $PSQL_BIN"

# Apply database schema
cd /var/www/fusionpbx
"$PHP_BIN" /var/www/fusionpbx/core/upgrade/upgrade_schema.php > /dev/null 2>&1 || \
    warn "Schema upgrade had warnings (normal on first run)"

DOMAIN_NAME=$(hostname -I | awk '{print $1}')
DOMAIN_UUID=$("$PHP_BIN" /var/www/fusionpbx/resources/uuid.php)
USER_UUID=$("$PHP_BIN"   /var/www/fusionpbx/resources/uuid.php)
USER_SALT=$("$PHP_BIN"   /var/www/fusionpbx/resources/uuid.php)

# Insert domain
DOM_EXISTS=$("$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
    -tAc "SELECT COUNT(*) FROM v_domains WHERE domain_name='$DOMAIN_NAME';" 2>/dev/null || echo "0")
if [[ "$DOM_EXISTS" == "0" ]]; then
    "$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
        -c "INSERT INTO v_domains (domain_uuid, domain_name, domain_enabled) \
            VALUES('$DOMAIN_UUID','$DOMAIN_NAME','true');" 2>/dev/null || warn "Domain insert failed"
fi

cd /var/www/fusionpbx
"$PHP_BIN" /var/www/fusionpbx/core/upgrade/upgrade_domains.php > /dev/null 2>&1 || true

# Hash admin password
# FusionPBX current versions use bcrypt (password_hash) not md5+salt
PASSWORD_HASH=$("$PHP_BIN" -r "echo password_hash('${SYSTEM_PASSWORD}', PASSWORD_BCRYPT);")

# Insert admin user
USR_EXISTS=$("$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
    -tAc "SELECT COUNT(*) FROM v_users WHERE username='$SYSTEM_USERNAME';" 2>/dev/null || echo "0")
if [[ "$USR_EXISTS" == "0" ]]; then
    "$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
        -c "INSERT INTO v_users \
            (user_uuid, domain_uuid, username, password, salt, user_enabled) \
            VALUES('$USER_UUID','$DOMAIN_UUID','$SYSTEM_USERNAME','$PASSWORD_HASH',NULL,'true');" \
        2>/dev/null || warn "User insert failed"
fi

# Add admin to superadmin group
GROUP_UUID=$("$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
    -tAc "SELECT group_uuid FROM v_groups WHERE group_name='superadmin' LIMIT 1;" \
    2>/dev/null | tr -d ' \n')
if [[ -n "$GROUP_UUID" ]]; then
    UG_UUID=$("$PHP_BIN" /var/www/fusionpbx/resources/uuid.php)
    "$PSQL_BIN" --host=127.0.0.1 --port=5432 --username="$DB_USER" \
        -c "INSERT INTO v_user_groups \
            (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid) \
            VALUES('$UG_UUID','$DOMAIN_UUID','superadmin','$GROUP_UUID','$USER_UUID');" \
        2>/dev/null || true
fi

cd /var/www/fusionpbx
"$PHP_BIN" /var/www/fusionpbx/core/upgrade/upgrade_domains.php > /dev/null 2>&1 || true
log "FusionPBX database configured."

# =============================================================================
# STEP 12 – File permissions
# =============================================================================
step "STEP 12 – Set permissions"

# nginx runs as freeswitch:daemon
sed -i 's/^user nginx;/user freeswitch daemon;/' /etc/nginx/nginx.conf 2>/dev/null || true

mkdir -p /var/lib/nginx/tmp
chown -R freeswitch:daemon /var/lib/nginx 2>/dev/null || true

# PHP-FPM pool (enforce freeswitch user)
PHP_FPM_CONF_F=$(find /etc -name "www.conf" -path "*/php-fpm.d/*" 2>/dev/null | head -1 || true)
if [[ -n "$PHP_FPM_CONF_F" ]]; then
    sed -i 's/^user = .*/user = freeswitch/'  "$PHP_FPM_CONF_F"
    sed -i 's/^group = .*/group = daemon/'    "$PHP_FPM_CONF_F"
fi

chown -R freeswitch:daemon /var/lib/php/session 2>/dev/null || true

# FusionPBX web root
find /var/www/fusionpbx -type d -exec chmod 770 {} \;
find /var/www/fusionpbx -type f -exec chmod 664 {} \;
chown -R freeswitch:daemon /var/www/fusionpbx
chown -R freeswitch:daemon /var/cache/fusionpbx 2>/dev/null || true
chown -R freeswitch:daemon /etc/fusionpbx       2>/dev/null || true

# FreeSWITCH directories
for DIR in /etc/freeswitch /var/lib/freeswitch /var/log/freeswitch /usr/share/freeswitch; do
    if [[ -d "$DIR" ]]; then
        chown -R freeswitch:daemon "$DIR"
        find "$DIR" -type d -exec chmod 770 {} \;
        find "$DIR" -type f -exec chmod 664 {} \;
    fi
done

# XML CDR credentials
XML_CDR="/etc/freeswitch/autoload_configs/xml_cdr.conf.xml"
if [[ -f "$XML_CDR" ]]; then
    set +o pipefail
    CDR_USER=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    CDR_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    set -o pipefail
    sed -i "s|{v_http_protocol}|http|g"   "$XML_CDR"
    sed -i "s|{domain_name}|127.0.0.1|g"  "$XML_CDR"
    sed -i "s|{v_project_path}||g"         "$XML_CDR"
    sed -i "s|{v_user}|$CDR_USER|g"       "$XML_CDR"
    sed -i "s|{v_pass}|$CDR_PASS|g"       "$XML_CDR"
fi

log "Permissions set."

# =============================================================================
# STEP 13 – Enable & start all services
# =============================================================================
step "STEP 13 – Enable and start services"

systemctl daemon-reload
systemctl mask wpa_supplicant.service 2>/dev/null || true

for SVC in chronyd memcached "postgresql-${PG_VERSION}" nginx freeswitch; do
    systemctl enable "$SVC" 2>/dev/null || warn "Could not enable $SVC"
done

PHP_FPM_SVC=$(systemctl list-unit-files 2>/dev/null | \
    grep -E "php[0-9]+-php-fpm|php-fpm" | awk '{print $1}' | head -1 || true)
[[ -n "$PHP_FPM_SVC" ]] && systemctl enable "$PHP_FPM_SVC" 2>/dev/null || true
systemctl enable fail2ban 2>/dev/null || true

log "Starting services..."
systemctl restart chronyd       2>/dev/null || true
systemctl restart memcached     2>/dev/null || true
systemctl restart "postgresql-${PG_VERSION}"
[[ -n "$PHP_FPM_SVC" ]] && \
    systemctl restart "$PHP_FPM_SVC" || warn "PHP-FPM not started"
nginx -t 2>/dev/null && systemctl restart nginx || warn "nginx config error — run: nginx -t"
systemctl restart freeswitch || warn "FreeSWITCH not started — check: journalctl -xeu freeswitch"
systemctl restart fail2ban 2>/dev/null || true

# =============================================================================
# Done – print credentials
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        FusionPBX Installation Complete!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  ┌── Web Interface ────────────────────────────────────────┐"
echo "  │  URL:      https://$IP_ADDR"
echo "  │  Username: $SYSTEM_USERNAME"
echo "  │  Password: $SYSTEM_PASSWORD"
echo "  │  (Domain login: ${SYSTEM_USERNAME}@${IP_ADDR})"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌── Database ──────────────────────────────────────────────┐"
echo "  │  Host:     127.0.0.1:5432"
echo "  │  Name:     $DB_NAME"
echo "  │  Username: $DB_USER"
echo "  │  Password: $DB_PASSWORD"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌── Service Status ────────────────────────────────────────┐"
for SVC in "postgresql-${PG_VERSION}" nginx freeswitch; do
    STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "unknown")
    [[ "$STATUS" == "active" ]] && C="${GREEN}" || C="${RED}"
    printf "  │  %-38s %b%s%b\n" "$SVC" "$C" "$STATUS" "$NC"
done
if [[ -n "$PHP_FPM_SVC" ]]; then
    STATUS=$(systemctl is-active "$PHP_FPM_SVC" 2>/dev/null || echo "unknown")
    [[ "$STATUS" == "active" ]] && C="${GREEN}" || C="${RED}"
    printf "  │  %-38s %b%s%b\n" "$PHP_FPM_SVC" "$C" "$STATUS" "$NC"
fi
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "  ${YELLOW}!! Save these credentials before closing this window !!${NC}"
echo -e "  ${YELLOW}!! Recommended: sudo reboot                           !!${NC}"
echo ""
