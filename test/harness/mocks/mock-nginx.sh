#!/usr/bin/env bash
# Mock nginx — -v (Versionszeile) und -t (Konfig-Test, prüft dass die
# vHost-Datei existiert, ansonsten Fehler wie das echte nginx).
set -uo pipefail
case "${1:-}" in
    -v)
        echo "nginx version: nginx/1.26.3 (mock)"
        exit 0
        ;;
    -t)
        if [[ -f /etc/nginx/sites-available/open-pdf-studio.conf ]]; then
            echo "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok"
            echo "nginx: configuration file /etc/nginx/nginx.conf test is successful"
            exit 0
        fi
        echo "nginx: [emerg] open() /etc/nginx/nginx.conf failed (mock)" >&2
        exit 1
        ;;
esac
exit 2
