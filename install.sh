#!/usr/bin/env bash
# holos-agent installer for Linux
#
# Mode 1 — PULSE token (recommended for clients):
#   curl -fsSL https://releases.holos.tech/install.sh | sudo bash -s -- --token tok_Ax7kP...
#
# Mode 2 — direct parameters (manual install / CI):
#   sudo bash install.sh --tenant-id acme-prod --api-key sk-xxx
#
# Environments:
#   --env prod  (default) → collector.holos.tech        production pipeline
#   --env dev             → collector.dev.holos.tech    development / QA pipeline
#
# Override endpoint manually (takes precedence over --env):
#   sudo bash install.sh --token tok_xxx --endpoint https://my-collector.internal
#
# HTTP/HTTPS proxy (for servers without direct internet access):
#   sudo bash install.sh --token tok_xxx --proxy http://10.20.0.2:3128
#
# Once installed, detect services on this host with:
#   holos-agent discover
#
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/holos-agent"
DATA_DIR="/var/lib/holos-agent"
AGENT_USER="holos-agent"
PULSE_API="${HOLOS_API_URL:-https://api.holos.tech}"
RELEASE_BASE="${HOLOS_RELEASE_URL:-https://releases.holos.tech}"

# ── Endpoint URLs per environment ─────────────────────────────────────────────
ENDPOINT_PROD="https://collector.holos.tech"
ENDPOINT_DEV="https://collector.dev.holos.tech"

# ── Output colors ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

step()  { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok()    { echo -e "${GREEN} ✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
die()   { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────────────────
INSTALL_TOKEN=""
TENANT_ID=""
API_KEY=""
COLLECTOR_TOKEN="${HOLOS_COLLECTOR_TOKEN:-}"   # optional; falls back to API_KEY in the agent
ENDPOINT=""
ENV="prod"
SITE=""
LOCAL_BINARY=""
PROXY_URL="${HTTPS_PROXY:-${HTTP_PROXY:-}}"    # inherit from environment or set via --proxy

while [[ $# -gt 0 ]]; do
  case $1 in
    --token)            INSTALL_TOKEN="$2";    shift 2 ;;
    --tenant-id)        TENANT_ID="$2";        shift 2 ;;
    --api-key)          API_KEY="$2";          shift 2 ;;
    --collector-token)  COLLECTOR_TOKEN="$2";  shift 2 ;;
    --endpoint)         ENDPOINT="$2";         shift 2 ;;
    --env)              ENV="$2";              shift 2 ;;
    --site)             SITE="$2";             shift 2 ;;
    --proxy)            PROXY_URL="$2";        shift 2 ;;
    --binary|--local-binary) LOCAL_BINARY="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Argument validation ───────────────────────────────────────────────────────
if [[ -z "$INSTALL_TOKEN" && -z "$TENANT_ID" ]]; then
  die "Either --token or --tenant-id is required. Use --help to see usage."
fi
if [[ -n "$TENANT_ID" && -z "$API_KEY" ]]; then
  die "If you use --tenant-id you must also provide --api-key."
fi

# Resolve endpoint: explicit --endpoint wins, then --env, then prod default
if [[ -z "$ENDPOINT" ]]; then
  case "$ENV" in
    dev)  ENDPOINT="$ENDPOINT_DEV" ;;
    prod) ENDPOINT="$ENDPOINT_PROD" ;;
    *)    die "Unknown --env value: '${ENV}'. Valid values: prod, dev" ;;
  esac
fi

# ── Verify root ───────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "This script must be run as root (sudo)."

# ── Helper: parse JSON without jq ────────────────────────────────────────────
json_value() {
  local key="$1" json="$2"
  echo "$json" | grep -o "\"${key}\":\"[^\"]*\"" | head -1 | sed 's/.*":"\(.*\)"/\1/'
}

