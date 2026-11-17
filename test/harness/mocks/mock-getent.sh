#!/usr/bin/env bash
# Mock getent — DNS-Auflösung im CT.
#   Normal: codeload.github.com löst sofort auf.
#   HARNESS_GETENT_FLAKY=1: Auflösung schlägt fehl, solange der Fallback
#   (1.1.1.1) NICHT in /etc/resolv.conf steht — simuliert den Live-Defekt aus
#   GitHub-Backup (DNS nach Boot kaputt, Fallback-Nameserver schreiben, chattr).
set -uo pipefail
sub="${1:-}"; shift || true

if [[ "$sub" == "hosts" ]]; then
    if [[ "${HARNESS_GETENT_FLAKY:-}" == "1" ]]; then
        if grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
            echo "93.184.216.34 codeload.github.com"
            exit 0
        fi
        exit 2
    fi
    echo "93.184.216.34 codeload.github.com"
    exit 0
fi
exit 2
