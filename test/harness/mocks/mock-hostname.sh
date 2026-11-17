#!/usr/bin/env bash
# Mock hostname — liefert die gemockte CT-IP.
if [[ "${1:-}" == "-I" ]]; then
    echo "10.120.1.234"
    exit 0
fi
echo "opds-harness-ct"
exit 0
