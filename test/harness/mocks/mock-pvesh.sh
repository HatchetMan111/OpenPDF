#!/usr/bin/env bash
# Mock pvesh — /cluster/resources (vmids aus $HARNESS_STATE/vmids.txt) und
# /storage (enthält local-lvm).
set -uo pipefail
STATE="${HARNESS_STATE:?HARNESS_STATE fehlt}"

sub="${1:-}"; shift || true
case "${1:-}" in
    /cluster/resources)
        out="["
        first=1
        while read -r id; do
            [[ -n "$id" ]] || continue
            if [[ "${HARNESS_QEMU_ID:-}" == "$id" ]]; then
                typ=qemu
            else
                typ=lxc
            fi
            if (( first )); then first=0; else out="${out},"; fi
            out="${out}{\"vmid\":${id},\"type\":\"${typ}\"}"
        done < "${STATE}/vmids.txt"
        echo "${out}]"
        exit 0
        ;;
    /storage)
        echo '[{"storage":"local","type":"dir"},{"storage":"local-lvm","type":"lvmthin"}]'
        exit 0
        ;;
esac
exit 2
