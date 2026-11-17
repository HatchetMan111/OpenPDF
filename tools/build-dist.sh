#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tools/build-dist.sh — baut die Web-Unit von Open PDF Studio (Upstream:
# OpenAEC-Foundation/open-pdf-studio) und aktualisiert ./dist im Installer-Repo.
#
# Die Browser-Version ist ein rein statischer Vite-Build (--mode hosted) —
# exakt wie die Upstream-CI (.github/workflows/live.yml). Kein Rust/CMake
# nötig (das ist nur für die Tauri-Desktop-Shell).
#
# Aufruf (auf einer Maschine mit Internet, ohne Root):
#   bash tools/build-dist.sh                 # benutzt VERSION als Ref
#   UPSTREAM_REF=v2026.48.0 bash tools/build-dist.sh
#
# Ergebnisse:
#   - dist/ im Repo-Root ersetzt (für den Installer: „dist committed, kein Node im CT")
#   - VERSION aktualisiert (wenn UPSTREAM_REF gesetzt war)
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_URL="https://github.com/OpenAEC-Foundation/open-pdf-studio.git"
VERSION_REF="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || true)"
UPSTREAM_REF="${UPSTREAM_REF:-${VERSION_REF:-v2026.47.0}}"
UPSTREAM_DIR="${REPO_ROOT}/.upstream/open-pdf-studio"
NODE_DIR="${REPO_ROOT}/.upstream/node"
NODE_VERSION="22.23.5"   # >= 22.12: von vite 7.x + pdfjs-dist gefordert

say()  { printf '\033[1;32m✔\033[0m %s\n' "$1"; }
info() { printf '\033[1;33mInfo:\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# ── Node 22 lokal (fasst Phils globale Installation NICHT an) ────────────────
if [[ ! -x "${NODE_DIR}/bin/node" ]]; then
    info "Lade Node ${NODE_VERSION} nach .upstream/node"
    mkdir -p "${REPO_ROOT}/.upstream"
    curl -fsSLo "${REPO_ROOT}/.upstream/node.tar.xz" \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
    tar -xf "${REPO_ROOT}/.upstream/node.tar.xz" -C "${REPO_ROOT}/.upstream"
    mv "${REPO_ROOT}/.upstream/node-v${NODE_VERSION}-linux-x64" "${NODE_DIR}"
    rm -f "${REPO_ROOT}/.upstream/node.tar.xz"
fi
export PATH="${NODE_DIR}/bin:${PATH}"
[[ "$(node --version)" == "v${NODE_VERSION}"* ]] || die "Node v${NODE_VERSION} erwartet, gefunden: $(node --version)"
say "Node $(node --version)"

# ── Sparse-Checkout des Upstream-Tags (nur App-Ordner + mcp-stdio) ───────────
if [[ -d "${UPSTREAM_DIR}/.git" ]]; then
    info "Upstream-Checkout vorhanden — refresh auf ${UPSTREAM_REF}"
    git -C "${UPSTREAM_DIR}" fetch --depth 1 origin "refs/tags/${UPSTREAM_REF}:refs/tags/${UPSTREAM_REF}" --force
    git -C "${UPSTREAM_DIR}" checkout --detach "${UPSTREAM_REF}"
else
    info "Klone ${UPSTREAM_URL} @ ${UPSTREAM_REF} (sparse: open-pdf-studio + mcp-stdio)"
    mkdir -p "${REPO_ROOT}/.upstream"
    git clone --depth 1 --filter=blob:none --sparse "${UPSTREAM_URL}" "${UPSTREAM_DIR}" 2>/dev/null \
        || git clone "${UPSTREAM_URL}" "${UPSTREAM_DIR}"
    git -C "${UPSTREAM_DIR}" fetch --depth 1 origin "refs/tags/${UPSTREAM_REF}:refs/tags/${UPSTREAM_REF}" --force
    git -C "${UPSTREAM_DIR}" checkout --detach "${UPSTREAM_REF}"
fi
git -C "${UPSTREAM_DIR}" sparse-checkout set open-pdf-studio mcp-stdio
say "Sparse-Checkout @ $(git -C "${UPSTREAM_DIR}" describe --tags)"

APP_DIR="${UPSTREAM_DIR}/open-pdf-studio"
[[ -f "${APP_DIR}/package.json" ]] || die "App-Ordner fehlt — Sparse-Checkout kaputt?"

# ── Build (vite --mode hosted = Web-Build, wie Upstream-CI) ──────────────────
cd "${APP_DIR}"
info "npm ci (Rust/CMake NICHT nötig — nur Node-Build)"
npm ci --no-audit --no-fund >/dev/null
info "vite build --mode hosted"
npm run build:hosted >/dev/null
say "Build fertig: $(du -sh dist | cut -f1), $(find dist -type f | wc -l) Dateien"

# ── dist ins Installer-Repo übernehmen ───────────────────────────────────────
rm -rf "${REPO_ROOT}/dist"
cp -r dist "${REPO_ROOT}/dist"
[[ -f "${REPO_ROOT}/dist/index.html" ]] || die "dist/index.html fehlt nach dem Kopieren"
grep -q "Open PDF Studio" "${REPO_ROOT}/dist/index.html" || die "dist/index.html trägt nicht den App-Titel?!"

# VERSION nur schreiben, wenn der Ref explizit vom Repo-Stand abweicht
# (Default-Lauf = Ref stammt aus VERSION → nichts ändern).
if [[ "${UPSTREAM_REF}" != "${VERSION_REF:-}" ]]; then
    printf '%s\n' "${UPSTREAM_REF}" > "${REPO_ROOT}/VERSION"
    say "VERSION -> ${UPSTREAM_REF}"
fi

say "dist/ im Repo aktualisiert (${REPO_ROOT}/dist)"
echo "  Nächste Schritte: git add dist VERSION && git commit && git push"
echo "  Danach im CT/Installer: einfach Installer re-run (lädt frisches dist)."
