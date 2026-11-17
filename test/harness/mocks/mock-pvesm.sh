#!/usr/bin/env bash
# Mock pvesm — Storage-Status mit vztmpl-fähigem 'local'.
set -uo pipefail
sub="${1:-}"; shift || true
case "$sub" in
    status)
        cat <<'EOF'
Name          Type        Content           Disk  Used   Avail
local         dir         vztmpl,iso,snip   468G  368G    77G
local-lvm     lvmthin     images,rootdir    468G  368G    77G
EOF
        exit 0
        ;;
esac
exit 2
