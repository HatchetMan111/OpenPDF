#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Open PDF Studio LXC Installer — Proxmox VE Community Scripts style
# App:  Open PDF Studio — freier PDF-Editor für Zeichnungen (Markup, Messen,
#       Revisionsvergleich); Browser-Version als statischer Vite-Build
# Repo: https://github.com/OpenAEC-Foundation/open-pdf-studio  (v2026.47.0, LGPL-3.0+)
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenPDFStudio-Proxmox/main/install/openpdfstudio.sh)"
#
# Was passiert:
#   1. Erzeugt einen unprivilegierten LXC (Debian, nesting=1, onboot=1, DHCP)
#      — oder aktualisiert eine bestehende Installation (re-run = update).
#   2. Prüft DNS im CT (3 konsekutive Auflösungs-Erfolge, sonst Fallback).
#   3. Pusht openpdfstudio-install.sh + nginx-Drop-in ins CT:
#      nginx installiert, dist/ (fertiger Web-UI-Build aus diesem Repo) nach
#      /var/www/open-pdf-studio, vHost auf Port 8080, nginx reboot-sicher.
#   4. Verifiziert (systemctl is-active, HTTP-Check, App-Titel) und schreibt
#      die CT-Beschreibung wie die Community Scripts.
#
# Idempotent: existing CT + existing install => update (neues dist + config).
# Alle Variablen per Environment überschreibbar (OPDS_CTID, OPDS_PORT, …).
#
# Copyright (c) 2026 — MIT License (Installer); App: LGPL-3.0-or-later (upstream)
# -----------------------------------------------------------------------------

set -euo pipefail

# ── Benutzervariablen (env-überschreibbar) ───────────────────────────────────
APP="Open PDF Studio"
OPDS_REPO_RAW="${OPDS_REPO_RAW:-https://raw.githubusercontent.com/HatchetMan111/OpenPDFStudio-Proxmox/main}"
OPDS_CTID="${OPDS_CTID:-}"
OPDS_CTHOSTNAME="${OPDS_CTHOSTNAME:-open-pdf-studio}"
OPDS_OS="${OPDS_OS:-debian}"
OPDS_VERSION_TEMPLATE="${OPDS_VERSION_TEMPLATE:-13}"
OPDS_CORES="${OPDS_CORES:-2}"
# Statische SPA + nginx — die Web-UI selbst braucht wenig; 2 GB RAM sind
# komfortabel (kein Build im CT, das dist ist committed).
OPDS_RAM="${OPDS_RAM:-2048}"
OPDS_DISK="${OPDS_DISK:-8}"
OPDS_BRIDGE="${OPDS_BRIDGE:-vmbr0}"
OPDS_STORAGE="${OPDS_STORAGE:-local-lvm}"
OPDS_PORT="${OPDS_PORT:-8080}"
OPDS_TAG="${OPDS_TAG:-pdf;editor;community-script}"
OPDS_UNPRIVILEGED="${OPDS_UNPRIVILEGED:-1}"

ONE_LINER="bash -c \"\$(wget -qLO - ${OPDS_REPO_RAW}/install/openpdfstudio.sh)\""

# ── Flags (grube 8: bash -c "$(wget …)" legt die Option in $0, nicht $1) ────
ARGS=("$@")
if [[ "${1:-}" == "" && "${0}" == -* ]]; then
    ARGS=("$0")
fi
MODE="install"
for a in "${ARGS[@]}"; do
    case "$a" in
        --update)    MODE="update" ;;
        --uninstall) MODE="uninstall" ;;
        --status)    MODE="status" ;;
        --no-color)  export OPDS_NO_COLOR=1 ;;
        --help|-h)
            echo "Open PDF Studio LXC-Installer"
            echo "  (ohne Flag)   Installieren — bei bestehender Installation: Update"
            echo "  --update      Nur aktualisieren (dist neu deployen + nginx prüfen)"
            echo "  --status      Status des Containers + Web-UI zeigen"
            echo "  --uninstall   Container stoppen und löschen (nur open-pdf-studio-CTs!)"
            echo "  --no-color    Ausgabe ohne Farben"
            echo ""
            echo "  Umgebungsvariablen: OPDS_CTID OPDS_PORT (8080) OPDS_RAM (2048)"
            echo "                      OPDS_DISK (8) OPDS_CORES (2) OPDS_STORAGE OPDS_BRIDGE"
            exit 0
            ;;
        *) ;;
    esac
