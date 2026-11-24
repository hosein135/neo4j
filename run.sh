#!/usr/bin/env bash
# =============================================================================
# run.sh — Neo4j Community + movie graph + Django API + Next.js UI
#
# Same shape as ../librelane/run.sh: NixOS 25.05 packages from devops/flake.nix,
# then the app. This app does not use Postgres. Graph data lives in Neo4j.
#
# Usage:
#   ./run.sh                # Neo4j, movie load, API :8000, UI :3000
#   ./run.sh --prep-only    # Nix env, Neo4j, and the movie graph only
#   ./run.sh --force-setup  # rebuild the cached Nix env, then start
#   ./run.sh --build        # production Next.js build + next start
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[neo4j-movies]${NC} $*"; }
warn()  { echo -e "${YELLOW}[neo4j-movies]${NC} $*"; }
error() { echo -e "${RED}[neo4j-movies]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[neo4j-movies]${NC} $*"; }

sanitize_shell_file() {
    local f="$1"
    [ -f "${f}" ] || return 0
    if ! grep -q $'\r' "${f}" 2>/dev/null; then
        return 0
    fi
    warn "Fixing Windows (CRLF) line endings in $(basename "${f}") ..."
    local tmp="${f}.lf.$$"
    tr -d '\r' < "${f}" > "${tmp}" && mv -f "${tmp}" "${f}"
}

sanitize_shell_file "${BASH_SOURCE[0]}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
FLAKE_DIR="${SCRIPT_DIR}/devops"
READY_MARKER="${SCRIPT_DIR}/.neo4j-nix-ready"
SYSTEM_CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/neo4j-movies"
NIX_PIN_VERSION="2.28.5"
NIX_INSTALL_URL="https://releases.nixos.org/nix/nix-${NIX_PIN_VERSION}/install"

FORCE_SETUP=false
PREP_ONLY=false
DO_LAUNCH=false
FRONTEND_BUILD=false
CLEANING_UP=false
INTERRUPTED=false
FRONTEND_PID=""
BACKEND_PID=""
NEO4J_PID=""
PORT="${PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            cat <<'EOF'
Neo4j movie explorer — setup or start (Linux / macOS / WSL).

  ./run.sh              Neo4j + movie graph + Django API (:8000) + Next.js (:3000)
  ./run.sh --prep-only  Nix env, Neo4j, and the movie graph
  ./run.sh --force-setup
  ./run.sh --build      production Next.js build + next start

Nix 2.28.5 is installed if the nix command is missing. An existing Nix is reused.
Packages come from devops/flake.nix (nixpkgs 25.05): neo4j and python313Packages.neo4j.
There is no Postgres service.
EOF
            exit 0 ;;
        --__launch)    DO_LAUNCH=true ;;
        --force-setup) FORCE_SETUP=true ;;
        --prep-only)   PREP_ONLY=true ;;
        --build)       FRONTEND_BUILD=true ;;
        *)
            warn "Unknown argument: $arg" ;;
    esac
done

source_nix_profile() {
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        # shellcheck source=/dev/null
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    elif [ -f "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]; then
        # shellcheck source=/dev/null
        . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
    elif [ -f /etc/profile.d/nix.sh ]; then
        # shellcheck source=/dev/null
        . /etc/profile.d/nix.sh
    fi
}

enable_flakes() {
    export NIX_PATH=""
    export NIX_CONFIG="${NIX_CONFIG:-}
experimental-features = nix-command flakes
warn-dirty = false
"
}

nix_cmd() {
    "${NIX_BIN:-nix}" --accept-flake-config "$@"
}

file_hash() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${f}" | awk '{print $1}'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${f}" | awk '{print $NF}'
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${f}"
        return 0
    fi
    error "Need sha256sum, openssl, or python3 to cache the Nix env."
    return 1
}

