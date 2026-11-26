#!/bin/bash
# =============================================================================
# TimeTracker Proxmox LXC Installer (Community-Scripts-Stil)
#
# Repo:        https://github.com/HatchetMan111/TimeTrackerServer
# Upstream:    https://github.com/DRYTRIX/TimeTracker  (GPL-3.0, v5.22.0)
# App:         Self-hosted Zeiterfassung + Rechnungen + Peppol e-Invoicing
# Stack:       Python 3.11 / Flask, PostgreSQL 16 (nativen im CT), Gunicorn+eventlet
# Web-UI:      http://<CT-IP>:8080
#
# Einzeiler:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TimeTrackerServer/main/install/timetracker.sh)"
#
# Modi:
#   (keine)        Neu-Installation (nächste freie CT-ID)
#   --update       App-Code + Assets aktualisieren, Service neu starten
#   --uninstall    Container entfernen (Daten-Ordner bleibt erhalten)
#   --status       Service-/HTTP-Status des bestehenden Containers
#   --id <N>       Explizite CT-ID (für --update/--uninstall/--status)
#   --ram <MB>     RAM in MB (Standard 2048)
#   --disk <GB>    Disk in GB (Standard 8)
#   --cores <N>    vCPU (Standard 2)
#   --hostname X   CT-Hostname (Standard: timetracker)
#   --port <N>     Web-Port im CT (Standard 8080)
#   --yes          Keine Rückfrage (für Automatisierung)
#
# set -Eeuo pipefail + ERR-Trap: vollständige Fehlerkette (Stacktrace, Logs,
# Exit-Codes). Bei Fehler wird ein `bash -x`-Log angeboten.
# =============================================================================

set -Eeuo pipefail

# ---------- Variablen (oben, Community-Scripts-Konform) ----------------------
APP_NAME="timetracker"
APP_TITLE="TimeTracker"
# App-Metadaten (Doku oben; identische Werte im In-Container-Script gesetzt)
# shellcheck disable=SC2034
APP_REPO="https://github.com/DRYTRIX/TimeTracker.git"   # Doku/ONE_LINER
APP_PORT="${TT_PORT:-8080}"

CTID=""
CT_HOSTNAME="timetracker"
CT_RAM=2048
CT_DISK=8
CT_CORES=2
CT_BRIDGE="vmbr0"
CT_STORAGE="local-lvm"
CT_TEMPLATE=""
CT_UNPRIVILEGED=1
CT_ONBOOT=1
ASSUME_YES=0
MODE="install"
# Roh-URL des Installers (für Reinstall-Hinweise in der Fehlerkette)
ONE_LINER="https://raw.githubusercontent.com/HatchetMan111/TimeTrackerServer/main/install/timetracker.sh"

# Farben / Helper
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}=== $* ===${NC}"; }
die()   { err "$*"; exit 1; }

# Fehlerkette: vollständiger Kontext + bash -x-Angebot
on_error() {
  local ec=$1 line=$2
  echo -e "\n${RED}${BOLD}████████  INSTALLATION FEHLGESCHLAGEN  ████████${NC}" >&2
  err "Exit-Code : $ec"
  err "Befehl/Zeile: Zeile $line"
  err "Modus      : $MODE"
  [ -n "${CTID:-}" ] && err "CT-ID      : $CTID"
  echo -e "\n${YELLOW}--- Letzte 40 Zeilen Setup-Log (falls vorhanden) ---${NC}" >&2
  if [ -n "${SETUP_LOG:-}" ] && [ -f "${SETUP_LOG}" ]; then
    tail -n 40 "${SETUP_LOG}" >&2 || true
  else
    echo "(kein Setup-Log vorhanden)" >&2
  fi
  echo -e "\n${YELLOW}--- Diagnose-Hinweise ---${NC}" >&2
  echo "• Vollständiges Log mit Zeilennummern erneut erzeugen:" >&2
  echo "    bash -x \"\$0\" $* 2>&1 | tee /tmp/timetracker-install-debug.log" >&2
  echo "• Container-Status:  pct status ${CTID:-<id>} ; pct config ${CTID:-<id>}" >&2
  echo "• In-Container-Logs: pct exec ${CTID:-<id>} -- journalctl -u ${APP_NAME} -n 80 --no-pager" >&2
  echo "${RED}████████████████████████████████████████████${NC}" >&2
}
trap 'on_error $? $LINENO' ERR