# ── Fetch credentials from PULSE (--token mode) ───────────────────────────────
if [[ -n "$INSTALL_TOKEN" ]]; then
  step "Fetching credentials from PULSE..."

  _proxy_args=()
  [[ -n "${PROXY_URL:-}" ]] && _proxy_args=(--proxy "$PROXY_URL")
  CREDS=$(curl -fsSL \
    --max-time 15 \
    --retry 3 \
    --retry-delay 2 \
    "${_proxy_args[@]+"${_proxy_args[@]}"}" \
    "${PULSE_API}/api/v1/install-credentials?token=${INSTALL_TOKEN}" 2>/dev/null) \
    || die "Could not connect to the PULSE API (${PULSE_API}). Check your connection."

  TENANT_ID=$(json_value "tenant_id"       "$CREDS")
  API_KEY=$(json_value "api_key"           "$CREDS")
  ENDPOINT=$(json_value "endpoint"         "$CREDS")
  COLLECTOR_TOKEN=$(json_value "collector_token" "$CREDS")   # may be empty on older tenants

  [[ -z "$TENANT_ID" ]] && die "Invalid or expired token. Get a new token from the PULSE portal."
  [[ -z "$API_KEY"   ]] && die "Unexpected API response (no api_key)."
  [[ -z "$ENDPOINT"  ]] && die "Unexpected API response (no endpoint)."

  ok "Credentials obtained for tenant: ${BOLD}${TENANT_ID}${RESET}"
fi

[[ -z "$SITE" ]] && SITE="$(hostname -f 2>/dev/null || hostname)"

echo ""
echo -e "${BOLD}holos-agent installer${RESET}"
echo    "  Tenant  : ${TENANT_ID}"
echo    "  Site    : ${SITE}"
echo    "  Env     : ${ENV}"
echo    "  Endpoint: ${ENDPOINT}"
echo ""

# ── Detect architecture ───────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="linux-amd64" ;;
  aarch64) ARCH_SUFFIX="linux-arm64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

# ── Create system user ────────────────────────────────────────────────────────
step "Setting up system user..."
if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
  # Detect nologin path — /usr/sbin/nologin on modern distros, /sbin/nologin on OL5/RHEL5
  NOLOGIN_SHELL="/usr/sbin/nologin"
  [ -x "/sbin/nologin" ] && [ ! -x "/usr/sbin/nologin" ] && NOLOGIN_SHELL="/sbin/nologin"

  # --system is not available on shadow-utils < 4.1 (OL5/RHEL5).
  # Fall back to -r (short form) which is supported since shadow-utils 4.0.
  if useradd --system --no-create-home --shell "$NOLOGIN_SHELL" "$AGENT_USER" 2>/dev/null; then
    ok "User ${AGENT_USER} created"
  elif useradd -r -M -s "$NOLOGIN_SHELL" "$AGENT_USER" 2>/dev/null; then
    ok "User ${AGENT_USER} created (legacy useradd)"
  else
    # Last resort: create a plain user without login capability
    useradd -M -s "$NOLOGIN_SHELL" "$AGENT_USER"
    ok "User ${AGENT_USER} created (basic useradd)"
  fi
else
  ok "User ${AGENT_USER} already exists"
fi

# ── Create directories ────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$DATA_DIR"
chown root:"${AGENT_USER}" "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"
chown "${AGENT_USER}:${AGENT_USER}" "$DATA_DIR"
chmod 750 "$DATA_DIR"

# ── Install binary ────────────────────────────────────────────────────────────
if [[ -n "$LOCAL_BINARY" ]]; then
  step "Installing local binary: ${LOCAL_BINARY}"
  [[ -f "$LOCAL_BINARY" ]] || die "Binary not found: ${LOCAL_BINARY}"
  cp "$LOCAL_BINARY" "${INSTALL_DIR}/holos-agent.new"
