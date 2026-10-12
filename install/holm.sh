#!/usr/bin/env bash
#
# Holm Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Holm – self-hosted dashboard fuer Team/Familie/Org (eigene Startseite
#           pro Person, Launcher, App-Suche, Onboarding, ein YAML-File)
# Upstream: https://github.com/man15h/holm
# Stack:    Node.js 22 + SvelteKit (nativ, ohne Docker, ohne Cloud)
#           Web-UI auf :3000, bind 0.0.0.0 im Container, SQLite eingebaut.
# Laeuft:   vollstaendig lokal im LXC, keine externen Cloud-Dienste noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/install/holm.sh)"
#   CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/install/holm.sh)"
#   bash holm.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
# Hinweis: Unit + Config werden live aus diesem Repo geladen (SERVICE_URL,
# CONFIG_URL unten). Ohne Netz zum Repo greift der Inline-Fallback im Skript.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="holm"                                        # Container-Hostname + Service-Name
APP_PORT="3000"                                   # Holm Web-UI
UPSTREAM_REPO="https://github.com/man15h/holm"
INSTALLER_REPO="https://github.com/HatchetMan111/HolmDashboard-Proxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/systemd/holm.service"
CONFIG_URL="https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/config/config.yml"

DEFAULT_CORES="2"                                 # vCPU (vite build + SvelteKit runtime)
DEFAULT_RAM="2048"                                # RAM in MB (Build braucht ~1 GB)
DEFAULT_SWAP="512"                                # Swap in MB
DEFAULT_DISK="8"                                  # Disk in GB (node_modules + build + SQLite)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                    # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"                   # Template-Familie
UNPRIVILEGED="1"                                  # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                              # nesting fuer Node/npm Robustheit
NODE_MAJOR="22"                                   # Node.js LTS-Linie fuer Holm

APP_USER="holm"
APP_DIR="/opt/holm"
CONFIG_DIR="/etc/holm"
CONFIG_FILE="/etc/holm/config.yml"
ENV_FILE="/etc/holm/holm.env"
DATA_DIR="/var/lib/holm"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=2048 DISK=8 ./holm.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash holm.sh [OPTIONEN]
  CT_ID=150 bash holm.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/../raw/main/install/holm.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Holm im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Holm im Container (Node ${NODE_MAJOR} + Build, ohne Docker) ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell Dollar oder Subshells anfasst (kein Escaping noetig).
pct exec "$CT_ID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git openssl
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q v22; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node --version
npm --version
id holm >/dev/null 2>&1 || useradd -m -s /bin/bash holm
mkdir -p /opt/holm /etc/holm /var/lib/holm
if [ ! -d /opt/holm/.git ]; then
  git clone https://github.com/man15h/holm.git /opt/holm
else
  git -C /opt/holm fetch origin
  git -C /opt/holm reset --hard origin/main
fi
chown -R holm:holm /opt/holm /var/lib/holm
if ! grep -qE ^HOLM_SECRET_KEY=[0-9a-f]{64}$ /etc/holm/holm.env 2>/dev/null; then
  umask 077
  openssl rand -hex 32 > /tmp/holm-secret-key
  grep -qE ^[0-9a-f]{64}$ /tmp/holm-secret-key || exit 1
  KEY=$(cat /tmp/holm-secret-key)
  echo HOLM_SECRET_KEY=$KEY > /etc/holm/holm.env
  rm -f /tmp/holm-secret-key
  umask 022
  chmod 600 /etc/holm/holm.env
  chown root:holm /etc/holm/holm.env
  grep -qE ^HOLM_SECRET_KEY=[0-9a-f]{64}$ /etc/holm/holm.env || exit 1