# ---------- Argumente --------------------------------------------------------
# Grube: bash -c "$(wget -qLO - URL)" belegt $0 mit dem ersten Arg → Fallback
if [[ "${0}" == -* ]]; then set -- "${0}" "$@"; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)     MODE="update"; shift ;;
    --uninstall)  MODE="uninstall"; shift ;;
    --status)     MODE="status"; shift ;;
    --id)         CTID="$2"; shift 2 ;;
    --ram)        CT_RAM="$2"; shift 2 ;;
    --disk)       CT_DISK="$2"; shift 2 ;;
    --cores)      CT_CORES="$2"; shift 2 ;;
    --hostname)   CT_HOSTNAME="$2"; shift 2 ;;
    --port)       APP_PORT="$2"; shift 2 ;;
    --bridge)     CT_BRIDGE="$2"; shift 2 ;;
    --storage)    CT_STORAGE="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

# ---------- Root-Prüfung -----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  die "Dieses Script muss als root auf dem Proxmox-Host laufen (sudo -i)."
fi
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – läuft das hier auf einem Proxmox-Host?"
command -v wget >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq wget ca-certificates; }

SETUP_LOG="/tmp/${APP_NAME}-setup.log"

# ---------- CT-Helfer --------------------------------------------------------
find_free_id() {
  local id
  id="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]')"
  if [[ "$id" =~ ^[0-9]+$ ]]; then echo "$id"; return 0; fi
  # Fallback: höchste ID + 1
  local max=100
  while read -r v _; do [[ "$v" =~ ^[0-9]+$ ]] && (( v > max )) && max=$v; done < <(pct list)
  echo $((max + 1))
}

# Grube 13/27: Name ist IMMER das letzte Feld; Fallback über pct config
find_ct_id_by_hostname() {
  local name="$1" id
  if [[ -n "${CTID:-}" ]]; then echo "$CTID"; return 0; fi
  while read -r id _; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if pct config "$id" 2>/dev/null | grep -q "^hostname: ${name}$"; then echo "$id"; return 0; fi
  done < <(pct list)
  return 1
}

# Host-Arch → Template-Arch (Grube 31a: arm64-vor-amd64-Falle)
host_arch() {
  local a; a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$a" ;;
  esac
}

# Arch-bewusste Template-Wahl + Download
prepare_template() {
  local arch; arch="$(host_arch)"
  info "Host-Architektur: $arch"
  # Vorhandene Templates im lokalen Speicher
  local avail; avail="$(pveam list local 2>/dev/null | awk '{print $1}' | sed 's|.*/||' || true)"
  CT_TEMPLATE="$(echo "$avail" | grep -oE "debian-1[23]-standard[^\ ]*_${arch}\.tar\.(zst|gz)" | sort -rV | head -1 || true)"
  if [ -z "$CT_TEMPLATE" ]; then
    info "Kein passendes Debian-Template lokal – lade debian-12-standard (${arch}) ..."
    pveam update >/dev/null 2>&1 || true
    local avail_list; avail_list="$(pveam available 2>/dev/null | awk '{print $2}' | sed 's|.*/||' || true)"
    # Glob: Versionsteile zwischen "debian-12-standard" und "_<arch>" erlauben
    CT_TEMPLATE="$(echo "$avail_list" | grep -oE "debian-12-standard[^\ ]*_${arch}\.tar\.(zst|gz)" | sort -rV | head -1 || true)"
    [ -n "$CT_TEMPLATE" ] || die "Kein debian-12-standard-Template (${arch}) in pveam available gefunden."
    pveam download local "$CT_TEMPLATE" >/dev/null 2>&1 || die "Template-Download fehlgeschlagen: $CT_TEMPLATE"
  fi
  # Auf Template-Existenz prüfen (pct create akzeptiert fehlende ISOs still – Grube 5)
  local avail2; avail2="$(pveam list local 2>/dev/null | awk '{print $1}' | sed 's|.*/||' || true)"
  echo "$avail2" | grep -qF "$CT_TEMPLATE" || die "Template $CT_TEMPLATE nicht im lokalen Speicher."
  ok "Template: $CT_TEMPLATE"
}

wait_ct_network() {
  local id="$1" tries=60 ip
  for ((i=1; i<=tries; i++)); do
    ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != 127.* ]]; then
      echo "$ip"; return 0
    fi
    sleep 2
  done
  return 1
}