init_cache_paths() {
    local key
    key="$(file_hash "${FLAKE_DIR}/flake.nix")-$(file_hash "${FLAKE_DIR}/web-shell.nix")"
    SYSTEM_CACHE="${SYSTEM_CACHE_ROOT}/${key}"
    SYSTEM_PROFILE="${SYSTEM_CACHE}/profile"
    SYSTEM_DEVENV="${SYSTEM_CACHE}/devenv.sh"
    SYSTEM_READY="${SYSTEM_CACHE}/ready"
    SYSTEM_LOCK="${SYSTEM_CACHE}/flake.lock"
}

check_host_os() {
    case "$(uname -s)" in
        Linux|Darwin) ;;
        *)
            error "Unsupported OS: $(uname -s). Use Linux, macOS, or WSL."
            return 1
            ;;
    esac
}

ensure_nix() {
    source_nix_profile || true
    enable_flakes
    if command -v nix >/dev/null 2>&1; then
        NIX_BIN="$(command -v nix)"
        info "Nix: $("${NIX_BIN}" --version 2>/dev/null | head -n 1)"
        return 0
    fi
    step "Nix not found — installing Nix ${NIX_PIN_VERSION} ..."
    command -v curl >/dev/null 2>&1 || {
        error "curl is required to install Nix."
        return 1
    }
    local installer="${TMPDIR:-/tmp}/nix-${NIX_PIN_VERSION}-install.sh"
    curl -fsSL "${NIX_INSTALL_URL}" -o "${installer}"
    sh "${installer}" --no-daemon --yes --no-channel-add
    rm -f "${installer}"
    source_nix_profile || true
    command -v nix >/dev/null 2>&1 || {
        error "Nix installed but not on PATH. Open a new terminal and run ./run.sh again."
        return 1
    }
    NIX_BIN="$(command -v nix)"
    info "Nix installed: $("${NIX_BIN}" --version 2>/dev/null | head -n 1)"
}

port_busy() {
    local port="$1"
    python -c 'import socket,sys
s=socket.socket(); s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except Exception:
    sys.exit(1)
else:
    sys.exit(0)' "${port}" >/dev/null 2>&1
}

