#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run.sh — Eintrittspunkt des Mock-Harness.
#
# Läuft die gesamte Suite in `unshare -rm` (User+Mount-Namespace → EUID 0,
# ohne sudo) und legt tmpfs über /etc und /var, damit der Installer im
# Sandbox-Dateisystem arbeitet und NICHTS auf dem echten System landet.
#
# Nutzung:  bash test/harness/run.sh
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v unshare >/dev/null 2>&1; then
    echo "ERROR: unshare fehlt — Harness kann nicht laufen." >&2
    exit 1
fi

# Kernstück: neuer User+Mount-Namespace, wir werden root NUR dort.
exec unshare -rm bash "${HERE}/runner-inner.sh"
