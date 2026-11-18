#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# openpdfstudio-install.sh — läuft IM LXC-Container (per pct push + pct exec
# vom Host-Script install/openpdfstudio.sh gepusht und gestartet).
#
# Schritte:
#   1. apt-Grundlagen (nur bei Frischinstall): nginx, curl, ca-certificates
#   2. dist/ der Web-UI (statischer Vite-Build aus dem Installer-Repo) nach
#      /var/www/open-pdf-studio deployen (atomar: .new → swap, .bak zurück)
#   3. nginx-vHost auf OPDS_PORT (SPA-Fallback, gzip, Cache-Header)
#   4. systemd-Drop-in für nginx (Restart=on-failure, network-online) + enable
#   5. Selbst-Verifikation: systemctl is-active + HTTP-Check + Titel-Grep
#
# Umgebung (vom Host-Script gesetzt):
#   OPDS_PORT     — HTTP-Port der Web-UI (Standard 8080)
#   OPDS_CTIP     — CT-IP (informativ)
#   OPDS_VERSION  — getaggte Upstream-Version, z. B. v2026.47.0
#   UPDATE_MODE   — 1 = bestehende Installation aktualisieren
#
# Debug: bash -x /tmp/openpdfstudio-install.sh
# -----------------------------------------------------------------------------
set -euo pipefail

OPDS_PORT="${OPDS_PORT:-8080}"
OPDS_CTIP="${OPDS_CTIP:-}"
OPDS_VERSION="${OPDS_VERSION:-unknown}"
UPDATE_MODE="${UPDATE_MODE:-0}"

APP_DIR="/var/www/open-pdf-studio"
VHOST="/etc/nginx/sites-available/open-pdf-studio.conf"
VHOST_ENABLED="/etc/nginx/sites-enabled/open-pdf-studio.conf"
DIST_TARBALL_URL="https://codeload.github.com/HatchetMan111/OpenPDF/tar.gz/refs/heads/main"

# ── Farben + Helper (Community-Scripts-Stil) ─────────────────────────────────
if [[ -t 1 ]] && [[ "${OPDS_NO_COLOR:-}" != "1" ]]; then
    YW=$(printf '\033[1;33m'); GN=$(printf '\033[1;32m'); RD=$(printf '\033[1;31m')
    BOLD=$(printf '\033[1m'); CL=$(printf '\033[0m')
else
    YW=""; GN=""; RD=""; BOLD=""; CL=""
fi
INFO="${YW}Info:${CL}"
ERROR="${RD}ERROR:${CL}"

msg_info()  { echo -e "${INFO} ${YW}$1${CL}"; }
msg_ok()    { echo -e "  ${GN}✔${CL} ${GN}$1${CL}"; }
msg_error() { echo -e "${ERROR} ${RD}$1${CL}" >&2; }

# $STD: leise laufen; bei Fehlschlag die letzten 40 Zeilen zeigen (Fehlerkette)
STD() { "$@" >/dev/null 2>&1 || { "$@" 2>&1 | tail -n 40 >&2; false; }; }

on_error() {
    local exit_code=$1 line=$2 cmd=$3
    echo "" >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "${RD}  IN-CONTAINER INSTALL FEHLGESCHLAGEN — volle Fehlerkette${CL}" >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "  ✘ Fehlgeschlagener Befehl : ${BOLD}${cmd}${CL}" >&2
    echo -e "  ✘ Exit-Code      : ${RD}${exit_code}${CL}" >&2
    echo -e "  ✘ Script-Zeile   : ${line}" >&2
    echo "" >&2
    echo -e "${YW}── nginx -t (Konfig-Test) ──${CL}" >&2
    { nginx -t 2>&1 || true; } >&2
    echo -e "${YW}── systemctl status nginx (letzte 25 Zeilen) ──${CL}" >&2
    { systemctl status nginx --no-pager -l 2>&1 | tail -n 25 || true; } >&2
    echo -e "${YW}── journalctl -u nginx (letzte 25 Zeilen) ──${CL}" >&2
    { journalctl -u nginx -n 25 --no-pager 2>&1 || true; } >&2
    echo -e "${YW}── ${APP_DIR} (Inhalt) ──${CL}" >&2
    { ls -la "${APP_DIR}" 2>&1 || true; } >&2
    echo -e "${YW}── apt-Fehlerreste ──${CL}" >&2
    { tail -n 20 /var/log/apt/term.log 2>/dev/null || echo "(keine /var/log/apt/term.log)"; } >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "${YW}Debug-Lauf: bash -x /tmp/openpdfstudio-install.sh${CL}" >&2
}
trap 'on_error $? $LINENO "${BASH_COMMAND}"' ERR

