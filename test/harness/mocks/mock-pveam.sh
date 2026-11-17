#!/usr/bin/env bash
# Mock pveam — Debian-13-Standard-Template vorhanden.
sub="${1:-}"; shift || true
case "$sub" in
    list)
        echo "local:vztmpl/debian-13-standard_13.2-1_amd64.tar.zst"
        exit 0
        ;;
    available)
        echo "system          debian-13-standard_13.2-1_amd64.tar.zst"
        exit 0
        ;;
    update)
        exit 0
        ;;
esac
exit 2
