#!/usr/bin/env bash
# Helper script for local VDB development on Linux/macOS/WSL.
# Windows equivalent: scripts/run.ps1
#
#   ./scripts/run.sh setup      # first run: install deps + create database
#   ./scripts/run.sh dev        # run backend + frontend
#   ./scripts/run.sh help       # list all commands

set -euo pipefail

# Backend opens JSON files without an explicit encoding (matters under Git Bash on Windows)
export PYTHONUTF8=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND="$ROOT/frontend"
BACKEND="$ROOT/backend"
CARDS_UPDATE="$ROOT/misc/cards-update"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

assert_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "'$1' not found in PATH. $2" >&2; exit 1; }
}

assert_prerequisites() {
    assert_tool uv "Install it from https://docs.astral.sh/uv/"
    assert_tool npm "Install Node.js from https://nodejs.org/"
}

# --- Install -----------------------------------------------------------------

install_backend() {
    step "Installing backend dependencies (uv sync)"
    (cd "$BACKEND" && uv sync)
}

install_frontend() {
    step "Installing frontend dependencies (npm install)"
    # xlsx is fetched from cdn.sheetjs.com; npm 12+ refuses remote tarballs by default
    (cd "$FRONTEND" && npm install --allow-remote=all)
}

update_db() {
    step "Generating and applying database migrations"
    (cd "$BACKEND" && uv run flask db migrate && uv run flask db upgrade)
}

init_db() {
    # migrations/ is gitignored, so it must be created locally on first run
    if [ ! -d "$BACKEND/migrations" ]; then
        step "Initializing migrations"
        (cd "$BACKEND" && uv run flask db init)
    fi
    update_db
}

random_key() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 32; }

create_env() {
    [ -f "$BACKEND/.env" ] && return
    step "Creating backend/.env with random secrets"
    printf 'SECRET_KEY = "%s"\nPLAYTEST_KEY = "%s"\n' "$(random_key)" "$(random_key)" >"$BACKEND/.env"
}

# --- Run ---------------------------------------------------------------------

start_backend() {
    step "Starting backend on http://localhost:5000"
    cd "$BACKEND" && uv run flask --debug run
}

start_frontend() {
    step "Starting frontend on http://localhost:5173"
    cd "$FRONTEND" && npm start
}

start_dev() {
    step "Starting backend in background (http://localhost:5000)"
    (cd "$BACKEND" && exec uv run flask --debug run) &
    local backend_pid=$!
    trap 'kill "$backend_pid" 2>/dev/null || true' EXIT INT TERM
    step "Starting frontend on http://localhost:5173"
    (cd "$FRONTEND" && npm start)
}

# --- Quality -----------------------------------------------------------------

lint() {
    # Run both linters even if the first one fails
    local failed=0
    step "Frontend: biome check"
    (cd "$FRONTEND" && npm run check) || failed=1
    step "Backend: ruff check"
    (cd "$BACKEND" && uvx ruff check .) || failed=1
    if [ "$failed" -ne 0 ]; then
        echo "Lint found issues (run './scripts/run.sh fix' to auto-fix some)" >&2
        exit 1
    fi
}

fix() {
    step "Frontend: biome check --write"
    (cd "$FRONTEND" && npm run fix)
    step "Backend: ruff check --fix + ruff format"
    (cd "$BACKEND" && uvx ruff check --fix . && uvx ruff format .)
}

# --- Card data ---------------------------------------------------------------

update_cards() {
    step "Installing cards-update dependencies"
    (cd "$CARDS_UPDATE" && uv sync && npm install)
    step "Downloading upstream resources"
    (cd "$CARDS_UPDATE" && ./download_resources.sh)
    step "Generating resources"
    (cd "$CARDS_UPDATE" && ./create_resources.sh)
}

# --- Help --------------------------------------------------------------------

show_help() {
    cat <<'EOF'
Usage: ./scripts/run.sh <command> [args]

Setup
  setup           Install all deps, create backend/.env and the database
  install         Install backend (uv) and frontend (npm) dependencies
  db              Create migrations folder if needed, then migrate + upgrade
  db-upgrade      Generate and apply migrations after model changes

Run
  dev             Backend in background + frontend (http://localhost:5173)
  backend         Flask dev server only (http://localhost:5000)
  frontend        Vite dev server only (http://localhost:5173)

Build
  build           Production build of the frontend (frontend/dist)
  preview         Serve the production build locally
  analyze         Bundle size visualizer

Quality
  lint            Biome check (frontend) + ruff check (backend)
  fix             Auto-fix/format with biome and ruff

Maintenance
  update-cards    Download upstream card data and regenerate resources
  password <account> [password|x]   Change a user password (x = random)
  playtest-admin <account>          Toggle playtest admin status
  clean           Remove node_modules, .venv, dist (keeps app.db)
EOF
}

# --- Dispatch ----------------------------------------------------------------

cmd="${1:-help}"
shift || true

case "$cmd" in
    setup)
        assert_prerequisites
        install_backend
        install_frontend
        create_env
        init_db
        step "Done. Run './scripts/run.sh dev' to start."
        ;;
    install) assert_prerequisites; install_backend; install_frontend ;;
    db) init_db ;;
    db-upgrade) update_db ;;
    dev) start_dev ;;
    backend) start_backend ;;
    frontend) start_frontend ;;
    build) step "Building frontend"; cd "$FRONTEND" && npm run build ;;
    preview) cd "$FRONTEND" && npx vite preview ;;
    analyze) cd "$FRONTEND" && npm run analyze ;;
    lint) lint ;;
    fix) fix ;;
    update-cards) update_cards ;;
    password)
        [ $# -ge 1 ] || { echo "Usage: ./scripts/run.sh password <account> [password|x]" >&2; exit 1; }
        cd "$BACKEND" && uv run change_password.py "$@"
        ;;
    playtest-admin)
        [ $# -ge 1 ] || { echo "Usage: ./scripts/run.sh playtest-admin <account>" >&2; exit 1; }
        cd "$BACKEND" && uv run change_playtest_admin.py "$@"
        ;;
    clean)
        step "Removing build artifacts and dependencies"
        rm -rf "$FRONTEND/node_modules" "$FRONTEND/dist" "$BACKEND/.venv" \
            "$CARDS_UPDATE/node_modules" "$CARDS_UPDATE/.venv"
        ;;
    *) show_help ;;
esac