# ── Preflight ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { msg_error "Als root im CT ausführen."; exit 1; }
msg_info "In-Container-Install startet (port=${OPDS_PORT}, ip=${OPDS_CTIP:-dhcp}, version=${OPDS_VERSION}, update-mode=${UPDATE_MODE})"
export DEBIAN_FRONTEND=noninteractive

# resolv.conf LESBAR für alle halten (apt-Sandbox-Benutzer _apt braucht das —
# ohne chmod stirbt apt-get update still mit "Temporary failure resolving")
chmod 0644 /etc/resolv.conf 2>/dev/null || true

# ── Schritt 1: nginx installieren (nur wenn fehlt) ───────────────────────────
# Debian installiert nginx nach /usr/sbin/nginx — dieser Check ist präziser
# als `command -v nginx` (PATH kann Umgebungsartefakte enthalten).
if ! test -x /usr/sbin/nginx; then
    msg_info "Installiere nginx + curl + ca-certificates (apt)"
    # APT-Sandbox-Fallback: wenn _apt nicht kann, darf root ziehen
    mkdir -p /etc/apt/apt.conf.d
    printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99opds-sandbox-root
    STD apt-get update
    STD apt-get install -y --no-install-recommends nginx curl ca-certificates
    msg_ok "nginx installiert: $(nginx -v 2>&1)"
else
    msg_info "nginx bereits vorhanden — überspringe apt ($(nginx -v 2>&1))"
fi

# ── Schritt 2: dist/ deployen (statischer Web-Build aus dem Installer-Repo) ──
msg_info "Lade Web-UI-Build (dist) aus dem Installer-Repo (${OPDS_VERSION})"
TARBALL="/tmp/opds-dist.tar.gz"
rm -f "$TARBALL"
WGET_TRY=0
until wget -q --tries=3 --timeout=30 -O "$TARBALL" "$DIST_TARBALL_URL"; do
    WGET_TRY=$((WGET_TRY + 1))
    if (( WGET_TRY >= 3 )); then
        msg_error "Download des dist-Tarballs fehlgeschlagen nach 3 Versuchen: ${DIST_TARBALL_URL}"
        # wget gibt unter -q nichts aus — die Netz-Fakten hier manuell sammeln
        { getent hosts codeload.github.com || true; } >&2
        { curl -sS -m 15 -o /dev/null -w 'HTTP %{http_code}\n' -I "$DIST_TARBALL_URL" || true; } >&2
        { ls -la "$TARBALL" 2>/dev/null || true; } >&2
        exit 1
    fi
    msg_info "Download-Versuch ${WGET_TRY} fehlgeschlagen — wiederhole in 5 s"
    sleep 5
done
TARBALL_SIZE=$(stat -c%s "$TARBALL" 2>/dev/null || echo 0)
if (( TARBALL_SIZE < 1000000 )); then
    msg_error "dist-Tarball verdächtig klein (${TARBALL_SIZE} Bytes) — abgebrochen."
    exit 1
fi
if ! TARBALL_LISTING=$(tar -tzf "$TARBALL" 2>/dev/null); then
    msg_error "Tarball ist kein gültiges gzip-Archiv (tar -tzf fehlgeschlagen)."
    exit 1
fi
# KEINE Pipeline mit grep -q! grep -q schließt die Pipe beim ersten Treffer,
# der andere Befehl stirbt an SIGPIPE (Broken pipe) — unter set -euo pipefail
# wird das als Fehler gemeldet. Darum: Variable in case/Shell-Muster prüfen.
case "$TARBALL_LISTING" in
    *"dist/index.html"*) : ;;  # Treffer — gut
    *)
        msg_error "Tarball enthält kein dist/index.html — falsches Repo oder leeres main?"
        # head -n 10 auf eine Variable (kein live-Datenstrom) ist sicher —
        # TARBALL_LISTING steht schon komplett im Speicher, kein SIGPIPE.
        printf '%s\n' "$TARBALL_LISTING" | head -n 10 >&2 || true
        exit 1
        ;;
