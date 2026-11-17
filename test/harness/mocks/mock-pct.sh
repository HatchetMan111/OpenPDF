#!/usr/bin/env bash
# Mock pct — Zustand in $HARNESS_STATE/pct-state/<id>/ (state-Datei).
# Die Sandbox (/var, /etc tmpfs) IST der CT — push/exec arbeiten direkt darauf.
set -uo pipefail
STATE="${HARNESS_STATE:?HARNESS_STATE fehlt}"
CTROOT="${STATE}/pct-state"

sub="${1:-}"; shift || true

case "$sub" in
    list)
        echo "VMID Status     Name"
        for d in "${CTROOT}"/*/; do
            [[ -d "$d" ]] || continue
            id=$(basename "$d")
            st=$(cat "${d}/state" 2>/dev/null || echo stopped)
            echo "${id}  ${st}  open-pdf-studio"
        done
        exit 0
        ;;
    config)
        id="${1:-}"
        [[ -d "${CTROOT}/${id}" ]] || exit 1
        echo "hostname: open-pdf-studio"
        echo "cores: 2"
        echo "memory: 2048"
        echo "onboot: 1"
        echo "unprivileged: 1"
        exit 0
        ;;
    status)
        id="${1:-}"
        [[ -d "${CTROOT}/${id}" ]] || { echo "400 The container \"${id}\" does not exist" >&2; exit 255; }
        echo "status: $(cat "${CTROOT}/${id}/state" 2>/dev/null || echo stopped)"
        exit 0
        ;;
    create)
        id="${1:-}"; shift || true
        [[ -n "${id}" ]] || exit 2
        mkdir -p "${CTROOT}/${id}"
        echo stopped > "${CTROOT}/${id}/state"
        # --hostname merken (für die Sicherheitsnetz-Checks)
        while (( $# > 0 )); do
            if [[ "${1:-}" == "--hostname" ]]; then echo "$2" > "${CTROOT}/${id}/hostname"; fi
            shift 2 || break
        done
        exit 0
        ;;
    start)
        id="${1:-}"
        [[ -d "${CTROOT}/${id}" ]] || { echo "400 The container \"${id}\" does not exist" >&2; exit 255; }
        echo running > "${CTROOT}/${id}/state"
        exit 0
        ;;
    stop|suspend)
        id="${1:-}"
        [[ -d "${CTROOT}/${id}" ]] && echo stopped > "${CTROOT}/${id}/state"
        exit 0
        ;;
    exec)
        id="${1:-}"; shift || true
        [[ -d "${CTROOT}/${id}" ]] || { echo "400 The container \"${id}\" does not exist" >&2; exit 255; }
        [[ "${1:-}" == "--" ]] && shift
        # Sandbox-FS = CT-FS: Befehl mit ORIGINAL-Argumentgrenzen ausführen
        # (KEIN eval — das würde 'bash -c hostname -I' zu $0='--I' verzerren)
        exec "$@"
        ;;
    push)
        id="${1:-}"; shift || true
        [[ -d "${CTROOT}/${id}" ]] || { echo "400 The container \"${id}\" does not exist" >&2; exit 255; }
        src="${1:-}"; dst="${2:-}"
        [[ -n "${src}" && -n "${dst}" ]] || exit 2
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        exit 0
        ;;
    set)
        # --description / --tags / --nameserver / --onboot … : nur registrieren
        exit 0
        ;;
    destroy)
        id="${1:-}"; shift || true
        [[ "$1" == "--purge" ]] && shift || true
        rm -rf "${CTROOT}/${id}"
        exit 0
        ;;
    snapshot|resume|clone)
        exit 0
        ;;
    *)
        echo "mock-pct: unbekannter Subcommand '$sub'" >&2
        exit 2
        ;;
esac