prefer_unix_path() {
    local cleaned="" part oldifs
    oldifs="${IFS}"
    IFS=':'
    # shellcheck disable=SC2086
    for part in ${PATH}; do
        case "${part}" in
            /mnt/[a-zA-Z]/*|"") continue ;;
        esac
        if [ -z "${cleaned}" ]; then
            cleaned="${part}"
        else
            cleaned="${cleaned}:${part}"
        fi
    done
    IFS="${oldifs}"
    export PATH="${cleaned}"
    hash -r 2>/dev/null || true
}

choose_data_dir() {
    if [ -n "${NEO4J_MOVIES_DATA_DIR:-}" ]; then
        mkdir -p "${NEO4J_MOVIES_DATA_DIR}"
        return 0
    fi
    case "${SCRIPT_DIR}" in
        /mnt/*)
            export NEO4J_MOVIES_DATA_DIR="${HOME}/.local/share/neo4j-movies"
            ;;
        *)
            export NEO4J_MOVIES_DATA_DIR="${SCRIPT_DIR}/.neo4j-data"
            ;;
    esac
    mkdir -p "${NEO4J_MOVIES_DATA_DIR}"
}

prepare_neo4j_home() {
    local home="${NEO4J_MOVIES_DATA_DIR}/home"
    if [ -z "${NEO4J_DIST:-}" ] || [ ! -d "${NEO4J_DIST}/lib" ]; then
        error "NEO4J_DIST is missing. Start the app with ./run.sh so the Nix shell is loaded."
        exit 1
    fi
    mkdir -p "${home}/conf" "${home}/data" "${home}/logs" "${home}/run" \
        "${home}/plugins" "${home}/import" "${home}/certificates"
    ln -sfn "${NEO4J_DIST}/lib" "${home}/lib"
    if [ -d "${NEO4J_DIST}/licenses" ]; then
        ln -sfn "${NEO4J_DIST}/licenses" "${home}/licenses"
    fi
    if [ -d "${NEO4J_DIST}/labs" ]; then
        ln -sfn "${NEO4J_DIST}/labs" "${home}/labs"
    fi
    if [ -d "${NEO4J_DIST}/products" ]; then
        ln -sfn "${NEO4J_DIST}/products" "${home}/products"
    fi
    if [ ! -f "${NEO4J_DIST}/conf/neo4j.conf" ]; then
        error "Neo4j package has no conf/neo4j.conf under ${NEO4J_DIST}"
        exit 1
    fi
    # The packaged config is mode 0444. Copy it into a new writable file.
    rm -f "${home}/conf/neo4j.conf"
    cat "${NEO4J_DIST}/conf/neo4j.conf" - > "${home}/conf/neo4j.conf" <<EOF

# Local movie explorer. Appended by run.sh so these values win.
server.default_listen_address=127.0.0.1
server.http.listen_address=:7474
server.bolt.listen_address=:7687
server.bolt.tls_level=DISABLED
server.directories.data=${home}/data
server.directories.logs=${home}/logs
server.directories.run=${home}/run
server.directories.plugins=${home}/plugins
server.directories.lib=${NEO4J_DIST}/lib
server.memory.heap.initial_size=256m
server.memory.heap.max_size=512m
server.memory.pagecache.size=128m
dbms.security.auth_enabled=true
EOF
    chmod 700 "${home}" 2>/dev/null || true
    chmod 600 "${home}/conf/neo4j.conf" 2>/dev/null || true
    export NEO4J_HOME="${home}"
    export NEO4J_CONF="${home}/conf"
}

stop_pid() {
    local pid="$1"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || return 0
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 0.4
    kill -KILL "${pid}" 2>/dev/null || true
}

shutdown_stack() {
    local code=$?
    if [ "${CLEANING_UP}" = true ]; then
        return 0
    fi
    CLEANING_UP=true
    trap - INT TERM EXIT
    echo ""
    step "Stopping Neo4j movie stack ..."
    stop_pid "${FRONTEND_PID}"
    stop_pid "${BACKEND_PID}"
    if [ -n "${NEO4J_PID:-}" ]; then
        stop_pid "${NEO4J_PID}"
    fi
    if [ -n "${NEO4J_HOME:-}" ] && command -v neo4j >/dev/null 2>&1; then
        neo4j stop >/dev/null 2>&1 || true
    fi
    info "Stopped."
    if [ "${INTERRUPTED}" = true ]; then
        exit 0
    fi
    exit "${code}"
}

wait_for_http() {
    local url="$1" label="$2" tries="${3:-60}" want="${4:-}"
    local i code
    for i in $(seq 1 "${tries}"); do
        code="$(curl -sS -o /dev/null -m 2 -w '%{http_code}' "${url}" 2>/dev/null || true)"
        if [ -n "${want}" ]; then
            [ "${code}" = "${want}" ] && return 0
        else
            case "${code}" in
                [1-5][0-9][0-9]) return 0 ;;
            esac
        fi
        sleep 1
    done
    error "${label} did not become ready at ${url}"
    return 1
}

ensure_initial_password() {
    local marker="${NEO4J_HOME}/.initial-password-set"
    local log="${NEO4J_MOVIES_DATA_DIR}/set-password.log"
    if [ -f "${marker}" ]; then
        return 0
    fi
    step "Setting the initial Neo4j password ..."
    if neo4j-admin dbms set-initial-password "${NEO4J_PASSWORD}" >"${log}" 2>&1; then
        touch "${marker}"
        return 0
    fi
    if grep -Eqi 'already|password was already' "${log}"; then
        info "Neo4j password is already initialized."
        touch "${marker}"
        return 0
    fi
    error "Could not set the Neo4j password. See ${log}"
    cat "${log}" >&2 || true
    exit 1
}

ensure_runnable_node() {
    if node -e 'process.exit(0)' >/dev/null 2>&1; then
        return 0
    fi
    # WSL1 rejects the Nix Node ELF. Next.js also respawns process.execPath, so a
    # dynamic-linker wrapper is not enough. Use the official Linux build of the
    # same Node version for the page only. Neo4j and Python stay on Nix.
    local version arch url tmp fallback real interp
    real="$(command -v node)"
    interp="$(grep -a -o '/nix/store/[^ ]*/ld-linux-x86-64.so.2' "${real}" | head -1 || true)"
    if [ -n "${interp}" ] && [ -x "${interp}" ]; then
        version="$("${interp}" "${real}" -v 2>/dev/null | tr -d 'v' || true)"
    fi
    if [ -z "${version}" ]; then
        version="22.20.0"
    fi
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        x86_64|amd64) arch="x64" ;;
        *)
            error "No runnable Node fallback for $(uname -m)."
            exit 1
            ;;
    esac
    fallback="${NEO4J_MOVIES_DATA_DIR}/node-fallback"
    if [ ! -x "${fallback}/bin/node" ]; then
        step "Nix Node cannot run on this host. Downloading the official Node ${version} build for the page."
        tmp="$(mktemp -d)"
        url="https://nodejs.org/dist/v${version}/node-v${version}-linux-${arch}.tar.gz"
        curl -fL --retry 3 -o "${tmp}/node.tar.gz" "${url}"
        tar -xzf "${tmp}/node.tar.gz" -C "${tmp}"
        rm -rf "${fallback}"
        mv "${tmp}/node-v${version}-linux-${arch}" "${fallback}"
        rm -rf "${tmp}"
    fi
    if ! "${fallback}/bin/node" -e 'process.exit(0)' >/dev/null 2>&1; then
        error "The Node fallback at ${fallback} cannot run."
        exit 1
    fi
    export PATH="${fallback}/bin:${PATH}"
    hash -r || true
    info "Using Node $(node -v) from ${fallback} so the page can start on this host."
}