done

# ── Farben (Community-Scripts-Stil) ──────────────────────────────────────────
if [[ -t 1 ]] && [[ "${OPDS_NO_COLOR:-}" != "1" ]]; then
    YW=$(printf '\033[1;33m'); GN=$(printf '\033[1;32m'); RD=$(printf '\033[1;31m')
    BGN=$(printf '\033[1;94m'); BOLD=$(printf '\033[1m'); CL=$(printf '\033[0m')
else
    YW=""; GN=""; RD=""; BGN=""; BOLD=""; CL=""
fi
INFO="${YW}Info:${CL}"
ERROR="${RD}ERROR:${CL}"

# ── Zentraler Fehler-Handler: volle Fehlerkette ──────────────────────────────
on_error() {
    local exit_code=$1 line=$2 cmd=$3
    if [[ -n "${PUSH_DIR:-}" && -d "$PUSH_DIR" ]]; then
        rm -rf "$PUSH_DIR" 2>/dev/null || true
    fi
    echo "" >&2
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
    echo -e "${RD}  INSTALLATION FEHLGESCHLAGEN — volle Fehlerkette${CL}" >&2
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
    echo -e "  ✘ Fehlgeschlagener Befehl : ${BOLD}${cmd}${CL}" >&2
    echo -e "  ✘ Exit-Code      : ${RD}${exit_code}${CL}" >&2
    echo -e "  ✘ Script-Zeile   : ${line}" >&2
    echo -e "  ✘ CT (falls angelegt): ${OPDS_CTID:-keine}" >&2
    echo "" >&2
    echo -e "${YW}Vollständigen Trace reproduzieren (bash -x):${CL}" >&2
    echo -e "  wget -qO /tmp/openpdfstudio.sh '${OPDS_REPO_RAW}/install/openpdfstudio.sh' && bash -x /tmp/openpdfstudio.sh" >&2
    echo "" >&2
    if [[ -n "${OPDS_CTID:-}" ]] && pct status "$OPDS_CTID" &>/dev/null; then
        echo -e "${YW}── Letzte 40 Zeilen: /var/log/openpdfstudio-install.log (im CT) ──${CL}" >&2
        pct exec "$OPDS_CTID" -- tail -n 40 /var/log/openpdfstudio-install.log >&2 2>/dev/null || true
        echo "" >&2
        echo -e "${YW}── systemctl status nginx (im CT) ──${CL}" >&2
        pct exec "$OPDS_CTID" -- bash -c \
            'systemctl status nginx --no-pager -l 2>&1 | tail -n 25' >&2 2>/dev/null || true
        echo "" >&2
        echo -e "${YW}── Netzwerk/DNS im CT ──${CL}" >&2
        pct exec "$OPDS_CTID" -- bash -c \
            'ip -4 addr show eth0; echo; cat /etc/resolv.conf; getent hosts codeload.github.com || echo "DNS: codeload.github.com löst NICHT auf"' >&2 2>/dev/null || true
        echo "" >&2
    fi
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
}
trap 'on_error $? $LINENO "${BASH_COMMAND}"' ERR

# ── Community-Scripts-Stil Helper ────────────────────────────────────────────
header_info() {
    clear 2>/dev/null || true
    echo -e "${BOLD}"
    cat <<-'EOF'
    ╔══════════════════════════════════════════════════════════╗
    ║                                                          ║
    ║   📕  Open PDF Studio  —  on Proxmox VE                   ║
    ║                                                          ║
    ║   Freier PDF-Editor für Zeichnungen (LGPL-3.0+)          ║
    ║   Markup · Messen · Revisionsvergleich · CAD-Import      ║
    ║   Community-Scripts-style LXC installer                  ║
    ║                                                          ║
    ╚══════════════════════════════════════════════════════════╝
EOF
    echo -e "${CL}"
}
msg_info()  { echo -e "${INFO} ${YW}$1${CL}"; }
msg_ok()    { echo -e "  ${GN}✔${CL} ${GN}$1${CL}"; }
msg_error() { echo -e "${ERROR} ${RD}$1${CL}" >&2; }

