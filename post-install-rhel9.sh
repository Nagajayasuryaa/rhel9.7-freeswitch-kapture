#!/bin/bash
# =============================================================================
# FusionPBX Post-Install: mod_audio_stream + Kapture-CRM Python Setup
# OS:   Red Hat Enterprise Linux 9.x (RHEL / Rocky / AlmaLinux)
# Arch: aarch64 / x86_64
# Run AFTER install-rhel9.sh has completed successfully.
# =============================================================================

set -euo pipefail

# --- Colour helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]  $(date '+%H:%M:%S') $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]  $(date '+%H:%M:%S') $*${NC}"; }
error() { echo -e "${RED}[ERROR] $(date '+%H:%M:%S') $*${NC}" >&2; exit 1; }
step()  { echo ""; echo -e "${BLUE}══════════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  $*${NC}"; \
          echo -e "${BLUE}══════════════════════════════════════════════${NC}"; }

# --- Pre-flight ---------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Must be run as root:  sudo ./post-install-rhel9.sh"
[[ ! -f /usr/bin/freeswitch ]] && error "FreeSWITCH not found. Run install-rhel9.sh first."

ARCH=$(uname -m)
FS_SRC="/usr/src/freeswitch-1.10.12"          # FreeSWITCH source (used for ESL build)
FS_MOD_DIR="/usr/lib64/freeswitch/mod"        # Module install directory
FS_HEADERS="/usr/include/freeswitch"          # FreeSWITCH headers
PKG_CFG="/usr/lib64/pkgconfig"               # freeswitch.pc lives here

export PKG_CONFIG_PATH="${PKG_CFG}:/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/pgsql-14/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export C_INCLUDE_PATH="/usr/local/include:/usr/pgsql-14/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="/usr/local/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

log "Arch: $ARCH"
log "FreeSWITCH binary : $(which freeswitch)"
log "FreeSWITCH modules: $FS_MOD_DIR"
log "PKG_CONFIG_PATH   : $PKG_CONFIG_PATH"

# =============================================================================
# STEP 1 – Build dependencies for mod_audio_stream
# =============================================================================
step "STEP 1 – Install mod_audio_stream build dependencies"

dnf install -y \
    cmake make gcc-c++ git \
    speexdsp-devel \
    libevent-devel \
    openssl-devel \
    2>/dev/null || warn "Some packages may already be installed"

log "Build dependencies installed."

# =============================================================================
# STEP 2 – Clone and build mod_audio_stream
# =============================================================================
step "STEP 2 – Clone and build mod_audio_stream"

cd /usr/local/src

if [[ -d mod_audio_stream ]]; then
    log "mod_audio_stream already cloned — pulling latest..."
    git -C mod_audio_stream pull || warn "git pull failed, continuing with existing code"
else
    git clone https://github.com/amigniter/mod_audio_stream.git
fi

cd mod_audio_stream
git submodule init
git submodule update

# Verify FreeSWITCH headers are present
[[ ! -f "${FS_HEADERS}/switch.h" ]] && \
    error "FreeSWITCH headers not found at ${FS_HEADERS}. Ensure install-rhel9.sh ran fully."

log "Configuring mod_audio_stream with cmake..."
rm -rf build
mkdir build && cd build

cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DFREESWITCH_INCLUDE_DIR="${FS_HEADERS}" \
    -DFREESWITCH_MOD_DIR="${FS_MOD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release

log "Compiling mod_audio_stream..."
make -j"$(nproc)"
make install

# Verify
[[ -f "${FS_MOD_DIR}/mod_audio_stream.so" ]] && \
    log "mod_audio_stream.so installed to ${FS_MOD_DIR}" || \
    warn "mod_audio_stream.so not found in ${FS_MOD_DIR} — install may have used a different path"

# =============================================================================
# STEP 3 – Python 3 + venv setup
# =============================================================================
step "STEP 3 – Python 3 environment setup"

# Ensure python3-devel and swig are available (needed for ESL C extension)
dnf install -y python3 python3-devel python3-pip swig 2>/dev/null || \
    warn "python3 packages may already be installed"

log "Python: $(python3 --version)"

# =============================================================================
# STEP 4 – Build Python ESL bindings from FreeSWITCH source
# =============================================================================
step "STEP 4 – Build Python ESL bindings"

ESL_PY3="${FS_SRC}/libs/esl/python3"

if [[ ! -d "${FS_SRC}/libs/esl" ]]; then
    warn "FreeSWITCH source not found at ${FS_SRC} — skipping ESL build."
    warn "ESL bindings must be installed manually or via python-ESL.zip."
else
    log "Building ESL Python3 extension from ${ESL_PY3}..."
    cd "${FS_SRC}/libs/esl"

    # Build the shared ESL C library first
    make -j"$(nproc)" 2>/dev/null || warn "ESL make had warnings"

    # Build the Python3 SWIG wrapper
    cd "${ESL_PY3}"
    make -j"$(nproc)" pymod 2>/dev/null || {
        warn "ESL pymod make failed — trying manual swig approach..."
        swig -python -modern ESL.i 2>/dev/null || true
        python3 setup.py build_ext --inplace 2>/dev/null || \
            warn "ESL Python extension build failed — check swig/python3-devel"
    }

    # Install ESL .so and .py to Python path
    ESL_SO=$(find "${ESL_PY3}" -name "_ESL.so" 2>/dev/null | head -1)
    PY3_SITE=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)

    if [[ -n "$ESL_SO" && -n "$PY3_SITE" ]]; then
        cp "${ESL_SO}" "${PY3_SITE}/"
        cp "${ESL_PY3}/ESL.py" "${PY3_SITE}/"
        log "ESL Python bindings installed to ${PY3_SITE}"
    else
        warn "ESL .so not built — will install from python-ESL.zip inside freeswitch-kapture if present"
    fi