# Grube 11/11a: DNS separat prüfen, 3 konsekutive Erfolge
verify_ct_dns() {
  local id="$1" host="${2:-deb.debian.org}" ok_count=0 i
  for i in 1 2 3 4 5 6; do
    if pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1; then
      ok_count=$((ok_count + 1))
      [ "$ok_count" -ge 3 ] && return 0
    else
      ok_count=0
    fi
    sleep 2
  done
  warn "DNS im CT flaky – schreibe Fallback-Nameserver."
  local ns; ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
  pct exec "$id" -- bash -c "printf 'nameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' '${ns:-192.168.178.1}' > /etc/resolv.conf" || true
  pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1 || die "DNS im CT bleibt defekt (siehe Diagnose)."
  ok "DNS-Fallback aktiv."
}

verify_ct_started() {
  local id="$1" i
  for i in $(seq 1 15); do
    [ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" = "running" ] && return 0
    sleep 2
  done
  err "CT $id ist nach 30 s nicht 'running' (Status: $(pct status "$id" 2>/dev/null))."
  err "Häufige Ursache: Template-Arch ≠ Host-Arch. Erzwinge Neu-Install:"
  echo "    pct destroy $id --purge && bash -c \"\$(wget -qLO - $ONE_LINER)\"" >&2
  die "verify_ct_started fehlgeschlagen."
}

# ---------- In-Container Setup-Script ----------------------------------------
render_inner_script() {
cat <<'INNEREOF'
#!/bin/bash
# TimeTracker In-Container Setup (wird via pct exec env PORT=... bash /root/tt-inner.sh ausgeführt)
set -Eeuo pipefail
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
err(){ echo "[FEHLER] $*" >&2; }
trap 'echo "[FEHLER] Exit $? in Zeile $LINENO" >&2' ERR

PORT="${PORT:-8080}"
APP_DIR="/opt/timetracker"
APP_USER="timetracker"
APP_NAME="${APP_NAME:-timetracker}"
APP_REPO="${APP_REPO:-https://github.com/DRYTRIX/TimeTracker.git}"
APP_VERSION="${APP_VERSION:-v5.22.0}"
DB_NAME="timetracker"
DB_USER="timetracker"
DB_PASS="$(openssl rand -hex 16)"
SECRET_KEY="$(openssl rand -hex 32)"

log "=== Basis-Pakete ==="
export DEBIAN_FRONTEND=noninteractive
# Migration 037 seedet Umlaute (expense_categories) → Python/psycopg2 müssen
# UTF-8 als Locale sehen, sonst UnicodeEncodeError (ascii codec).
export LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  curl wget ca-certificates gnupg lsb-release openssl \
  python3 python3-venv python3-pip python3-dev \
  build-essential libpq-dev \
  libgdk-pixbuf-2.0-0 libpango-1.0-0 libcairo2 libpangocairo-1.0-0 \
  libffi-dev shared-mime-info fonts-liberation fonts-dejavu-core \
  libxml2-dev libxmlsec1-dev libxmlsec1-openssl pkg-config \
  postgresql postgresql-contrib redis-server \
  git dos2unix >/dev/null

log "=== Node.js 20 (für einmaligen Asset-Build) ==="
if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | cut -c2- | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 || {
    log "NodeSource fehlgeschlagen – Fallback auf nodejs.org-Binary."
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in amd64) NARCH=x64;; arm64) NARCH=arm64;; *) NARCH=x64;; esac
    mkdir -p /opt/node20
    curl -fsSL "https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-${NARCH}.tar.xz" -o /tmp/node.tar.xz
    tar -xJf /tmp/node.tar.xz -C /opt/node20 --strip-components=1
    ln -sf /opt/node20/bin/node /usr/local/bin/node
    ln -sf /opt/node20/bin/npm /usr/local/bin/npm
    ln -sf /opt/node20/bin/npx /usr/local/bin/npx
  }
fi
apt-get install -y -qq nodejs >/dev/null 2>&1 || true
log "node: $(node -v 2>/dev/null || echo fehlt)  npm: $(npm -v 2>/dev/null || echo fehlt)"