start_neo4j() {
    local log="${NEO4J_MOVIES_DATA_DIR}/neo4j.console.log"
    step "Starting Neo4j Community on bolt://127.0.0.1:7687 ..."
    neo4j stop >/dev/null 2>&1 || true
    set -m
    neo4j console >"${log}" 2>&1 &
    NEO4J_PID=$!
    echo "${NEO4J_PID}" > "${NEO4J_MOVIES_DATA_DIR}/neo4j.pid"
    sleep 1
    if ! kill -0 "${NEO4J_PID}" 2>/dev/null; then
        error "Neo4j exited during startup. Last log lines:"
        tail -n 80 "${log}" >&2 || true
        exit 1
    fi
}

start_backend() {
    local log="${NEO4J_MOVIES_DATA_DIR}/backend.log"
    step "Starting Django API on :${BACKEND_PORT} ..."
    NEO4J_MOVIES_WEB_HOST=127.0.0.1 NEO4J_MOVIES_WEB_PORT="${BACKEND_PORT}" \
        neo4j-movies-web >"${log}" 2>&1 &
    BACKEND_PID=$!
    echo "${BACKEND_PID}" > "${NEO4J_MOVIES_DATA_DIR}/backend.pid"
    if wait_for_http "http://127.0.0.1:${BACKEND_PORT}/api/health" "Backend" 60 200; then
        info "Backend API: http://127.0.0.1:${BACKEND_PORT}"
        return 0
    fi
    error "Backend did not become ready. Last log lines:"
    tail -n 40 "${log}" >&2 || true
    exit 1
}