# ── Gast-Inventar Helper (robust gegen die klassischen Fallen) ───────────────
cluster_vmids() {
    pvesh get /cluster/resources --output json 2>/dev/null \
        | grep -oE '"vmid": ?[0-9]+' | grep -oE '[0-9]+' || true
}
guest_type() {  # prints: lxc | qemu | none
    local id="$1"
    if pct config "$id" &>/dev/null; then echo lxc; return 0; fi
    if qm config "$id" &>/dev/null; then echo qemu; return 0; fi
    echo none
}
next_free_ctid() {
    local id=100 used
    used=$(cluster_vmids)
    while printf '%s\n' "$used" | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}
validate_ctid() {  # sanitize + validate; druckt saubere ID, 1 wenn schlecht
    local raw="$1" clean
    clean=$(printf '%s' "$raw" | tr -d '[:space:]')
    if ! [[ "$clean" =~ ^[0-9]+$ ]]; then return 1; fi
    if ! (( 10#$clean >= 100 && 10#$clean <= 999999999 )); then return 1; fi
    printf '%s' "$clean"
}
ensure_running_and_detect() {
    # Vor jedem pct push/exec: CT muss laufen (pct exec auf gestopptem CT → Exit 255)
    local state
    state=$(pct status "$OPDS_CTID" 2>/dev/null | awk '{print $2}' || echo unknown)
    if [[ "$state" != "running" ]]; then
        msg_info "Starte bestehenden CT ${OPDS_CTID} (Status: ${state:-unbekannt})"
        pct start "$OPDS_CTID"
        msg_ok "CT gestartet"
    fi
    if ! pct exec "$OPDS_CTID" -- true 2>/dev/null; then
        msg_error "Kann keine Befehle im CT ${OPDS_CTID} ausführen (pct exec fehlgeschlagen) — ist er gesund?"
        exit 1
    fi
    if pct exec "$OPDS_CTID" -- test -f /var/www/open-pdf-studio/index.html 2>/dev/null; then
        HAS_INSTALL=1
    else
        HAS_INSTALL=0
    fi
}
get_ct_ip() {
    # IP holen — || true INNERHALB der Substitution (pct-exec-Fehler unter
    # pipefail würde sonst den falschen Täter melden)
    pct exec "$OPDS_CTID" -- bash -c \
        "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true
}

# ── DNS-Verifikation im CT (3 KONSEKUTIVE Erfolge — ein einzelner Erfolg winkt
#    flaky DNS durch!) + Fallback-Nameserver + Notkeule chattr +i ─────────────
verify_ct_dns() {
    local ok_count=0 i resolved
    msg_info "Prüfe DNS im CT (3 konsekutive Auflösungen von codeload.github.com)"
    for i in $(seq 1 12); do
        resolved=$(pct exec "$OPDS_CTID" -- getent hosts codeload.github.com 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$resolved" ]]; then
            ok_count=$((ok_count + 1))
            if (( ok_count >= 3 )); then
                msg_ok "DNS im CT stabil (3 konsekutive Auflösungen: ${resolved})"
                return 0
            fi
        else
            ok_count=0
        fi
        sleep 2
    done
    msg_error "DNS im CT instabil oder defekt — schreibe Fallback-Nameserver"
    local host_ns
    host_ns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk 'NR==1{print $2}' || true)
    [[ -n "$host_ns" ]] || host_ns="1.1.1.1"
    pct exec "$OPDS_CTID" -- bash -c "
        printf 'nameserver ${host_ns}\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        chmod 0644 /etc/resolv.conf
    " || { msg_error "Konnte Fallback-Nameserver nicht schreiben."; exit 1; }
    msg_info "Fallback gesetzt (${host_ns}, 1.1.1.1, 8.8.8.8) — erneute Prüfung"
    ok_count=0
    for i in $(seq 1 9); do
        resolved=$(pct exec "$OPDS_CTID" -- getent hosts codeload.github.com 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$resolved" ]]; then
            ok_count=$((ok_count + 1))
            if (( ok_count >= 3 )); then
                msg_ok "DNS im CT funktioniert mit Fallback (${resolved})"
                # Dauerhaft fixieren: PVE schreibt bei jedem Start resolv.conf neu,
                # NUR wenn --nameserver in der Config steht — hier via pct set:
                pct set "$OPDS_CTID" --nameserver "${host_ns},1.1.1.1,8.8.8.8" >/dev/null 2>&1 || true
                return 0
            fi
        else
            ok_count=0
        fi
        sleep 2
    done
    msg_error "DNS im CT auch mit Fallback defekt. Diagnose:"
    pct exec "$OPDS_CTID" -- bash -c 'cat /etc/resolv.conf; echo; ping -c 2 -W 2 1.1.1.1 2>&1 | tail -n 4 || true' >&2 2>/dev/null || true
    exit 1
}

# ── Preflight ────────────────────────────────────────────────────────────────
header_info
if [[ $EUID -ne 0 ]]; then
    msg_error "Dieses Script muss als root auf dem Proxmox-Host laufen."
    exit 1
fi
for cmd in pct pvesh qm pveam pvesm wget curl; do
    command -v "$cmd" >/dev/null 2>&1 \
        || { msg_error "Fehlender Befehl: '$cmd' — auf dem Proxmox-Host ausführen."; exit 1; }
done
if ! pvesh get /storage --output json 2>/dev/null | grep -q "\"${OPDS_STORAGE}\""; then
    msg_error "Storage '${OPDS_STORAGE}' auf diesem Node nicht gefunden. Verfügbare Storages:"
    pvesh get /storage --output json 2>/dev/null \
        | grep -oE '"storage":"[^"]*"' | cut -d'"' -f4 | sed 's/^/    /' >&2 || true
    exit 1
fi
if ! [[ "$OPDS_PORT" =~ ^[0-9]+$ ]] || (( OPDS_PORT < 1 || OPDS_PORT > 65535 )); then
    msg_error "Ungültiger Port: OPDS_PORT='${OPDS_PORT}' (1-65535)."
    exit 1
fi

# ── Modus: status / uninstall ────────────────────────────────────────────────
do_status() {
    local id
    id="${OPDS_CTID:-$(next_free_ctid)}"
    if [[ "$(guest_type "$id")" != "lxc" ]]; then
        # Status soll auch funktionieren, wenn der CT unter einem anderen ID-Bereich liegt
        for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
            if pct config "$id" 2>/dev/null | grep -q "hostname: ${OPDS_CTHOSTNAME}"; then
                break
            fi
            id=""
        done
        if [[ -z "${id:-}" ]]; then
            msg_error "Kein ${APP}-CT gefunden (Hostname '${OPDS_CTHOSTNAME}')."
            exit 1
        fi
    fi
    local state ip svc http ver
    state=$(pct status "$id" 2>/dev/null | awk '{print $2}' || echo unbekannt)
    echo -e "${BOLD}${APP} — CT ${id}${CL}"
    echo -e "  CT-Status : ${state}"
    if [[ "$state" == "running" ]]; then
        ip=$(get_ct_ip)
        echo -e "  IP        : ${ip:-unbekannt}"
        svc=$(pct exec "$id" -- bash -c 'systemctl is-active nginx' 2>/dev/null || true)
        echo -e "  nginx     : ${svc:-unbekannt}"
        if [[ -n "$ip" ]]; then
            http=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://${ip}:${OPDS_PORT}/" 2>/dev/null || true)
            [[ -n "$http" ]] || http=000
            echo -e "  Web-UI    : http://${ip}:${OPDS_PORT}/  (HTTP ${http})"
        fi
        ver=$(pct exec "$id" -- bash -c 'cat /var/www/open-pdf-studio/.opds-version 2>/dev/null' 2>/dev/null || true)
        echo -e "  Version   : ${ver:-unbekannt}"
    fi
    return 0
}

do_uninstall() {
    local id="${OPDS_CTID:-}"
    if [[ -z "$id" ]]; then
        for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
            if pct config "$id" 2>/dev/null | grep -q "hostname: ${OPDS_CTHOSTNAME}"; then
                break
            fi
            id=""
        done
        if [[ -z "${id:-}" ]]; then
            msg_error "Kein ${APP}-CT gefunden (Hostname '${OPDS_CTHOSTNAME}') — nichts zu deinstallieren."
            exit 1
        fi
    fi
    # Sicherheitsnetz: nur löschen, was wirklich unser CT ist
    if ! pct config "$id" 2>/dev/null | grep -q "hostname: ${OPDS_CTHOSTNAME}"; then
        msg_error "CT ${id} trägt nicht den Hostnamen '${OPDS_CTHOSTNAME}' — NICHT löschen (Sicherheitsnetz)."
        msg_error "Explizit: OPDS_CTID=${id} mit --uninstall nur nach manueller Prüfung."
        exit 1
    fi
    msg_info "Stoppe und lösche CT ${id} (${APP})"
    pct stop "$id" || true
    pct destroy "$id" --purge
    msg_ok "CT ${id} gelöscht."
    echo -e "  (Web-Daten lagen nur im CT — entfernte PDFs waren nie auf dem Server.)"
    return 0
}

case "$MODE" in
    status)    do_status; exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
esac

# ── CT-ID: Prompt mit Validierung (Default = nächste freie ID) ───────────────
if [[ -n "${OPDS_CTID:-}" ]]; then
    if ! OPDS_CTID=$(validate_ctid "$OPDS_CTID"); then
        msg_error "Ungültige OPDS_CTID (muss numerisch sein, 100-999999999)."
        exit 1
    fi
else
    DEFAULT_ID=$(next_free_ctid)
    OPDS_CTID=""
    for _ in 1 2 3; do
        INPUT_ID=""
        if ! read -r -p "$(echo -e "${YW}CT-ID eingeben [ENTER für ${DEFAULT_ID} (nächste freie)]:${CL}") " INPUT_ID; then
            INPUT_ID="$DEFAULT_ID"
        fi
        INPUT_ID="${INPUT_ID:-$DEFAULT_ID}"
        if CLEAN_ID=$(validate_ctid "$INPUT_ID"); then
            OPDS_CTID="$CLEAN_ID"
            break
        fi
        msg_error "Ungültige CT-ID '${INPUT_ID}' — muss numerisch sein (100-999999999). Erneut versuchen."
    done
    if [[ -z "${OPDS_CTID:-}" ]]; then
        msg_error "Keine gültige CT-ID eingegeben."
        exit 1
    fi
fi

# ── Was lebt unter dieser VMID? (lxc / qemu / none) ──────────────────────────
case "$(guest_type "$OPDS_CTID")" in
    qemu)
        msg_error "VMID ${OPDS_CTID} ist eine QEMU-VM, kein LXC-Container."
        msg_error "Dieser Installer verwaltet nur LXC — andere ID wählen (nächste freie: $(next_free_ctid))."
        exit 1
        ;;
    lxc)
        NEED_CREATE=0
        ensure_running_and_detect
        if [[ "$HAS_INSTALL" -eq 1 ]]; then
            msg_info "CT ${OPDS_CTID} hat eine bestehende ${APP}-Installation — Update-Modus (Daten bleiben)"
        else
            msg_info "CT ${OPDS_CTID} existiert ohne ${APP}-Installation — frische Installation hinein"
        fi
        ;;
    none)
        NEED_CREATE=1
        HAS_INSTALL=0
        ;;
