#!/usr/bin/env bash
# Mock qm — nur für die qemu-Erkennung in guest_type(): wenn HARNESS_QEMU_ID
# gesetzt ist und zur angefragten VMID passt, antwortet die VM-Konfig.
sub="${1:-}"; shift || true
case "$sub" in
    config)
        if [[ "${HARNESS_QEMU_ID:-}" == "${1:-}" ]]; then
            echo "name: collide-vm"
            echo "cores: 1"
            exit 0
        fi
        exit 1
        ;;
esac
exit 2
