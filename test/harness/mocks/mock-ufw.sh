#!/usr/bin/env bash
# Mock ufw — inaktiv (Standard in LXC-Template).
case "${1:-}" in
    status) echo "Status: inactive"; exit 0 ;;
esac
exit 2
