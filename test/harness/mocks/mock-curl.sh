#!/usr/bin/env bash
# Mock curl — die Sandbox /var/www/open-pdf-studio IST die Web-UI:
#   * -w '%{http_code}' → '200' (OHNE Zeilenumbruch — Grube 15) bzw. '000'
#   * plain GET         → Inhalt der deployten index.html
#   * -I / -v           → minimale 200-Antwort
set -uo pipefail
INDEX="/var/www/open-pdf-studio/index.html"
print_code() {
    if [[ -f "$INDEX" ]]; then
        printf '200'
    else
        printf '000'
    fi
}

want_code=0; want_head=0; want_verbose=0; url=""
prev=""
for a in "$@"; do
    case "$a" in
        -w) prev="w" ;;
        -w*) want_code=1 ;;
        -I) want_head=1 ;;
        -v) want_verbose=1 ;;
        -s|-sS|-S) ;;
        -o) prev="o" ;;
        -m|-H|-X|-d|--data|--header) prev="" ;;
        -*) prev="" ;;
        *)
            if [[ "$prev" == "w" ]]; then
                if [[ "$a" == *http_code* ]]; then want_code=1; fi
                prev=""
            elif [[ "$prev" == "o" ]]; then prev=""
            else url="$a"
            fi
            ;;
    esac
done

if (( want_code )); then
    print_code
    exit 0
fi
if (( want_head )); then
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n'
    exit 0
fi
if (( want_verbose )); then
    printf '* Trying 127.0.0.1...\n< HTTP/1.1 200 OK\n< Content-Type: text/html\n'
    exit 0
fi
if [[ -f "$INDEX" ]]; then
    cat "$INDEX"
    exit 0
fi
printf '<!DOCTYPE html><html><head><title>404</title></head></html>\n'
exit 0
