#!/usr/bin/env bash
# Mock systemctl — nginx-Service-State als Marker-Datei:
#   $HARNESS_STATE/systemctl-nginx-active → aktiv
set -uo pipefail
STATE="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MARKER="${STATE}/systemctl-nginx-active"
action="${1:-}"; shift || true
unit="${1:-}"

case "$action" in
    is-active)
        if [[ "$unit" == "nginx" && -f "$MARKER" ]]; then
            echo "active"
            exit 0
        fi
        echo "inactive"
        exit 3
        ;;
    restart|start)
        if [[ "$unit" == "nginx" ]]; then
            printf '%s\n' "$(date '+%s')" > "$MARKER"
        fi
        exit 0
        ;;
    enable|disable|daemon-reload)
        exit 0
        ;;
    status)
        if [[ -f "$MARKER" ]]; then
            echo "● nginx.service - A high performance web server (mock)"
            echo "   Loaded: loaded (/lib/systemd/system/nginx.service; enabled)"
            echo "   Active: active (running)"
        else
            echo "○ nginx.service (mock)"
            echo "   Active: inactive"
        fi
        exit 0
        ;;
esac
exit 2
