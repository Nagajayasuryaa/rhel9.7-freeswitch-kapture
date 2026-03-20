# rhel9.7-freeswitch-kapture

Automated **FusionPBX + FreeSWITCH + Kapture-CRM** installation scripts for:

- Red Hat Enterprise Linux 9.x
- Rocky Linux 9.x
- AlmaLinux 9.x

Supports both **x86_64** and **aarch64 (ARM64)** architectures.

---

## What gets installed

| Component | Version | Method |
|---|---|---|
| FreeSWITCH | 1.10.12 | Compiled from source (FusionPBX fork) |
| FusionPBX | Latest (master) | Cloned from GitHub |
| PostgreSQL | 14 | PGDG official repo |
| PHP | 8.2 | Remi repo |
| nginx | Latest | RHEL AppStream |
| Fail2ban | Latest | EPEL |
| Memcached | Latest | RHEL AppStream |
| mod_audio_stream | Latest | Compiled from source |
| Python ESL bindings | Built from FS source | FreeSWITCH ESL SWIG |
| Kapture-CRM integration | Latest | Cloned from GitHub |

> **No SignalWire token required.**
> FreeSWITCH is compiled from the [FusionPBX fork](https://github.com/fusionpbx/freeswitch)
> exactly as the official Debian/Ubuntu installer does.

---

## Requirements

| Resource | Minimum |
|---|---|
| OS | RHEL / Rocky / AlmaLinux 9.x |
| CPU | 2 cores |
| RAM | 2 GB (4 GB recommended) |
| Disk | 20 GB free |
| Network | Internet access (for package downloads) |

---

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/Nagajayasuryaa/rhel9.7-freeswitch-kapture.git
cd rhel9.7-freeswitch-kapture

# 2. Make scripts executable
chmod +x install-rhel9.sh post-install-rhel9.sh

# 3. Run inside screen (recommended — compilation takes 30-60 min)
sudo dnf install -y screen
screen -S fusionpbx

# 4. Run with log capture (recommended)
sudo bash install-rhel9.sh 2>&1 | tee install.log
```

If your SSH session drops, reconnect with:
```bash
screen -r fusionpbx
```

Once `install-rhel9.sh` completes, run the post-install script:
```bash
sudo bash post-install-rhel9.sh 2>&1 | tee post-install.log
```

---

## Log Output

Both scripts print colour-coded output to the terminal as they run.

### Log levels

| Prefix | Colour | Meaning |
|---|---|---|
| `[INFO]  HH:MM:SS` | Green | Normal progress message |
| `[WARN]  HH:MM:SS` | Yellow | Non-fatal warning (script continues) |
| `[ERROR] HH:MM:SS` | Red | Fatal error — script exits immediately |

Example output:
```
[INFO]  09:14:02 OS:   rocky 9
[INFO]  09:14:02 Arch: x86_64
[INFO]  09:14:02 IP:   192.168.1.100
[WARN]  09:14:10 Some packages may already be installed
[INFO]  09:14:15 PostgreSQL 14 ready.
[ERROR] 09:14:20 FreeSWITCH not found. Run install-rhel9.sh first.
```

### Capturing logs to a file

Run the script with `tee` to save output while still viewing it live:

```bash
# install log
sudo bash install-rhel9.sh 2>&1 | tee install.log

# post-install log
sudo bash post-install-rhel9.sh 2>&1 | tee post-install.log
```

> **Note:** Using `tee` strips ANSI colour codes from the saved file — the terminal still shows colours.

### Viewing logs after the run

```bash
# Full install log
cat install.log

# Filter only errors and warnings
grep -E "\[ERROR\]|\[WARN\]" install.log

# Filter only errors
grep "\[ERROR\]" install.log

# Follow live output (if still running)
tail -f install.log
```

### System service logs (after installation)

```bash
# FreeSWITCH application log
tail -f /var/log/freeswitch/freeswitch.log

# FreeSWITCH systemd journal
journalctl -xeu freeswitch

# nginx access + error logs
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log

# PHP-FPM log
journalctl -xeu php82-php-fpm
```

---

## Script 1 — install-rhel9.sh (Base Installation)

### What it does

```
STEP 0  — Pre-flight checks (OS version, architecture, root check)
STEP 1  — Remove broken repos, enable EPEL + CRB, update system
STEP 2  — Set SELinux to permissive
STEP 3  — PostgreSQL setup
            ├── Local (DB_HOST=127.0.0.1): install PG14, create roles/DBs
            └── External (DB_HOST=<remote>): install psql client only, verify connectivity
STEP 4  — Clone FusionPBX from GitHub
STEP 5  — Generate self-signed SSL certificate
STEP 6  — Install and configure nginx
STEP 7  — Install PHP 8.2 (Remi repo) + all required extensions
STEP 8  — Configure FirewallD (HTTP/HTTPS + SIP 5060/5080 + RTP 16384-32768)
STEP 9  — Compile FreeSWITCH from source
            ├── Build libks
            ├── Build sofia-sip
            ├── Build spandsp
            └── Compile FreeSWITCH
STEP 10 — Install Fail2ban + FusionPBX filters
STEP 11 — Configure FusionPBX (DB schema, admin user, domain)
STEP 12 — Set file permissions
STEP 13 — Enable and start all services
```

### Customisation

Edit the variables at the top of `install-rhel9.sh` before running:

```bash
SYSTEM_USERNAME="admin"      # Web UI login username
SYSTEM_PASSWORD="random"     # 'random' = auto-generate
PHP_VERSION="82"             # 80 | 81 | 82 | 83
PG_VERSION="14"              # PostgreSQL version (also selects psql client version)

# Database — see "Database Configuration" section below
DB_HOST="127.0.0.1"          # Change to remote IP/hostname for external DB
DB_PORT="5432"
DB_NAME="fusionpbx"
DB_USER="fusionpbx"
DB_PASSWORD="random"         # 'random' = auto-generate (local only)
```

---

## Database Configuration

The script supports two modes controlled by the `DB_HOST` variable at the top of `install-rhel9.sh`.

---

### Option A — Local PostgreSQL (default)

Leave `DB_HOST` as `127.0.0.1`. The script installs and configures PostgreSQL 14 on the same server automatically.

```bash
DB_HOST="127.0.0.1"    # default — installs PostgreSQL locally
DB_PORT="5432"
DB_NAME="fusionpbx"
DB_USER="fusionpbx"
DB_PASSWORD="random"   # auto-generated and printed at the end
PG_VERSION="14"
```

Nothing else is needed — roles, databases, and permissions are all created by the script.

---

### Option B — External / Centralized PostgreSQL

Use this when you want multiple FusionPBX nodes sharing one database, or when your organisation already runs a managed PostgreSQL server.

#### Step 1 — Prepare the remote database server

Run these commands on the **remote PostgreSQL server** as a superuser (e.g. `postgres`):

```sql
-- Create roles
CREATE ROLE fusionpbx  WITH SUPERUSER LOGIN PASSWORD 'YourStrongPassword';
CREATE ROLE freeswitch WITH SUPERUSER LOGIN PASSWORD 'YourStrongPassword';

-- Create databases
CREATE DATABASE fusionpbx  OWNER fusionpbx;
CREATE DATABASE freeswitch OWNER fusionpbx;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE fusionpbx  TO fusionpbx;
GRANT ALL PRIVILEGES ON DATABASE freeswitch TO fusionpbx;
GRANT ALL PRIVILEGES ON DATABASE freeswitch TO freeswitch;
```

#### Step 2 — Allow connections from the FusionPBX server

On the **remote PostgreSQL server**, edit `pg_hba.conf`:

```
# Allow fusionpbx role from the FusionPBX server IP
host    fusionpbx    fusionpbx    <fusionpbx-server-ip>/32    md5
host    freeswitch   fusionpbx    <fusionpbx-server-ip>/32    md5
```

Then reload PostgreSQL:
```bash
systemctl reload postgresql-14
```

Also open port `5432` in the DB server's firewall:
```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<fusionpbx-server-ip>/32" port port="5432" protocol="tcp" accept'
firewall-cmd --reload
```

#### Step 3 — Update install-rhel9.sh

Edit the DB variables at the top of `install-rhel9.sh`:

```bash
DB_HOST="192.168.1.50"       # IP or hostname of your remote DB server
DB_PORT="5432"
DB_NAME="fusionpbx"
DB_USER="fusionpbx"
DB_PASSWORD="YourStrongPassword"   # must match what you set in Step 1
```

> **Important:** `DB_PASSWORD` must be set explicitly — `"random"` is not allowed when using an external DB.

#### Step 4 — Run the install script as normal

```bash
sudo bash install-rhel9.sh 2>&1 | tee install.log
```

The script will:
1. **Skip** local PostgreSQL installation entirely
2. Install only the `psql` client package (needed to run schema upgrades)
3. **Test connectivity** to `DB_HOST:DB_PORT` before proceeding — exits with `[ERROR]` if it cannot connect
4. Run `upgrade_schema.php` to create all FusionPBX tables on the remote DB
5. Write `DB_HOST` and `DB_PORT` into `/etc/fusionpbx/config.conf`

#### Verify the config after install

```bash
cat /etc/fusionpbx/config.conf
```

Should show your remote host:
```php
$db_type     = 'pgsql';
$db_host     = '192.168.1.50';
$db_port     = '5432';
$db_name     = 'fusionpbx';
$db_username = 'fusionpbx';
$db_password = 'YourStrongPassword';
```

#### Troubleshoot external DB connection

```bash
# Test connectivity manually from the FusionPBX server
PGPASSWORD="YourStrongPassword" psql \
  --host=192.168.1.50 --port=5432 \
  --username=fusionpbx --dbname=fusionpbx \
  -c "SELECT version();"

# Check if pg_hba.conf is rejecting the connection
# (run on the DB server)
tail -f /var/lib/pgsql/14/data/log/postgresql-*.log
```

---

### After Installation

The script prints your credentials when complete:

```
URL:      https://<server-ip>
Username: admin
Password: <auto-generated>
```

Then reboot:
```bash
sudo reboot
```

Open `https://<server-ip>` in your browser to access FusionPBX.

If prompted for domain login use:
```
admin@<server-ip>
```

---

## Script 2 — post-install-rhel9.sh (Kapture-CRM Integration)

Run this **after** `install-rhel9.sh` has completed successfully.

### What it does

```
Pre-flight — Verifies FreeSWITCH binary exists before proceeding
STEP 1     — Install build dependencies for mod_audio_stream
               (cmake, gcc-c++, speexdsp, libevent, openssl)
STEP 2     — Clone and compile mod_audio_stream
               (from github.com/amigniter/mod_audio_stream)
STEP 3     — Python 3 environment setup
               (installs python3, pip, setuptools, swig)
STEP 4     — Build Python ESL bindings from FreeSWITCH source
               (compiles ESL SWIG bindings from /usr/src/freeswitch-1.10.12)
STEP 5     — Clone freeswitch-kapture repo (Kapture-CRM integration)
STEP 6     — Python virtual environment + pip requirements
               (creates venv, installs all Python dependencies)
STEP 7     — Load mod_audio_stream into FreeSWITCH
               (adds module config and reloads FreeSWITCH)
STEP 8     — Start Kapture-CRM Python services
               (esl_integration + websocket_server as background services)
```

### Run it

```bash
sudo bash post-install-rhel9.sh
```

> **Note:** This script requires `install-rhel9.sh` to have been run first.
> It will exit with an error if FreeSWITCH is not installed.

---

## Architecture differences handled automatically

| | x86_64 | aarch64 |
|---|---|---|
| yasm / nasm | Installed | Skipped (x86-only assemblers) |
| mod_av / mod_vpx | Enabled | Disabled (no x86 codec path) |
| PostgreSQL repo | EL-9-x86_64 | EL-9-aarch64 |
| CPU scheduling | Realtime (bare-metal) | Standard (VM-safe) |

---

## Troubleshooting

**Check service status:**
```bash
systemctl status freeswitch
systemctl status nginx
systemctl status php82-php-fpm
systemctl status postgresql-14
```

**Check FreeSWITCH logs:**
```bash
journalctl -xeu freeswitch
tail -f /var/log/freeswitch/freeswitch.log
```

**Check nginx config:**
```bash
nginx -t
```

**Check mod_audio_stream is loaded:**
```bash
fs_cli -x "module_exists mod_audio_stream"
```

**Rerun if interrupted:**
Both scripts are safe to re-run — they skip steps already completed
(e.g. if FreeSWITCH binary already exists, compilation is skipped).

---

## Ports opened by FirewallD

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | HTTP (redirects to HTTPS) |
| 443 | TCP | HTTPS — FusionPBX web UI |
| 5060, 5061 | UDP/TCP | SIP |
| 5080, 5081 | UDP/TCP | SIP (outbound) |
| 16384–32768 | UDP | RTP media (audio) |