else
  step "Downloading holos-agent (${ARCH_SUFFIX})..."
  BINARY_URL="${RELEASE_BASE}/holos-agent-${ARCH_SUFFIX}"

  # Download helper: tries multiple methods in order to handle old OS TLS stacks
  # (RHEL/OL 6 has OpenSSL 1.0.1 which cannot negotiate TLS 1.2 with Cloudflare).
  # The binary integrity is verified below via `version` check.
  _download() {
    local url="$1" dest="$2"
    # Build proxy args arrays — empty when PROXY_URL is unset or blank.
    # Use the "${arr[@]+...}" form so set -u does not fire on empty arrays.
    local proxy_args=()
    [[ -n "${PROXY_URL:-}" ]] && proxy_args=(--proxy "$PROXY_URL")
    local wget_proxy=()
    [[ -n "${PROXY_URL:-}" ]] && wget_proxy=(-e "https_proxy=$PROXY_URL" -e "http_proxy=$PROXY_URL")
    # 1) normal curl (with proxy if set)
    if curl -fsSL "${proxy_args[@]+"${proxy_args[@]}"}" --progress-bar -o "$dest" "$url" 2>/dev/null; then return 0; fi
    # 2) curl without cert verification (old CA bundles)
    if curl -fsSLk "${proxy_args[@]+"${proxy_args[@]}"}" --progress-bar -o "$dest" "$url" 2>/dev/null; then
      warn "Downloaded without TLS verification (old OpenSSL detected)."; return 0
    fi
    # 3) curl forcing TLS 1.0 + relaxed ciphers (OL6 / RHEL6)
    if curl -fsSLk "${proxy_args[@]+"${proxy_args[@]}"}" --tlsv1 --ciphers 'DEFAULT:@SECLEVEL=0' --progress-bar -o "$dest" "$url" 2>/dev/null; then
      warn "Downloaded using TLS 1.0 (very old OpenSSL detected)."; return 0
    fi
    # 4) wget fallback (uses NSS/GnuTLS on RHEL6, avoids OpenSSL limitation)
    if command -v wget >/dev/null 2>&1; then
      if wget -q --no-check-certificate "${wget_proxy[@]+"${wget_proxy[@]}"}" -O "$dest" "$url" 2>/dev/null; then
        warn "Downloaded via wget without TLS verification."; return 0
      fi
    fi
    # 5) python fallback (urllib2 on Python 2, urllib on Python 3)
    if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
      local py; py=$(command -v python3 || command -v python)
      if "$py" -c "
import sys, os
proxy = os.environ.get('HTTPS_PROXY') or os.environ.get('HTTP_PROXY') or ''
try:
    import urllib.request as ul
    if proxy:
        ul.install_opener(ul.build_opener(ul.ProxyHandler({'https': proxy, 'http': proxy})))
    ul.urlretrieve('$url', '$dest')
except ImportError:
    import urllib2, shutil
    if proxy:
        opener = urllib2.build_opener(urllib2.ProxyHandler({'https': proxy, 'http': proxy}))
        urllib2.install_opener(opener)
    r = urllib2.urlopen('$url')
    with open('$dest','wb') as f: shutil.copyfileobj(r, f)
" 2>/dev/null; then
        warn "Downloaded via Python (TLS fallback)."; return 0
      fi
    fi
    return 1
  }
  # Export proxy for download helper (python fallback reads env vars)
  [[ -n "$PROXY_URL" ]] && export HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL"

  _download "$BINARY_URL" "${INSTALL_DIR}/holos-agent.new" \
    || die "Error downloading binary from ${BINARY_URL}. Check connectivity and that port 443 is open."
fi

chmod 755 "${INSTALL_DIR}/holos-agent.new"

"${INSTALL_DIR}/holos-agent.new" version >/dev/null 2>&1 \
  || die "Binary is not valid or architecture does not match this server."

mv "${INSTALL_DIR}/holos-agent.new" "${INSTALL_DIR}/holos-agent"
ok "Binary installed at ${INSTALL_DIR}/holos-agent"

# ── Write agent.env ───────────────────────────────────────────────────────────
step "Saving credentials..."
install -o root -g "$AGENT_USER" -m 640 /dev/null "${CONFIG_DIR}/agent.env"
printf 'HOLOS_API_KEY=%s\n' "$API_KEY" > "${CONFIG_DIR}/agent.env"
# Write collector token when provided (obtained from PULSE or passed explicitly).
# The agent reads this at startup and removes it from the process environment
# immediately after, so it never appears in /proc/<pid>/environ.
if [[ -n "${COLLECTOR_TOKEN:-}" ]]; then
  printf 'HOLOS_COLLECTOR_TOKEN=%s\n' "$COLLECTOR_TOKEN" >> "${CONFIG_DIR}/agent.env"
