#!/usr/bin/env bash
# Mock wget — bedient die Installer-Downloads aus dem lokalen Repo/Fixture:
#   * .../install/openpdfstudio-install.sh → Repo-Datei
#   * .../systemd/nginx-openpdfstudio.conf → Repo-Datei
#   * codeload.github.com/…                → dist-Fixture-Tarball
set -uo pipefail
REPO="${HARNESS_REPO:?HARNESS_REPO fehlt}"
TARBALL="${HARNESS_TARBALL:?HARNESS_TARBALL fehlt}"

out=""
url=""
prev=""
for a in "$@"; do
    case "$a" in
        -O) prev="O" ;;
        -O*) out="${a#-O}" ;;
        -*) prev="" ;;
        *)
            if [[ "$prev" == "O" ]]; then out="$a"; prev=""; else url="$a"; fi
            ;;
    esac
done
[[ -n "$out" && -n "$url" ]] || exit 2

case "$url" in
    *codeload.github.com*|*tar.gz*)
        cp "$TARBALL" "$out"
        exit 0
        ;;
    */install/openpdfstudio-install.sh)
        cp "${REPO}/install/openpdfstudio-install.sh" "$out"
        exit 0
        ;;
    */systemd/nginx-openpdfstudio.conf)
        cp "${REPO}/systemd/nginx-openpdfstudio.conf" "$out"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
