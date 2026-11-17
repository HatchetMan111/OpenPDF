#!/usr/bin/env bash
# Mock apt-get — installiert das nginx-Skeleton (Dirs + Default-Site-Symlink),
# damit das In-Container-Script eine echte Debian-nginx-Installation vorfindet.
set -uo pipefail
action="${1:-}"; shift || true
case "$action" in
    update|upgrade|install)
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/log/nginx
        [[ -f /etc/nginx/nginx.conf ]] || printf 'events {}\nhttp {\n    include /etc/nginx/mime.types;\n    include /etc/nginx/sites-enabled/*;\n}\n' > /etc/nginx/nginx.conf
        [[ -e /etc/nginx/sites-enabled/default ]] || ln -sf ../sites-available/default /etc/nginx/sites-enabled/default
        printf 'server {\n    listen 80 default_server;\n    server_name _;\n    return 404;\n}\n' \
            > /etc/nginx/sites-available/default
        exit 0
        ;;
esac
exit 2