esac
UPDATE_MODE=$HAS_INSTALL

# ── Template-Auflösung (lokal zuerst, pveam-Download als Fallback) ────────────
resolve_template() {
    local pat="debian-${OPDS_VERSION_TEMPLATE}-standard" store fname
    for store in local $(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | grep -vx local || true); do
        fname=$(pveam list "$store" 2>/dev/null | grep -oE "${pat}[^ ]*\.tar\.zst" | sort -V | tail -n1 || true)
        if [[ -n "$fname" ]]; then
            printf '%s:vztmpl/%s' "$store" "$fname"
            return 0
        fi
    done
    return 1
}
template_store() {
    local stores first
    stores=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' || true)
    if printf '%s\n' "$stores" | grep -qx local; then echo local; return 0; fi
    first=$(printf '%s\n' "$stores" | head -n1)
    if [[ -z "$first" ]]; then return 1; fi
    echo "$first"
}
download_template() {
    local store="$1" file
    msg_info "Aktualisiere Template-Index (pveam update ${store})"
    pveam update "$store" >/dev/null 2>&1 || true
    file=$(pveam available --section system 2>/dev/null \
        | grep -oE "debian-${OPDS_VERSION_TEMPLATE}-standard[^ \"']*\.tar\.zst" \
        | sort -V | tail -n1 || true)
    if [[ -z "$file" ]]; then
        msg_error "Kein Debian-${OPDS_VERSION_TEMPLATE}-Template im pveam-Index."
        return 1
    fi
    msg_info "Lade Template ${file} auf '${store}'"
    pveam download "$store" "$file" >/dev/null
    printf '%s:vztmpl/%s' "$store" "$file"
}