fi
su holm -c "cd /opt/holm && npm ci"
su holm -c "cd /opt/holm && npm test"
su holm -c "cd /opt/holm && npm run build"
su holm -c "cd /opt/holm && npm prune --omit=dev"
chown -R holm:holm /opt/holm
'
# Hinweis: bewusst kein Pipe-Tail hier – mit pipefail wuerde der trap sonst
# die Pipe statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# Host-seitiger Guard: bricht laut ab, falls der Build unvollstaendig ist.
pct exec "$CT_ID" -- test -f /opt/holm/build/manifest.js \
  || pct exec "$CT_ID" -- test -f /opt/holm/build/server/index.js \
  || { msg_error "Installation unvollstaendig: /opt/holm/build fehlt im Container (npm run build prüfen)."; exit 1; }
msg_ok "Build ok (SvelteKit-Build in /opt/holm/build vorhanden)."

# Config aus diesem Repo uebernehmen (faellt auf Inline-Config zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/holm/config.yml "$CONFIG_URL" 2>/dev/null; then
  msg_ok "config.yml aus Repo uebernommen."
else
  msg_warn "Config-URL nicht erreichbar – schreibe Inline-Config (auth aus, Demo-Set)."
  pct push "$CT_ID" /dev/stdin /etc/holm/config.yml <<CONFIG
branding:
  name: "Holm"
  description: "A home page for everyone in the house"
auth:
  enabled: false
database:
  enabled: true
customization:
  enabled: true
apps:
  - id: immich
    name: "Photos"
    url: "https://photos.example.com"
    icon: "di:immich"
    self_hosted: true
  - id: nextcloud
    name: "Cloud"
    url: "https://cloud.example.com"
    icon: "di:nextcloud"
    self_hosted: true
  - id: jellyfin
    name: "Jellyfin"
    url: "https://jellyfin.example.com"
    icon: "di:jellyfin"
    self_hosted: true
  - id: vault
    name: "Vault"
    url: "https://vault.example.com"
    icon: "di:bitwarden"
    self_hosted: true
  - id: paperless
    name: "Paperless"
    url: "https://paperless.example.com"
    icon: "di:paperless-ngx"
    self_hosted: true
search:
  enabled: true
  url: "https://duckduckgo.com/"
  param: "q"
  name: "DuckDuckGo"
  icon: "di:duckduckgo"
wallpapers:
  enabled: true
  source: "gitlab"
  count: 326
weather:
  enabled: true
onboarding:
  enabled: true
  welcome_text: "One home page for the whole house. Pick the apps you use; everyone else gets their own."
  slides:
    - type: welcome
    - type: services
privacy:
  enabled: false
tips:
  enabled: true
CONFIG
fi
pct exec "$CT_ID" -- chown root:holm /etc/holm/config.yml
pct exec "$CT_ID" -- chmod 640 /etc/holm/config.yml

# systemd-Unit aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/holm.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "holm.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/holm.service <<UNIT
[Unit]
Description=Holm – self-hosted dashboard for team, family, org
Documentation=https://github.com/man15h/holm
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=holm
Group=holm
WorkingDirectory=/opt/holm
EnvironmentFile=/etc/holm/holm.env
Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=3000
Environment=CONFIG_PATH=/etc/holm/config.yml
Environment=DATABASE_PATH=/var/lib/holm/holm.db
ExecStart=/usr/bin/node /opt/holm/build
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now holm
msg_ok "systemd-Service holm aktiviert (enable --now)."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active holm || { msg_error "systemd-Service holm ist nicht active."; pct exec "$CT_ID" -- systemctl status holm --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active holm = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status holm --no-pager || true; pct exec "$CT_ID" -- journalctl -u holm --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Holm – Dashboard fuer Team/Familie/Org"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Login        : auth.enabled=false (sofort nutzbar, nur LAN!); OIDC siehe README"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status holm  (im Container via: pct enter $CT_ID)"
echo "  Config       : /etc/holm/config.yml (Start-Set, Beispiel: Upstream config.example.yml)"
echo "  Secret       : /etc/holm/holm.env (HOLM_SECRET_KEY, 600, nicht teilen)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + rebuild + restart)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