log "=== PostgreSQL 16 ==="
if ! command -v pg_isready >/dev/null 2>&1; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-16 postgresql-client-16 >/dev/null
fi
systemctl enable postgresql >/dev/null 2>&1 || true
systemctl start postgresql || true
# DB + Rolle anlegen (idempotent). Läuft als root im CT → kein sudo nötig
# (nacktes Debian-Template hat kein sudo; su - postgres ist der root-Weg).
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1 \
  || su - postgres -c "psql -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}'\"" >/dev/null
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1 \
  || su - postgres -c "createdb -O ${DB_USER} ${DB_NAME}"
log "PostgreSQL bereit (DB ${DB_NAME})."

log "=== App-Code klonen (${APP_REPO}) ==="
mkdir -p "$(dirname "$APP_DIR")"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --depth 1 origin main >/dev/null 2>&1 || true
  git -C "$APP_DIR" reset --hard origin/main >/dev/null 2>&1 || true
else
  rm -rf "$APP_DIR"
  git clone --depth 1 "$APP_REPO" "$APP_DIR" >/dev/null
fi
log "App bei $(git -C "$APP_DIR" rev-parse --short HEAD)"

log "=== Python-Abhängigkeiten ==="
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --no-cache-dir --upgrade "pip>=25.0" "setuptools>=78.1.1" wheel >/dev/null
"$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt" >/dev/null
log "pip install fertig."

log "=== Frontend-Assets bauen ==="
cd "$APP_DIR"
npm install --no-audit --no-fund >/dev/null 2>&1 || { log "npm install warn (retry)"; npm install --no-audit --no-fund; }
npm run build:docker >/dev/null
log "Assets gebaut: dist=$(ls app/static/dist 2>/dev/null | wc -l) vendor=$(ls app/static/vendor 2>/dev/null | wc -l)"

log "=== Benutzer + Verzeichnisse ==="
id "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER"
mkdir -p /data /data/uploads "$APP_DIR/logs" "$APP_DIR/instance" "$APP_DIR/app/static/uploads/logos"
# start-fixed.py ist für Docker hardcoded: os.chdir("/app") + execv("/usr/local/bin/gunicorn").
# Im LXC fehlen beide → Symlinks legen, damit der offizielle Entrypoint läuft.
ln -sfn "$APP_DIR" /app 2>/dev/null || true
mkdir -p /usr/local/bin
ln -sf "$APP_DIR/venv/bin/gunicorn" /usr/local/bin/gunicorn 2>/dev/null || true
# /app/logs wird von der App als LOG_FILE genutzt → Symlink auf persistente Daten
mkdir -p /app/logs 2>/dev/null || true
ln -sfn /data "$APP_DIR/../data" 2>/dev/null || true
chown -R "$APP_USER:$APP_USER" "$APP_DIR" /data 2>/dev/null || true

log "=== .env schreiben ==="
cat > "$APP_DIR/.env" <<ENVEOF
FLASK_APP=app
FLASK_ENV=production
APP_VERSION=${APP_VERSION:-dev}
PORT=${PORT}
SECRET_KEY=${SECRET_KEY}
DATABASE_URL=postgresql+psycopg2://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
LOG_FILE=/data/timetracker.log
# start.py liegt in docker/ → App-Root muss im Python-Path liegen
PYTHONPATH=${APP_DIR}
# UTF-8-Locale: Migration 037 seedet Umlaute → sonst UnicodeEncodeError (ascii)
LANG=C.UTF-8
LC_ALL=C.UTF-8
TZ=${TZ:-Europe/Berlin}
CURRENCY=${CURRENCY:-EUR}
ALLOW_SELF_REGISTER=true
ADMIN_USERNAMES=admin
WTF_CSRF_ENABLED=true
SESSION_COOKIE_SECURE=false
REMEMBER_COOKIE_SECURE=false
PREFERRED_URL_SCHEME=http
AI_ENABLED=false
ENABLE_TELEMETRY=false
ENVEOF
chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

log "=== systemd-Unit ==="
cat > "/etc/systemd/system/${APP_NAME}.service" <<UNITEOF
[Unit]
Description=TimeTracker (Flask + Gunicorn)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
# start.py liegt in docker/ → sys.path[0] ist docker/, nicht das App-Root.
# PYTHONPATH sorgt dafür, dass "from app import create_app" gefunden wird.
Environment=PYTHONPATH=${APP_DIR}
# UTF-8 für Migrationen/Seeds mit Umlauten
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/docker/start-fixed.py
Restart=always
RestartSec=5
StandardOutput=append:/data/timetracker.log
StandardError=append:/data/timetracker.log

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable "${APP_NAME}" >/dev/null 2>&1 || true