# ── Container anlegen (übersprungen bei bestehendem CT) ──────────────────────
if [[ "$NEED_CREATE" -eq 1 ]]; then
    msg_info "Suche Debian ${OPDS_VERSION_TEMPLATE}-LXC-Template"
    if ! TEMPLATE=$(resolve_template); then
        TS=$(template_store) || { msg_error "Kein Storage mit 'vztmpl'-Inhalt gefunden."; exit 1; }
        TEMPLATE=$(download_template "$TS") || exit 1
    fi
    msg_ok "Template: ${TEMPLATE}"

    msg_info "Erstelle LXC ${OPDS_CTID} (${OPDS_CTHOSTNAME}: ${OPDS_CORES} vCPU, ${OPDS_RAM} MiB RAM, ${OPDS_DISK} GB Disk, Storage: ${OPDS_STORAGE}, $([[ "$OPDS_UNPRIVILEGED" == "0" ]] && echo privileged || echo unprivileged))"
    if CREATE_OUT=$(pct create "$OPDS_CTID" "$TEMPLATE" \
            --hostname "$OPDS_CTHOSTNAME" \
            --cores "$OPDS_CORES" \
            --memory "$OPDS_RAM" \
            --swap 512 \
            --rootfs "${OPDS_STORAGE}:${OPDS_DISK}" \
            --net0 "name=eth0,bridge=${OPDS_BRIDGE},ip=dhcp,type=veth" \
            --features nesting=1 \
            --unprivileged "$OPDS_UNPRIVILEGED" \
            --onboot 1 \
            --start 0 2>&1); then
        msg_ok "LXC ${OPDS_CTID} erstellt"
        msg_info "Starte Container"
        pct start "$OPDS_CTID"
        msg_ok "Container gestartet"
    elif echo "$CREATE_OUT" | grep -qi "already exists"; then
        msg_info "CT ${OPDS_CTID} existiert bereits — fahre fort (idempotent)"
        NEED_CREATE=0
        if [[ "$(guest_type "$OPDS_CTID")" != "lxc" ]]; then
            msg_error "VMID ${OPDS_CTID} ist kein LXC-Container — Abbruch."
            exit 1
        fi
        ensure_running_and_detect
        UPDATE_MODE=$HAS_INSTALL
    else
        echo "$CREATE_OUT" >&2
        exit 1
    fi
