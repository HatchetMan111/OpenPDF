#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# runner-inner.sh — läuft INNERHALB von unshare -rm (EUID 0 im Namespace).
#
# Setup:
#   1. tmpfs über /etc und /var mounten (alle Schreibzugriffe der Installer
#      bleiben in der Sandbox — /tmp ist real, aber je-Test eindeutig benannt)
#   2. fakebin mit Symlinks unter ECHTEN Namen bauen (Grube 15: env -i,
#      kein exportierter ugrep-Funktion-Einfluss; Runner: unset -f)
#   3. dist-Fixture-Tarball mit --owner=0 --group=0 bauen (Grube 16)
#   4. Tests T1–T9 ausführen, PASS/FAIL-Summary
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d /tmp/opds-harness-XXXXXX)"
STATE="${WORK}/state"
mkdir -p "${STATE}"

# Exportierte Funktionen (phils Profil: grep→ugrep) neutralisieren
unset -f grep awk sed cat ls stat find head tail 2>/dev/null || true

# ── 1. Sandbox-Mounts ────────────────────────────────────────────────────────
# /etc-Bestandteile sichern, die nach dem tmpfs-Overlay sonst fehlen
# (awk ist eine Alternative → /etc/alternatives — Grube aus Lauf 1)
STAGE="${WORK}/etc-stage"
mkdir -p "${STAGE}"
cp -a /etc/alternatives "${STAGE}/alternatives" 2>/dev/null || true
cp -a /etc/passwd /etc/group /etc/nsswitch.conf "${STAGE}/" 2>/dev/null || true
mount --make-rprivate /
mount -t tmpfs tmpfs /etc
mount -t tmpfs tmpfs /var
printf 'nameserver 10.10.10.1\n' > /etc/resolv.conf
chmod 0644 /etc/resolv.conf
printf 'opds-harness\n' > /etc/hostname
cp -a "${STAGE}/alternatives" /etc/ 2>/dev/null || true
cp -a "${STAGE}/passwd" "${STAGE}/group" "${STAGE}/nsswitch.conf" /etc/ 2>/dev/null || true
mkdir -p /var/www /var/log

# ── 2. fakebin (Symlinks unter echten Namen) ─────────────────────────────────
export HARNESS_STATE="${STATE}"
export HARNESS_REPO="${REPO}"
export HARNESS_TARBALL="${WORK}/opds-dist.tar.gz"
export OPDS_NO_COLOR=1
BIN="${WORK}/bin"
mkdir -p "${BIN}"
# env -i: Profil-Funktionen dürfen den Symlink-Bau nicht sehen (Grube 15)
env -i PATH=/usr/bin:/bin bash -c '
    set -euo pipefail
    BIN="$1"; MOCKS="$2"
    for name in pct qm pvesh pveam pvesm wget curl hostname getent apt-get nginx systemctl ufw journalctl; do
        ln -s "${MOCKS}/mock-${name}.sh" "${BIN}/${name}"
    done
' bash "${BIN}" "${HERE}/mocks"

export PATH="${BIN}:/usr/bin:/bin"

# ── 3. dist-Fixture-Tarball (Grube 16: --owner=0 --group=0) ──────────────────
FIXTURE="${WORK}/dist-fixture"
mkdir -p "${FIXTURE}/dist/assets"
printf '<!DOCTYPE html><html><head><title>Open PDF Studio</title></head><body id="app-root"></body></html>\n' \
    > "${FIXTURE}/dist/index.html"
printf 'body{background:#222}\n' > "${FIXTURE}/dist/assets/index-TESTHASH.css"
# 2 MB Inkompressibles, damit der Tarball die ≥1-MB-Sanity-Check des
# In-Container-Scripts realistisch passiert (echtes dist: ~12 MB gz)
dd if=/dev/urandom of="${FIXTURE}/dist/assets/app-TESTHASH.js" bs=1M count=2 2>/dev/null
printf 'vTEST.47.0\n' > "${FIXTURE}/VERSION"
tar -czf "${HARNESS_TARBALL}" --owner=0 --group=0 -C "${FIXTURE}" \
    --transform 's|^|OpenPDFStudio-Proxmox-main/|' dist VERSION

# ── Test-Framework ───────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED_LABELS=()
check() {  # check <label> <bedingung-befehl…>
    local label="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "  PASS: ${label}"
    else
        FAIL=$((FAIL + 1)); FAILED_LABELS+=("${label}")
        echo "  FAIL: ${label}" >&2
    fi
    return 0
}
assert_contains() {  # assert_contains <label> <datei> <needle> (Fix-String)
    local label="$1" haystack="$2" needle="$3"
    check "${label}" grep -qF -- "${needle}" "${haystack}"
}

# Stand des pct-Mocks als flaches Verzeichnis je CT
init_vmids() { printf '%s\n' 100 101 102 103 104 > "${STATE}/vmids.txt"; }
reset_state() {
    rm -rf "${STATE}/pct-state" "${STATE}/getent-count" "${STATE}/systemctl-nginx-active"
    init_vmids
}