start_frontend() {
    local log="${NEO4J_MOVIES_DATA_DIR}/frontend.log"
    step "Starting Next.js on :${PORT} ..."
    cd "${SCRIPT_DIR}/frontend"
    if [ ! -d node_modules ]; then
        step "npm install (first time) ..."
        npm install
    fi
    case "${SCRIPT_DIR}" in
        /mnt/*)
            export WATCHPACK_POLLING=true
            export CHOKIDAR_USEPOLLING=true
            ;;
    esac
    if [ "${FRONTEND_BUILD}" = true ]; then
        step "Building the production UI ..."
        DJANGO_ORIGIN="http://127.0.0.1:${BACKEND_PORT}" npm run build
        DJANGO_ORIGIN="http://127.0.0.1:${BACKEND_PORT}" \
            npm run start -- --port "${PORT}" --hostname 127.0.0.1 \
            >"${log}" 2>&1 &
    else
        DJANGO_ORIGIN="http://127.0.0.1:${BACKEND_PORT}" \
            npm run dev -- --port "${PORT}" --hostname 127.0.0.1 \
            >"${log}" 2>&1 &
    fi
    FRONTEND_PID=$!
    echo "${FRONTEND_PID}" > "${NEO4J_MOVIES_DATA_DIR}/frontend.pid"
    cd "${SCRIPT_DIR}"
    if ! wait_for_http "http://127.0.0.1:${PORT}/" "Frontend" 180; then
        error "Frontend did not become ready. See ${log}"
        tail -n 40 "${log}" >&2 || true
        exit 1
    fi
}

launch_stack() {
    prefer_unix_path
    export NEO4J_MOVIES_ROOT="${SCRIPT_DIR}"
    choose_data_dir
    export NEO4J_URI="${NEO4J_URI:-bolt://127.0.0.1:7687}"
    export NEO4J_USER="${NEO4J_USER:-neo4j}"
    export NEO4J_PASSWORD="${NEO4J_PASSWORD:-neo4jadmin}"
    if port_busy "${BACKEND_PORT}"; then
        if [ "${BACKEND_PORT}" = "8000" ] && ! port_busy 8010; then
            warn "127.0.0.1:8000 is already in use. Django API will use :8010."
            BACKEND_PORT=8010
        else
            error "Backend port ${BACKEND_PORT} is already in use."
            exit 1
        fi
    fi
    if port_busy "${PORT}"; then
        error "Frontend port ${PORT} is already in use."
        exit 1
    fi
    export DJANGO_ORIGIN="http://127.0.0.1:${BACKEND_PORT}"
    export NEXT_ORIGIN="http://127.0.0.1:${PORT}"
    export NEO4J_MOVIES_WEB_PORT="${BACKEND_PORT}"
    ensure_runnable_node
    info "Python: $(command -v python)"
    info "Neo4j:  $(command -v neo4j)"
    info "Node:   $(command -v node)"
    info "Data:   ${NEO4J_MOVIES_DATA_DIR}"
    trap 'INTERRUPTED=true; shutdown_stack' INT
    trap 'INTERRUPTED=true; shutdown_stack' TERM
    trap shutdown_stack EXIT
    prepare_neo4j_home
    ensure_initial_password
    start_neo4j
    step "Loading the movie graph (first start can take a minute) ..."
    if ! neo4j-movies-manage load_movies; then
        error "Movie graph load failed. Last Neo4j log lines:"
        tail -n 40 "${NEO4J_MOVIES_DATA_DIR}/neo4j.console.log" >&2 || true
        tail -n 80 "${NEO4J_HOME}/logs/neo4j.log" >&2 || true
        exit 1
    fi
    if [ "${PREP_ONLY}" = true ]; then
        info "Prep-only — Neo4j is up and the movie graph is loaded."
        info "Bolt: bolt://127.0.0.1:7687"
        trap - INT TERM EXIT
        return 0
    fi
    start_backend
    start_frontend
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  App UI:  http://127.0.0.1:${PORT}"
    info "  API:     http://127.0.0.1:${BACKEND_PORT}"
    info "  Sample:  Who acted in The Matrix?"
    info "  Ctrl+C stops the page, the API, and Neo4j."
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    wait "${FRONTEND_PID}" || true
}

refresh_flake_lock() {
    warn "Updating devops/flake.lock for this Nix, then retrying."
    nix_cmd flake lock "${FLAKE_DIR}"
    mkdir -p "${SYSTEM_CACHE}"
    cp -f "${FLAKE_DIR}/flake.lock" "${SYSTEM_LOCK}"
}

realize_nix_shell() {
    local develop_err beat=0 st=0
    mkdir -p "${SYSTEM_CACHE}"
    develop_err="${SYSTEM_CACHE}/develop.err"
    source_nix_profile || true
    enable_flakes
    if [ ! -f "${FLAKE_DIR}/flake.lock" ] && [ -f "${SYSTEM_LOCK}" ]; then
        cp -f "${SYSTEM_LOCK}" "${FLAKE_DIR}/flake.lock"
    fi
    if [ ! -f "${FLAKE_DIR}/flake.lock" ]; then
        step "Locking nixpkgs 25.05 ..."
        nix_cmd flake lock "${FLAKE_DIR}"
    fi
    step "Fetching Nix packages (Neo4j Community, Python 3.13, Node.js) ..."
    info "The first fetch is large. A status line is printed every 20 seconds."
    (
        while true; do
            sleep 20
            info "Still fetching Nix packages ($(date -u +%H:%M:%S)). Leave this terminal open."
        done
    ) &
    beat=$!
    set +e
    nix_cmd develop "${FLAKE_DIR}" \
        --profile "${SYSTEM_PROFILE}" \
        --print-build-logs \
        --no-update-lock-file \
        --command true 2>&1 | tee "${develop_err}"
    st=${PIPESTATUS[0]}
    set -e
    kill "${beat}" 2>/dev/null || true
    wait "${beat}" 2>/dev/null || true
    if [ "${st}" -ne 0 ]; then
        if grep -qE 'lock file|no-update-lock-file|requires lock file changes' "${develop_err}"; then
            cat "${develop_err}"
            refresh_flake_lock
            nix_cmd develop "${FLAKE_DIR}" \
                --profile "${SYSTEM_PROFILE}" \
                --print-build-logs \
                --command true
        else
            cat "${develop_err}" >&2
            exit 1
        fi
    fi
    if ! nix_cmd print-dev-env "${FLAKE_DIR}" --offline --no-update-lock-file \
        > "${SYSTEM_DEVENV}.tmp" 2>"${develop_err}"; then
        warn "Saving the dev environment without --no-update-lock-file."
        nix_cmd print-dev-env "${FLAKE_DIR}" --offline > "${SYSTEM_DEVENV}.tmp"
    fi
    tr -d '\r' < "${SYSTEM_DEVENV}.tmp" > "${SYSTEM_DEVENV}"
    rm -f "${SYSTEM_DEVENV}.tmp"
    cp -f "${FLAKE_DIR}/flake.lock" "${SYSTEM_LOCK}"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${SYSTEM_READY}"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${READY_MARKER}"
    info "Nix packages cached at ${SYSTEM_CACHE}"
}

run_inside_nix() {
    step "Nix environment ready — starting Neo4j and the movie page ..."
    if [ -f "${SYSTEM_DEVENV}" ]; then
        info "Using cached Nix env"
        sanitize_shell_file "${SYSTEM_DEVENV}"
        (
            set +u
            # shellcheck disable=SC1090
            . "${SYSTEM_DEVENV}"
            cd "${SCRIPT_DIR}"
            exec bash "${SCRIPT_DIR}/run.sh" --__launch "$@"
        )
        return 0
    fi
    nix_cmd develop "${FLAKE_DIR}" --offline --command bash "${SCRIPT_DIR}/run.sh" --__launch "$@"
}

main() {
    if [ "${DO_LAUNCH}" = true ]; then
        launch_stack
        exit 0
    fi
    check_host_os || exit 1
    init_cache_paths
    ensure_nix || exit 1
    if [ "${FORCE_SETUP}" = true ]; then
        rm -rf "${SYSTEM_CACHE}" "${READY_MARKER}"
        init_cache_paths
    fi
    if [ ! -f "${SYSTEM_READY}" ] || [ ! -f "${SYSTEM_DEVENV}" ]; then
        realize_nix_shell
    else
        info "Nix environment already cached — starting."
        source_nix_profile || true
        enable_flakes
    fi
    if [ "${PREP_ONLY}" = true ]; then
        run_inside_nix --prep-only
        exit 0
    fi
    if [ "${FRONTEND_BUILD}" = true ]; then
        run_inside_nix --build
        exit 0
    fi
    run_inside_nix
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