fi

# ── Auf Netz warten (DHCP-Lease) — aktiv pollen, kein blindes sleep ──────────
msg_info "Warte auf Container-IP (DHCP)"
CT_IP=""
for _ in $(seq 1 60); do
    CT_IP=$(get_ct_ip)
    if [[ -n "$CT_IP" ]]; then break; fi
    sleep 2
done
if [[ -z "$CT_IP" ]]; then
    msg_error "Keine Container-IP nach 120 s — DHCP/Netzwerk-Problem. Diagnostik:"
    pct exec "$OPDS_CTID" -- bash -c 'ip addr; ip route; cat /etc/resolv.conf' 2>&1 | tail -n 25 >&2 || true
    exit 1
fi
msg_ok "Container-IP: ${CT_IP}"

# ── DNS im CT verifizieren (BEVOR der Download/apt läuft) ────────────────────
verify_ct_dns

# ── Container-seitige Scripte holen + pushen (GitHub-first) ──────────────────
msg_info "Hole openpdfstudio-install.sh + nginx-Drop-in aus dem Repo"
PUSH_DIR=$(mktemp -d)
wget -q -O "${PUSH_DIR}/openpdfstudio-install.sh" "${OPDS_REPO_RAW}/install/openpdfstudio-install.sh" \
    || { msg_error "Konnte ${OPDS_REPO_RAW}/install/openpdfstudio-install.sh nicht laden"; exit 1; }