fi

# =============================================================================
# STEP 5 – Clone Kapture-CRM freeswitch-kapture repo
# =============================================================================
step "STEP 5 – Clone freeswitch-kapture repo"

KAPTURE_DIR="/usr/local/src/freeswitch-kapture"

if [[ -d "${KAPTURE_DIR}" ]]; then
    log "freeswitch-kapture already present — pulling latest..."
    git -C "${KAPTURE_DIR}" pull || warn "git pull failed, continuing with existing code"
else
    log "Cloning freeswitch-kapture (you may be prompted for credentials)..."
    git clone https://github.com/Kapture-CRM/freeswitch-kapture.git "${KAPTURE_DIR}"
fi

cd "${KAPTURE_DIR}"

# =============================================================================
# STEP 6 – Python virtual environment + requirements
# =============================================================================
step "STEP 6 – Python virtual environment + pip requirements"

log "Creating Python virtual environment..."
rm -rf venv/
python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip setuptools wheel

# If python-ESL.zip is bundled in the repo, install it
if [[ -f "python-ESL.zip" ]]; then
    log "Installing Python ESL from bundled zip..."
    unzip -o python-ESL.zip
    cd python-ESL
    pip install setuptools
    python3 setup.py install
    cd ..
else
    # Try installing from system-built ESL (placed in site-packages above)
    python3 -c "import ESL" 2>/dev/null && \
        log "ESL module already importable (system-built)." || \
        warn "python-ESL.zip not found and ESL not importable — check manually"
fi

# Install script requirements
if [[ -f "scripts/requirements.txt" ]]; then
    log "Installing pip requirements from scripts/requirements.txt..."
    pip install -r scripts/requirements.txt
elif [[ -f "requirements.txt" ]]; then
    log "Installing pip requirements from requirements.txt..."
    pip install -r requirements.txt
else
    warn "No requirements.txt found — skipping pip install"
fi

deactivate
log "Virtual environment ready at ${KAPTURE_DIR}/venv"

# =============================================================================
# STEP 7 – Load mod_audio_stream into FreeSWITCH
# =============================================================================
step "STEP 7 – Load mod_audio_stream and reload FreeSWITCH"

# Ensure freeswitch is running
systemctl is-active freeswitch &>/dev/null || {
    log "Starting FreeSWITCH..."
    systemctl start freeswitch
    sleep 3
}

log "Loading mod_audio_stream..."
/bin/fs_cli -x "load mod_audio_stream" 2>/dev/null || \
    warn "Could not load mod_audio_stream via fs_cli — check: fs_cli -x 'module_exists mod_audio_stream'"

log "Reloading XML config..."
/bin/fs_cli -x "reloadxml" 2>/dev/null || warn "reloadxml failed"

log "Restarting SIP profiles..."
/bin/fs_cli -x "sofia profile external restart" 2>/dev/null || true
/bin/fs_cli -x "sofia profile internal restart" 2>/dev/null || true

# =============================================================================
# STEP 8 – Start Python services (esl_integration + websocket_server)
# =============================================================================
step "STEP 8 – Start Kapture-CRM Python services"

VENV_PYTHON="${KAPTURE_DIR}/venv/bin/python3"
SCRIPTS_DIR="${KAPTURE_DIR}/scripts"
LOG_DIR="/var/log"

# Stop any running instances
pkill -f esl_integration.py   2>/dev/null && log "Stopped existing esl_integration.py"   || true
pkill -f websocket_server.py  2>/dev/null && log "Stopped existing websocket_server.py"  || true
sleep 1

# Start esl_integration.py
if [[ -f "${SCRIPTS_DIR}/esl_integration.py" ]]; then
    nohup "${VENV_PYTHON}" "${SCRIPTS_DIR}/esl_integration.py" \
        >> "${LOG_DIR}/esl_integration.log" 2>&1 &
    log "esl_integration.py started (PID $!) — log: ${LOG_DIR}/esl_integration.log"
else
    warn "esl_integration.py not found at ${SCRIPTS_DIR}/"
fi

# Start websocket_server.py
if [[ -f "${SCRIPTS_DIR}/websocket_server.py" ]]; then
    nohup "${VENV_PYTHON}" "${SCRIPTS_DIR}/websocket_server.py" \
        >> "${LOG_DIR}/websocket_server.log" 2>&1 &
    log "websocket_server.py started (PID $!) — log: ${LOG_DIR}/websocket_server.log"
else
    warn "websocket_server.py not found at ${SCRIPTS_DIR}/"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Post-Install Setup Complete!                     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  ┌── Installed ─────────────────────────────────────────────┐"
echo "  │  mod_audio_stream  : ${FS_MOD_DIR}/mod_audio_stream.so"
echo "  │  Python venv       : ${KAPTURE_DIR}/venv"
echo "  │  Kapture repo      : ${KAPTURE_DIR}"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌── Service Logs ───────────────────────────────────────────┐"
echo "  │  esl_integration   : tail -f /var/log/esl_integration.log"
echo "  │  websocket_server  : tail -f /var/log/websocket_server.log"
echo "  │  freeswitch        : journalctl -fu freeswitch"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌── Verify mod_audio_stream loaded ────────────────────────┐"
echo "  │  fs_cli -x 'module_exists mod_audio_stream'"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