esac
msg_ok "dist-Tarball geladen ($(( TARBALL_SIZE / 1024 / 1024 )) MB)"

# Version aus dem Tarball-Root (falls neu gepusht wurde, ist das die aktuelle)
rm -rf /tmp/opds-meta
mkdir -p /tmp/opds-meta
tar -xzf "$TARBALL" -C /tmp/opds-meta --strip-components=1 --wildcards '*/VERSION' 2>/dev/null || true
OPDS_VERSION_DETECTED=$(cat /tmp/opds-meta/VERSION 2>/dev/null || true)
rm -rf /tmp/opds-meta
[[ -n "$OPDS_VERSION_DETECTED" ]] || OPDS_VERSION_DETECTED="${OPDS_VERSION:-unbekannt}"

msg_info "Deploye nach ${APP_DIR} (atomar: .new → swap)"
rm -rf "${APP_DIR}.new"
mkdir -p "${APP_DIR}.new"
# Tarball-Mitglieder OpenPDF-main/dist/<x> → direkt <x> (strip 2)
tar -xzf "$TARBALL" -C "${APP_DIR}.new" --strip-components=2 --wildcards '*/dist/*'
[[ -f "${APP_DIR}.new/index.html" ]] || { msg_error "index.html fehlt nach dem Entpacken."; exit 1; }
printf '%s\n' "${OPDS_VERSION_DETECTED}" > "${APP_DIR}.new/.opds-version"
# Alte Version sicherheitshalber zurückhalten, bis der Swap durch ist
rm -rf "${APP_DIR}.bak"
if [[ -d "${APP_DIR}" ]]; then mv "${APP_DIR}" "${APP_DIR}.bak"; fi
mv "${APP_DIR}.new" "${APP_DIR}"
rm -rf "${APP_DIR}.bak"
msg_ok "Web-UI deployed: ${APP_DIR} ($(( $(du -sm "${APP_DIR}" | cut -f1) )) MB, Version $(cat "${APP_DIR}/.opds-version"))"

# ── Schritt 3: nginx-vHost ───────────────────────────────────────────────────
msg_info "Schreibe nginx-vHost (${VHOST}, Port ${OPDS_PORT})"
cat > "$VHOST" <<'VHOST'
# Open PDF Studio — Web-UI (statischer Vite-Build)
# __OPDS_PORT__ wird vom Installer ersetzt.
server {
    listen __OPDS_PORT__ default_server;
    listen [::]:__OPDS_PORT__ default_server;
    server_name _;

    root /var/www/open-pdf-studio;
    index index.html;

    # gzip für die großen JS/WASM-Assets
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_vary on;
    gzip_types
        application/javascript
        application/json
        application/wasm
        application/xml
        image/svg+xml
        text/css
        text/plain;

    # MIME-Typen: erst die Standard-Tabelle laden, dann die für den Web-Build
    # fehlenden ergänzen. WICHTIG: ein `types`-Block ersetzt die globale
    # mime.types-Tabelle komplett — ohne include würde alles als
    # application/octet-stream ausgeliefert und der Browser lädt JS-Dateien
    # herunter statt die App auszuführen.
    include /etc/nginx/mime.types;
    types {
        application/wasm                    wasm;
        application/javascript             js mjs;
        font/woff2                         woff2;
    }

    # Hash-Assets: unveränderlich cachebar (Dateinamen enthalten den Hash)
    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files $uri =404;
    }

    # SPA: unbekannte Pfade auf index.html (startet leer, alles clientseitig)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # index.html immer frisch ausliefern (verweist auf neue Hash-Assets)
    location = /index.html {
        add_header Cache-Control "no-cache";
    }
}
VHOST
sed -i "s/__OPDS_PORT__/${OPDS_PORT}/g" "$VHOST"

# Default-Site aushängen (belegt sonst Port 80 und ist Rauschen)
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    msg_ok "nginx-Default-Site deaktiviert"
fi
ln -sf "$VHOST" "$VHOST_ENABLED"
nginx -t || { msg_error "nginx-Konfig-Test fehlgeschlagen (siehe oben im Fehlerfall)."; exit 1; }
msg_ok "nginx-vHost aktiv (Sites-enabled-Symlink gesetzt, nginx -t grün)"