wget -q -O "${PUSH_DIR}/nginx-openpdfstudio.conf" "${OPDS_REPO_RAW}/systemd/nginx-openpdfstudio.conf" \
    || { msg_error "Konnte ${OPDS_REPO_RAW}/systemd/nginx-openpdfstudio.conf nicht laden"; exit 1; }
msg_ok "Install-Scripte aus dem Repo geladen"

msg_info "Pushe Scripte in CT ${OPDS_CTID}"
pct push "$OPDS_CTID" "${PUSH_DIR}/openpdfstudio-install.sh" /tmp/openpdfstudio-install.sh
pct push "$OPDS_CTID" "${PUSH_DIR}/nginx-openpdfstudio.conf" /tmp/opds-nginx-dropin.conf
rm -rf "$PUSH_DIR"
msg_ok "Scripte im CT bereit"

# ── In-Container-Installer ausführen ─────────────────────────────────────────
msg_info "Führe In-Container-Installer aus (nginx + dist-Deploy + systemd) — einige Minuten"
# pipefail im CT: sonst meldet tee (Exit 0) einen Inner-Script-Crash glatt
pct exec "$OPDS_CTID" -- bash -c "
set -euo pipefail
export OPDS_PORT='${OPDS_PORT}'
export OPDS_CTIP='${CT_IP}'
export OPDS_VERSION='neu'
export UPDATE_MODE='${UPDATE_MODE}'
bash /tmp/openpdfstudio-install.sh 2>&1 | tee /var/log/openpdfstudio-install.log
"
msg_ok "In-Container-Install fertig (Log: /var/log/openpdfstudio-install.log)"

# ── Verifikation (Anforderung 7) ─────────────────────────────────────────────
msg_info "Verifiziere Service (systemctl is-active nginx)"
SVC_STATE=$(pct exec "$OPDS_CTID" -- bash -c 'systemctl is-active nginx' 2>/dev/null || true)
if [[ "$SVC_STATE" != "active" ]]; then
    msg_error "Service 'nginx' ist NICHT aktiv (Status: ${SVC_STATE:-unbekannt}). Voller Status:"
    pct exec "$OPDS_CTID" -- bash -c 'systemctl status nginx --no-pager -l 2>&1 | tail -n 30' >&2 || true
    exit 1
fi
msg_ok "Service nginx: active"

msg_info "Verifiziere Web-UI (HTTP-Check im CT auf localhost:${OPDS_PORT})"
HTTP_CODE=$(pct exec "$OPDS_CTID" -- bash -c \
    "curl -s -m 10 -o /dev/null -w '%{http_code}' http://localhost:${OPDS_PORT}/ 2>/dev/null" 2>/dev/null || true)