log "=== Service starten ==="
systemctl restart "${APP_NAME}"
# Health-Poll (bis zu 90 s)
for i in $(seq 1 45); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${PORT}/_health" || true)"
  if [ "$code" = "200" ]; then log "Upstream /_health = 200"; break; fi
  if [ "$i" = "45" ]; then
    err "App wurde nicht healthy (letzter Code: ${code:-000})"
    echo "--- journalctl (letzte 40) ---" >&2
    journalctl -u "${APP_NAME}" -n 40 --no-pager >&2 || true
    echo "--- /data/timetracker.log (letzte 60) ---" >&2
    tail -n 60 /data/timetracker.log >&2 2>/dev/null || echo "(kein App-Log)" >&2
    echo "--- manueller Start-Versuch (Fehler direkt sichtbar) ---" >&2
    su - "${APP_USER}" -c "cd ${APP_DIR} && set -a && . ${APP_DIR}/.env && set +a && ${APP_DIR}/venv/bin/python ${APP_DIR}/docker/start-fixed.py" >&2 2>&1 | tail -n 30 || true
    exit 1
  fi
  sleep 2
done
log "=== Setup abgeschlossen (Port ${PORT}) ==="
INNEREOF
}

# ---------- Modi -------------------------------------------------------------
do_install() {
  header "TimeTracker – Neu-Installation"
  [ -z "$CTID" ] && CTID="$(find_free_id)"
  info "CT-ID: $CTID  Hostname: $CT_HOSTNAME  RAM: ${CT_RAM}MB  Disk: ${CT_DISK}GB  Cores: $CT_CORES"
  if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "So fortfahren? [j/N] " ans; [[ "$ans" =~ ^[jJ]$ ]] || die "Abgebrochen."
  fi

  prepare_template

  header "Erstelle Container $CTID"
  pct create "$CTID" "local:vztmpl/${CT_TEMPLATE}" \
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --unprivileged "$CT_UNPRIVILEGED" --features nesting=1 --onboot "$CT_ONBOOT" \
    --ostype debian --start 0
  # Start (idempotent; pct create --start 0 → jetzt starten)
  pct start "$CTID" || die "pct start fehlgeschlagen (siehe pct config $CTID)."
  # Grube 31a: create/start kann Exit 0 trotz fehlgeschlagenem Spawn liefern → Status-Poll
  if ! verify_ct_started "$CTID"; then
    err "pct start meldete Erfolg, aber der Container läuft nicht (häufig: Template-Arch ≠ Host-Arch)."
    echo "    pct destroy $CTID --purge && bash -c \"\$(wget -qLO - $ONE_LINER)\"" >&2
    exit 1
  fi
  pct set "$CTID" --onboot "$CT_ONBOOT" >/dev/null 2>&1 || true
  ok "Container läuft."

  local ip; ip="$(wait_ct_network "$CTID")" || die "CT bekam keine IP (DHCP? Bridge $CT_BRIDGE?)."
  ok "CT-IP: $ip"
  if ! verify_ct_dns "$CTID"; then die "DNS im CT defekt (siehe Diagnose)."; fi

  header "In-Container Setup (dauert einige Minuten)"
  render_inner_script > /tmp/tt-inner.sh
  pct push "$CTID" /tmp/tt-inner.sh /root/tt-inner.sh >/dev/null
  # Grube 14: pipefail im Inner, damit pct exit-code nicht von tee verschluckt wird
  pct exec "$CTID" -- env PORT="$APP_PORT" TZ="${TZ:-Europe/Berlin}" \
    bash -c 'set -o pipefail; bash /root/tt-inner.sh 2>&1 | tee /var/log/timetracker-setup.log'
  rc=$?
  [ $rc -eq 0 ] || { SETUP_LOG=/var/log/timetracker-setup.log; die "In-Container Setup fehlgeschlagen (Exit $rc)."; }
  pct exec "$CTID" -- rm -f /root/tt-inner.sh >/dev/null 2>&1 || true

  header "Verifikation"
  local svc http
  svc="$(pct exec "$CTID" -- systemctl is-active "$APP_NAME" 2>/dev/null || true)"
  [ "$svc" = "active" ] && ok "systemctl is-active: active" || die "Service nicht active (Status: ${svc:-unbekannt})."
  http="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${APP_PORT}/_health" || true)"
  [ "$http" = "200" ] && ok "HTTP /_health = 200" || die "Web-UI antwortet nicht (HTTP ${http:-000})."

  summary "$ip"
}