echo "════════════════════════════════════════════════════════"
echo " Open PDF Studio Installer — Mock-Harness ($(date '+%H:%M:%S'))"
echo "════════════════════════════════════════════════════════"

# ── T1: Frischinstallation End-to-End ────────────────────────────────────────
echo ""
echo "── T1: Frischinstallation (nächste freie ID = 105) ──"
reset_state
unset OPDS_CTID || true
if bash "${REPO}/install/openpdfstudio.sh" < /dev/null > "${WORK}/t1.log" 2>&1; then
    check "T1: Installer beendet sich mit 0" true
else
    check "T1: Installer beendet sich mit 0" false
    echo "── T1-Log (letzte 40 Zeilen) ──" >&2
    tail -n 40 "${WORK}/t1.log" >&2 || true
fi
assert_contains "T1: CT 105 angelegt (nächste freie ID)"       "${WORK}/t1.log" "LXC 105"
assert_contains "T1: Container-IP gemockt"                     "${WORK}/t1.log" "Container-IP: 10.120.1.234"
assert_contains "T1: DNS-Verifikation 3x konsekutiv"           "${WORK}/t1.log" "DNS im CT stabil"
assert_contains "T1: Verifikation Service aktiv"               "${WORK}/t1.log" "Service nginx: active"
assert_contains "T1: Web-UI vom Host erreichbar"               "${WORK}/t1.log" "Web-UI vom Host erreichbar (HTTP 200)"
assert_contains "T1: Summary-Box mit finaler URL"              "${WORK}/t1.log" "http://10.120.1.234:8080"
assert_contains "T1: Version aus Fixture-Tarball erkannt"      "${WORK}/t1.log" "vTEST.47.0"
check "T1: dist im Sandbox-FS deployed"    test -f /var/www/open-pdf-studio/index.html
check "T1: .opds-version geschrieben"      test -f /var/www/open-pdf-studio/.opds-version
check "T1: vHost existiert"                test -f /etc/nginx/sites-available/open-pdf-studio.conf
check "T1: vHost enabled (Symlink)"        test -L /etc/nginx/sites-enabled/open-pdf-studio.conf
check "T1: Default-Site entfernt"          test ! -e /etc/nginx/sites-enabled/default
check "T1: systemd-Drop-in installiert"    test -f /etc/systemd/system/nginx.service.d/openpdfstudio.conf
check "T1: Install-Log im CT-Sandbox-Pfad" test -f /var/log/openpdfstudio-install.log
check "T1: vHost hört auf Port 8080"       grep -q 'listen 8080' /etc/nginx/sites-available/open-pdf-studio.conf
check "T1: Drop-in hat Restart=on-failure" grep -q 'Restart=on-failure' /etc/systemd/system/nginx.service.d/openpdfstudio.conf
check "T1: pct-Mock kennt CT 105"          test -d "${STATE}/pct-state/105"

# ── T2: Re-Run = Update-Modus ────────────────────────────────────────────────
echo ""
echo "── T2: Re-Run (Update-Modus, gleiche ID) ──"
if OPDS_CTID=105 bash "${REPO}/install/openpdfstudio.sh" < /dev/null > "${WORK}/t2.log" 2>&1; then
    check "T2: Update-Lauf beendet sich mit 0" true
else
    check "T2: Update-Lauf beendet sich mit 0" false
    tail -n 40 "${WORK}/t2.log" >&2 || true
fi
assert_contains "T2: Update-Modus erkannt"              "${WORK}/t2.log" "Update-Modus"
assert_contains "T2: weiterhin erfolgreich"             "${WORK}/t2.log" "erfolgreich installiert"
assert_contains "T2: kein zweiter CT (bleibt 105)"      "${WORK}/t2.log" "LXC 105"
check "T2: CT 105 existiert weiter" test -d "${STATE}/pct-state/105"

# ── T3: --status ─────────────────────────────────────────────────────────────
echo ""
echo "── T3: Status-Modus ──"
if bash "${REPO}/install/openpdfstudio.sh" --status < /dev/null > "${WORK}/t3.log" 2>&1; then
    check "T3: --status beendet sich mit 0" true
else
    check "T3: --status beendet sich mit 0" false
    tail -n 30 "${WORK}/t3.log" >&2 || true
fi
assert_contains "T3: Status zeigt nginx"        "${WORK}/t3.log" "nginx"
assert_contains "T3: Status zeigt Web-UI-URL"   "${WORK}/t3.log" "http://10.120.1.234:8080/"
assert_contains "T3: Status zeigt Version"      "${WORK}/t3.log" "Version"

# ── T4: Inner-Script direkt mit anderem Port ─────────────────────────────────
echo ""
echo "── T4: Inner-Script direkt (Port 9090) ──"
export OPDS_PORT=9090 OPDS_CTIP=10.120.1.234 OPDS_VERSION=neu UPDATE_MODE=1
if bash "${REPO}/install/openpdfstudio-install.sh" < /dev/null > "${WORK}/t4.log" 2>&1; then
    check "T4: Inner-Script beendet sich mit 0" true
else
    check "T4: Inner-Script beendet sich mit 0" false
    tail -n 60 "${WORK}/t4.log" >&2 || true