if [[ -z "$HTTP_CODE" ]]; then HTTP_CODE=000; fi
if [[ "$HTTP_CODE" != "200" ]]; then
    msg_error "HTTP-Check im CT fehlgeschlagen (Code: ${HTTP_CODE})"
    pct exec "$OPDS_CTID" -- bash -c \
        "curl -v http://localhost:${OPDS_PORT}/ 2>&1 | tail -n 20" >&2 || true
    exit 1
fi
msg_ok "Web-UI antwortet im CT (HTTP ${HTTP_CODE})"

msg_info "Verifiziere Web-UI vom Proxmox-Host: http://${CT_IP}:${OPDS_PORT}/"
HOST_HTTP=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://${CT_IP}:${OPDS_PORT}/" 2>/dev/null || true)
if [[ -z "$HOST_HTTP" ]]; then HOST_HTTP=000; fi
if [[ "$HOST_HTTP" != "200" ]]; then
    msg_error "Web-UI vom Host NICHT erreichbar (HTTP ${HOST_HTTP}) — Bridge '${OPDS_BRIDGE}' oder Firewall prüfen."
    curl -v "http://${CT_IP}:${OPDS_PORT}/" 2>&1 | tail -n 20 >&2 || true
    exit 1
fi
msg_ok "Web-UI vom Host erreichbar (HTTP ${HOST_HTTP})"

INSTALLED_VERSION=$(pct exec "$OPDS_CTID" -- bash -c 'cat /var/www/open-pdf-studio/.opds-version 2>/dev/null' 2>/dev/null || true)
if [[ -z "$INSTALLED_VERSION" ]]; then INSTALLED_VERSION="unbekannt"; fi

# ── CT-Beschreibung + Tags (Community-Scripts-Stil) ──────────────────────────
pct set "$OPDS_CTID" \
    --description "<div align='center'>
  <h2 style='font-size:18px;'>📕 Open PDF Studio LXC</h2>
  <p>Web UI: <a href='http://${CT_IP}:${OPDS_PORT}'>http://${CT_IP}:${OPDS_PORT}</a> — ${INSTALLED_VERSION}</p>
  <p style='font-size:12px;'>Community-scripts style installer · Update: Installer re-run · Remove: pct stop ${OPDS_CTID} &amp;&amp; pct destroy ${OPDS_CTID} --purge</p>
</div>" \
    --tags "${OPDS_TAG}" >/dev/null
msg_ok "CT-Beschreibung + Tags gesetzt"

# ── Abschluss ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}✔ ${APP} wurde erfolgreich installiert!${CL}"
echo ""
echo -e "  ${BGN}Web UI  :${CL} http://${CT_IP}:${OPDS_PORT}"
echo -e "  ${BGN}Version :${CL} ${INSTALLED_VERSION} (Upstream: OpenAEC-Foundation/open-pdf-studio, LGPL-3.0+)"
echo -e "  ${BGN}Lokal   :${CL} Dokumente bleiben im Browser/dem eigenen Rechner — kein Cloud-Dienst"
echo -e "  ${BGN}CT      :${CL} LXC ${OPDS_CTID} '${OPDS_CTHOSTNAME}' (unprivileged, onboot=1, reboot-sicher)"
echo -e "  ${BGN}Logs    :${CL} pct exec ${OPDS_CTID} -- journalctl -u nginx -f"
echo -e "  ${BGN}Update  :${CL} Installer erneut ausführen (läuft als Update):"
echo -e "            ${BOLD}${ONE_LINER}${CL}"
echo -e "  ${BGN}Status  :${CL} ${ONE_LINER} --status"
echo -e "  ${BGN}Deinstall:${CL} ${ONE_LINER} --uninstall"
echo ""
echo -e "  ${YW}Hinweis:${CL} PDFs werden ausschließlich im Browser verarbeitet (PDF.js) —"
echo -e "  keine Datei verlässt dein LAN, der Server speichert nichts."
echo ""
exit 0