fi
# Write proxy variables when the server has no direct internet access.
if [[ -n "${PROXY_URL:-}" ]]; then
  printf 'HTTPS_PROXY=%s\n' "$PROXY_URL" >> "${CONFIG_DIR}/agent.env"
  printf 'HTTP_PROXY=%s\n'  "$PROXY_URL" >> "${CONFIG_DIR}/agent.env"
fi
ok "Credentials saved to ${CONFIG_DIR}/agent.env"

# ── Write config.yaml ─────────────────────────────────────────────────────────
step "Generating configuration..."

if [[ -f "${CONFIG_DIR}/config.yaml" ]]; then
  warn "config.yaml already exists — not overwriting. The agent will use the existing configuration."
else
  TLS_INSECURE="false"
  [[ "$ENDPOINT" == http://* ]] && TLS_INSECURE="true"

  {
    cat <<EOF
agent:
  tenant_id:   "${TENANT_ID}"
  environment: "prod"
  site:        "${SITE}"
  log_level:   "info"

transport:
  # api_key and collector_token are injected from agent.env at startup
  endpoint: "${ENDPOINT}"
EOF
    # collector_token line: only written when a token was provided by PULSE
    if [[ -n "${COLLECTOR_TOKEN:-}" ]]; then
      printf '  collector_token: "%s"\n' "${COLLECTOR_TOKEN}"
    fi
    cat <<EOF
  heartbeat_endpoint: "${ENDPOINT}/api/v1/agents/heartbeat"
  tls:
    insecure: ${TLS_INSECURE}
  queue:
    enabled: true
    path: "${DATA_DIR}/queue.ndjson"
    max_size_mb: 500

collection:
  interval: "30s"

plugins: []
EOF
  } > "${CONFIG_DIR}/config.yaml"

  chmod 640 "${CONFIG_DIR}/config.yaml"
  chown root:"${AGENT_USER}" "${CONFIG_DIR}/config.yaml"
  ok "config.yaml generated at ${CONFIG_DIR}/config.yaml"
fi

# ── Detect init system ────────────────────────────────────────────────────────
USE_SYSTEMD=false
if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1 && \
   [ -d /etc/systemd/system ]; then
  USE_SYSTEMD=true
fi

# ── Install service ───────────────────────────────────────────────────────────
if $USE_SYSTEMD; then
  step "Installing systemd service..."
  cat > /etc/systemd/system/holos-agent.service <<EOF
[Unit]
Description=Holos Agent - PULSE telemetry collector
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${AGENT_USER}
EnvironmentFile=${CONFIG_DIR}/agent.env
ExecStart=${INSTALL_DIR}/holos-agent start --config ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=holos-agent
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable holos-agent
  ok "systemd service installed and enabled"
else
  # SysV init (RHEL/OL 6, SLES 11, etc.)
  step "Installing SysV init service..."
  cat > /etc/init.d/holos-agent <<'SYSV'
#!/bin/bash
# chkconfig: 2345 90 10
# description: Holos Agent - PULSE telemetry collector
### BEGIN INIT INFO
# Provides:          holos-agent
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Holos Agent
### END INIT INFO

AGENT_BIN=/usr/local/bin/holos-agent
CONFIG=/etc/holos-agent/config.yaml
ENV_FILE=/etc/holos-agent/agent.env
PIDFILE=/var/run/holos-agent.pid
LOGFILE=/var/log/holos-agent.log
AGENT_USER=holos-agent

[ -f "$ENV_FILE" ] && . "$ENV_FILE"
export HOLOS_API_KEY HTTPS_PROXY HTTP_PROXY

case "$1" in
  start)
    echo -n "Starting holos-agent: "
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
      echo "already running"
      exit 0
    fi
    # Use 'exec' inside su so that su is replaced by the agent process;
    # the PID captured by $! in the outer shell IS the agent PID.
    # Root writes the pidfile — no permission issues on the agent user side.
    nohup su -s /bin/bash -c "exec $AGENT_BIN start --config $CONFIG" \
      "$AGENT_USER" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "OK"
    ;;
  stop)
    echo -n "Stopping holos-agent: "
    if [ -f "$PIDFILE" ]; then
      kill "$(cat $PIDFILE)" 2>/dev/null && rm -f "$PIDFILE"
      echo "OK"
    else
      echo "not running"
    fi
    ;;
  restart)
    $0 stop; sleep 1; $0 start
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
      echo "holos-agent is running (pid $(cat $PIDFILE))"
    else
      echo "holos-agent is not running"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