fi
unset OPDS_PORT OPDS_CTIP OPDS_VERSION UPDATE_MODE || true
check "T4: vHost hört auf Port 9090"    grep -q 'listen 9090' /etc/nginx/sites-available/open-pdf-studio.conf
assert_contains "T4: Titel-Verifikation grün"  "${WORK}/t4.log" "App-Titel bestätigt"
assert_contains "T4: Version vom Tarball"      "${WORK}/t4.log" "vTEST.47.0"

# ── T5: DNS-Fallback-Pfad (getent schlägt fehl bis Fallback geschrieben ist) ──
echo ""
echo "── T5: DNS-Defekt → Fallback-Nameserver ──"
reset_state
export HARNESS_GETENT_FLAKY=1   # getent schlägt fehl, solange kein 1.1.1.1 in /etc/resolv.conf
if bash "${REPO}/install/openpdfstudio.sh" < /dev/null > "${WORK}/t5.log" 2>&1; then
    check "T5: Install mit DNS-Fallback beendet sich mit 0" true
else
    check "T5: Install mit DNS-Fallback beendet sich mit 0" false
    tail -n 60 "${WORK}/t5.log" >&2 || true
fi
unset HARNESS_GETENT_FLAKY || true
assert_contains "T5: Fallback-Namesserver gesetzt"        "${WORK}/t5.log" "Fallback gesetzt"
assert_contains "T5: nach Fallback DNS stabil"            "${WORK}/t5.log" "DNS im CT funktioniert mit Fallback"
assert_contains "T5: Installation am Ende erfolgreich"    "${WORK}/t5.log" "erfolgreich installiert"
check "T5: resolv.conf enthält 1.1.1.1" grep -q '1.1.1.1' /etc/resolv.conf

# ── T6: QEMU-Kollision ───────────────────────────────────────────────────────
echo ""
echo "── T6: VMID ist eine QEMU-VM → Abbruch ──"
reset_state
export HARNESS_QEMU_ID=105
if bash "${REPO}/install/openpdfstudio.sh" < /dev/null > "${WORK}/t6.log" 2>&1; then
    check "T6: Installer muss bei QEMU-VM scheitern" false
else
    check "T6: Installer muss bei QEMU-VM scheitern" true
fi
unset HARNESS_QEMU_ID || true
assert_contains "T6: klare QEMU-Fehlermeldung" "${WORK}/t6.log" "QEMU-VM"

# ── T7: $0-Fallback für Flags (Einzeiler-Grube 8) ────────────────────────────
echo ""
echo "── T7: \$0-Fallback (bash -c \"\$(wget …)\" --status) ──"
# T6 hat nichts zerstört (Abbruch vor CT-Handling); frischer CT für Status:
reset_state
bash "${REPO}/install/openpdfstudio.sh" < /dev/null > "${WORK}/t7-install.log" 2>&1 \
    || { echo "  FAIL: Basis-Install für T7" >&2; FAIL=$((FAIL+1)); }
# Exakte Reproduktion des Einzeilers: Script-INHALT als String an bash -c,
# Flag dahinter → Flag landet in $0 (nicht $1!)
if bash -c "$(cat "${REPO}/install/openpdfstudio.sh")" --status < /dev/null > "${WORK}/t7.log" 2>&1; then
    check "T7: \$0='--status' wird erkannt (Exit 0)" true
else
    check "T7: \$0='--status' wird erkannt (Exit 0)" false
    tail -n 30 "${WORK}/t7.log" >&2 || true
fi
assert_contains "T7: Status-Ausgabe vorhanden" "${WORK}/t7.log" "CT-Status"

if bash -c "$(cat "${REPO}/install/openpdfstudio.sh")" --uninstall < /dev/null > "${WORK}/t7b.log" 2>&1; then
    check "T7: \$0='--uninstall' wird erkannt (Exit 0)" true
else
    check "T7: \$0='--uninstall' wird erkannt (Exit 0)" false
    tail -n 30 "${WORK}/t7b.log" >&2 || true
fi
assert_contains "T7: Deinstall-Meldung"        "${WORK}/t7b.log" "gelöscht"
check "T7: CT nach Uninstall weg"              test ! -d "${STATE}/pct-state/105"

# ── T8: --help ───────────────────────────────────────────────────────────────
echo ""
echo "── T8: Hilfe ──"
if bash "${REPO}/install/openpdfstudio.sh" --help < /dev/null > "${WORK}/t8.log" 2>&1; then
    check "T8: --help Exit 0" true
else
    check "T8: --help Exit 0" false
fi
assert_contains "T8: Hilfe listet Modi" "${WORK}/t8.log" "--uninstall"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " Ergebnis: ${PASS} PASS, ${FAIL} FAIL"
if (( FAIL > 0 )); then
    printf '  ✘ %s\n' "${FAILED_LABELS[@]}"
    echo " Logs: ${WORK}"
    echo "════════════════════════════════════════════════════════"
    exit 1
fi
echo " Logs: ${WORK}"
echo "════════════════════════════════════════════════════════"
exit 0