do_update() {
  header "TimeTracker – Update"
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME")" || die "Kein laufender CT '$CT_HOSTNAME' gefunden. Nutze --id <N>."
  CTID="$id"
  ensure_ct_running "$CTID"
  local ip; ip="$(get_ct_ip "$CTID")" || die "Keine IP für CT $CTID."
  verify_ct_dns "$CTID" || true
  info "Update auf CT $CTID ($ip) ..."
  render_inner_script > /tmp/tt-inner.sh
  pct push "$CTID" /tmp/tt-inner.sh /root/tt-inner.sh >/dev/null
  pct exec "$CTID" -- env PORT="$APP_PORT" TZ="${TZ:-Europe/Berlin}" \
    bash -c 'set -o pipefail; bash /root/tt-inner.sh 2>&1 | tee /var/log/timetracker-setup.log'
  pct exec "$CTID" -- rm -f /root/tt-inner.sh >/dev/null 2>&1 || true
  local svc; svc="$(pct exec "$CTID" -- systemctl is-active "$APP_NAME" 2>/dev/null || true)"
  [ "$svc" = "active" ] && ok "Service active" || die "Service nach Update nicht active."
  summary "$ip"
}

do_uninstall() {
  header "TimeTracker – Deinstallieren"
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME" || true)"
  [ -z "$id" ] && [ -n "${CTID:-}" ] && id="$CTID"
  [ -z "$id" ] && { warn "Kein CT '$CT_HOSTNAME' gefunden – nichts zu tun."; return 0; }
  warn "Container $id wird ZERSTÖRT (Daten-Ordner /data bleibt nur bei --purge-Warnung erhalten)."
  if [ "$ASSUME_YES" -eq 0 ]; then read -r -p "Wirklich löschen? [j/N] " a; [[ "$a" =~ ^[jJ]$ ]] || die "Abgebrochen."; fi
  pct stop "$id" >/dev/null 2>&1 || true
  pct destroy "$id" || die "pct destroy fehlgeschlagen."
  ok "Container $id entfernt."
}

do_status() {
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME" || true)"
  [ -z "$id" ] && [ -n "${CTID:-}" ] && id="$CTID"
  [ -z "$id" ] && die "Kein CT gefunden. Nutze --id <N>."
  local st ip svc http
  st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
  ip="$(get_ct_ip "$id" || true)"
  echo "CT $id ($CT_HOSTNAME): ${st:-unbekannt}  IP: ${ip:-–}"
  if [ "$st" = "running" ]; then
    svc="$(pct exec "$id" -- systemctl is-active "$APP_NAME" 2>/dev/null || true)"
    http="$(pct exec "$id" -- curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${APP_PORT}/_health" 2>/dev/null || true)"
    echo "  service=${svc:-?}  http=${http:-?}"
    [ "${http:-000}" = "200" ] && echo "  URL: http://${ip}:${APP_PORT}"
  fi
}

ensure_ct_running() {
  local id="$1"
  if [ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" != "running" ]; then
    info "CT $id ist gestoppt – starte ihn."
    pct start "$id" || die "pct start $id fehlgeschlagen."
    wait_ct_network "$id" >/dev/null || die "CT $id bekam nach Start keine IP."
  fi
}

get_ct_ip() { wait_ct_network "$1"; }

summary() {
  local ip="$1"
  echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║  ${APP_TITLE} ist installiert und läuft!                  ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "  🆔 CT-ID     : ${CTID}"
  echo -e "  🌐 URL       : ${BLUE}http://${ip}:${APP_PORT}${NC}"
  echo -e "  🔑 Erster Login wird Admin (Benutzer: admin)."
  echo -e "  📜 Logs      : pct exec ${CTID} -- journalctl -u ${APP_NAME} -n 50 --no-pager"
  echo -e "  ♻️  Update    : bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TimeTrackerServer/main/install/timetracker.sh)\" -- --update"
  echo -e "  🗑️  Deinstall: ... -- --uninstall"
  echo -e "  🔄 Reboot-Test: pct reboot ${CTID}  (danach ist die App via systemd wieder da)"
  echo ""
}

case "$MODE" in
  install)   do_install ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)         die "Unbekannter Modus: $MODE" ;;
esac