# ── Schritt 4: systemd-Drop-in für nginx (reboot-sicher) ─────────────────────
msg_info "Installiere systemd-Drop-in für nginx.service (Restart=on-failure, network-online)"
if [[ -f /tmp/opds-nginx-dropin.conf ]]; then
    mkdir -p /etc/systemd/system/nginx.service.d
    cp /tmp/opds-nginx-dropin.conf /etc/systemd/system/nginx.service.d/openpdfstudio.conf
else
    # Fallback (sollte nicht passieren — Host-Script pusht die Datei immer mit)
    mkdir -p /etc/systemd/system/nginx.service.d
    printf '[Unit]\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nRestart=on-failure\nRestartSec=3\n' \
        > /etc/systemd/system/nginx.service.d/openpdfstudio.conf
fi
systemctl daemon-reload
STD systemctl enable nginx
msg_ok "nginx.service: enabled + Drop-in installiert (reboot-sicher)"

# ── Schritt 5: nginx (neu) starten ───────────────────────────────────────────
msg_info "Starte nginx (idempotent)"
STD systemctl restart nginx
msg_ok "nginx läuft"

# ── Schritt 6: Selbst-Verifikation (Anforderung 7) ───────────────────────────
msg_info "Verifiziere Service (systemctl is-active nginx)"
SVC_STATE=$(systemctl is-active nginx 2>/dev/null || true)
if [[ "$SVC_STATE" != "active" ]]; then
    msg_error "nginx ist NICHT aktiv (Status: ${SVC_STATE:-unbekannt})."
    exit 1
fi
msg_ok "Service nginx: active"

msg_info "Warte auf Web-UI auf localhost:${OPDS_PORT} (bis 60 s)"
HTTP_CODE=""
DEADLINE=$((SECONDS + 60))
while (( SECONDS < DEADLINE )); do
    # curl gibt bei Verbindungsfehler bereits 000 aus — hier KEIN zusätzliches
    # "|| echo 000" (würde '000000' erzeugen und den Check falsch-positiv machen)
    HTTP_CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://localhost:${OPDS_PORT}/" 2>/dev/null || true)
    [[ -n "$HTTP_CODE" ]] || HTTP_CODE=000
    [[ "$HTTP_CODE" == "200" ]] && break
    sleep 2
done
if [[ "$HTTP_CODE" != "200" ]]; then
    msg_error "Web-UI antwortet nicht auf localhost:${OPDS_PORT} (letzter HTTP-Code: ${HTTP_CODE:-keiner})"
    exit 1
fi
msg_ok "Web-UI antwortet: http://localhost:${OPDS_PORT}/ (HTTP 200)"

msg_info "Prüfe App-Titel in der Antwort"
TITLE=$(curl -s -m 5 "http://localhost:${OPDS_PORT}/" 2>/dev/null | grep -o '<title>[^<]*</title>' | head -n1 || true)
if [[ "$TITLE" != *"Open PDF Studio"* ]]; then
    msg_error "Index-Seite trägt nicht den App-Titel (gefunden: ${TITLE:-nichts}) — falsches dist deployed?"
    exit 1
fi
msg_ok "App-Titel bestätigt: ${TITLE}"

# ── Firewall (in LXC meist inaktiv — dokumentierter No-op) ───────────────────
# Kein `ufw status | grep -q`: grep -q schließt die Pipe beim ersten Treffer,
# ufw stirbt an SIGPIPE → pipefail meldet Fehler. Status erst in Variable holen.
UFW_OUT=""
if command -v ufw >/dev/null 2>&1; then
    UFW_OUT=$(ufw status 2>/dev/null || true)
fi
case "$UFW_OUT" in
    *"Status: active"*)
        STD ufw allow "${OPDS_PORT}/tcp"
        msg_ok "ufw: Port ${OPDS_PORT} freigegeben"
        ;;
    *)
        msg_ok "Keine aktive Firewall (ufw) — Port ${OPDS_PORT} ist offen"
        ;;
esac

msg_info "In-Container-Install erfolgreich abgeschlossen"
exit 0