exit 0
SYSV
  chmod 755 /etc/init.d/holos-agent
  chkconfig --add holos-agent
  # Log file pre-created; pidfile is written by root at runtime — no chown needed.
  touch /var/log/holos-agent.log
  chown "${AGENT_USER}:${AGENT_USER}" /var/log/holos-agent.log
  ok "SysV service installed and enabled"
fi

# ── Start the service ─────────────────────────────────────────────────────────
step "Starting holos-agent..."
if $USE_SYSTEMD; then
  systemctl restart holos-agent
  sleep 2
  if systemctl is-active --quiet holos-agent; then
    ok "holos-agent running"
  else
    warn "Service did not start. Check: journalctl -u holos-agent -n 50"
  fi
else
  service holos-agent start
  sleep 2
  if service holos-agent status >/dev/null 2>&1; then
    ok "holos-agent running"
  else
    warn "Service did not start. Check: /var/log/holos-agent.log"
  fi
fi

# ── Post-install registration ────────────────────────────────────────────────
# Notify the PULSE backend that the agent was installed successfully.
# This is non-fatal: if the backend is unavailable the agent will register
# itself via the heartbeat once the service connects.
_post_registration() {
  local agent_id=""
  if [[ -f /var/lib/holos-agent/agent.id ]]; then
    agent_id=$(cat /var/lib/holos-agent/agent.id)
  fi
  local os_type; os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
  local arch; arch=$(uname -m)
  local version; version=$("${INSTALL_DIR}/holos-agent" version 2>/dev/null | awk '{print $NF}' || echo "unknown")
  local payload
  payload=$(cat <<JSON
{
  "agent_id":  "${agent_id}",
  "tenant_id": "${TENANT_ID}",
  "site":      "${SITE}",
  "hostname":  "$(hostname -f 2>/dev/null || hostname)",
  "os_type":   "${os_type}",
  "arch":      "${arch}",
  "version":   "${version}"
}
JSON
)
  curl -fsSL -X POST \
    --max-time 10 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "${payload}" \
    "${PULSE_API}/api/v1/agents" >/dev/null 2>&1 \
    && ok "Agent registered with PULSE backend" \
    || warn "Could not reach PULSE backend — agent will register via heartbeat on first start."
}
_post_registration

# ── Summary ───────────────────────────────────────────────────────────────────
if $USE_SYSTEMD; then
  SVC_LOGS="journalctl -u holos-agent -f"
  SVC_STATUS="systemctl status holos-agent"
  SVC_RESTART="sudo systemctl restart holos-agent"
else
  SVC_LOGS="tail -f /var/log/holos-agent.log"
  SVC_STATUS="service holos-agent status"
  SVC_RESTART="sudo service holos-agent restart"
fi

echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   holos-agent installed successfully ✓        ║${RESET}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════╝${RESET}"
echo ""
echo    "  Tenant  : ${TENANT_ID}"
echo    "  Site    : ${SITE}"
echo    "  Config  : ${CONFIG_DIR}/config.yaml"
[[ -n "${PROXY_URL:-}" ]] && echo "  Proxy   : ${PROXY_URL}"
echo    "  Logs    : ${SVC_LOGS}"
echo    "  Status  : ${SVC_STATUS}"
echo ""
echo -e "${BOLD}Next steps — configure monitoring plugins:${RESET}"
echo ""
echo    "  1. Detect services on this host:"
echo -e "     ${BOLD}holos-agent discover${RESET}"
echo ""
echo    "  2. Add a plugin manually:"
echo -e "     ${BOLD}holos-agent plugin add mysql --host localhost --username holos_monitor${RESET}"
echo ""
echo    "  3. Verify plugin connectivity:"
echo -e "     ${BOLD}holos-agent plugin test mysql${RESET}"
echo ""
echo    "  4. Restart after adding plugins:"
echo -e "     ${BOLD}${SVC_RESTART}${RESET}"
echo ""
