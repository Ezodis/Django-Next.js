#!/bin/bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║  dev.sh — Cross-platform dev launcher (macOS · Linux · Windows)             ║
# ╠═════════════════════════════════════════════════════════════════════════════╣
# ║  macOS prerequisite: Install Xcode from the App Store, then:                ║
# ║    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer          ║
# ╠═════════════════════════════════════════════════════════════════════════════╣
# ║  USAGE                                                                      ║
# ║    ./dev.sh                      Start everything                           ║
# ║                                    • Tunnel starts if internet available    ║
# ║                                    • Falls back to localhost automatically  ║
# ║                                    • Emulators/simulators always work       ║
# ║    ./dev.sh android              Start Android emulator + install apps      ║
# ║    ./dev.sh ios                  Install cached iOS builds/IPAs on simulator║
# ║    ./dev.sh qr [app-name]        Show QR codes for mobile apps              ║
# ║                                    • No app name = show all apps            ║
# ║                                    • With app name = open in new terminal   ║
# ║                                                                             ║
# ║    ./dev.sh eas whoami           Show current EAS account                   ║
# ║    ./dev.sh eas login            Log in to EAS interactively                ║
# ║    ./dev.sh eas logout           Log out from EAS                           ║
# ║                                                                             ║
# ║    ./dev.sh build <app> [android|ios|watchos] [development|production] [local]
# ║    ./dev.sh watchos <app> [--simulator <UDID>]  Install watch simulator app
# ║      watchos requires local builds on macOS; no Metro runtime or EAS
# ║    ./dev.sh build-all [android|ios] [development|production] [testflight]   ║
# ║                                    Build all mobile apps in parallel        ║
# ║                                    Add 'testflight' to auto-submit to TF    ║
# ║    ./dev.sh release [android|ios] setup     Generate keystores/credentials  ║
# ║    ./dev.sh release [android|ios] <local>   Build AABs/IPAs (EAS default)   ║
# ║                                                                             ║
# ║    ./dev.sh logs                 Follow logs for all running containers     ║
# ║    ./dev.sh stop                 Stop all containers (keep images/volumes)  ║
# ║    ./dev.sh down                 Stop + deep clean (images, volumes, cache) ║
# ║                                    • Stops tunnel too                        ║
# ║    ./dev.sh down android         Wipe Android emulator back to factory      ║
# ║                                    • Kills emulator, deletes AVD data       ║
# ║                                    • Next ./dev.sh android starts fresh     ║
# ║    ./dev.sh down all             Stop + deep clean ALL projects + delete VM ║
# ║                                    • Stops tunnel too                        ║
# ║    ./dev.sh setup                Install all dependencies                   ║
# ║    ./dev.sh build                Build Podman images only                   ║
# ║    ./dev.sh up                   Start core + mobile services               ║
# ║    ./dev.sh core                 Start core services only (no mobile)       ║
# ║    ./dev.sh expose               Prepare access, keep or assign a tunnel  ║
# ║    ./dev.sh mobile               Start only mobile services                 ║
# ║    ./dev.sh status               Live status monitor (Ctrl+C to quit)      ║
# ║    ./dev.sh rebuild [svc]        Rebuild all services or a specific one     ║
# ║    ./dev.sh check [svc]          Check status of all services or one        ║
# ║    ./dev.sh adb-reverse          Port-forward for physical Android devices  ║
# ║    ./dev.sh verify-ios           Verify iOS networking configuration        ║
# ║    ./dev.sh init                 One-time scaffold                          ║
# ║    ./dev.sh disk                 Show disk usage breakdown                  ║
# ║                                                                             ║
# ║  BACKUP / RESTORE                                                           ║
# ║    ./dev.sh backup               Full snapshot (DB + media) → start/        ║
# ║    ./dev.sh backup db            DB-only backup (.sql.gz) → start/          ║
# ║      Saved to backend/backup/start/ (one file max — oldest removed)        ║
# ║      Commit that file → production auto-restores on next deploy             ║
# ║    ./dev.sh backup list          List all backups (start/ and local)        ║
# ║                                                                             ║
# ║  TEMPLATE SYNC                                                              ║
# ║    ./dev.sh sync                 Pull latest template → this project        ║
# ║    ./dev.sh sync --dry-run       Show what would change, no writes          ║
# ║    ./dev.sh sync --yes           Auto-accept all (CI mode)                  ║
# ║    ./dev.sh sync push            Push this project's template files →       ║
# ║                                    sibling template repo clone              ║
# ║    ./dev.sh sync push --dir <p>  Use a specific local clone path            ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# ── Windows ───────────────────────────────────────────────────────────────────
#
#   On Windows run:  .\dev.ps1   (PowerShell — installs WSL2+Ubuntu, then calls
#                                 this script inside Ubuntu automatically)
#
#   Sync on Windows: .\dev.ps1 sync [--dry-run] [--yes]
#                    .\dev.ps1 sync push          (auto-detects sibling template repo/)
#                    .\dev.ps1 sync [push] --dir <path>  (explicit template clone)
#                    (skips full bootstrap — goes straight to WSL2, fast)
#
#   macOS / Linux:   ./dev.sh    (bash — runs directly, no wrapper needed)
#
# ─────────────────────────────────────────────────────────────────────────────

set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the detached Windows-to-WSL mirror worker in the launcher itself.
if [[ "${1:-}" == "_workspace-sync" ]]; then
  set -u
  SOURCE_DIR="$(realpath "$2")"
  WORKSPACE_DIR="$(realpath "$3")"
  [[ "$SOURCE_DIR" != "$WORKSPACE_DIR" && "$WORKSPACE_DIR" == /root/.codex-workspaces/* ]] || exit 1
  # One worker per runtime workspace. The lock is released even after a crash.
  exec 9>"$WORKSPACE_DIR/.dev-sync.lock"
  flock -n 9 || exit 0
  echo "$$" > "$WORKSPACE_DIR/.dev-sync.pid"
  excludes=(--exclude .git/ --exclude node_modules/ --exclude .next/
    --exclude .expo/ --exclude .metro-cache/ --exclude .gradle/ --exclude .venv/
    --exclude venv/ --exclude __pycache__/ --exclude '*.pyc'
    --exclude .cxx/ --exclude Pods/ --exclude build/ --exclude dist/
    --exclude backend/media/ --exclude backend/config/staticfiles/
    --exclude /.env --exclude /.dev-sync.lock --exclude /.dev-sync.pid)
  # Bulk sync runs separately so native apps and assets cannot delay web edits.
  (
    while true; do
      rsync -a --delete "${excludes[@]}" --exclude frontend/web/ --exclude backend/ \
        "$SOURCE_DIR/" "$WORKSPACE_DIR/" || echo 'Workspace sync failed; retrying.' >&2
      sleep 2
    done
  ) &
  BULK_PID=$!
  trap 'kill "$BULK_PID" 2>/dev/null || true' EXIT
  trap 'exit 0' TERM INT
  while true; do
    for part in frontend/web backend; do
      rsync -a --delete "${excludes[@]}" --exclude media/ --exclude config/staticfiles/ \
        "$SOURCE_DIR/$part/" "$WORKSPACE_DIR/$part/" || echo "Sync failed for $part; retrying." >&2
    done
    sleep 1
  done
fi

# Sync is a file operation: skip bootstrap, .env edits, containers and tunnels.
if [[ "${1:-}" == "sync" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for template sync."; exit 1; }
  exec python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" sync "${@:2}"
fi

if [[ "${1:-}" == "watchos" || ( "${1:-}" == "build" && "${3:-}" == "watchos" ) ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for watchOS tooling."; exit 1; }
  exec python3 "$ROOT_DIR/backend/config/watchos.py" "$ROOT_DIR" "$@"
fi

# Project-owned commands run before bootstrap; discovery reads literals only.
if [[ "${1:-}" == "_exposure_check_only" ]]; then
  _exposure_output=$(python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" exposure-check-command) || exit 1
  _exposure_project=$(basename "$ROOT_DIR" | tr -cd 'a-zA-Z0-9.' | tr '[:upper:]' '[:lower:]' | tr -d '.')
  [[ -n "$_exposure_project" ]] || _exposure_project="project-$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
  _exposure_backend=$(podman ps --filter "label=com.docker.compose.project=${_exposure_project}" \
    --filter "label=com.docker.compose.service=backend" --format '{{.Names}}' | head -1) || exit 1
  [[ -n "$_exposure_backend" ]] || { echo "Exposure refused: start the secured backend first." >&2; exit 1; }
  _exposure_command=()
  while IFS= read -r _exposure_arg; do _exposure_command+=("$_exposure_arg"); done <<< "$_exposure_output"
  exec podman exec "$_exposure_backend" "${_exposure_command[@]}"
fi

if [[ "${1:-}" == "expose" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for exposure checks."; exit 1; }
  python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" exposure-check-command >/dev/null || exit 1
fi

if [[ -n "${1:-}" ]] && command -v python3 >/dev/null 2>&1 &&
   python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" has-dev-command "$1"; then
  exec python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" run-dev-command "$@"
fi



# Keep the Compose project name available from the first line that may need a
# project-scoped temporary file.  In particular, project.py compose extensions
# are extracted below, before the environment bootstrap.
PROJECT_NAME="$(basename "$ROOT_DIR" | tr -cd 'a-zA-Z0-9.' | tr '[:upper:]' '[:lower:]' | tr -d '.')"
[[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="project-$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
PROJECT_DISPLAY_NAME="$(basename "$ROOT_DIR")"

# ── Ensure Homebrew tools (gtimeout, etc.) are in PATH on macOS ──────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
  for _brew_bin in /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$_brew_bin" ]] && export PATH="$_brew_bin:$PATH"
  done
fi
COMPOSE_FILE="$ROOT_DIR/dev.yml"
MOBILE_DIR="$ROOT_DIR/frontend/mobile"

# Always declare MOBILE_APPS so it exists as an array
MOBILE_APPS=()

# ── Extra compose services (project-specific overrides) ───────────────────────
# COMPOSE_SERVICES string inside backend/project.py is extracted into a
# temp file and merged with dev.yml — one file to edit instead of two.
COMPOSE_F=(-f "$COMPOSE_FILE")
_project_py="$ROOT_DIR/backend/project.py"
_extra_yml="/tmp/${PROJECT_NAME}-project-services.yml"

rm -f "$_extra_yml"  # Never reuse overrides removed from project.py.

# Extract the COMPOSE_SERVICES string from project.py and write to a temp file.
# Uses Python to parse the literal string safely (handles triple-quotes, escapes).
if [[ -f "$_project_py" ]]; then
  python3 - "$_project_py" "$_extra_yml" <<'EXTRACT_COMPOSE_EOF'
import ast, sys, os

src_path, dest_path = sys.argv[1], sys.argv[2]
try:
    tree = ast.parse(open(src_path, encoding="utf-8-sig").read())
except SyntaxError as error:
    raise SystemExit(f"Invalid project configuration: {error}")

for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "COMPOSE_SERVICES":
                if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                    content = node.value.value
                    # Only write if there's at least one real (non-comment) line
                    real_lines = [l for l in content.splitlines()
                                  if l.strip() and not l.strip().startswith('#')]
                    if real_lines:
                        with open(dest_path, 'w') as f:
                            # Project snippets contain service entries indented
                            # beneath Compose's required top-level `services:`.
                            # Also accept a complete Compose fragment.
                            if any(l.strip() == 'services:' for l in content.splitlines()):
                                f.write(content)
                            else:
                                f.write('services:\n' + content)
                    sys.exit(0)
EXTRACT_COMPOSE_EOF

  # Include the extracted services file if it has real content
  if [[ -f "$_extra_yml" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$_extra_yml" 2>/dev/null; then
    COMPOSE_F+=(-f "$_extra_yml")
  fi
fi
unset _project_py _extra_yml

export DOCKER_CONFIG="$ROOT_DIR/.docker"
export DOCKER_BUILDKIT=1

# ── Cross-platform helpers ────────────────────────────────────────────────────

# sed -i in-place: macOS requires '' argument, Linux/Windows Git Bash does not
_sed_inplace() {
  if [[ "$OS" == "mac" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get LAN IP: macOS uses ipconfig getifaddr, Linux/Windows uses hostname -I
_get_lan_ip() {
  case "$OS" in
    mac)
      ipconfig getifaddr en0 2>/dev/null \
        || ipconfig getifaddr en1 2>/dev/null \
        || echo "localhost"
      ;;
    wsl|linux)
      # A WSL address (normally 172.x) is NAT-only and cannot be opened by a
      # phone on Wi-Fi. Prefer the Windows host's physical LAN address so the
      # LOCAL QR code works on real devices as well as emulators.
      if [[ "$OS" == "wsl" ]] && [[ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
        local _win_lan_ip
        _win_lan_ip=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '$ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.InterfaceAlias -notmatch "WSL|vEthernet|Loopback" } | Select-Object -First 1 -ExpandProperty IPAddress; Write-Output $ip' 2>/dev/null | tr -d '\r' | tail -1)
        [[ "$_win_lan_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$_win_lan_ip"; return; }
      fi
      hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
      ;;
    windows)
      # In Git Bash / MSYS2 on Windows
      hostname -I 2>/dev/null | awk '{print $1}' \
        || ipconfig 2>/dev/null | grep -E "IPv4|IPv4 Address" | head -1 | awk -F': ' '{print $2}' | tr -d '\r' \
        || echo "localhost"
      ;;
    *)
      echo "localhost"
      ;;
  esac
}

# Cross-platform port-in-use check — returns 0 (true) if port is occupied
_port_in_use() {
  local _p="$1"
  case "$OS" in
    mac)
      lsof -nP -iTCP:"$_p" -sTCP:LISTEN >/dev/null 2>&1
      ;;
    linux|wsl)
      ss -tnl "sport = :${_p}" 2>/dev/null | grep -q "LISTEN" \
        || netstat -tnl 2>/dev/null | grep -qE ":${_p}\s" \
        || false
      ;;
    windows)
      netstat -an 2>/dev/null | grep -qE "[:.]${_p}\s.*LISTENING" || false
      ;;
    *)
      false
      ;;
  esac
}

# Cross-platform port listener PID (empty if none)
_port_listener_info() {
  local _p="$1"
  case "$OS" in
    mac)
      lsof -nP -iTCP:"$_p" -sTCP:LISTEN 2>/dev/null \
        | awk 'NR>1 {print $1, $2}' | grep -v -E '^(gvproxy|vpnkit) ' | head -1
      ;;
    linux|wsl)
      ss -tlnp "sport = :${_p}" 2>/dev/null \
        | awk 'NR>1 {print $6}' | sed 's/.*pid=\([0-9]*\).*/\1/' | head -1 || true
      ;;
    windows)
      netstat -anob 2>/dev/null | grep -A1 "[:.]${_p}.*LISTENING" | tail -1 | tr -d '[] ' || true
      ;;
    *)
      true
      ;;
  esac
}

# Bootstrap reads only this checkout; project defaults belong in project.py.
_bootstrap_env() {
  [[ -f "$ROOT_DIR/.env" ]] && return 0
  python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" bootstrap-env
  echo "✅ Created local .env using this project's defaults."
}

# Run bootstrap immediately so .env is ready for all subsequent commands
_bootstrap_env

# Project name derived from the repo folder (declared above because extraction
# of project-specific Compose services also uses it).
# Podman Compose strips dots from project names, so we do the same for consistency.
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"

# Display name preserves original capitalization and dots for UI/status display
# PROJECT_DISPLAY_NAME was also declared above for early callers.

# PROJECT_HOST is a single DNS label derived from the project folder.  A
# single-label `name.localhost` resolves automatically on Windows, macOS, and
# Linux; keeping dots would create `name.app.localhost`, which Windows does not
# consistently resolve without an elevated hosts-file edit.
PROJECT_HOST="$PROJECT_NAME"
export PROJECT_HOST
# Accept the dotted repository name too, while retaining the portable hostname.
PROJECT_HOST_ALIAS="$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')"
export PROJECT_HOST_ALIAS

# ── OS detection ──────────────────────────────────────────────────────────────
_UNAME="$(uname -s)"
case "$_UNAME" in
  Darwin) OS="mac" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"
    else OS="linux"
    fi ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *) OS="unknown" ;;
esac

# Write PROJECT_HOST and COMPOSE_PROJECT_NAME to .env so podman-compose always
# resolves them correctly even when invoked outside of dev.sh.
_env_file="$ROOT_DIR/.env"
if [[ -f "$_env_file" ]]; then
  if grep -q "^PROJECT_HOST=" "$_env_file" 2>/dev/null; then
    _sed_inplace "s|^PROJECT_HOST=.*|PROJECT_HOST=$PROJECT_HOST|" "$_env_file"
  else
    printf '\nPROJECT_HOST=%s\n' "$PROJECT_HOST" >> "$_env_file"
  fi
  if grep -q "^COMPOSE_PROJECT_NAME=" "$_env_file" 2>/dev/null; then
    _sed_inplace "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=$PROJECT_NAME|" "$_env_file"
  else
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT_NAME" >> "$_env_file"
  fi
  if grep -q "^PROJECT_HOST_ALIAS=" "$_env_file" 2>/dev/null; then
    _sed_inplace "s|^PROJECT_HOST_ALIAS=.*|PROJECT_HOST_ALIAS=$PROJECT_HOST_ALIAS|" "$_env_file"
  else
    printf 'PROJECT_HOST_ALIAS=%s\n' "$PROJECT_HOST_ALIAS" >> "$_env_file"
  fi
fi
unset _env_file

# ── Windows: always run inside WSL2 Ubuntu ────────────────────────────────────
# On Windows, Podman runs natively inside WSL2 (same role as Apple Hypervisor
# on macOS). If WSL2 Ubuntu is already set up, exec the whole script there now.
# If not set up yet, run_setup's windows) case will install it first.
if [[ "$OS" == "windows" ]]; then
  if wsl.exe -l --quiet 2>/dev/null | tr -d '\0\r\n ' | grep -qi "Ubuntu"; then
    # Ubuntu is installed — convert path and re-exec inside WSL2
    _wsl_root=$(wsl.exe -d Ubuntu -- wslpath -a "$(cygpath -w "$ROOT_DIR")" 2>/dev/null | tr -d '\r\n')
    [[ -z "$_wsl_root" ]] && _wsl_root=$(echo "$ROOT_DIR" | sed 's|^/\([a-z]\)/|/mnt/\1/|')
    exec wsl.exe -d Ubuntu -- bash -c \
      "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd '${_wsl_root}' && bash dev.sh $(printf '%q ' "$@")"
  fi
  # Ubuntu not yet installed — fall through to run_setup windows) which installs it
fi

_default_android_sdk() {
  case "$OS" in
    mac)     echo "$HOME/Library/Android/sdk" ;;
    linux)   echo "$HOME/Android/Sdk" ;;
    wsl)     echo "$HOME/Android/Sdk" ;;
    windows) echo "$HOME/AppData/Local/Android/Sdk" ;;
    *)       echo "$HOME/Android/Sdk" ;;
  esac
}

# ── gen_app_json ──────────────────────────────────────────────────────────────
# Auto-generates app.json for every app folder under frontend/mobile/.
# Reads app.config.js (if present) for bundle IDs, preserves existing EAS
# project IDs and owner fields, and handles both bare and managed workflows.
# Also auto-generates optimized metro.config.js and .watchmanconfig if missing.
gen_app_json() {
  [[ -d "$MOBILE_DIR" ]] || return 0

  # First, ensure metro.config.base.js exists
  local base_config="$MOBILE_DIR/metro.config.base.js"
  local _skip_metro=0
  [[ ! -f "$base_config" ]] && _skip_metro=1

  local _tmp_script
  _tmp_script=$(mktemp /tmp/gen_app_json_XXXXXX.js)
  # Write the node script to a temp file to avoid backtick/heredoc conflicts inside $()
  cat > "$_tmp_script" << 'NODEEOF'
const fs   = require('fs');
const path = require('path');

const MOBILE_DIR  = process.argv[2] || path.resolve(__dirname, '..');
const SHARED_ASSETS = path.resolve(MOBILE_DIR, '..', 'shared', 'assets');
const SKIP = new Set(['node_modules', 'shared', 'scripts', 'packages']);

const toSlug = (n) => n.toLowerCase().replace(/\s+/g, '-');
const toId   = (n) => n.toLowerCase().replace(/\s+/g, '');
const dig    = (obj, ...keys) => keys.reduce((o, k) => (o && o[k] !== undefined ? o[k] : null), obj);

// Import shared helpers for consistent package identifier generation
let getPackageIdentifier, getUrlScheme;
try {
  const helpers = require(path.join(MOBILE_DIR, 'shared', 'expoDisplayName.js'));
  getPackageIdentifier = helpers.getPackageIdentifier;
  getUrlScheme = helpers.getUrlScheme;
} catch (e) {
  // Fallback if shared helpers aren't available
  getPackageIdentifier = (base, env) => env === 'production' ? base : `${base}.${env}`;
  getUrlScheme = (base, env) => env === 'production' ? base : `${base}-${env}`;
}

const readAppConfigJs = (appDir) => {
  // 1. Regex-parse app.config.js first — it's the source of truth when present.
  //    Avoids require()/new Function() which both fail on ESM (export default).
  const p = path.join(appDir, 'app.config.js');
  if (fs.existsSync(p)) {
    try {
      const src = fs.readFileSync(p, 'utf8');
      // Match direct string literals: package: 'com.myapp'
      const pkg = src.match(/package\s*:\s*['"]([\w.]+)['"]/);
      const bid = src.match(/bundleIdentifier\s*:\s*['"]([\w.]+)['"]/);
      if (pkg || bid) return {
        androidPackage: pkg ? pkg[1] : null,
        iosBundleId:    bid ? bid[1] : null,
      };
      // Match getPackageIdentifier('com.myapp', ...) or getPackageIdentifier("com.myapp.module", ...)
      const pkgId = src.match(/getPackageIdentifier\s*\(\s*['"]([^'"]+)['"]/);
      if (pkgId) return {
        androidPackage: pkgId[1],
        iosBundleId:    pkgId[1],
      };
    } catch (_) {}
  }
  // 2. Fall back to app.json — plain JSON, always safe to parse
  const appJsonPath = path.join(appDir, 'app.json');
  if (fs.existsSync(appJsonPath)) {
    try {
      const d = JSON.parse(fs.readFileSync(appJsonPath, 'utf8'));
      const expo = d.expo || d;
      return {
        androidPackage: (expo.android && expo.android.package) || null,
        iosBundleId:    (expo.ios    && expo.ios.bundleIdentifier) || null,
      };
    } catch (_) {}
  }
  return {};
};

let folders;
try {
  folders = fs.readdirSync(MOBILE_DIR).filter((name) => {
    if (SKIP.has(name)) return false;
    const dir = path.join(MOBILE_DIR, name);
    try { return fs.statSync(dir).isDirectory() && fs.existsSync(path.join(dir, 'package.json')); }
    catch (_) { return false; }
  });
} catch (err) {
  console.error('Could not read mobile dir:', err.message);
  process.exit(0);
}

if (folders.length === 0) { process.exit(0); }

for (const name of folders) {
  const appDir  = path.join(MOBILE_DIR, name);
  const appJson = path.join(appDir, 'app.json');
  const slug    = toSlug(name);
  const appConfig = readAppConfigJs(appDir);
  const bundleId = appConfig.androidPackage || appConfig.iosBundleId || ('app.' + toId(name));

  // If app.config.js exists it is the single source of truth — skip writing
  // app.json entirely. Having both causes Expo prebuild to merge them with
  // conflicting values (wrong package name, stale icon paths, missing projectId).
  if (fs.existsSync(path.join(appDir, 'app.config.js'))) {
    console.log('✅ ' + name + '  →  ' + bundleId + '  (' + slug + ')');
    continue;
  }

  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(appJson, 'utf8')); } catch (_) {}

  const projectId = dig(existing, 'expo', 'extra', 'eas', 'projectId') || null;
  const owner     = dig(existing, 'expo', 'owner') || null;
  const isBare    = fs.existsSync(path.join(appDir, 'android')) || fs.existsSync(path.join(appDir, 'ios'));

  let config;
  if (isBare) {
    config = {
      expo: {
        name, slug,
        version:        dig(existing, 'expo', 'version')        || '1.0.0',
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ...(dig(existing, 'expo', 'icon')    ? { icon:    dig(existing, 'expo', 'icon')    } : {}),
        ...(dig(existing, 'expo', 'splash')  ? { splash:  dig(existing, 'expo', 'splash')  } : {}),
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
        ...(dig(existing, 'expo', 'android') ? { android: dig(existing, 'expo', 'android') } : {}),
        ...(dig(existing, 'expo', 'ios')     ? { ios:     dig(existing, 'expo', 'ios')     } : {}),
      },
    };
  } else {
    // Find the PNG in shared/assets for this slug.
    let iconPath = '../shared/assets/' + slug + '-icon.png';
    try {
      const files = fs.readdirSync(SHARED_ASSETS);
      const exact = files.find(f => f === (slug + '-icon.png'));
      const plain = files.find(f => f === (slug + '.png'));
      const loose = files.filter(f => f.endsWith('.png') && (f === (slug + '.png') || new RegExp('^' + slug + '[^a-z0-9]').test(f))).sort()[0];
      const match = exact || plain || loose;
      if (match) iconPath = path.relative(appDir, path.join(SHARED_ASSETS, match)).replace(/\\/g, '/');
    } catch (_) {}

    config = {
      expo: {
        name, slug, scheme: slug,
        version:           dig(existing, 'expo', 'version') || '1.0.0',
        orientation:       'portrait',
        icon:              iconPath,
        userInterfaceStyle: 'light',
        splash: {
          image:           iconPath,
          resizeMode:      'contain',
          backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000',
        },
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ios: {
          supportsTablet:   true,
          bundleIdentifier: bundleId,
          infoPlist: {
            NSLocationWhenInUseUsageDescription:          name + ' needs your location.',
            NSLocationAlwaysAndWhenInUseUsageDescription: name + ' needs your location in the background.',
            ITSAppUsesNonExemptEncryption: false,
            ...(dig(existing, 'expo', 'ios', 'infoPlist') || {}),
          },
        },
        android: {
          adaptiveIcon: {
            foregroundImage: iconPath,
            backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000',
          },
          package: bundleId,
          ...(dig(existing, 'expo', 'android', 'permissions')
            ? { permissions: dig(existing, 'expo', 'android', 'permissions') } : {}),
        },
        web: { favicon: './assets/favicon.png' },
        plugins: dig(existing, 'expo', 'plugins') || [
          ['expo-location', {
            locationAlwaysAndWhenInUsePermission: 'Allow ' + name + ' to use your location.',
            locationWhenInUsePermission:          'Allow ' + name + ' to use your location.',
          }],
        ],
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
      },
    };
  }

  fs.writeFileSync(appJson, JSON.stringify(config, null, 2) + '\n');
  console.log('✅ ' + name + '  →  ' + bundleId + '  (' + slug + ')');

  // Auto-generate optimized metro.config.js if missing
  const metroConfig = path.join(appDir, 'metro.config.js');
  if (!fs.existsSync(metroConfig) && fs.existsSync(path.join(MOBILE_DIR, 'metro.config.base.js'))) {
    const metroTemplate = [
      '/**',
      ' * Metro configuration for ' + name,
      ' *',
      ' * Uses the shared optimized config from metro.config.base.js',
      ' * Add app-specific customizations here if needed.',
      ' */',
      '',
      "const createMetroConfig = require('../metro.config.base');",
      '',
      '// Create the optimized config for this app',
      'const config = createMetroConfig(__dirname, {});',
      '',
      'module.exports = config;',
      '',
    ].join('\n');
    fs.writeFileSync(metroConfig, metroTemplate);
    console.log('   📝 Created optimized metro.config.js');
  }

  // Auto-generate .watchmanconfig if missing
  const watchmanConfig = path.join(appDir, '.watchmanconfig');
  if (!fs.existsSync(watchmanConfig)) {
    const watchmanTemplate = {
      ignore_dirs: [
        '.git', 'node_modules', '.expo', '.expo-shared',
        'android/build', 'ios/build', 'android/.gradle', '.metro-cache',
      ],
    };
    fs.writeFileSync(watchmanConfig, JSON.stringify(watchmanTemplate, null, 2) + '\n');
    console.log('   📝 Created .watchmanconfig');
  }
}
NODEEOF

  local _node_out
  _node_out=$(node "$_tmp_script" "$MOBILE_DIR" 2>/dev/null)
  rm -f "$_tmp_script"

  if [[ -n "$_node_out" ]]; then
    echo "$_node_out"
  elif [[ "$_skip_metro" -eq 1 ]]; then
    echo "   Mobile not configured (no metro.config.base.js or app folders)"
  fi
}

# ── Forward declaration: real implementation is defined later in this file ────
# run_setup (line ~553) is called from the entry point before the full function
# body at line ~2769 has been parsed by bash. This stub ensures the symbol exists
# on non-mac systems where the function is a no-op anyway.
_ensure_podman_machine_autostart() {
  # Real implementation is defined later in this file (after gen_compose_yml).
  # This stub is only invoked during the early run_setup call at script startup;
  # all later call sites (e.g. the main start path) use the fully-defined version.
  [[ "$OS" == "mac" ]] || return 0
  # On mac, silently skip — the LaunchAgent will be registered on the next
  # run_setup invocation (e.g. ./dev.sh up) once bash has parsed the real body.
  return 0
}

# ── Dependency setup ──────────────────────────────────────────────────────────
run_setup() {
  echo "🔍 Checking dependencies... (OS: $OS)"

  case "$OS" in
    mac)
      # Xcode must be installed first (App Store)
      if ! xcode-select -p &>/dev/null 2>&1; then
        echo ""
        echo "❌ Xcode is required. Install from the App Store:"
        echo "   https://apps.apple.com/app/xcode/id497799835"
        echo "   Then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo "   Then re-run: ./dev.sh"
        exit 1
      fi
      echo "✅ Xcode installed ($(xcode-select -p))"

      # Homebrew — extract tarball directly, no installer script, no CLT popup
      if ! command -v brew &>/dev/null; then
        echo "📦 Installing Homebrew..."
        # Official non-interactive install — NONINTERACTIVE skips all prompts
        NONINTERACTIVE=1 /bin/bash -c \
          "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Wire brew into PATH for the rest of this session
        if [[ -x /opt/homebrew/bin/brew ]]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -x /usr/local/bin/brew ]]; then
          eval "$(/usr/local/bin/brew shellenv)"
        fi
        echo "✅ Homebrew installed"
      else
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
          || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
        echo "✅ Homebrew already installed"
      fi

      # Podman
      if ! command -v podman &>/dev/null; then
        echo "📦 Installing Podman..."
        yes | brew install podman || true
      else
        echo "✅ Podman already installed ($(podman --version))"
      fi

      # podman-compose
      if ! command -v podman-compose &>/dev/null; then
        echo "📦 Installing podman-compose..."
        yes | brew install podman-compose || true
      else
        echo "✅ podman-compose already installed"
      fi

      # Podman machine
      if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
        if ! podman machine list 2>/dev/null | grep -q "default"; then
          echo "🖥️  Creating Podman machine..."
          podman machine init --cpus 4 --memory 8192 --disk-size 60 2>&1 | grep -v "rootless mode" | grep -v "Docker API socket" | grep -v "DOCKER_HOST" || true
        fi
        echo "🚀 Starting Podman machine..."
        podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
      else
        echo "✅ Podman machine already running"
      fi

      # Java (required for Android SDK tools)
      # Check /usr/libexec/java_home first, then scan Homebrew openjdk paths
      _find_java_home_mac() {
        local jh
        # Prefer Java 21 LTS — required for Gradle 9 + React Native (JVM 25 breaks foojay-resolver)
        for vm in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
                  /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
                  /Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home \
                  /Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home; do
          [ -x "$vm/bin/java" ] && echo "$vm" && return
        done
        # Fall back to any available JVM
        jh="$(/usr/libexec/java_home 2>/dev/null || true)"
        [ -n "$jh" ] && [ -x "$jh/bin/java" ] && echo "$jh" && return
        for vm in /Library/Java/JavaVirtualMachines/*/Contents/Home \
                  /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                  /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
                  /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                  /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home; do
          [ -x "$vm/bin/java" ] && echo "$vm" && return
        done
      }
      _JAVA_HOME="$(_find_java_home_mac)"
      if [ -z "$_JAVA_HOME" ]; then
        echo "📦 Installing Java 21 LTS (required for Android/Gradle builds)..."
        # openjdk@21 is the LTS version supported by React Native + Gradle 9.
        # openjdk (latest, currently 25) breaks Gradle's foojay-resolver plugin.
        # `yes |` answers Homebrew's interactive confirmation prompt non-interactively.
        yes | brew install openjdk@21 2>&1 || \
          echo "⚠️  Java install failed — Android builds unavailable. Install manually: brew install openjdk@21"
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
        _JAVA_HOME="$(_find_java_home_mac)"
      else
        echo "✅ Java already installed ($_JAVA_HOME)"
      fi
      export JAVA_HOME="${_JAVA_HOME:-}"
      [ -n "$JAVA_HOME" ] && export PATH="$JAVA_HOME/bin:$PATH"

      # Re-wire brew PATH so newly installed binaries are found after a Mac restart
      eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
        || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

      # Node.js
      if ! command -v node &>/dev/null; then
        echo "📦 Installing Node.js..."
        yes | brew install node || true
        # Re-wire PATH so node is available immediately in this session
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
          || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
      else
        echo "✅ Node.js already installed ($(node --version))"
      fi

      # Cloudflared (for Cloudflare Tunnel)
      if ! command -v cloudflared &>/dev/null; then
        echo "📦 Installing cloudflared (for Cloudflare Tunnel)..."
        yes | brew install cloudflared || true
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
          || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
      else
        echo "✅ cloudflared already installed ($(cloudflared --version))"
      fi

      # ── Android SDK + Emulator ──────────────────────────────────────────────
      # Delegate to the shared helper so setup and `./dev.sh android` stay in sync.
      _install_android_sdk
      ;;


    linux|wsl)
      if ! command -v podman &>/dev/null; then
        echo "📦 Installing Podman..."
        if command -v apt-get &>/dev/null; then
          sudo apt-get update && sudo apt-get install -y podman
        elif command -v dnf &>/dev/null; then
          sudo dnf install -y podman
        elif command -v pacman &>/dev/null; then
          sudo pacman -Sy --noconfirm podman
        else
          echo "❌ Cannot auto-install Podman. See: https://podman.io/getting-started/installation"
          exit 1
        fi
      else
        echo "✅ Podman already installed ($(podman --version))"
      fi

      if ! command -v podman-compose &>/dev/null; then
        echo "📦 Installing podman-compose..."
        # Ubuntu 24.04+ (PEP 668) blocks pip install without --break-system-packages.
        # Try pipx first (cleanest), then pip with the flag, then plain pip.
        if ! command -v pipx &>/dev/null; then
          sudo apt-get install -y -qq pipx 2>/dev/null || true
        fi
        if command -v pipx &>/dev/null; then
          pipx install podman-compose 2>/dev/null || true
        fi
        if ! command -v podman-compose &>/dev/null; then
          pip3 install --user --break-system-packages podman-compose 2>/dev/null \
            || pip3 install --user podman-compose 2>/dev/null \
            || pip install --user podman-compose 2>/dev/null || true
        fi
        export PATH="$HOME/.local/bin:$PATH"
        echo "✅ podman-compose installed"
      else
        echo "✅ podman-compose already installed"
      fi

      if ! command -v git &>/dev/null; then
        echo "📦 Installing Git..."
        if command -v apt-get &>/dev/null; then sudo apt-get update && sudo apt-get install -y git
        elif command -v dnf &>/dev/null; then sudo dnf install -y git
        elif command -v pacman &>/dev/null; then sudo pacman -Sy --noconfirm git
        else echo "❌ Cannot auto-install Git. See: https://git-scm.com/download/linux"; exit 1
        fi
      else
        echo "✅ Git already installed ($(git --version))"
      fi

      if ! command -v node &>/dev/null; then
        echo "📦 Installing Node.js (LTS)..."
        if command -v apt-get &>/dev/null; then
          curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
          sudo apt-get install -y nodejs
        elif command -v dnf &>/dev/null; then sudo dnf install -y nodejs
        else echo "❌ Cannot auto-install Node.js. See: https://nodejs.org"; exit 1
        fi
      else
        echo "✅ Node.js already installed ($(node --version))"
      fi

      # Cloudflared (for Cloudflare Tunnel)
      if ! command -v cloudflared &>/dev/null; then
        echo "📦 Installing cloudflared (for Cloudflare Tunnel)..."
        if command -v apt-get &>/dev/null; then
          # Add Cloudflare GPG key and repository
          sudo mkdir -p --mode=0755 /usr/share/keyrings
          curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
          echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
          sudo apt-get update && sudo apt-get install -y cloudflared
        elif command -v dnf &>/dev/null; then
          sudo dnf install -y cloudflared
        elif command -v pacman &>/dev/null; then
          sudo pacman -Sy --noconfirm cloudflared
        else
          echo "⚠️  Cannot auto-install cloudflared. Install manually from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
        fi
      else
        echo "✅ cloudflared already installed"
      fi

      # Configure Podman to search Docker Hub for unqualified image names
      # (e.g. "postgres:17" instead of "docker.io/library/postgres:17")
      sudo mkdir -p /etc/containers/registries.conf.d
      if ! grep -q 'docker.io' /etc/containers/registries.conf.d/docker.conf 2>/dev/null; then
        echo 'unqualified-search-registries = ["docker.io"]' \
          | sudo tee /etc/containers/registries.conf.d/docker.conf >/dev/null
        echo "✅ Podman registry configured (docker.io)"
      fi

      # Enable systemd lingering so rootless Podman containers survive terminal close
      _ensure_lingering
      ;;

    windows)
      # ── Strategy: this block runs from Git Bash on Windows ────────────────
      # The real Windows entry point is the PowerShell section at the top of
      # this file (.\dev.sh from PowerShell) which handles Git + WSL2 install
      # before bash is even available. If we get here it means Git Bash is
      # already running, so WSL2 Ubuntu may or may not be installed yet.
      echo "🪟 Windows detected (Git Bash)"

      # ── Step 1: Ensure WSL2 + Ubuntu is installed ─────────────────────────
      _wsl_has_ubuntu=false
      if wsl.exe -l --quiet 2>/dev/null | tr -d '\0\r\n ' | grep -qi "Ubuntu"; then
        _wsl_has_ubuntu=true
        echo "✅ WSL2 Ubuntu already installed"
      else
        echo "📦 Installing WSL2 + Ubuntu (one-time ~2 min, UAC prompt may appear)..."

        # Try directly first — works on Win11 22H2+ without elevation
        wsl.exe --install -d Ubuntu --no-launch 2>/dev/null | tr -d '\r' || true

        local _w=0
        while [[ $_w -lt 120 ]]; do
          wsl.exe -l --quiet 2>/dev/null | tr -d '\0\r\n ' | grep -qi "Ubuntu" \
            && { _wsl_has_ubuntu=true; break; }
          sleep 3; _w=$((_w+3))
        done

        # Retry with elevation if still not registered
        if [[ "$_wsl_has_ubuntu" == "false" ]]; then
          echo "   Retrying with elevated privileges (UAC prompt will appear)..."
          powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
            "Start-Process wsl.exe -ArgumentList '--install -d Ubuntu --no-launch' \
             -Verb RunAs -Wait -WindowStyle Normal" 2>/dev/null | tr -d '\r' || true
          _w=0
          while [[ $_w -lt 180 ]]; do
            wsl.exe -l --quiet 2>/dev/null | tr -d '\0\r\n ' | grep -qi "Ubuntu" \
              && { _wsl_has_ubuntu=true; break; }
            sleep 3; _w=$((_w+3))
          done
        fi

        if [[ "$_wsl_has_ubuntu" == "false" ]]; then
          echo ""
          echo "❌ Ubuntu did not appear after install."
          echo "   WSL2 may need a reboot to activate. Run in Admin PowerShell:"
          echo "     wsl --install -d Ubuntu"
          echo "   Then restart your PC and re-run: ./dev.sh"
          exit 1
        fi
        echo "✅ WSL2 + Ubuntu installed"
      fi

      # ── Step 2: Wait for Ubuntu first-boot (rootfs extraction ~30 s) ──────
      echo "🔄 Checking Ubuntu is ready..."
      local _init_ok=false _init_w=0
      while [[ $_init_w -lt 240 ]]; do
        wsl.exe -d Ubuntu -- bash -c 'echo ready' 2>/dev/null \
          | grep -q "ready" && { _init_ok=true; break; }
        sleep 5; _init_w=$((_init_w+5))
        (( _init_w % 30 == 0 )) && echo "   Still initialising... (${_init_w}s)"
      done

      if [[ "$_init_ok" == "false" ]]; then
        # Stuck on interactive first-launch prompt — set root as default user
        echo "   Setting Ubuntu default user to root (unattended mode)..."
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
          "ubuntu.exe config --default-user root" 2>/dev/null | tr -d '\r' || true
        wsl.exe --terminate Ubuntu 2>/dev/null || true
        sleep 3
        if ! wsl.exe -d Ubuntu -- bash -c 'echo ready' 2>/dev/null | grep -q "ready"; then
          echo ""
          echo "❌ Ubuntu won't respond. Run:  wsl -d Ubuntu"
          echo "   Complete the first-launch setup, then re-run: ./dev.sh"
          exit 1
        fi
      fi
      echo "✅ WSL2 Ubuntu ready"

      # ── Step 3: Bootstrap tools inside WSL2 (idempotent) ─────────────────
      echo "🐧 Installing tools inside WSL2..."
      wsl.exe -d Ubuntu -- bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive

        _apt_install() {
          for pkg in "$@"; do
            dpkg -s "$pkg" &>/dev/null || MISSING="$MISSING $pkg"
          done
          [ -z "$MISSING" ] && return 0
          sudo apt-get update -qq
          sudo apt-get install -y -qq $MISSING
        }

        # Core tools
        _apt_install curl ca-certificates gnupg

        # Node.js LTS (via NodeSource) — needed for Expo/Metro
        if ! command -v node &>/dev/null; then
          echo "📦 Installing Node.js LTS..."
          curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - 2>/dev/null
          sudo apt-get install -y -qq nodejs
          echo "✅ Node.js $(node --version)"
        else
          echo "✅ Node.js $(node --version)"
        fi

        # Podman
        if ! command -v podman &>/dev/null; then
          echo "📦 Installing Podman..."
          sudo apt-get update -qq
          sudo apt-get install -y -qq podman 2>/dev/null || {
            # Fallback: kubic repository
            curl -fsSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04/Release.key \
              | sudo gpg --dearmor -o /usr/share/keyrings/podman.gpg
            echo "deb [signed-by=/usr/share/keyrings/podman.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04 /" \
              | sudo tee /etc/apt/sources.list.d/podman.list
            sudo apt-get update -qq && sudo apt-get install -y -qq podman
          }
          echo "✅ Podman $(podman --version)"
        else
          echo "✅ Podman $(podman --version)"
        fi

        # podman-compose
        if ! command -v podman-compose &>/dev/null; then
          echo "📦 Installing podman-compose..."
          sudo apt-get install -y -qq python3-pip 2>/dev/null || true
          pip3 install --user -q podman-compose 2>/dev/null \
            || pip install --user -q podman-compose 2>/dev/null || true
          echo "✅ podman-compose installed"
        else
          echo "✅ podman-compose ready"
        fi

        # cloudflared
        if ! command -v cloudflared &>/dev/null; then
          echo "📦 Installing cloudflared..."
          curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
          echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
          sudo apt-get update -qq && sudo apt-get install -y -qq cloudflared 2>/dev/null || true
          echo "✅ cloudflared installed"
        else
          echo "✅ cloudflared ready"
        fi

        # git (usually pre-installed in Ubuntu, but ensure it)
        command -v git &>/dev/null || sudo apt-get install -y -qq git
        command -v python3 &>/dev/null || sudo apt-get install -y -qq python3

        echo "✅ WSL2 tools ready"
      ' || true

      # ── Step 4: Re-exec dev.sh inside WSL2 ───────────────────────────────
      # All containers run inside WSL2 (same role as the Apple Hypervisor VM on
      # macOS). From here the Linux path takes over completely — nothing below
      # this exec line runs on Windows.
      echo ""
      echo "🔀 Switching to WSL2 Linux environment..."
      _wsl_root=$(wsl.exe -d Ubuntu -- wslpath -a "$(cygpath -w "$ROOT_DIR" 2>/dev/null || echo "$ROOT_DIR")" 2>/dev/null | tr -d '\r\n')
      [[ -z "$_wsl_root" ]] && _wsl_root=$(echo "$ROOT_DIR" | sed 's|^/\([a-z]\)/|/mnt/\1/|')
      exec wsl.exe -d Ubuntu -- bash -c \
        "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd '${_wsl_root}' && bash dev.sh $(printf '%q ' "$@")"
      ;;

    *)
      echo "❌ Unsupported OS: $_UNAME"
      exit 1
      ;;
  esac

  if ! command -v mkcert &>/dev/null || ! command -v openssl &>/dev/null \
    || { [[ "$OS" == "linux" || "$OS" == "wsl" ]] && ! command -v certutil &>/dev/null; }; then
    echo "Installing local HTTPS dependencies..."
    case "$OS" in
      mac)
        brew install mkcert nss openssl || return 1
        ;;
      linux|wsl)
        if command -v apt-get &>/dev/null; then
          sudo apt-get update && sudo apt-get install -y mkcert libnss3-tools openssl ca-certificates || return 1
        elif command -v dnf &>/dev/null; then
          sudo dnf install -y mkcert nss-tools openssl ca-certificates || return 1
        elif command -v pacman &>/dev/null; then
          sudo pacman -Sy --noconfirm mkcert nss openssl ca-certificates || return 1
        else
          echo "Cannot install local HTTPS dependencies: no supported package manager found." >&2
          return 1
        fi
        ;;
    esac
  fi
  if ! command -v mkcert &>/dev/null || ! command -v openssl &>/dev/null; then
    echo "Local HTTPS dependencies are unavailable; setup did not complete." >&2
    return 1
  fi

  # ── Install anything listed in setup.txt that isn't already present ────────
  local dev_reqs="$ROOT_DIR/backend/requirements/setup.txt"
  if [[ -f "$dev_reqs" ]] && command -v brew &>/dev/null; then
    while IFS= read -r line; do
      # Strip comments and blank lines
      line="${line%%#*}"; line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue

      if [[ "$line" == brew:* ]]; then
        local formula="${line#brew:}"
        if ! brew list --formula "$formula" &>/dev/null 2>&1; then
          echo "📦 Installing $formula..."
          yes | brew install "$formula" || true
        else
          echo "✅ $formula already installed"
        fi

      elif [[ "$line" == brew-cask:* ]]; then
        local cask="${line#brew-cask:}"
        if ! brew list --cask "$cask" &>/dev/null 2>&1; then
          echo "📦 Installing $cask (cask)..."
          yes | brew install --cask "$cask" || true
        else
          echo "✅ $cask already installed"
        fi
      fi
      # custom: entries are handled by the OS-specific blocks above — skip here
    done < "$dev_reqs"
  fi

  _wire_podman_socket
  _ensure_podman_machine_autostart

  echo ""
  echo "✅ All dependencies ready!"
  command -v podman          &>/dev/null && echo "   Podman:          $(podman --version)"
  command -v podman-compose  &>/dev/null && echo "   podman-compose:  $(podman-compose --version 2>/dev/null | head -1)"
  command -v node            &>/dev/null && echo "   Node:            $(node --version)"
  command -v git             &>/dev/null && echo "   Git:             $(git --version)"
  command -v python3         &>/dev/null && echo "   Python:          $(python3 --version)"
  echo ""

}

# ── Wire Podman socket ────────────────────────────────────────────────────────
_wire_podman_socket() {
  if ! command -v podman &>/dev/null; then return; fi
  case "$OS" in
    mac)
      local sock
      sock="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo "")"
      if [[ -n "$sock" && -S "$sock" ]]; then
        export DOCKER_HOST="unix://$sock"
      else
        # Fallback: scan /var/folders for socket
        local fallback_sock="/var/folders/*/T/podman/podman-machine-default-api.sock"
        for s in $fallback_sock; do
          if [[ -S "$s" ]]; then
            export DOCKER_HOST="unix://$s"
            break
          fi
        done
      fi
      ;;
    linux|wsl)
      local uid_sock
      if [[ "$(id -u)" -eq 0 ]]; then
        uid_sock="/run/podman/podman.sock"
      else
        uid_sock="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
        if [[ -z "$uid_sock" ]]; then
          if [[ -n "$XDG_RUNTIME_DIR" ]]; then
            uid_sock="$XDG_RUNTIME_DIR/podman/podman.sock"
          else
            uid_sock="/tmp/podman-run-$(id -u)/podman/podman.sock"
          fi
        fi
      fi

      # WSL without systemd has no socket-activated Podman API. Traefik needs
      # this API to discover container labels; without it every route is a 404.
      # A socket file can remain behind after the API process exits, so test the
      # API itself instead of treating the presence of the file as healthy.
      local _socket_healthy=false
      if [[ -S "$uid_sock" ]] && command -v curl &>/dev/null && \
         curl --silent --fail --max-time 1 --unix-socket "$uid_sock" \
           http://localhost/_ping >/dev/null 2>&1; then
        _socket_healthy=true
      fi
      if [[ "$_socket_healthy" != "true" ]] && [[ ! -d /run/systemd/system ]]; then
        local _socket_pid_file="/tmp/podman-api-$(id -u).pid"
        local _socket_pid=""
        [[ -f "$_socket_pid_file" ]] && _socket_pid=$(cat "$_socket_pid_file" 2>/dev/null || true)
        # Only stop the recorded PID when it is actually our socket service;
        # PID numbers can be reused after an old pid file is left behind.
        if [[ "$_socket_pid" =~ ^[0-9]+$ ]] && kill -0 "$_socket_pid" 2>/dev/null; then
          local _socket_cmdline=""
          [[ -r "/proc/${_socket_pid}/cmdline" ]] && \
            _socket_cmdline=$(tr '\0' ' ' < "/proc/${_socket_pid}/cmdline" 2>/dev/null || true)
          [[ "$_socket_cmdline" == *"podman system service"* ]] && kill "$_socket_pid" 2>/dev/null || true
        fi
        rm -f "$uid_sock" "$_socket_pid_file" 2>/dev/null || true
        mkdir -p "$(dirname "$uid_sock")"
        _run_detached "/tmp/podman-api-$(id -u).log" "$_socket_pid_file" \
          podman system service --time=0 "unix://${uid_sock}"

        local _socket_wait=0
        while [[ $_socket_wait -lt 50 ]]; do
          if [[ -S "$uid_sock" ]] && \
             curl --silent --fail --max-time 1 --unix-socket "$uid_sock" \
               http://localhost/_ping >/dev/null 2>&1; then
            _socket_healthy=true
            break
          fi
          sleep 0.1
          _socket_wait=$((_socket_wait + 1))
        done
      fi

      if [[ -S "$uid_sock" ]]; then
        export DOCKER_HOST="unix://$uid_sock"
        export PODMAN_SOCK="$uid_sock"
      fi
      ;;
  esac
}

# ── Setup Java environment ────────────────────────────────────────────────────
_setup_java_env() {
  # Only needed on macOS for now
  if [[ "$OS" != "mac" ]]; then return 0; fi

  # Check if Java is already available and actually works (not just the macOS stub)
  if command -v java &>/dev/null && command -v keytool &>/dev/null; then
    # Verify Java actually works (not the macOS stub that shows "Unable to locate")
    if java -version &>/dev/null; then
      return 0
    fi
  fi

  # Try to find Java 21 from Homebrew
  local java_home=""
  for vm in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
            /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
            /Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home \
            /Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home; do
    if [[ -x "$vm/bin/java" ]]; then
      java_home="$vm"
      break
    fi
  done

  # Fallback to any available JVM
  if [[ -z "$java_home" ]]; then
    java_home="$(/usr/libexec/java_home 2>/dev/null || true)"
  fi

  if [[ -n "$java_home" && -x "$java_home/bin/java" ]]; then
    export JAVA_HOME="$java_home"
    export PATH="$java_home/bin:$PATH"
  else
    echo "⚠️  Java not found. Install with: brew install openjdk@21"
    return 1
  fi
}

# ── Detached double-fork helper ───────────────────────────────────────────────
# Usage: _run_detached <log_file> <pid_file> <cmd> [args...]
# Runs the given command completely detached from the terminal (survives close).
# Writes the spawned PID to <pid_file> so callers can track/kill the process.
#
# On Unix (macOS/Linux): uses double-fork to fully detach from terminal.
# On Windows (Git Bash/MSYS2): uses subprocess.Popen with DETACHED_PROCESS flag.
# NOTE: Uses a temp script file instead of a heredoc so this works correctly
# under both bash and zsh (heredocs inside functions are mangled by zsh).
_run_detached() {
  local log_file="$1"; local pid_file="$2"; shift 2
  local _script; _script=$(mktemp /tmp/_run_detached_XXXXXX.py)

  if [[ "$OS" == "windows" ]]; then
    # Windows: use subprocess.Popen with CREATE_NEW_PROCESS_GROUP + DETACHED_PROCESS
    printf '%s\n' \
      'import sys, os, subprocess' \
      'log_file = sys.argv[1]' \
      'pid_file = sys.argv[2]' \
      'cmd      = sys.argv[3:]' \
      'DETACHED_PROCESS = 0x00000008' \
      'CREATE_NEW_PROCESS_GROUP = 0x00000200' \
      'flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP' \
      'log_fd = open(log_file, "a")' \
      'try:' \
      '    p = subprocess.Popen(cmd, stdout=log_fd, stderr=log_fd,' \
      '                         stdin=subprocess.DEVNULL, creationflags=flags,' \
      '                         close_fds=True)' \
      '    if pid_file:' \
      '        with open(pid_file, "w") as f:' \
      '            f.write(str(p.pid) + "\n")' \
      'except Exception as e:' \
      '    print(f"_run_detached error: {e}", file=sys.stderr)' \
      'finally:' \
      '    log_fd.close()' \
      > "$_script"
  else
    # Unix (macOS/Linux/WSL): double-fork to detach from terminal session
    printf '%s\n' \
      'import sys, os, signal' \
      'log_file = sys.argv[1]' \
      'pid_file = sys.argv[2]' \
      'cmd      = sys.argv[3:]' \
      'pid = os.fork()' \
      'if pid > 0:' \
      '    os.waitpid(pid, 0); sys.exit(0)' \
      'os.setsid()' \
      'pid2 = os.fork()' \
      'if pid2 > 0:' \
      '    try:' \
      '        with open(pid_file, "w") as f:' \
      '            f.write(str(pid2) + "\n")' \
      '    except Exception:' \
      '        pass' \
      '    sys.exit(0)' \
      'signal.signal(signal.SIGHUP, signal.SIG_IGN)' \
      'devnull = os.open(os.devnull, os.O_RDWR)' \
      'os.dup2(devnull, 0)' \
      'log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)' \
      'os.dup2(log_fd, 1); os.dup2(log_fd, 2)' \
      'os.execvp(cmd[0], cmd)' \
      > "$_script"
  fi

  python3 "$_script" "$log_file" "$pid_file" "$@"
  rm -f "$_script"
}

# ── Enable systemd user-session lingering (Linux / WSL) ──────────────────────
# On Linux, rootless Podman containers are managed by conmon processes that live
# inside the user's systemd slice.  Without lingering, systemd-logind tears down
# that slice (and kills all containers) the moment the user's *last* terminal
# session closes — even if `restart: unless-stopped` is set.
#
# `loginctl enable-linger` keeps the user slice alive indefinitely, so containers
# survive terminal close and auto-restart as configured.  This is the canonical
# fix documented in the Podman rootless-containers guide.
#
# Also enables podman.socket so the Podman API socket starts automatically on
# login (needed for podman-compose to connect after a reboot without running
# `podman system service` manually).
_ensure_lingering() {
  # Lingering only applies to rootless Podman under a running systemd/logind.
  # The Windows bootstrap currently runs WSL as root; rootful containers are not
  # tied to a user slice, and loginctl is commonly installed but offline there.
  [[ "$OS" == "linux" || "$OS" == "wsl" ]] || return 0
  [[ "$(id -u)" -ne 0 ]] || return 0
  [[ -d /run/systemd/system ]] || return 0
  command -v loginctl &>/dev/null || return 0  # no systemd-logind → skip

  local linger_ok=false
  loginctl show-user "$USER" --property=Linger 2>/dev/null \
    | grep -q "Linger=yes" && linger_ok=true

  if ! $linger_ok; then
    echo "🔒 Enabling persistent user session so containers survive terminal close..."
    loginctl enable-linger "$USER" 2>/dev/null \
      && echo "✅ Lingering enabled for $USER" \
      || echo "⚠️  Could not enable lingering (try: loginctl enable-linger $USER)"
  fi

  # Enable the Podman API socket so containers are managed even after reboot
  if command -v systemctl &>/dev/null; then
    systemctl --user enable --now podman.socket 2>/dev/null || true
  fi
}

# ── Manual health check runner (WSL2 / no-systemd fallback) ──────────────────
# On WSL2 without systemd, Podman's health check timer unit never starts, so
# containers stay stuck at "starting" forever even when they are actually healthy.
# This function detects that situation and spawns a lightweight background loop
# that calls `podman healthcheck run` for every project container every 5 seconds,
# which is all that's needed to update the health status in Podman's state store.
# It is completely safe to call on systemd systems — it just exits immediately.
_start_healthcheck_runner() {
  [[ "$OS" == "linux" || "$OS" == "wsl" ]] || return 0
  # If systemd is PID 1, Podman's own timer handles it — nothing to do.
  local _init; _init=$(cat /proc/1/comm 2>/dev/null || true)
  if [[ "$_init" == "systemd" ]]; then return 0; fi

  local _pid_file="/tmp/${PROJECT_NAME}-healthcheck-runner.pid"
  local _log_file="/tmp/${PROJECT_NAME}-healthcheck-runner.log"

  # Keep a live runner. A previous version wrote $$ from inside the background
  # subshell; in Bash that is the parent dev.sh PID, so the next launch killed
  # dev.sh itself here before it could open live_monitor.
  if [[ -f "$_pid_file" ]]; then
    local _epid; _epid=$(cat "$_pid_file" 2>/dev/null || true)
    if [[ "$_epid" =~ ^[0-9]+$ ]] && kill -0 "$_epid" 2>/dev/null \
      && [[ "$(ps -p "$_epid" -o args= 2>/dev/null)" == *"_project-healthchecks $PROJECT_NAME"* ]]; then
      return 0
    fi
    rm -f "$_pid_file"
  fi

  # Spawn detached runner:
  #  - Phase 1: 15 rapid rounds at 2s intervals to satisfy retries=10 fast
  #  - Phase 2: steady 5s poll forever
  # Ignore terminal hangups and detach all standard streams. disown alone does
  # not protect a background subshell when its WSL launcher closes.
  nohup bash -c '
    PROJECT_NAME="$1"
    _log_file="$2"
    _run_checks() {
      while IFS= read -r _cname; do
        [[ -z "$_cname" ]] && continue
        # Workers and other services can legitimately omit a health check.
        [[ "$(podman inspect --format "{{if .Config.Healthcheck}}yes{{end}}" "$_cname" 2>/dev/null)" == yes ]] || continue
        # podman may read from stdin. Without /dev/null it consumes the process
        # substitution feeding this loop, so only the first container is checked.
        podman healthcheck run "$_cname" </dev/null >> "$_log_file" 2>&1 || true
      done < <(podman ps \
        --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
        --format "{{.Names}}" 2>/dev/null)
    }
    # Phase 1 — burst: 15 rounds × 2s = 30s to flip all containers healthy
    for _i in $(seq 1 15); do
      _run_checks
      sleep 2
    done
    # Phase 2 — steady poll
    while true; do
      _run_checks
      sleep 5
    done
  ' _project-healthchecks "$PROJECT_NAME" "$_log_file" </dev/null >> "$_log_file" 2>&1 &
  local _runner_pid=$!
  echo "$_runner_pid" > "$_pid_file"
  disown "$_runner_pid" 2>/dev/null || true
}

# ── Update mobile API URL with current local IP ──────────────────────────────
# Automatically detects the Mac's local IP address and updates EXPO_PUBLIC_API_URL
# in .env so the mobile app can connect to the backend even when the IP changes.
update_mobile_ip() {
  # Deprecated: Mobile apps now use Cloudflare Tunnel or localhost
  # No need to auto-update IP addresses
  return 0
}

# ── Mobile app discovery ──────────────────────────────────────────────────────
# NOTE: defined here (before _start_cloudflare_tunnel and the stop/down block)
# so it is available when _stop_cloudflare_tunnel calls it during `./dev.sh down`.
discover_apps() {
  MOBILE_APPS=()
  [[ -d "$MOBILE_DIR" ]] || return 0
  # Discover folders with package.json; optional ordering lives in project.py.
  local _discovered name
  _discovered=$(python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" mobile-apps) || return
  while IFS= read -r name; do
    [[ -n "$name" ]] && MOBILE_APPS+=("$name")
  done <<< "$_discovered"
  return 0
}

has_mobile_apps() {
  discover_apps
  [[ ${#MOBILE_APPS[@]} -gt 0 ]]
}

folder_to_service() {
  echo "mobile-$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
}

# ── Ensure Metro rewriting proxies are running ───────────────────────────────
# Idempotent — starts a proxy for each Metro app port if not already running.
# Called both on fresh tunnel start and when reusing an existing tunnel.
_ensure_metro_proxies() {
  discover_apps
  local _port=8081
  for _folder in "${MOBILE_APPS[@]}"; do
    local _metro_proxy_port=$(( _port + 1000 ))
    local _metro_proxy_pid_file="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.pid"
    local _metro_proxy_script="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.py"
    local _metro_proxy_log="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.log"
    local _metro_tunnel_url
    _metro_tunnel_url=$(grep "^METRO_TUNNEL_URL_${_port}=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")

    # Check if already running with the correct tunnel URL
    if [[ -f "$_metro_proxy_pid_file" ]]; then
      local _epid; _epid=$(cat "$_metro_proxy_pid_file" 2>/dev/null || true)
      if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
        if ps -p "$_epid" -o args= 2>/dev/null | grep -qF "$_metro_tunnel_url"; then
          _port=$(( _port + 1 )); continue
        fi
        kill "$_epid" 2>/dev/null || true; sleep 0.2
      fi
      rm -f "$_metro_proxy_pid_file"
    fi

    # (Re)write the proxy script — always keep it fresh
    local _p="$_port" _pp="$_metro_proxy_port"
    cat > "$_metro_proxy_script" << 'METRO_PROXY_EOF'
import sys, socket, threading, os

metro_port = int(sys.argv[1])
proxy_port = int(sys.argv[2])
pid_file   = sys.argv[3] if len(sys.argv) > 3 else None
tunnel_url = (sys.argv[4].rstrip('/') if len(sys.argv) > 4 else '').encode()

def recv_all(sock, n):
    buf = b''
    while len(buf) < n:
        d = sock.recv(n - len(buf))
        if not d: break
        buf += d
    return buf

def read_http_response(sock):
    head = b''
    sock.settimeout(30)
    while b'\r\n\r\n' not in head:
        c = sock.recv(1)
        if not c: return b'', b''
        head += c
    lines = head.split(b'\r\n')
    headers = {}
    for line in lines[1:]:
        if b':' in line:
            k, _, v = line.partition(b':')
            headers[k.strip().lower()] = v.strip()
    body = b''
    cl = headers.get(b'content-length')
    te = headers.get(b'transfer-encoding', b'')
    if cl:
        body = recv_all(sock, int(cl))
    elif b'chunked' in te:
        while True:
            size_line = b''
            while not size_line.endswith(b'\r\n'):
                c = sock.recv(1)
                if not c: break
                size_line += c
            try: size = int(size_line.strip(), 16)
            except ValueError: break
            if size == 0: sock.recv(2); break
            body += recv_all(sock, size)
            sock.recv(2)
    return head, body

def handle(client):
    up = None
    try:
        up = socket.create_connection(('127.0.0.1', metro_port), timeout=10)
        req = b''
        client.settimeout(10)
        while b'\r\n\r\n' not in req:
            c = client.recv(1)
            if not c: break
            req += c
        if not req: return
        up.sendall(req)
        head, body = read_http_response(up)
        if not head: return
        ct = b''
        for line in head.split(b'\r\n')[1:]:
            if line.lower().startswith(b'content-type:'):
                ct = line.lower()
        is_text = any(t in ct for t in [b'json', b'javascript', b'text'])
        if tunnel_url and is_text and body:
            old = ('localhost:' + str(metro_port)).encode()
            body = body.replace(b'http://' + old, tunnel_url)
            body = body.replace(old, tunnel_url)
        new_lines = []
        for line in head.split(b'\r\n'):
            ll = line.lower()
            if ll.startswith(b'transfer-encoding:') or ll.startswith(b'content-length:'):
                continue
            if not line:
                continue  # strip existing blank line — we add \r\n\r\n below
            new_lines.append(line)
        new_lines.append(b'Content-Length: ' + str(len(body)).encode())
        client.sendall(b'\r\n'.join(new_lines) + b'\r\n\r\n' + body)
    except Exception: pass
    finally:
        for s in (client, up):
            try: s and s.close()
            except Exception: pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: srv.bind(('127.0.0.1', proxy_port))
except OSError: sys.exit(1)
srv.listen(256)
if pid_file:
    with open(pid_file, 'w') as f: f.write(str(os.getpid()) + '\n')
while True:
    try:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except Exception: pass
METRO_PROXY_EOF

    nohup python3 "$_metro_proxy_script" "$_port" "$_metro_proxy_port" \
      "$_metro_proxy_pid_file" "$_metro_tunnel_url" \
      >> "$_metro_proxy_log" 2>&1 &
    disown $! 2>/dev/null || true

    local _w=0
    while [[ $_w -lt 10 ]]; do
      python3 -c "import socket; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',${_metro_proxy_port})); s.close()" 2>/dev/null && break
      sleep 0.2; _w=$(( _w + 1 ))
    done

    _port=$(( _port + 1 ))
  done
}

# ── Ensure Metro cloudflared tunnel processes are running ────────────────────
# Checks each Metro port's cloudflared process and restarts any that died.
# This is separate from _ensure_metro_proxies (which manages the rewriting proxy).
# Both must be running for physical-device Metro access via Cloudflare Tunnel.
_ensure_metro_tunnels() {
  grep -Eq '^DISABLE_PUBLIC_TUNNELS=true\r?$' "$ROOT_DIR/.env" && return 0
  discover_apps
  [[ ${#MOBILE_APPS[@]} -eq 0 ]] && return 0

  local _port=8081
  for _folder in "${MOBILE_APPS[@]}"; do
    local metro_proxy_port=$(( _port + 1000 ))
    local metro_log="/tmp/${PROJECT_NAME}-metro-${_port}.log"
    local metro_pid_file="/tmp/${PROJECT_NAME}-metro-${_port}.pid"

    local _named_token _configured_url
    _named_token=$(sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' "$ROOT_DIR/.env" | tr -d '\r')
    _configured_url=$(sed -n "s/^METRO_TUNNEL_URL_${_port}=//p" "$ROOT_DIR/.env" | tr -d '\r')
    if [[ -n "$_named_token" ]]; then
      # Named mode never silently falls back to an address that will change.
      if [[ "$_configured_url" != https://* || "$_configured_url" == *trycloudflare.com* ]]; then
        echo "⚠️  Set a fixed METRO_TUNNEL_URL_${_port} hostname for ${_folder} in .env"
      fi
      # All fixed Metro hostnames are routed by the main named connector.
      _port=$(( _port + 1 ))
      continue
    fi

    # Check if cloudflared process is still alive
    local _alive=false
    if [[ -f "$metro_pid_file" ]]; then
      local _mpid; _mpid=$(cat "$metro_pid_file" 2>/dev/null || true)
      [[ -n "$_mpid" ]] && kill -0 "$_mpid" 2>/dev/null && _alive=true
    fi

    # A quick tunnel can expire while cloudflared keeps retrying forever.
    if [[ "$_alive" == "true" ]] && tail -20 "$metro_log" 2>/dev/null | grep -q 'Unauthorized: Tunnel not found'; then
      kill "$_mpid" 2>/dev/null || true
      rm -f "$metro_pid_file"
      _alive=false
      sleep 1
      kill -9 "$_mpid" 2>/dev/null || true
    fi

    # Also re-adopt orphaned cloudflared process for this proxy port
    if [[ "$_alive" == "false" ]]; then
      local _candidate
      _candidate=$(pgrep -f "cloudflared tunnel.*--url http://localhost:${metro_proxy_port}" 2>/dev/null | head -1 || true)
      if [[ -n "$_candidate" ]]; then
        echo "$_candidate" > "$metro_pid_file"
        _alive=true
      fi
    fi

    if [[ "$_alive" == "false" ]]; then
      # Start the Metro rewriting proxy first (needed before cloudflared)
      _ensure_metro_proxies 2>/dev/null || true

      # (Re)start cloudflared for this Metro port
      rm -f "$metro_log"
      _run_detached "$metro_log" "$metro_pid_file" \
        cloudflared tunnel --protocol http2 --url "http://localhost:${metro_proxy_port}"

      # Wait up to 60s for tunnel URL
      local _attempts=0 _metro_url=""
      while [[ $_attempts -lt 120 ]]; do
        _metro_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$metro_log" 2>/dev/null | head -1 || true)
        [[ -n "$_metro_url" ]] && break
        sleep 0.5; _attempts=$((_attempts + 1))
      done

      if [[ -n "$_metro_url" ]]; then
        local env_key="METRO_TUNNEL_URL_${_port}"
        if grep -q "^${env_key}=" "$ROOT_DIR/.env" 2>/dev/null; then
          _sed_inplace "s|^${env_key}=.*|${env_key}=${_metro_url}|" "$ROOT_DIR/.env"
        else
          echo "${env_key}=${_metro_url}" >> "$ROOT_DIR/.env"
        fi
        echo "   📱 ${_folder} Metro tunnel:  $_metro_url"

        # Restart the rewriting proxy with the real tunnel URL
        local metro_proxy_pid_file="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.pid"
        local metro_proxy_script="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.py"
        local metro_proxy_log="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.log"
        if [[ -f "$metro_proxy_pid_file" ]]; then
          local _old_pp; _old_pp=$(cat "$metro_proxy_pid_file" 2>/dev/null || true)
          [[ -n "$_old_pp" ]] && kill "$_old_pp" 2>/dev/null || true
          rm -f "$metro_proxy_pid_file"
        fi
        sleep 0.2
        nohup python3 "$metro_proxy_script" "$_port" "$metro_proxy_port" \
          "$metro_proxy_pid_file" "$_metro_url" \
          >> "$metro_proxy_log" 2>&1 &
        disown $! 2>/dev/null || true
      fi
    fi

    _port=$(( _port + 1 ))
  done
}

# ── Ensure macOS DNS can resolve trycloudflare.com subdomains ────────────────
# trycloudflare.com subdomains are freshly-assigned per tunnel session.
# Home/office routers often have aggressive TTL caching or return NXDOMAIN for
# unknown subdomains. Cloudflare's own resolvers (1.1.1.1 / 1.0.0.1) always
# have the correct answer. This function adds them to Wi-Fi DNS if not already
# present — completely idempotent, never removes existing servers.
# Also flushes the mDNSResponder cache so the new entry is live immediately.
_ensure_cloudflare_dns() {
  [[ "$OS" == "mac" ]] || return 0
  command -v networksetup &>/dev/null || return 0

  # Find the active network interface (first connected Wi-Fi or Ethernet)
  local _iface=""
  while IFS= read -r _svc; do
    [[ "$_svc" == An* ]] && continue   # "An asterisk (*) denotes..."
    [[ "$_svc" == \** ]] && continue   # disabled service
    # Accept Wi-Fi and Ethernet services
    if echo "$_svc" | grep -qiE "wi-fi|wifi|ethernet|en[0-9]"; then
      _iface="$_svc"
      break
    fi
  done < <(networksetup -listallnetworkservices 2>/dev/null)

  [[ -z "$_iface" ]] && _iface="Wi-Fi"  # safe default

  # Read current DNS servers for this interface
  local _current
  _current=$(networksetup -getdnsservers "$_iface" 2>/dev/null || true)

  # Already has 1.1.1.1? Nothing to do — no sudo needed.
  if echo "$_current" | grep -qF "1.1.1.1"; then
    # Always flush cache on startup so fresh trycloudflare.com subdomains resolve.
    # sudo -n = non-interactive (never prompts); falls back silently if no cached creds.
    sudo -n dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
    sudo -n killall -HUP mDNSResponder 2>/dev/null || killall -HUP mDNSResponder 2>/dev/null || true
    return 0
  fi

  echo "🔧 Adding Cloudflare DNS (1.1.1.1) to $_iface so tunnel URLs resolve correctly..."

  # Build new DNS list: prepend 1.1.1.1 + 1.0.0.1, keep existing servers after
  local _new_servers="1.1.1.1 1.0.0.1"
  # If there were existing custom servers (not "There aren't any"), append them
  if ! echo "$_current" | grep -qi "There aren't any"; then
    while IFS= read -r _s; do
      [[ -z "$_s" ]] && continue
      _new_servers="$_new_servers $_s"
    done <<< "$_current"
  fi

  # Try non-interactive sudo first (works if credentials are cached from this session).
  # If that fails, ask once with a clear explanation — this is a one-time setup.
  if ! sudo -n networksetup -setdnsservers "$_iface" $_new_servers 2>/dev/null; then
    echo "   ℹ️  One-time setup: adding 1.1.1.1 to DNS so tunnel URLs always resolve."
    sudo -p "   [sudo] password (one-time DNS setup): " \
      networksetup -setdnsservers "$_iface" $_new_servers 2>/dev/null || {
      echo "   ⚠️  Could not set DNS automatically — tunnel URLs may not resolve."
      echo "      Fix manually: System Settings → Wi-Fi → Details → DNS → add 1.1.1.1"
      return 0
    }
  fi

  # Flush cache so the new resolver is used immediately
  sudo -n dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
  sudo -n killall -HUP mDNSResponder 2>/dev/null || killall -HUP mDNSResponder 2>/dev/null || true

  echo "✅ DNS updated — tunnel URLs will now resolve correctly"
}

# ── Start Cloudflare Tunnel automatically ────────────────────────────────────
# Always attempts the tunnel. Falls back to localhost silently if:
#   - cloudflared is not installed
#   - no internet connection
#   - tunnel URL never appears (hung process)
# Emulators/simulators always work regardless — they use LAN IP directly.
#
# With the shared Traefik architecture, each project gets its own cloudflared
# process on a unique high port (derived from PROJECT_NAME hash). The tunnel
# points at that port, and a local socat/nc proxy forwards it into the shared
# Traefik with the correct Host header for this project.
# This gives every project a completely independent tunnel URL.
_start_cloudflare_tunnel() {
  if grep -Eq '^DISABLE_PUBLIC_TUNNELS=true\r?$' "$ROOT_DIR/.env"; then
    _stop_cloudflare_tunnel
    return 0
  fi
  # Projects own their public-access preparation. The shared launcher only
  # discovers the command and recreates services it reports as stale.
  local _prepare_output _prepare_command=() _prepare_services=() _prepare_arg
  _prepare_output=$(python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" exposure-prepare-command) || return 1
  if [[ -n "$_prepare_output" ]]; then
    while IFS= read -r _prepare_arg; do _prepare_command+=("$_prepare_arg"); done <<< "$_prepare_output"
    if ! _prepare_output=$(bash "$ROOT_DIR/dev.sh" "${_prepare_command[@]}"); then
      _stop_cloudflare_tunnel
      echo "Public tunnel disabled: project preparation failed."
      return 1
    fi
    if [[ -n "$_prepare_output" ]]; then
      while IFS= read -r _prepare_arg; do
        [[ "$_prepare_arg" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
        _prepare_services+=("$_prepare_arg")
      done <<< "$_prepare_output"
      echo "🔧 Applying public-access settings to ${_prepare_services[*]}..."
      if ! "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" up -d --no-deps --build --force-recreate "${_prepare_services[@]}" >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1; then
        _stop_cloudflare_tunnel
        echo "Public tunnel disabled: service update failed. Check /tmp/${PROJECT_NAME}-compose.log"
        return 1
      fi
      # Entry points must finish migrations and account creation before checks.
      local _ready=false _wait _backend
      _backend=$(podman ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" --filter "label=com.docker.compose.service=backend" --format '{{.Names}}' | head -1)
      for _wait in $(seq 1 60); do
        if [[ -n "$_backend" ]] && [[ "$(podman inspect --format '{{.State.Health.Status}}' "$_backend" 2>/dev/null)" == healthy ]]; then
          _ready=true; break
        fi
        sleep 2
      done
      if [[ "$_ready" != true ]]; then
        _stop_cloudflare_tunnel
        echo "Public tunnel disabled: backend did not become healthy."
        return 1
      fi
    fi
  fi
  if python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" has-exposure-check; then
    if ! bash "$ROOT_DIR/dev.sh" _exposure_check_only; then
      _stop_cloudflare_tunnel
      echo "Public tunnel disabled: project security checks did not pass."
      return 0
    fi
  fi
  # Auto-install cloudflared if missing — no manual step required
  if ! command -v cloudflared &>/dev/null; then
    echo "📦 Installing cloudflared (Cloudflare Tunnel)..."
    case "$OS" in
      mac)
        if command -v brew &>/dev/null; then
          brew install cloudflared 2>&1 | tail -3 || true
        else
          echo "⚠️  Homebrew not found — cannot auto-install cloudflared"
          _clear_tunnel_urls; return 0
        fi
        ;;
      linux|wsl)
        if command -v apt-get &>/dev/null; then
          curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null 2>&1 || true
          echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null 2>&1 || true
          sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq cloudflared 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
          sudo dnf install -y cloudflared 2>/dev/null || true
        else
          echo "⚠️  Cannot auto-install cloudflared on this Linux distro"
          _clear_tunnel_urls; return 0
        fi
        ;;
      *)
        echo "⚠️  cloudflared not installed — running without tunnel"
        _clear_tunnel_urls; return 0
        ;;
    esac
    # Re-wire PATH so newly installed cloudflared is found
    if [[ "$OS" == "mac" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
        || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
    fi
    if ! command -v cloudflared &>/dev/null; then
      echo "⚠️  cloudflared install failed — running without tunnel"
      _clear_tunnel_urls; return 0
    fi
    echo "✅ cloudflared installed ($(cloudflared --version 2>&1 | head -1))"
  fi

  # Ensure macOS DNS can resolve fresh trycloudflare.com subdomains
  _ensure_cloudflare_dns

  # Check for internet connectivity before attempting tunnel.
  # Retry up to 5 times with a short sleep — the Podman machine startup can
  # briefly disrupt the Mac's network interface, causing a false negative.
  local _net_ok=false
  for _net_try in 1 2 3 4 5; do
    if curl -sf --max-time 5 https://cloudflare.com >/dev/null 2>&1; then
      _net_ok=true
      break
    fi
    [[ $_net_try -lt 5 ]] && sleep 2
  done
  if [[ "$_net_ok" == "false" ]]; then
    echo "ℹ️  No internet — preserving tunnel addresses for reconnection"
    return 0
  fi

  local _tunnel_token
  _tunnel_token=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' || true)
  local _retry_file="/tmp/${PROJECT_NAME}-tunnel-retry-after"
  if [[ -z "$_tunnel_token" && -f "$_retry_file" ]]; then
    local _retry_after _retry_now
    _retry_after=$(cat "$_retry_file" 2>/dev/null || echo 0)
    _retry_now=$(date +%s)
    if [[ "$_retry_after" =~ ^[0-9]+$ ]] && [[ "$_retry_after" -gt "$_retry_now" ]]; then
      echo "⏳ Cloudflare quick-tunnel cooldown active — retrying automatically in $(( _retry_after - _retry_now ))s"
      return 0
    fi
    rm -f "$_retry_file"
  fi

  local tunnel_log="/tmp/${PROJECT_NAME}-tunnel.log"
  local tunnel_pid_file="/tmp/${PROJECT_NAME}-tunnel.pid"
  local _local_host="${PROJECT_HOST}.localhost"

  # A failed HTTP/DNS/metrics probe is not proof that a tunnel lease died.
  # Let cloudflared reconnect using its existing identity after network loss.
  local _saved_url _saved_pid
  _saved_url=$(sed -n 's/^CLOUDFLARE_TUNNEL_URL=//p' "$ROOT_DIR/.env" | tr -d '\r')
  if [[ -n "$_tunnel_token" && ( "$_saved_url" != https://* || "$_saved_url" == *trycloudflare.com* ) ]]; then
    echo "⚠️  Named tunnel requires a fixed CLOUDFLARE_TUNNEL_URL=https://your-hostname in .env"
    return 0
  fi
  _saved_pid=$(cat "$tunnel_pid_file" 2>/dev/null || true)
  if [[ -z "$_tunnel_token" ]] && { [[ ! "$_saved_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$_saved_pid" 2>/dev/null; }; then
    _saved_pid=$(pgrep -f "cloudflared tunnel.*--http-host-header ${_local_host}" 2>/dev/null | head -1 || true)
  fi
  if [[ "$_saved_pid" =~ ^[0-9]+$ ]] && kill -0 "$_saved_pid" 2>/dev/null &&
      ps -p "$_saved_pid" -o args= | grep -q '[c]loudflared tunnel'; then
    if [[ -n "$_tunnel_token" ]] || ! tail -20 "$tunnel_log" 2>/dev/null | grep -q 'Unauthorized: Tunnel not found'; then
      echo "$_saved_pid" > "$tunnel_pid_file"
      if [[ -z "$_tunnel_token" ]]; then
        # The live connector owns its URL; .env may have been copied from an
        # older workspace. Never register an old hostname against a new lease.
        _saved_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$tunnel_log" | head -1 || true)
      fi
      echo "✅ Keeping existing Cloudflare Tunnel (including while reconnecting)"
      if [[ -n "$_saved_url" ]]; then
        _save_tunnel_url "$_saved_url"
        _register_tunnel_with_traefik "$_saved_url"
      fi
      _sync_metro_tunnel_urls_from_logs
      _ensure_metro_proxies
      _ensure_metro_tunnels
      return 0
    fi
  fi

  echo "🌐 Starting Cloudflare Tunnel for ${PROJECT_DISPLAY_NAME}..."

  # Kill any leftover tunnel process
  if [[ -f "$tunnel_pid_file" ]]; then
    local _old_pid; _old_pid=$(cat "$tunnel_pid_file" 2>/dev/null || true)
    [[ -n "$_old_pid" ]] && kill "$_old_pid" 2>/dev/null || true
    rm -f "$tunnel_pid_file"
  fi
  # Also kill any stale proxy from the old approach
  local _old_proxy_pid_file="/tmp/${PROJECT_NAME}-tunnel-proxy.pid"
  if [[ -f "$_old_proxy_pid_file" ]]; then
    local _old_pp; _old_pp=$(cat "$_old_proxy_pid_file" 2>/dev/null || true)
    [[ -n "$_old_pp" ]] && kill "$_old_pp" 2>/dev/null || true
    rm -f "$_old_proxy_pid_file"
  fi
  sleep 0.3

  # ── Start cloudflared with native host-header rewriting ─────────────────────
  # --url          points cloudflared at Traefik's port 80 on the host
  # --http-host-header  rewrites Host header so Traefik routes to the right project
  # --protocol http2   forces TCP/HTTP2 — QUIC (the default) causes persistent
  #   "control stream failure" reconnection loops on some network configurations.
  # --proxy-connect-timeout  keeps it from giving up on a slow Traefik start
  #   (--origin-server-connect-timeout was removed in cloudflared ≥ 2026.x)
  # No Python proxy needed — cloudflared handles the Host rewrite natively.
  #
  # Named tunnel mode: if CLOUDFLARE_TUNNEL_TOKEN is set in .env, use it.
  # This gives a stable, persistent URL that survives machine restarts and works
  # from any location — ideal for testing from remote machines.
  # To set up: create a tunnel at dash.cloudflare.com > Zero Trust > Networks > Tunnels
  # then copy the token into .env as: CLOUDFLARE_TUNNEL_TOKEN=<token>
  rm -f "$tunnel_log"
  if [[ -n "$_tunnel_token" ]]; then
    # Named tunnel: URL is stable and configured in the Cloudflare dashboard.
    # cloudflared run --token handles routing internally — no --url or Host header needed.
    echo "🔑 Using named Cloudflare Tunnel (stable URL)..."
    _run_detached "$tunnel_log" "$tunnel_pid_file" \
      cloudflared tunnel \
        --protocol http2 \
        --no-autoupdate \
        run --token "$_tunnel_token"
  else
    _run_detached "$tunnel_log" "$tunnel_pid_file" \
      cloudflared tunnel \
        --protocol http2 \
        --url "http://localhost:80" \
        --http-host-header "${_local_host}" \
        --proxy-connect-timeout 30s
  fi
  sleep 0.3

  # Web recovery must not replace independent Metro tunnel identities.
  _ensure_metro_proxies
  _ensure_metro_tunnels

  # ── Wait for webapp tunnel URL (up to 90s) ──────────────────────────────────
  # Named hostnames come from configuration; quick hostnames come from logs.
  local attempts=0 tunnel_url="" _last_dot=0
  printf "   ⏳ Waiting for tunnel URL"
  while [[ $attempts -lt 180 ]]; do
    # Quick tunnel URL
    tunnel_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$tunnel_log" 2>/dev/null | head -1 || true)
    # Named tunnel: look for "Registered tunnel connection" or the configured hostname
    if [[ -z "$tunnel_url" ]] && [[ -n "$_tunnel_token" ]]; then
      tunnel_url="$_saved_url"
    fi
    [[ -n "$tunnel_url" ]] && break
    # Cloudflare has already rejected this quick-tunnel request. Do not wait
    # the full 90 seconds or let repeated launcher runs amplify the rate limit.
    if grep -q "429\|Too Many Requests\|error code: 1015" "$tunnel_log" 2>/dev/null; then
      break
    fi
    local _now; _now=$(( attempts / 10 ))
    if [[ $_now -gt $_last_dot ]]; then
      printf "."
      _last_dot=$_now
    fi
    sleep 0.5; attempts=$((attempts + 1))
  done
  echo ""

  if [[ -z "$tunnel_url" ]]; then
    # Check if Cloudflare rate-limited us (429)
    if grep -q "429\|Too Many Requests\|error code: 1015" "$tunnel_log" 2>/dev/null; then
      echo $(( $(date +%s) + 600 )) > "$_retry_file"
      echo "⚠️  Cloudflare rate-limited tunnel creation (429 Too Many Requests)"
      echo "   Too many tunnels were created in a short period."
      echo "   ⏳ Wait ~10 minutes, then run ./dev.sh again."
      echo "   ℹ️  App is still accessible at https://${PROJECT_HOST}.localhost"
    else
      echo "⚠️  Tunnel did not start in time — running without tunnel"
      echo "   Check: tail -f $tunnel_log"
    fi
    return 0
  fi

  echo "✅ Tunnel: $tunnel_url"
  rm -f "$_retry_file"
  _save_tunnel_url "$tunnel_url"
  # Flush macOS DNS cache so the new trycloudflare.com subdomain resolves immediately.
  # sudo -n = non-interactive, never prompts — silently skips if no cached credentials.
  if [[ "$OS" == "mac" ]]; then
    sudo -n dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
    sudo -n killall -HUP mDNSResponder 2>/dev/null || killall -HUP mDNSResponder 2>/dev/null || true
  fi
  # Register the tunnel hostname with Traefik so it routes traffic correctly
  _register_tunnel_with_traefik "$tunnel_url"

  _sync_metro_tunnel_urls_from_logs
  _ensure_metro_proxies

}

# ── Per-project tunnel proxy ──────────────────────────────────────────────────
# Listens on 127.0.0.1:$proxy_port, rewrites the Host header to $local_host
# (e.g. myproject.com.localhost), and forwards to Traefik on port 80.
#
# This is the key piece that makes multi-project tunnels work without DNS:
#   cloudflared → localhost:$proxy_port → proxy rewrites Host → Traefik:80
#   Traefik sees Host: myproject.com.localhost and routes to the right containers.
#   The trycloudflare.com hostname only needs to resolve on Cloudflare's edge.
_start_tunnel_proxy() {
  local proxy_port="$1"
  local local_host="$2"
  local pid_file="/tmp/${PROJECT_NAME}-tunnel-proxy.pid"
  local proxy_script="/tmp/${PROJECT_NAME}-tunnel-proxy.py"

  # Already running and healthy?
  if [[ -f "$pid_file" ]]; then
    local _existing_pid; _existing_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$_existing_pid" ]] && kill -0 "$_existing_pid" 2>/dev/null; then
      if python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1',${proxy_port})); s.close()" 2>/dev/null; then
        return 0
      fi
      kill "$_existing_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  # Write proxy script using a heredoc with quoted delimiter to avoid escaping issues
  cat > "$proxy_script" << 'PROXY_SCRIPT'
import sys, socket, threading, re, os
proxy_port = int(sys.argv[1])
local_host = sys.argv[2].encode()
pid_file = sys.argv[3] if len(sys.argv) > 3 else None
HOST_RE = re.compile(rb"(?im)^Host:[ \t]*[^\r\n]*\r?\n")
def read_headers(sock):
    buf = b""
    sock.settimeout(10)
    while b"\r\n\r\n" not in buf and b"\n\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk: break
        buf += chunk
    return buf
def pipe(src, dst, ev):
    try:
        while not ev.is_set():
            src.settimeout(60)
            d = src.recv(65536)
            if not d: break
            dst.sendall(d)
    except Exception: pass
    finally:
        ev.set()
        try: src.shutdown(socket.SHUT_RD)
        except Exception: pass
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass
def connect_upstream():
    # Port 18080: Traefik's dedicated tunnel entrypoint (127.0.0.1 bound on host).
    # Falls back to port 80 if 18080 is not yet available (e.g. before Traefik restart).
    for port in (18080, 80):
        for host in ("127.0.0.1", "::1", "localhost"):
            try:
                return socket.create_connection((host, port), timeout=5)
            except OSError:
                continue
    raise OSError("Cannot connect to Traefik upstream")
def handle(client):
    up = None
    try:
        up = connect_upstream()
        data = read_headers(client)
        if not data: return
        client_addr = client.getpeername()[0].encode()
        if HOST_RE.search(data):
            data = HOST_RE.sub(b"Host: " + local_host + b"\r\n", data, count=1)
        else:
            i = data.find(b"\r\n")
            if i != -1: data = data[:i+2] + b"Host: " + local_host + b"\r\n" + data[i+2:]
        headers_end = data.find(b"\r\n\r\n")
        if headers_end == -1: headers_end = data.find(b"\n\n")
        if headers_end != -1:
            fwd_proto = b"X-Forwarded-Proto: https\r\n"
            fwd_host = b"X-Forwarded-Host: " + data.split(b"Host: ")[1].split(b"\r\n")[0] + b"\r\n"
            fwd_for = b"X-Forwarded-For: " + client_addr + b"\r\n"
            real_ip = b"X-Real-IP: " + client_addr + b"\r\n"
            data = data[:headers_end+2] + fwd_proto + fwd_host + fwd_for + real_ip + data[headers_end+2:]
        up.sendall(data)
        ev = threading.Event()
        t1 = threading.Thread(target=pipe, args=(up, client, ev), daemon=True)
        t2 = threading.Thread(target=pipe, args=(client, up, ev), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
    except Exception: pass
    finally:
        for s in (client, up):
            try: s and s.close()
            except Exception: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: srv.bind(("127.0.0.1", proxy_port))
except OSError: sys.exit(1)
srv.listen(256)
if pid_file:
    with open(pid_file, "w") as f: f.write(str(os.getpid()) + "\n")
while True:
    try:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except Exception: pass
PROXY_SCRIPT

  # Start proxy using _run_detached so it survives terminal close
  # Use absolute path to avoid path resolution issues
  local _proxy_script_abs="/tmp/${PROJECT_NAME}-tunnel-proxy.py"
  _run_detached "/tmp/${PROJECT_NAME}-tunnel-proxy.log" "$pid_file" \
    python3 "$_proxy_script_abs" "$proxy_port" "$local_host" "$pid_file"

  # Wait up to 3s for it to start listening
  local _w=0
  while [[ $_w -lt 15 ]]; do
    if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1',${proxy_port})); s.close()" 2>/dev/null; then
      break
    fi
    sleep 0.2; _w=$((_w + 1))
  done
}

# ── Register tunnel URL with Traefik via file provider ────────────────────────
# Writes a dynamic config YAML to /tmp/traefik-dynamic/ inside the Podman VM,
# which Traefik watches. This works with Podman (which has no `podman label add`
# command unlike Docker). Traefik picks up the file within ~100ms — no restart.
_register_tunnel_with_traefik() {
  local tunnel_url="$1"
  local tunnel_host="${tunnel_url#https://}"
  tunnel_host="${tunnel_host%/}"

  local _fe_svc="${PROJECT_NAME}_frontend_1"
  local _be_svc="${PROJECT_NAME}_backend_1"
  local _proj="${PROJECT_NAME}"

  # Generate Traefik dynamic config YAML and base64-encode it.
  # Using a heredoc avoids bash 3.2 quoting issues with inline strings.
  local _b64
  _b64=$(base64 <<TRAEFIK_YAML
http:
  routers:
    ${_proj}-tunnel-frontend:
      rule: "Host(\`${tunnel_host}\`)"
      entryPoints: [web]
      priority: 1
      service: ${_proj}-tunnel-frontend-svc
    ${_proj}-tunnel-api:
      rule: "Host(\`${tunnel_host}\`) && PathPrefix(\`/api\`)"
      entryPoints: [web]
      priority: 100
      middlewares:
        - ${_proj}-tunnel-strip-api
        - ${_proj}-compress
      service: ${_proj}-tunnel-backend-svc
    ${_proj}-tunnel-admin:
      rule: "Host(\`${tunnel_host}\`) && PathPrefix(\`/admin\`)"
      entryPoints: [web]
      priority: 100
      middlewares:
        - ${_proj}-compress
      service: ${_proj}-tunnel-backend-svc
    ${_proj}-tunnel-static:
      rule: "Host(\`${tunnel_host}\`) && PathPrefix(\`/static\`)"
      entryPoints: [web]
      priority: 100
      service: ${_proj}-tunnel-backend-svc
    ${_proj}-tunnel-media:
      rule: "Host(\`${tunnel_host}\`) && PathPrefix(\`/media\`)"
      entryPoints: [web]
      priority: 100
      service: ${_proj}-tunnel-backend-svc
  middlewares:
    ${_proj}-tunnel-strip-api:
      stripPrefix:
        prefixes: ["/api"]
    ${_proj}-compress:
      compress: {}
  services:
    ${_proj}-tunnel-frontend-svc:
      loadBalancer:
        servers:
          - url: "http://${_fe_svc}:3000"
    ${_proj}-tunnel-backend-svc:
      loadBalancer:
        servers:
          - url: "http://${_be_svc}:8000"
TRAEFIK_YAML
)

  if [[ -z "$_b64" ]]; then
    echo "   ⚠️  Could not generate Traefik dynamic config"
    return 0
  fi

  local _dest="/tmp/traefik-dynamic/${PROJECT_NAME}.yml"

  if [[ "$OS" == "mac" ]] && podman machine ssh "true" 2>/dev/null; then
    # On macOS, stdin redirect to `podman machine ssh` is silently dropped.
    # Pass content as a base64 argument and decode inside the VM instead.
    podman machine ssh "mkdir -p /tmp/traefik-dynamic" 2>/dev/null || true
    if podman machine ssh "echo '${_b64}' | base64 -d > ${_dest}" 2>/dev/null; then
      echo "   📄 Traefik dynamic config written (tunnel routing active)"
    else
      # Retry once — SSH can fail transiently on first attempt after machine start
      sleep 1
      podman machine ssh "mkdir -p /tmp/traefik-dynamic" 2>/dev/null || true
      podman machine ssh "echo '${_b64}' | base64 -d > ${_dest}" 2>/dev/null \
        && echo "   📄 Traefik dynamic config written (tunnel routing active)" \
        || echo "   ⚠️  Could not write Traefik dynamic config (tunnel may not route correctly)"
    fi
  else
    # Linux / Windows / no VM — write directly to host filesystem
    mkdir -p /tmp/traefik-dynamic
    echo "${_b64}" | base64 -d > "$_dest"
    echo "   📄 Traefik dynamic config written → ${_dest}"
  fi
}

# ── Stop tunnel proxy ─────────────────────────────────────────────────────────
_stop_tunnel_proxy() {
  local pid_file="/tmp/${PROJECT_NAME}-tunnel-proxy.pid"
  if [[ -f "$pid_file" ]]; then
    local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi
  rm -f "/tmp/${PROJECT_NAME}-tunnel-proxy.log" "/tmp/${PROJECT_NAME}-tunnel-proxy.py"
  # Remove dynamic config from Podman VM (macOS) or host filesystem (Linux/Windows)
  if [[ "$OS" == "mac" ]] && podman machine ssh "true" 2>/dev/null; then
    podman machine ssh "rm -f /tmp/traefik-dynamic/${PROJECT_NAME}.yml" 2>/dev/null || true
  else
    rm -f "/tmp/traefik-dynamic/${PROJECT_NAME}.yml"
  fi
}

# Save webapp tunnel URL to .env
_save_tunnel_url() {
  local url="$1" _target
  local _targets=("$ROOT_DIR/.env")
  if [[ -n "${DEV_SOURCE_DIR:-}" && "$DEV_SOURCE_DIR" != "$ROOT_DIR" ]]; then
    _targets+=("$DEV_SOURCE_DIR/.env")
  fi
  for _target in "${_targets[@]}"; do
    if grep -q "^CLOUDFLARE_TUNNEL_URL=" "$_target" 2>/dev/null; then
      _sed_inplace "s|^CLOUDFLARE_TUNNEL_URL=.*|CLOUDFLARE_TUNNEL_URL=${url}|" "$_target"
    else
      echo "CLOUDFLARE_TUNNEL_URL=${url}" >> "$_target"
    fi
  done
}

# Clear all tunnel URLs from .env (used on fallback to localhost)
_clear_tunnel_urls() {
  # Named hostnames are configuration, not disposable quick-tunnel state.
  if grep -q '^CLOUDFLARE_TUNNEL_TOKEN=.' "$ROOT_DIR/.env" 2>/dev/null; then return 0; fi
  if [[ -f "$ROOT_DIR/.env" ]]; then
    _sed_inplace "s|^CLOUDFLARE_TUNNEL_URL=.*|CLOUDFLARE_TUNNEL_URL=|" "$ROOT_DIR/.env" 2>/dev/null || true
    _sed_inplace '/^METRO_TUNNEL_URL_[0-9]*=/d' "$ROOT_DIR/.env" 2>/dev/null || true
  fi
}

# Sync Metro tunnel URLs from existing cloudflared log files into .env
_sync_metro_tunnel_urls_from_logs() {
  discover_apps
  local port=8081
  for folder in "${MOBILE_APPS[@]}"; do
    local log="/tmp/${PROJECT_NAME}-metro-${port}.log"
    local configured named_token
    configured=$(sed -n "s/^METRO_TUNNEL_URL_${port}=//p" "$ROOT_DIR/.env" | tr -d '\r')
    named_token=$(sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' "$ROOT_DIR/.env" | tr -d '\r')
    if [[ -n "$named_token" ]]; then
      port=$((port + 1))
      continue
    fi
    if [[ -f "$log" ]]; then
      local url
      url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$log" | head -1 || true)
      if [[ -n "$url" ]]; then
        local key="METRO_TUNNEL_URL_${port}"
        if grep -q "^${key}=" "$ROOT_DIR/.env" 2>/dev/null; then
          _sed_inplace "s|^${key}=.*|${key}=${url}|" "$ROOT_DIR/.env"
        else
          echo "${key}=${url}" >> "$ROOT_DIR/.env"
        fi
        echo "   📱 ${folder}:  $url"
      fi
    fi
    port=$((port + 1))
  done
}

# ── Stop Cloudflare Tunnel ───────────────────────────────────────────────────
_stop_cloudflare_tunnel() {
  # Stop the watchdog first so it doesn't restart the tunnel we're killing
  local watchdog_pid_file="/tmp/${PROJECT_NAME}-tunnel-watchdog.pid"
  if [[ -f "$watchdog_pid_file" ]]; then
    local wpid; wpid=$(cat "$watchdog_pid_file" 2>/dev/null || true)
    [[ -n "$wpid" ]] && kill "$wpid" 2>/dev/null || true
    rm -f "$watchdog_pid_file"
  fi
  # Kill the tunnel process tracked by the per-project PID file
  local tunnel_pid_file="/tmp/${PROJECT_NAME}-tunnel.pid"
  if [[ -f "$tunnel_pid_file" ]]; then
    local _tpid; _tpid=$(cat "$tunnel_pid_file" 2>/dev/null || true)
    if [[ -n "$_tpid" ]] && kill -0 "$_tpid" 2>/dev/null; then
      echo "🛑 Stopping Cloudflare Tunnel..."
      kill "$_tpid" 2>/dev/null || true
    fi
    rm -f "$tunnel_pid_file"
  fi
  # Also stop any Metro tunnels for this project using their PID files
  discover_apps
  local _port=8081
  for _folder in "${MOBILE_APPS[@]}"; do
    local _mpid_file="/tmp/${PROJECT_NAME}-metro-${_port}.pid"
    if [[ -f "$_mpid_file" ]]; then
      local _mpid; _mpid=$(cat "$_mpid_file" 2>/dev/null || true)
      [[ -n "$_mpid" ]] && kill "$_mpid" 2>/dev/null || true
      rm -f "$_mpid_file"
    fi
    rm -f "/tmp/${PROJECT_NAME}-metro-${_port}.log"
    # Also stop the Metro rewriting proxy for this port
    local _mproxy_pid_file="/tmp/${PROJECT_NAME}-metro-proxy-${_port}.pid"
    if [[ -f "$_mproxy_pid_file" ]]; then
      local _mppid; _mppid=$(cat "$_mproxy_pid_file" 2>/dev/null || true)
      [[ -n "$_mppid" ]] && kill "$_mppid" 2>/dev/null || true
      rm -f "$_mproxy_pid_file"
    fi
    rm -f "/tmp/${PROJECT_NAME}-metro-proxy-${_port}.log" "/tmp/${PROJECT_NAME}-metro-proxy-${_port}.py"
    _port=$((_port + 1))
  done
  rm -f "/tmp/${PROJECT_NAME}-tunnel.log"
  # Stop the proxy and remove Traefik dynamic config
  _stop_tunnel_proxy
  # Clear all tunnel URLs from .env (main + Metro)
  _clear_tunnel_urls
}

# ── Detect compose command ────────────────────────────────────────────────────
detect_compose() {
  if ! command -v podman-compose &>/dev/null; then
    echo "❌ podman-compose not found. Run: ./dev.sh setup"
    exit 1
  fi

  if ! command -v podman &>/dev/null; then
    echo "❌ podman not found. Run: ./dev.sh setup"
    exit 1
  fi

  # Verify Podman machine is running (macOS only)
  # On Linux/WSL, Podman runs natively without a separate VM
  if [[ "$OS" == "mac" ]]; then
    if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
      echo "❌ Podman machine is not running"
      echo "   Start it with: podman machine start"
      exit 1
    fi
  else
    # On Linux/WSL, just verify Podman is working
    if ! podman info >/dev/null 2>&1; then
      echo "❌ Podman is not responding"
      echo "   Check if Podman is properly installed and running"
      exit 1
    fi
  fi

  DC_CMD="podman-compose"
  # Fail before Compose can reuse another checkout's containers or host routes.
  python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" check-isolation \
    "$PROJECT_NAME" "${PROJECT_HOST}.localhost" "${PROJECT_HOST_ALIAS}.localhost" || exit 1
  _wire_podman_socket
  export CONTAINER_RUNTIME="podman"
}

# ── Global Traefik — shared across all projects on this machine ───────────────
# One Traefik instance on port 80 routes to all projects by hostname:
#   http://myproject.localhost  → MyProject
#   http://otherapp.localhost   → OtherApp
#   http://<any>.localhost      → whichever project registered that host
#
# Traefik watches the shared "traefik" Podman network for container labels.
# Each project's dev.yml joins that network and sets traefik.enable=true labels.
# This function is idempotent — safe to call from every project's dev.sh.

# ── Ensure PROJECT_HOST.localhost resolves locally ────────────────────────────
# Plain single-label subdomains like myapp.localhost resolve automatically on
# macOS and modern Linux. But if PROJECT_HOST contains a dot (e.g. myapp.io),
# the resulting hostname myapp.io.localhost is a multi-level name that the
# system resolver won't auto-resolve — it needs an /etc/hosts entry.
# This function adds the entry idempotently using sudo (prompts once if needed).
_ensure_hosts_entry() {
  # Windows host resolution is handled by dev.ps1; /etc/hosts in WSL would
  # not change the Windows browser's resolver.
  [[ "$OS" == "wsl" ]] && return 0
  local _local_host _qr_host
  _qr_host=$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
  for _local_host in "${PROJECT_HOST}.localhost" "${_qr_host}.localhost"; do
    grep -qF "$_local_host" /etc/hosts 2>/dev/null && continue
    echo "🔧 Adding ${_local_host} to /etc/hosts so browsers can resolve it..."
    printf '127.0.0.1  %s\n' "$_local_host" | sudo tee -a /etc/hosts >/dev/null \
      || echo "   ⚠️  Add manually to /etc/hosts: 127.0.0.1 $_local_host"
  done
}

_ensure_local_tls() {
  local certdir="/tmp/traefik-dynamic/certs" host="${PROJECT_HOST}.localhost"
  local alias_host="${PROJECT_HOST_ALIAS:-$PROJECT_HOST}.localhost"
  if ! command -v mkcert >/dev/null; then
    echo "Install mkcert to enable trusted local HTTPS." >&2
    return 1
  fi
  mkdir -p "$certdir"
  mkcert -install >/dev/null 2>&1
  # Every routed local hostname needs certificate coverage, including aliases.
  # Renew existing certificates when a hostname is added or the local CA changes.
  if [[ ! -s "$certdir/${PROJECT_NAME}.pem" || ! -s "$certdir/${PROJECT_NAME}-key.pem" ]] \
    || ! openssl x509 -checkend 86400 -noout -in "$certdir/${PROJECT_NAME}.pem" >/dev/null 2>&1 \
    || ! openssl x509 -checkhost "$host" -noout -in "$certdir/${PROJECT_NAME}.pem" 2>/dev/null | grep -q 'does match certificate' \
    || ! openssl x509 -checkhost "$alias_host" -noout -in "$certdir/${PROJECT_NAME}.pem" 2>/dev/null | grep -q 'does match certificate' \
    || ! openssl verify -CAfile "$(mkcert -CAROOT)/rootCA.pem" "$certdir/${PROJECT_NAME}.pem" >/dev/null 2>&1; then
    local -a cert_hosts=("$host")
    [[ "$alias_host" == "$host" ]] || cert_hosts+=("$alias_host")
    mkcert -cert-file "$certdir/${PROJECT_NAME}.pem" -key-file "$certdir/${PROJECT_NAME}-key.pem" "${cert_hosts[@]}" || return 1
  fi
  # Keep certificates inside the existing shared mount, including on macOS.
  if [[ "$OS" == "mac" ]]; then
    podman machine ssh "mkdir -p '$certdir'"
    for file in "${PROJECT_NAME}.pem" "${PROJECT_NAME}-key.pem"; do
      podman machine ssh "cat > '$certdir/$file'" < "$certdir/$file"
    done
  fi
  local config="tls:\n  certificates:\n    - certFile: /traefik-dynamic/certs/${PROJECT_NAME}.pem\n      keyFile: /traefik-dynamic/certs/${PROJECT_NAME}-key.pem\n"
  if [[ "$OS" == "mac" ]]; then
    printf '%b' "$config" | podman machine ssh "cat > '/tmp/traefik-dynamic/${PROJECT_NAME}-tls.yml'"
  else
    printf '%b' "$config" > "/tmp/traefik-dynamic/${PROJECT_NAME}-tls.yml"
  fi
  # WSL's CA store is separate from the Windows browser's current-user store.
  if grep -qi microsoft /proc/version 2>/dev/null; then
    local certutil="/mnt/c/Windows/System32/certutil.exe"
    if [[ -x "$certutil" ]]; then
      "$certutil" -user -addstore Root "$(wslpath -w "$(mkcert -CAROOT)/rootCA.pem")" >/dev/null
    fi
  fi
}

# Netavark can retain DNAT rules for an old Traefik IP after WSL restarts.
# Those earlier rules win over the current mapping, even after network reload.
# Remove only obsolete mappings for Traefik's published ports on its network.
_repair_traefik_hostports() {
  [[ "$OS" == "mac" ]] && return 0
  command -v nft >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - <<'PY' || echo "⚠️  Could not check Traefik host-port rules"
import json
import subprocess

def read(*args):
    return json.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL))

try:
    container = read('podman', 'inspect', 'traefik')[0]
    network = container['NetworkSettings']['Networks']['traefik']
    address = network['IPAddress']
    if not container['State']['Running'] or not address:
        raise SystemExit(0)
    network_id = network['NetworkID'][:8]
    rules = read('nft', '-j', '-a', 'list', 'table', 'inet', 'netavark')
except (subprocess.CalledProcessError, KeyError, IndexError, ValueError):
    raise SystemExit(0)

removed = 0
for item in rules['nftables']:
    rule = item.get('rule', {})
    chain = rule.get('chain', '')
    if not chain.startswith(f'nv_{network_id}_') or not chain.endswith('_dnat'):
        continue
    port = None
    destination = None
    for expression in rule.get('expr', []):
        match = expression.get('match', {})
        payload = match.get('left', {}).get('payload', {}) if isinstance(match.get('left'), dict) else {}
        if payload == {'protocol': 'tcp', 'field': 'dport'} and match.get('op') == '==':
            port = match.get('right')
        if 'dnat' in expression:
            destination = expression['dnat']
    if (port in (80, 443, 8080) and destination
            and destination.get('port') == port
            and isinstance(destination.get('addr'), str)
            and destination['addr'] != address):
        subprocess.run(['nft', 'delete', 'rule', 'inet', 'netavark', chain,
                        'handle', str(rule['handle'])], check=True)
        removed += 1
if removed:
    print(f'✅ Repaired {removed} stale Traefik host-port rules')
PY
}

_ensure_global_traefik() {
  command -v podman &>/dev/null || return 0
  podman ps >/dev/null 2>&1 || return 0

  # Ensure the Docker-compatible API exists before deciding how to launch
  # Traefik. This is required on WSL installations that do not run systemd.
  _wire_podman_socket

  local _net="traefik"
  local _cname="traefik"

  # 1. Create the shared network if it doesn't exist
  if ! podman network exists "$_net" 2>/dev/null; then
    echo "🌐 Creating shared Traefik network (${_net})..."
    podman network create "$_net" >/dev/null 2>&1 || true
  fi

  # 2. Find the Podman socket path for the Docker provider
  local _sock=""
  _sock=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)
  if [[ -z "$_sock" || ! -S "$_sock" ]]; then
    # On WSL/Linux, ensure the Podman socket service is running
    if [[ "$OS" != "mac" ]]; then
      local _podman_socket_needed=false
      for _s in \
        /run/podman/podman.sock \
        /run/user/$(id -u)/podman/podman.sock \
        /tmp/podman-run-$(id -u)/podman/podman.sock; do
        if [[ ! -S "$_s" ]]; then
          _podman_socket_needed=true
        else
          _sock="$_s"
          break
        fi
      done

      # Start the Podman socket service if needed
      if [[ "$_podman_socket_needed" == "true" || -z "$_sock" ]]; then
        if [[ -w /run/podman ]]; then
          _sock="/run/podman/podman.sock"
        elif [[ -w /run/user/$(id -u) ]]; then
          mkdir -p /run/user/$(id -u)/podman
          _sock="/run/user/$(id -u)/podman/podman.sock"
        else
          mkdir -p /tmp/podman-run-$(id -u)/podman
          _sock="/tmp/podman-run-$(id -u)/podman/podman.sock"
        fi

        # Kill any existing socket service and start a new one
        pkill -f "podman system service.*${_sock}" 2>/dev/null || true
        rm -f "$_sock" 2>/dev/null || true
        nohup podman system service --time=0 "unix://${_sock}" >/tmp/podman-socket.log 2>&1 &
        sleep 2
      fi
    else
      # macOS Podman machine
      for _s in \
        /var/folders/*/T/podman/podman-machine-default-api.sock \
        /run/podman/podman.sock \
        /run/user/$(id -u)/podman/podman.sock \
        /tmp/podman-run-$(id -u)/podman/podman.sock; do
        [[ -S "$_s" ]] && _sock="$_s" && break
      done
    fi
  fi

  local _sock_args=()
  local _endpoint_args=()
  local _selinux_args=()
  # On macOS with Podman machine the socket lives inside the VM.
  # /var/run/docker.sock is a symlink — resolve it to the real path.
  # Mount it to a flat path (/var/run/podman.sock) to avoid directory
  # traversal permission issues, and disable SELinux labeling so the
  # Traefik process (running as root in container_t) can actually connect.
  # On Linux/WSL, use the user socket or /var/run/docker.sock directly.
  # On Windows, Podman exposes a named pipe which Traefik can use directly.
  local _vm_sock_real=""
  if [[ "$OS" == "mac" ]]; then
    _vm_sock_real=$(podman machine ssh "readlink -f /var/run/docker.sock" 2>/dev/null || true)
    if [[ -n "$_vm_sock_real" ]]; then
      _sock_args=("-v" "${_vm_sock_real}:/var/run/podman.sock:ro")
      _endpoint_args=("--providers.docker.endpoint=unix:///var/run/podman.sock")
      _selinux_args=("--security-opt" "label=disable")
    elif [[ -S "$_sock" ]]; then
      local _vm_sock="/var/run/docker.sock"
      _sock_args=("-v" "${_sock}:${_vm_sock}:ro")
      _endpoint_args=("--providers.docker.endpoint=unix://${_vm_sock}")
    fi
  elif [[ -S "$_sock" ]]; then
    local _vm_sock="/var/run/docker.sock"
    _sock_args=("-v" "${_sock}:${_vm_sock}:ro")
    _endpoint_args=("--providers.docker.endpoint=unix://${_vm_sock}")
  fi

  _ensure_local_tls

  # 3. Config fingerprint — hash of the flags we pass to Traefik.
  #    If it changes (e.g. after a dev.sh update), the container is recreated
  #    automatically. New container labels from projects are picked up live by
  #    the Docker provider — no restart needed for those.
  local _config_sig
  # Include the socket inode. If a dead socket is replaced at the same path,
  # an existing Traefik container is still bound to the old inode and must be
  # recreated before it can discover routes again.
  local _sock_inode=""
  [[ -S "$_sock" ]] && _sock_inode=$(ls -i "$_sock" 2>/dev/null | awk '{print $1}')
  _config_sig=$(echo "traefik:v3.6.5-selinux-disable-dashboard-fileprovider-project-tls-v1 ${_vm_sock_real:-$_sock} ${_sock_inode} ${_net}" | md5 -q 2>/dev/null \
             || echo "traefik:v3.6.5-selinux-disable-dashboard-fileprovider-project-tls-v1 ${_vm_sock_real:-$_sock} ${_sock_inode} ${_net}" | md5sum 2>/dev/null | cut -d' ' -f1)
  local _sig_label
  _sig_label=$(podman inspect "$_cname" \
    --format '{{index .Config.Labels "dev.kiro.config-sig"}}' 2>/dev/null || true)

  local _needs_recreate=false
  if ! podman inspect "$_cname" --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
    _needs_recreate=true
  elif [[ "$_sig_label" != "$_config_sig" ]]; then
    echo "🔄 Global Traefik config changed — recreating..."
    _needs_recreate=true
  fi

  # 4. Start (or recreate) global Traefik
  if [[ "$_needs_recreate" == "true" ]]; then
    [[ "$_needs_recreate" == "true" && "$_sig_label" == "$_config_sig" ]] || \
      echo "🚦 Starting global Traefik (shared router for all projects)..."
    podman rm -f "$_cname" 2>/dev/null || true

    mkdir -p /tmp/traefik-dynamic
    # Also ensure the directory exists inside the Podman VM (macOS only — Linux/Windows write directly)
    [[ "$OS" == "mac" ]] && podman machine ssh "mkdir -p /tmp/traefik-dynamic" 2>/dev/null || true

    podman run -d \
      --name "$_cname" \
      --network "$_net" \
      --restart unless-stopped \
      -p 80:80 \
      -p 443:443 \
      -p 8080:8080 \
      -v /tmp/traefik-dynamic:/traefik-dynamic:ro \
      --label "dev.kiro.config-sig=${_config_sig}" \
      --label "traefik.enable=true" \
      --label "traefik.docker.network=${_net}" \
      --label "traefik.http.routers.traefik-dashboard.rule=Host(\`traefik.localhost\`)" \
      --label "traefik.http.routers.traefik-dashboard.entrypoints=web" \
      --label "traefik.http.routers.traefik-dashboard.service=api@internal" \
      --label "traefik.http.routers.traefik-dashboard.middlewares=traefik-dashboard-redirect" \
      --label 'traefik.http.middlewares.traefik-dashboard-redirect.redirectregex.regex=^http://traefik\.localhost/?$' \
      --label "traefik.http.middlewares.traefik-dashboard-redirect.redirectregex.replacement=http://traefik.localhost/dashboard/" \
      --label "traefik.http.middlewares.traefik-dashboard-redirect.redirectregex.permanent=false" \
      "${_selinux_args[@]}" \
      "${_sock_args[@]}" \
      traefik:v3.6.5 \
        --log.level=INFO \
        --ping=true \
        --ping.entrypoint=web \
        --api=true \
        --api.dashboard=true \
        --api.insecure=true \
        --entrypoints.web.address=:80 \
        --entrypoints.websecure.address=:443 \
        --entrypoints.traefik.address=:8080 \
        --entrypoints.web.transport.respondingTimeouts.readTimeout=0 \
        --entrypoints.web.transport.respondingTimeouts.writeTimeout=0 \
        --entrypoints.web.transport.respondingTimeouts.idleTimeout=180s \
        --providers.docker=true \
        --providers.docker.network="$_net" \
        --providers.docker.exposedbydefault=false \
        --providers.file.directory=/traefik-dynamic \
        --providers.file.watch=true \
        "${_endpoint_args[@]}" \
        --global.checknewversion=false \
        --global.sendanonymoususage=false \
      >/dev/null 2>&1 && echo "✅ Global Traefik started → http://traefik.localhost" || echo "⚠️  Global Traefik failed to start (non-fatal)"
  fi

  _repair_traefik_hostports
}

# ── Ensure Podman machine is running ─────────────────────────────────────────
ensure_podman_running() {
  if ! command -v podman &>/dev/null; then return; fi

  case "$OS" in
    mac)
      # Check if machine is actually running — use case-insensitive grep and
      # also accept "starting" as a live state. Fall back to `podman ps` as a
      # secondary check so a slow/empty inspect doesn't trigger a spurious start.
      local _machine_state
      _machine_state=$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo "")
      local _podman_responsive=false
      podman ps >/dev/null 2>&1 && _podman_responsive=true

      if echo "$_machine_state" | grep -qi "running\|starting" || $_podman_responsive; then
        : # machine is up — nothing to do
      else
        # Check if the actual VM files exist (may have been deleted by `down all`)
        local _machine_exists=false
        if [[ -f "$HOME/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw" ]] || \
           [[ -f "$HOME/.local/share/containers/podman/machine/qemu/podman-machine-default_fedora-coreos.qcow2" ]]; then
          _machine_exists=true
        fi

        if [[ "$_machine_exists" == "false" ]]; then
          # Clean up stale system connections before creating new machine
          podman system connection rm podman-machine-default 2>/dev/null || true
          podman system connection rm podman-machine-default-root 2>/dev/null || true

          echo "🖥️  Creating Podman machine (200GiB disk)..."
          local _init_out
          _init_out=$(podman machine init --cpus 4 --memory 8192 --disk-size 60 2>&1 || true)
          echo "$_init_out" | grep -v "^$" | grep -v "rootless mode" \
            | grep -v "Docker API socket" | grep -v "DOCKER_HOST" \
            | grep -v "^Looking up" | grep -v "^Extracting" || true

          # HCS error means nested virtualization is not available on this machine.
          # Since we now use WSL2-native Podman (not podman machine), this path
          # should no longer be reached. Log it and bail cleanly.
          if echo "$_init_out" | grep -qi "HCS_E_HYPERV_NOT_INSTALLED\|virtualization is not enabled\|VirtualMachinePlatform"; then
            echo ""
            echo "❌ Podman machine requires nested virtualization which is not available."
            echo "   On Shadow PC / cloud VMs, use the WSL2-native path instead."
            echo "   Run: ./dev.sh   (the script will switch to WSL2 mode automatically)"
            exit 1
          fi

          # Re-check if machine was actually created
          if ! podman machine list 2>/dev/null | grep -q "default"; then
            echo "⚠️  Podman machine creation failed. Check the error above."
            return 0
          fi
        fi

        echo "🚀 Starting Podman machine..."
        podman machine start 2>&1 || true

        # Wait for socket to be ready (up to 60s)
        local waited=0
        while [[ $waited -lt 60 ]]; do
          if podman ps >/dev/null 2>&1; then
            break
          fi
          sleep 2; waited=$((waited + 2))
        done

        # Verify the machine is actually running
        if ! podman ps >/dev/null 2>&1; then
          echo "⚠️  Podman machine failed to start. Trying stop/start cycle..."
          podman machine stop 2>/dev/null || true
          sleep 3
          podman machine start 2>&1 || true
          # Final wait
          local waited2=0
          while [[ $waited2 -lt 30 ]]; do
            if podman ps >/dev/null 2>&1; then
              break
            fi
            sleep 2; waited2=$((waited2 + 2))
          done
          if ! podman ps >/dev/null 2>&1; then
            echo "❌ Podman machine could not be started. Try: podman machine start"
            exit 1
          fi
        fi

        echo "✅ Podman machine running."
      fi

      # Allow Podman VM to bind privileged ports (80, 443) — macOS-only via SSH into the VM.
      # On Windows, Podman uses WSL2 which handles port binding differently.
      if [[ "$OS" == "mac" ]]; then
        local _port80_check
        _port80_check=$(podman machine ssh "grep -q 'ip_unprivileged_port_start=80' /etc/sysctl.d/99-podman.conf 2>/dev/null && echo 'already_set' || echo 'not_set'" 2>/dev/null || echo "ssh_unavailable")
        if [[ "$_port80_check" == "not_set" ]]; then
          echo "🔧 Allowing Podman to bind port 80 (one-time setup)..."
          podman machine ssh "echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-podman.conf > /dev/null && sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80 > /dev/null" 2>/dev/null || true
          echo "✅ Port 80 unlocked"
        fi
      fi
      ;;
  esac
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Template sync is handled by config/project_config.py before bootstrap above.
# Pull uses the configured sibling template checkout when present, otherwise GitHub.
# Push copies shared files into that checkout for review, commit, and publication.

CMD="${1:-}"


if [[ "$CMD" == "setup" ]]; then
  run_setup
  exit 0
fi

# Commands that don't need dependency checks or app discovery preamble
_SKIP_SETUP=false
case "$CMD" in
  status|logs|down|stop|rebuild|disk|_status_only|_metro_tunnels_only|service-logs|sync|expose) _SKIP_SETUP=true ;;
  # ios/android only need Xcode/ADB/Node — no Podman, no Docker deps
  ios|android) _SKIP_SETUP=true ;;
esac

# For `build <app> <platform> local` we don't need Podman at all
# For `build <app> <platform>` (EAS cloud) we also don't need Podman
_BUILD_LOCAL=false
_BUILD_EAS=false
if [[ "$CMD" == "build" ]]; then
  for _a in "$@"; do [[ "$_a" == "local" ]] && _BUILD_LOCAL=true; done
  # EAS build: has an app name argument and no 'local' flag
  _build_arg2="${2:-}"
  if [[ -n "$_build_arg2" && "$_build_arg2" != "local" && "$_BUILD_LOCAL" == "false" ]]; then
    _BUILD_EAS=true
  fi
fi

_deps_installed() {
  command -v podman         &>/dev/null || return 1
  command -v podman-compose &>/dev/null || return 1
  command -v node           &>/dev/null || return 1
  command -v git            &>/dev/null || return 1
  command -v python3 &>/dev/null || command -v python &>/dev/null || return 1
  command -v cloudflared    &>/dev/null || return 1
  command -v mkcert         &>/dev/null || return 1
  command -v openssl        &>/dev/null || return 1
  if [[ "$OS" == "linux" || "$OS" == "wsl" ]]; then
    command -v certutil     &>/dev/null || return 1
  fi
  return 0
}

# Wire brew PATH before dependency check — after a Mac restart, brew-installed
# binaries (node, podman-compose, etc.) won't be in PATH until shellenv is eval'd
if [[ "$OS" == "mac" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
    || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
fi

# On Windows (Git Bash / MSYS2) ensure common tool paths are on PATH
if [[ "$OS" == "windows" ]]; then
  # Scoop shims
  [[ -d "$HOME/scoop/shims" ]] && export PATH="$HOME/scoop/shims:$PATH"
  # Chocolatey
  [[ -d "/c/ProgramData/chocolatey/bin" ]] && export PATH="/c/ProgramData/chocolatey/bin:$PATH"
  # Python user scripts (pip install --user)
  _py_user_scripts=$(python3 -c "import site; print(site.getuserbase())" 2>/dev/null || true)
  [[ -n "$_py_user_scripts" ]] && export PATH="${_py_user_scripts}/Scripts:$PATH"
  # python3 shim — on Windows 'python' is often available but not 'python3'
  if ! command -v python3 &>/dev/null && command -v python &>/dev/null; then
    python3() { python "$@"; }
    export -f python3 2>/dev/null || true
  fi
fi

if [[ "$_SKIP_SETUP" == "false" ]]; then
  if ! _deps_installed; then
    run_setup
    # Re-wire brew PATH so tools installed by run_setup are found in this session
    if [[ "$OS" == "mac" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
        || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
    fi
  fi
  gen_app_json 2>/dev/null || true
fi

# ── Helper: human-readable size from KB ──────────────────────────────────────
_format_size_kb() {
  local kb="$1"
  if [[ $kb -ge 1048576 ]]; then
    local gb_raw; gb_raw=$(echo "scale=2; $kb / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "${gb_raw} GB"
  elif [[ $kb -ge 1024 ]]; then
    echo "$(( kb / 1024 )) MB"
  else
    echo "${kb} KB"
  fi
}

# ── Helper: measure disk usage of Podman storage on macOS/Windows ─────────────
_measure_podman_storage_kb() {
  local _machine_size=0
  local _storage_size=0
  local _applehv_dir="$HOME/.local/share/containers/podman/machine/applehv"
  local _qemu_dir="$HOME/.local/share/containers/podman/machine/qemu"

  # macOS applehv: match any .raw file (covers both podman-machine-default.raw
  # and podman-machine-default-arm64.raw on Apple Silicon)
  if [[ -d "$_applehv_dir" ]]; then
    _machine_size=$(find "$_applehv_dir" -maxdepth 1 -name "*.raw" -exec du -sk {} + 2>/dev/null \
      | awk '{s+=$1} END{print s+0}')
  fi
  # macOS qemu fallback
  if [[ $_machine_size -eq 0 && -d "$_qemu_dir" ]]; then
    _machine_size=$(find "$_qemu_dir" -maxdepth 1 \( -name "*.qcow2" -o -name "*.raw" \) -exec du -sk {} + 2>/dev/null \
      | awk '{s+=$1} END{print s+0}')
  fi

  if [[ -d "$HOME/.local/share/containers/storage" ]]; then
    _storage_size=$(du -sk "$HOME/.local/share/containers/storage" 2>/dev/null | awk '{print $1}')
  fi
  # Windows: Podman uses WSL2 — du inside WSL is unreliable from Git Bash; return 0
  echo $(( _machine_size + _storage_size ))
}

# ── Helper: cross-platform total Podman storage in KB ────────────────────────
# On macOS: sums the VM disk image + containers/storage on the host filesystem.
# On Linux/WSL: uses `podman system df` which reports actual on-disk usage
#               (images reclaimable + volumes + build cache).
# Returns 0 if Podman is not running or nothing is found.
_measure_total_podman_storage_kb() {
  case "$OS" in
    mac)
      _measure_podman_storage_kb
      ;;
    linux|wsl)
      # Sum the SIZE column (field 4) from `podman system df`:
      #   TYPE          TOTAL  ACTIVE  SIZE    RECLAIMABLE
      #   Images        6      2       281MB   168MB (59%)
      #   Containers    3      1       0B      0B (0%)
      #   Local Volumes 1      1       22B     0B (0%)
      podman system df 2>/dev/null | awk '
        function parse(s,   n,u) {
          n = s + 0; u = s
          gsub(/[0-9.]+/, "", u)
          if      (u ~ /[Gg]B?$/) return int(n * 1024 * 1024)
          else if (u ~ /[Mm]B?$/) return int(n * 1024)
          else if (u ~ /[Kk]B?$/) return int(n)
          else                    return int(n / 1024)
        }
        NR > 1 && NF >= 4 { total += parse($4) }
        END { print total + 0 }
      ' || echo 0
      ;;
    *)
      echo 0
      ;;
  esac
}

# ── Helper: measure project-level Podman storage (images + volumes) ───────────
# Returns size in KB. Uses multiple methods with fallbacks for reliability.
_measure_project_storage_kb() {
  local img_kb=0
  local vol_kb=0
  local cache_kb=0

  # ── Image sizes: parse human-readable {{.Size}} values (e.g. "1.2 GB", "450 MB")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name size_str
    name="${line%% *}"
    size_str="${line#* }"
    # Convert to KB based on unit suffix
    if echo "$size_str" | grep -qi "GB"; then
      local num; num=$(echo "$size_str" | sed 's/[^0-9.]//g')
      img_kb=$(( img_kb + $(echo "scale=0; $num * 1024 * 1024 / 1" | bc 2>/dev/null || echo 0) ))
    elif echo "$size_str" | grep -qi "MB"; then
      local num; num=$(echo "$size_str" | sed 's/[^0-9.]//g')
      img_kb=$(( img_kb + $(echo "scale=0; $num * 1024 / 1" | bc 2>/dev/null || echo 0) ))
    elif echo "$size_str" | grep -qi "KB\|kB"; then
      local num; num=$(echo "$size_str" | sed 's/[^0-9.]//g')
      img_kb=$(( img_kb + ${num%.*} ))
    elif echo "$size_str" | grep -qE "^[0-9]+$"; then
      img_kb=$(( img_kb + size_str / 1024 ))
    fi
  done < <(podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2>/dev/null \
    | grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" || true)

  # ── Volume sizes: walk mount points on disk (most accurate)
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    local mp; mp=$(podman volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
    if [[ -n "$mp" && -d "$mp" ]]; then
      local vsize; vsize=$(du -sk "$mp" 2>/dev/null | awk '{print $1}')
      vol_kb=$(( vol_kb + ${vsize:-0} ))
    fi
  done < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PROJECT_NAME}_" || true)

  # ── Build cache: `podman system df` reports total cache size (not per-project,
  #    but it's the main source of recoverable space and is pruned by this command)
  local cache_raw
  cache_raw=$(podman system df 2>/dev/null | awk '/Build Cache/{print $NF}' | tail -1 || true)
  if [[ -n "$cache_raw" ]]; then
    if echo "$cache_raw" | grep -qi "GB"; then
      local num; num=$(echo "$cache_raw" | sed 's/[^0-9.]//g')
      cache_kb=$(echo "scale=0; $num * 1024 * 1024 / 1" | bc 2>/dev/null || echo 0)
    elif echo "$cache_raw" | grep -qi "MB"; then
      local num; num=$(echo "$cache_raw" | sed 's/[^0-9.]//g')
      cache_kb=$(echo "scale=0; $num * 1024 / 1" | bc 2>/dev/null || echo 0)
    elif echo "$cache_raw" | grep -qi "KB\|kB"; then
      local num; num=$(echo "$cache_raw" | sed 's/[^0-9.]//g')
      cache_kb=${num%.*}
    fi
  fi

  echo $(( img_kb + vol_kb + cache_kb ))
}

# stop/down — handle early before ensure_podman_running
if [[ "$CMD" == "stop" || "$CMD" == "down" ]]; then
  # ── ./dev.sh down android — wipe emulator data for a clean slate ────────────
  if [[ "$CMD" == "down" && "${2:-}" == "android" ]]; then
    _setup_android_path
    _adb_bin="${ANDROID_HOME}/platform-tools/adb"
    _emu_bin="${ANDROID_HOME}/emulator/emulator"
    _avdmanager_bin="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"

    echo "🗑️  Wiping Android emulator data..."
    echo ""

    # 1. Kill any running emulator
    if [[ -x "$_adb_bin" ]]; then
      _running_emus=$("$_adb_bin" devices 2>/dev/null | grep "^emulator" | awk '{print $1}')
      if [[ -n "$_running_emus" ]]; then
        echo "🛑 Killing running emulator(s): $_running_emus"
        for _emu_serial in $_running_emus; do
          "$_adb_bin" -s "$_emu_serial" emu kill 2>/dev/null || true
        done
        sleep 2
      else
        echo "ℹ️  No running emulator found"
      fi
    fi
    # Belt-and-suspenders: kill the emulator process directly
    pkill -f "emulator.*-avd" 2>/dev/null || true
    sleep 1

    # 2. Find all AVDs and wipe their data
    if [[ -x "$_emu_bin" ]]; then
      _avd_list=$("$_emu_bin" -list-avds 2>/dev/null || true)
      if [[ -n "$_avd_list" ]]; then
        while IFS= read -r _avd_name; do
          [[ -z "$_avd_name" ]] && continue
          echo "🗑️  Wiping AVD: $_avd_name"
          # Delete the AVD's userdata/cache partitions (the data, not the AVD config)
          _avd_data_dir="$HOME/.android/avd/${_avd_name}.avd"
          if [[ -d "$_avd_data_dir" ]]; then
            rm -f "$_avd_data_dir/userdata-qemu.img" 2>/dev/null || true
            rm -f "$_avd_data_dir/userdata-qemu.img.qcow2" 2>/dev/null || true
            rm -f "$_avd_data_dir/userdata.img" 2>/dev/null || true
            rm -f "$_avd_data_dir/cache.img" 2>/dev/null || true
            rm -f "$_avd_data_dir/cache.img.qcow2" 2>/dev/null || true
            rm -f "$_avd_data_dir/sdcard.img" 2>/dev/null || true
            rm -f "$_avd_data_dir/sdcard.img.qcow2" 2>/dev/null || true
            rm -rf "$_avd_data_dir/snapshots" 2>/dev/null || true
            echo "   ✅ $_avd_name data wiped"
          else
            echo "   ⚠️  AVD data dir not found: $_avd_data_dir"
          fi
        done <<< "$_avd_list"
      else
        echo "ℹ️  No AVDs found — nothing to wipe"
      fi
    else
      echo "⚠️  Android emulator not found at: $_emu_bin"
      echo "   Run ./dev.sh android to install the SDK first"
    fi

    # 3. Clear any installed APKs from the builds cache
    _builds_dir="$ROOT_DIR/frontend/mobile/builds"
    if [[ -d "$_builds_dir" ]] && ls "$_builds_dir"/*.apk 2>/dev/null | grep -q .; then
      echo ""
      echo "🗑️  Removing cached APKs from frontend/mobile/builds/..."
      rm -f "$_builds_dir"/*.apk 2>/dev/null || true
      echo "   ✅ APK cache cleared"
    fi

    echo ""
    echo "✅ Android emulator wiped. Run './dev.sh android' to start fresh."
    exit 0
  fi

  # Check flags for down command
  _DOWN_ALL=false
  if [[ "$CMD" == "down" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "all" ]] && _DOWN_ALL=true
    done
  fi

  # Stop Cloudflare Tunnel only for "down" — not for "stop".
  # "stop" just pauses containers but keeps the tunnel alive so the URL is preserved.
  if [[ "$CMD" == "down" ]]; then
    _stop_cloudflare_tunnel
    # Belt-and-suspenders: always clear tunnel URLs from .env directly
    _clear_tunnel_urls
    # For "down all", also kill ALL cloudflared processes across every project
    if [[ "$_DOWN_ALL" == "true" ]]; then
      pkill -f "cloudflared tunnel" 2>/dev/null || true
      # Kill all tunnel watchdogs and proxies across all projects
      pkill -f "socat.*190[0-9][0-9]" 2>/dev/null || true
      rm -f /tmp/*-tunnel.log /tmp/*-tunnel-proxy.pid /tmp/*-tunnel-watchdog.pid 2>/dev/null || true
      rm -f /tmp/*-metro-*.log /tmp/*-metro-proxy-*.pid /tmp/*-metro-proxy-*.log /tmp/*-metro-proxy-*.py 2>/dev/null || true
    fi
  fi

  if [[ "$_DOWN_ALL" == "true" ]]; then
    # Capture disk usage before cleanup (cross-platform: mac uses VM disk files,
    # linux/wsl uses `podman system df` reclaimable totals)
    _SPACE_BEFORE=0
    _SPACE_BEFORE=$(_measure_total_podman_storage_kb 2>/dev/null || echo 0)
    # Also snapshot total free space on the main volume before deletion,
    # so we can compute a real delta if the above returns 0.
    _DF_FREE_BEFORE=$(df -k / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)

    echo "🛑 Stopping ALL Podman services (all projects)..."

    # Stop global infrastructure containers (traefik) gracefully first
    _wire_podman_socket 2>/dev/null || true
    for _gcname in "traefik"; do
      if podman ps -q --filter "name=^${_gcname}$" 2>/dev/null | grep -q .; then
        echo "   Stopping ${_gcname}..."
        podman rm -f -t 1 "$_gcname" 2>/dev/null || true
      fi
    done
    # Remove the shared traefik network
    podman network rm traefik 2>/dev/null || true
    # Clean up traefik dynamic config directory
    rm -rf /tmp/traefik-dynamic 2>/dev/null || true

    # On Linux/WSL: prune all images, volumes and build cache BEFORE killing
    # Podman — podman system prune requires the daemon to be alive.
    if [[ "$OS" == "linux" || "$OS" == "wsl" ]]; then
      echo "🗑️  Pruning all Podman data (images, volumes, build cache)..."
      podman system prune -a --volumes -f 2>/dev/null || true
    fi

    # Kill all Podman processes immediately - fastest way to stop everything
    # (macOS: kills the VM hypervisor; Linux/WSL: kills the Podman daemon)
    pkill -9 -f "vfkit.*podman-machine" 2>/dev/null || true
    pkill -9 -f "gvproxy.*podman-machine" 2>/dev/null || true
    pkill -9 podman 2>/dev/null || true
    sleep 1

    echo "✅ All services stopped."
  else
    _wire_podman_socket
    # detect_compose exits if podman-compose is missing — skip it for down/stop
    # since we only need podman directly, not podman-compose
    if command -v podman-compose &>/dev/null; then
      detect_compose
    fi

    # Capture project storage before cleanup (for space-freed report)
    _SPACE_BEFORE=0
    if [[ "$CMD" == "down" ]]; then
      _SPACE_BEFORE=$(_measure_project_storage_kb 2>/dev/null || echo "0")
    fi

    echo "🛑 Stopping ${PROJECT_NAME} services..."
    # Scope stop to this project only — never touch containers from other projects.
    # Use -t 1 for 1 second timeout, then force kill. Much faster than default 10s per container.
    # For `stop`: leave containers in "exited" state so the monitor shows "stopped".
    # For `down`: remove containers entirely so the monitor drops the project section live.
    _project_containers=$(podman ps --filter "label=io.podman.compose.project=${PROJECT_NAME}" -q 2>/dev/null | tr '\n' ' ' || true)
    if [[ -n "${_project_containers// /}" ]]; then
      podman stop -t 1 $_project_containers 2>/dev/null || true
    fi
    if [[ "$CMD" == "down" ]]; then
      # Also remove exited containers (including ones that were already stopped before this run)
      _all_project_containers=$(podman ps -a --filter "label=io.podman.compose.project=${PROJECT_NAME}" -q 2>/dev/null | tr '\n' ' ' || true)
      if [[ -n "${_all_project_containers// /}" ]]; then
        podman rm $_all_project_containers 2>/dev/null || true
      fi
    fi
    echo "✅ ${PROJECT_NAME} services stopped."
  fi

  if [[ "$CMD" == "down" ]]; then
    echo ""

    if [[ "$_DOWN_ALL" == "true" ]]; then
      echo "🗑️  Cleaning ALL temporary files..."
      rm -f /tmp/*-mobile-compose.yml /tmp/*-compose.log /tmp/*-mobile.log 2>/dev/null || true
      rm -f /tmp/*-tunnel.log /tmp/*-tunnel-proxy.pid /tmp/*-tunnel-watchdog.pid 2>/dev/null || true
      rm -f /tmp/*-metro-*.log /tmp/*-metro-proxy-*.pid /tmp/*-metro-proxy-*.log /tmp/*-metro-proxy-*.py 2>/dev/null || true
      rm -rf /tmp/traefik-dynamic 2>/dev/null || true
    else
      # For project-specific cleanup, we need podman commands
      _wire_podman_socket
      if command -v podman-compose &>/dev/null; then
        detect_compose
      fi

      echo "🗑️  Removing project images and volumes..."
      # Remove project-specific images
      podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" \
        | xargs -r podman rmi -f 2>/dev/null || true

      # Remove project volumes
      podman volume ls --format '{{.Name}}' 2>/dev/null \
        | grep -E "^${PROJECT_NAME}_" \
        | xargs -r podman volume rm 2>/dev/null || true

      echo "🗑️  Pruning build cache..."
      podman builder prune -a -f 2>/dev/null || true

      echo "🗑️  Pruning dangling images..."
      podman image prune -f 2>/dev/null || true

      echo "🗑️  Cleaning temporary files..."
      rm -f "/tmp/${PROJECT_NAME}-mobile-compose.yml" "/tmp/${PROJECT_NAME}-compose.log" "/tmp/${PROJECT_NAME}-mobile.log" 2>/dev/null || true

      # Clean up any build artifacts in the project directory
      [[ -d "$ROOT_DIR/backend/__pycache__" ]] && rm -rf "$ROOT_DIR/backend/__pycache__" || true
      [[ -d "$ROOT_DIR/backend/.pytest_cache" ]] && rm -rf "$ROOT_DIR/backend/.pytest_cache" || true
      find "$ROOT_DIR/backend" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
      find "$ROOT_DIR/backend" -type f -name "*.pyc" -delete 2>/dev/null || true

      # Clean up node_modules caches if they exist
      if [[ -d "$ROOT_DIR/frontend" ]]; then
        find "$ROOT_DIR/frontend" -type d -name ".expo" -exec rm -rf {} + 2>/dev/null || true
        find "$ROOT_DIR/frontend" -type d -name ".expo-shared" -exec rm -rf {} + 2>/dev/null || true
        find "$ROOT_DIR/frontend" -type d -name "node_modules/.cache" -exec rm -rf {} + 2>/dev/null || true
      fi
    fi

    # ── Reclaim disk space from Podman machine (macOS only) ─────────────────
    if [[ "$OS" == "mac" ]]; then
      if [[ "$_DOWN_ALL" == "true" ]]; then
        echo "💾 Deleting Podman machine (space fully reclaimed)..."
        podman system connection rm podman-machine-default 2>/dev/null || true
        podman system connection rm podman-machine-default-root 2>/dev/null || true
        rm -rf "$HOME/.local/share/containers/podman/machine/applehv/podman-machine-default"* 2>/dev/null || true
        rm -rf "$HOME/.config/containers/podman/machine/applehv/podman-machine-default"* 2>/dev/null || true
        rm -rf "$HOME/.local/share/containers/podman/machine/qemu/podman-machine-default"* 2>/dev/null || true
        rm -rf "$HOME/.config/containers/podman/machine/qemu/podman-machine-default"* 2>/dev/null || true
        rm -f /var/folders/*/T/podman/podman-machine-default* 2>/dev/null || true
        rm -f /var/folders/*/T/podman/gvproxy.* 2>/dev/null || true
        rm -rf "$HOME/.local/share/containers/storage" 2>/dev/null || true
        # Remove the downloaded VM image cache (the .raw.zst — the big one, ~1GB)
        rm -rf "$HOME/.local/share/containers/podman/machine/applehv/cache" 2>/dev/null || true
        rm -rf "$HOME/.local/share/containers/podman/machine/libkrun" 2>/dev/null || true
        # Remove any temp podman sockets/locks
        rm -f /var/folders/*/T/podman/podman-machine-default* 2>/dev/null || true
        rm -rf /var/folders/*/T/podman/ 2>/dev/null || true
        # Remove stale podman SSH keys and config
        rm -f "$HOME/.local/share/containers/podman/machine/machine" 2>/dev/null || true
        rm -f "$HOME/.local/share/containers/podman/machine/machine.pub" 2>/dev/null || true
        rm -f "$HOME/.local/share/containers/podman/machine/port-alloc.dat" 2>/dev/null || true
        # Purge homebrew's podman-related download cache (formulae tarballs)
        brew cleanup --prune=0 podman podman-compose 2>/dev/null || true
        echo "✅ Podman machine + all caches deleted. Run ./dev.sh to recreate it."
      else
        podman machine ssh -- sudo fstrim -av 2>/dev/null || true
      fi
    fi

    echo ""
    if [[ "$_DOWN_ALL" == "true" ]]; then
      # Everything was pruned before Podman was killed — all the space is gone.
      _SPACE_AFTER=0
      _space_freed_kb=$(( _SPACE_BEFORE - _SPACE_AFTER ))
      # Fallback: if file-based measurement returned 0 (machine wasn't running or
      # files were already gone), use the df free-space delta instead.
      if [[ $_space_freed_kb -le 0 && -n "${_DF_FREE_BEFORE:-}" ]]; then
        _df_free_after=$(df -k / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
        _space_freed_kb=$(( _df_free_after - _DF_FREE_BEFORE ))
        [[ $_space_freed_kb -lt 0 ]] && _space_freed_kb=0
      fi
      _clean_msg="✅ All projects cleaned. Run ./dev.sh to start fresh."
      echo "$_clean_msg"
      if [[ $_space_freed_kb -gt 0 ]]; then
        echo "💾 Space freed: $(_format_size_kb $_space_freed_kb)"
      else
        echo "💾 Space freed: — (already clean or nothing to measure)"
      fi
    else
      # Measure storage after cleanup and report the difference
      _SPACE_AFTER=$(_measure_project_storage_kb 2>/dev/null || echo "0")
      _space_freed_kb=$(( _SPACE_BEFORE - _SPACE_AFTER ))
      if [[ $_space_freed_kb -gt 0 ]]; then
        echo "✅ ${PROJECT_DISPLAY_NAME} cleaned. Run ./dev.sh to start fresh."
        echo "💾 Space freed: $(_format_size_kb $_space_freed_kb)"
      elif [[ $_SPACE_BEFORE -eq 0 && $_SPACE_AFTER -eq 0 ]]; then
        echo "✅ ${PROJECT_DISPLAY_NAME} cleaned. Run ./dev.sh to start fresh."
        echo "💾 Space freed: — (no images or volumes found for this project)"
      else
        echo "✅ ${PROJECT_DISPLAY_NAME} cleaned. Run ./dev.sh to start fresh."
        echo "💾 Space freed: — (already clean or Podman unavailable)"
      fi
    fi
  fi
  exit 0
fi

if [[ "$CMD" != "status" && "$CMD" != "_status_only" && "$CMD" != "rebuild" && "$CMD" != "ios" && "$CMD" != "android" && "$_BUILD_LOCAL" != "true" && "$_BUILD_EAS" != "true" ]]; then
  ensure_podman_running
fi
if [[ "$CMD" != "status" && "$CMD" != "_status_only" && "$CMD" != "stop" && "$CMD" != "logs" && "$CMD" != "ios" && "$CMD" != "android" ]]; then
  _ensure_global_traefik
  _ensure_hosts_entry
fi
# Start the backend proxy on localhost:8000 → Traefik on every startup.
# Lets the Android emulator (adb reverse tcp:8000 tcp:8000) and iOS simulator
# reach the backend at http://localhost:8000/api. Idempotent.
if [[ "$CMD" != "status" && "$CMD" != "_status_only" && "$CMD" != "stop" && "$CMD" != "down" && "$CMD" != "logs" && "$CMD" != "ios" && "$CMD" != "android" ]]; then
  _start_backend_proxy 2>/dev/null || true
fi
# Ensure Metro rewriting proxies are running (tunnel → rewrites localhost:PORT → tunnel URL).
if [[ "$CMD" == "" || "$CMD" == "mobile" || "$CMD" == "up" || "$CMD" == "core" ]]; then
  _ensure_metro_proxies 2>/dev/null || true
fi
if [[ "$CMD" != "ios" && "$CMD" != "android" ]]; then
  detect_compose
  _wire_podman_socket
fi
# DC_CMD / PROJECT_NAME / COMPOSE_FILE are used directly everywhere — no $DC shorthand needed.

gen_mobile_yaml() {
  discover_apps
  local port=8081
  local METRO_BASE=8081

  echo "services:"
  for folder in "${MOBILE_APPS[@]}"; do
    local service fslug
    service=$(folder_to_service "$folder")
    fslug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    echo ""
    echo "  ${service}:"
    echo "    build:"
    echo "      context: ${ROOT_DIR}"
    echo "      dockerfile: frontend/mobile/Dockerfile"
    echo "    environment:"
    echo "      APP_TYPE: \"${fslug}\""
    echo "      EXPO_DEBUG: \"true\""
    echo "      EXPO_NO_TELEMETRY: \"1\""
    echo "      EXPO_NO_REDIRECT_PAGE: \"1\""
    # API URL: use tunnel URL if available, otherwise localhost
    local _tunnel_url _api_url
    _tunnel_url=$(grep "^CLOUDFLARE_TUNNEL_URL=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")
    if [[ -n "$_tunnel_url" ]]; then
      _api_url="$_tunnel_url"
    else
      _api_url="http://localhost:8000"
    fi
    echo "      CLOUDFLARE_TUNNEL_URL: \"${_tunnel_url}\""
    echo "      EXPO_PUBLIC_API_URL: \"${_api_url}\""
    # Pass through all EXPO_PUBLIC_* vars from the host environment / .env
    if [[ -f "$ROOT_DIR/.env" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^EXPO_PUBLIC_[A-Z_]+=  ]] || continue
        local varname="${line%%=*}"
        echo "      ${varname}: \"\${${varname}:-}\""
      done < "$ROOT_DIR/.env"
    fi
    echo "      EXPO_PUBLIC_ENV: \"development\""
    echo "      NODE_ENV: \"development\""
    echo "      NODE_OPTIONS: \"--max-old-space-size=8192\""
    echo "      EXPO_NO_INSPECTOR_PROXY: \"1\""
    echo "      METRO_PORT: \"${port}\""
    # Metro hostname strategy:
    #
    #   - Android emulator: adb reverse maps localhost:PORT → host. ✅
    #   - iOS simulator: LAN IP is the Mac itself, direct connection. ✅
    #   - Physical device same WiFi: LAN IP reachable directly. ✅
    #   - Physical device different WiFi: the Metro tunnel rewriting proxy
    #     (started by _start_cloudflare_tunnel) intercepts tunnel traffic and
    #     rewrites localhost:PORT → tunnel URL in Metro's manifest/bundle
    #     responses. Metro itself always advertises localhost:PORT — the proxy
    #     handles the substitution transparently for remote clients. ✅
    #
    # Use localhost when an emulator is running (adb reverse), LAN IP otherwise.
    local _lan_ip _packager_host
    _lan_ip=$(_get_lan_ip)
    _setup_android_path
    local _adb_bin="${ANDROID_HOME}/platform-tools/adb"
    # Always use 0.0.0.0 so Metro is accessible from:
    # - Within container (localhost)
    # - From host via port forwarding (0.0.0.0:8081)
    # - From emulator via adb reverse or tunnel
    # - From physical devices via tunnel URL
    _packager_host="0.0.0.0"
    echo "      REACT_NATIVE_PACKAGER_HOSTNAME: \"${_packager_host}\""
    # Expose tunnel URL as informational env var
    local _metro_tunnel_url
    _metro_tunnel_url=$(grep "^METRO_TUNNEL_URL_${port}=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")
    if [[ -n "$_metro_tunnel_url" ]]; then
      echo "      METRO_TUNNEL_URL: \"${_metro_tunnel_url}\""
    fi
    # Enable Metro file-watcher polling so changes on host volumes are detected
    # immediately on macOS/Linux without requiring a container rebuild.
    # EXPO_USE_FAST_REFRESH=true — explicitly enable Fast Refresh (CI=1 would disable it).
    echo "      WATCHMAN_DISABLE_RECRAWL: \"true\""
    echo "      EXPO_USE_FAST_REFRESH: \"true\""
    echo "      EXPO_USE_METRO_WORKSPACE_ROOT: \"1\""
    echo "      WATCHPACK_POLLING: \"true\""
    echo "      WATCHPACK_POLLING_INTERVAL: \"500\""
    echo "      CHOKIDAR_USEPOLLING: \"true\""
    echo "      CHOKIDAR_INTERVAL: \"500\""
    # Skip expo-updates runtime version resolution — it hangs when expo-updates
    # is not fully installed (only expo-updates-interface is present).
    echo "      EXPO_NO_UPDATES_CHECK: \"1\""
    echo "      EAS_NO_VCS: \"1\""
    # NOTE: EXPO_OFFLINE is intentionally NOT set here.
    # Setting EXPO_OFFLINE=1 prevents expo start from registering the dev session,
    # which makes the server invisible to dev clients on iOS/Android.
    # The getUserAsync hang it was meant to prevent only affects EAS builds, not expo start.
    echo "      METRO_CACHE: \"/tmp/metro-cache\""
    echo "    volumes:"
    for vdir in "${MOBILE_APPS[@]}"; do
      # Mount each app directory so Metro reads live files from the host
      echo "      - \"${ROOT_DIR}/frontend/mobile/${vdir}:/app/${vdir}:z\""
      # Protect the image-built node_modules from being overwritten by the host mount.
      # The host app dir typically has no node_modules (or only @assets), so without
      # this anonymous volume the container's full node_modules (including expo) would
      # be replaced by the empty host directory, causing "expo is not installed" errors.
      echo "      - \"/app/${vdir}/node_modules\""
    done
    echo "      - \"${ROOT_DIR}/frontend/mobile/shared:/app/shared:z\""
    # Mount shared assets inside /app/shared/assets so Metro can find them
    echo "      - \"${ROOT_DIR}/frontend/web/public:/app/shared/assets:z\""
    # Mount metro.config.base.js so host changes are live without image rebuild
    echo "      - \"${ROOT_DIR}/frontend/mobile/metro.config.base.js:/app/metro.config.base.js:z\""
    # Persist Metro cache for faster rebuilds
    echo "      - \"${service}_metro_cache:/tmp/metro-cache\""
    echo "      - /app/node_modules"
    echo "    ports:"
    echo "      - \"${port}:${port}\""
    echo "    depends_on:"
    echo "      backend:"
    echo "        condition: service_started"
    echo "    healthcheck:"
    # Expo's current Metro server accepts connections before its HTTP /status
    # handler is responsive (and that endpoint can hang indefinitely). A TCP
    # listener check accurately reports whether Metro has finished binding.
    echo "      test: [\"CMD\", \"node\", \"-e\", \"const s=require('net').connect({host:'127.0.0.1',port:${port}});s.setTimeout(5000);s.on('connect',()=>{s.destroy();process.exit(0)});s.on('error',()=>process.exit(1));s.on('timeout',()=>{s.destroy();process.exit(1)})\"]"
    echo "      interval: 30s"
    echo "      timeout: 20s"
    echo "      retries: 10"
    echo "      start_period: 300s"
    echo "    labels:"
    echo "      - \"traefik.enable=false\""
    echo "    restart: unless-stopped"
    echo "    stdin_open: true"
    echo "    tty: true"
    port=$((port + 1))
  done

  # Generate top-level volumes section for all mobile services
  echo ""
  echo "volumes:"
  for folder in "${MOBILE_APPS[@]}"; do
    local service
    service=$(folder_to_service "$folder")
    echo "  ${service}_metro_cache:"
  done
}

# ── Ensure Podman machine auto-starts via launchd (macOS) ────────────────────
# Installs a LaunchAgent + helper script that:
#   1. Starts the Podman machine on login/reboot
#   2. Starts all exited/created project containers after the machine is ready
# This ensures services survive terminal close and Mac reboots.
_ensure_podman_machine_autostart() {
  [[ "$OS" == "mac" ]] || return 0
  command -v podman &>/dev/null || return 0

  local podman_bin; podman_bin="$(command -v podman)"
  local helper="$HOME/.local/bin/podman-start-services.sh"
  local plist="$HOME/Library/LaunchAgents/com.podman.machine.default.plist"

  # ── Install podman-mac-helper for a stable socket path ───────────────────
  # Without this the socket lives in /var/folders (session temp) and breaks
  # when a new terminal opens.  The helper moves it to /var/run/docker.sock.
  local helper_bin
  for candidate in \
    "$(brew --prefix 2>/dev/null)/Cellar/podman"/*/bin/podman-mac-helper \
    /opt/homebrew/bin/podman-mac-helper \
    /usr/local/bin/podman-mac-helper; do
    [[ -x "$candidate" ]] && helper_bin="$candidate" && break
  done
  # Check if already installed — it registers as a system daemon, so check /Library/LaunchDaemons
  local _helper_label="com.github.containers.podman.helper-${USER}"
  if [[ -n "$helper_bin" ]] && ! ls /Library/LaunchDaemons/ 2>/dev/null | grep -q "podman.helper"; then
    echo "🔧 Installing podman-mac-helper (stable socket path)..."
    sudo "$helper_bin" install 2>/dev/null && \
      echo "✅ podman-mac-helper installed" || \
      echo "⚠️  podman-mac-helper install failed (non-fatal)"
  fi

  # ── Write the autostart helper script ────────────────────────────────────
  mkdir -p "$HOME/.local/bin"
  cat > "$helper" <<SCRIPT
#!/bin/bash
# Auto-start Podman machine and all containers on login/reboot.
# Managed by dev.sh — do not edit manually.
PODMAN="${podman_bin}"
LOG=/tmp/podman-autostart.log

echo "\$(date): podman-start-services.sh invoked" >> "\$LOG"

# Check if machine is already running
if "\$PODMAN" machine inspect --format '{{.State}}' 2>/dev/null | grep -qi "running"; then
  echo "\$(date): Machine already running, ensuring containers are up..." >> "\$LOG"
else
  echo "\$(date): Starting Podman machine (detached from terminal)..." >> "\$LOG"
  # Use python3 double-fork so gvproxy/vfkit spawn in a new session with no
  # controlling terminal — they won't receive SIGHUP when any terminal closes.
  python3 - "\$PODMAN" >> "\$LOG" 2>&1 <<'PYEOF'
import sys, os, subprocess
podman = sys.argv[1]
pid = os.fork()
if pid > 0:
    os.waitpid(pid, 0)
    sys.exit(0)
os.setsid()
pid2 = os.fork()
if pid2 > 0:
    sys.exit(0)
import signal
signal.signal(signal.SIGHUP, signal.SIG_IGN)
devnull = open(os.devnull, 'r')
os.dup2(devnull.fileno(), 0)
subprocess.run([podman, "machine", "start"], check=False)
PYEOF

  # Wait up to 60s for the machine to be responsive
  for i in \$(seq 1 30); do
    if "\$PODMAN" ps >/dev/null 2>&1; then
      echo "\$(date): Machine is responsive after \$((i*2))s" >> "\$LOG"
      break
    fi
    sleep 2
  done
fi

# Restart stopped/created containers, but ONLY for projects that were
# already partially running (i.e. at least one container from that project
# is currently in "running" state). This prevents auto-starting projects
# that were intentionally stopped by the user.
echo "\$(date): Checking which projects have running containers..." >> "\$LOG"

RUNNING_PROJECTS=\$("\$PODMAN" ps \
  --filter "status=running" \
  --filter "label=io.podman.compose.project" \
  --format '{{index .Labels "io.podman.compose.project"}}' 2>/dev/null | sort -u)

echo "\$(date): Projects with running containers: \${RUNNING_PROJECTS:-none}" >> "\$LOG"

if [ -z "\$RUNNING_PROJECTS" ]; then
  echo "\$(date): No projects currently running — skipping container restart." >> "\$LOG"
else
  TO_START=""
  STOPPED_NAMES=\$("\$PODMAN" ps -a \
    --filter "status=exited" \
    --filter "status=created" \
    --filter "label=io.podman.compose.project" \
    --format '{{.Names}}' 2>/dev/null)
  for cname in \$STOPPED_NAMES; do
    proj=\$("\$PODMAN" inspect "\$cname" --format '{{index .Config.Labels "io.podman.compose.project"}}' 2>/dev/null || true)
    policy=\$("\$PODMAN" inspect "\$cname" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true)
    if echo "\$RUNNING_PROJECTS" | grep -qx "\$proj" && \
       { [ "\$policy" = "unless-stopped" ] || [ "\$policy" = "always" ]; }; then
      TO_START="\$TO_START \$cname"
    fi
  done
  if [ -n "\${TO_START// /}" ]; then
    echo "\$(date): Starting:\$TO_START" >> "\$LOG"
    \$PODMAN start \$TO_START >> "\$LOG" 2>&1 || true
  else
    echo "\$(date): No containers to restart." >> "\$LOG"
  fi
fi
echo "\$(date): Done." >> "\$LOG"

# Exit 0 so launchd (KeepAlive SuccessfulExit=false) does NOT restart us
exit 0
SCRIPT
  chmod +x "$helper"

  # ── Write the LaunchAgent plist ───────────────────────────────────────────
  mkdir -p "$HOME/Library/LaunchAgents"
  # Always rewrite so the helper path stays current after brew upgrades
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.podman.machine.default</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${helper}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>/tmp/podman-autostart.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/podman-autostart.log</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>AbandonProcessGroup</key>
  <true/>
</dict>
</plist>
PLIST
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load  "$plist" 2>/dev/null || true
}

# ── Force-start any project containers stuck in "created" state ──────────────
# podman-compose 1.5.x has a bug where `up -d` creates containers but does not
# call `podman start` on them when depends_on conditions are involved.
# This function explicitly starts any project containers still in "created" state
# and ensures they have the correct restart policy.
_start_created_containers() {
  local created
  created=$(podman ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "status=created" \
    --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  [[ -z "${created// /}" ]] && return 0
  echo "▶  Starting containers stuck in 'created' state: ${created}"
  local _proxy_error=false
  for cname in $created; do
    # Ensure unless-stopped restart policy before starting
    podman update --restart unless-stopped "$cname" >/dev/null 2>&1 || true
    local _start_out
    _start_out=$(podman start "$cname" 2>&1) || {
      if echo "$_start_out" | grep -q "proxy already running"; then
        echo "  ⚠️  Stale network proxy lock detected on $cname — will recreate after machine restart"
        _proxy_error=true
      fi
    }
  done
  # If we hit a stale proxy lock, the Podman machine needs a restart to clear it.
  # Remove all stuck containers and restart the machine so they can be recreated cleanly.
  if $_proxy_error; then
    echo "🔄 Clearing stale proxy lock: stopping Podman machine..."
    # Remove all created-state containers for this project before stopping
    local _stuck
    _stuck=$(podman ps -a \
      --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
      --filter "status=created" \
      --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    for cname in $_stuck; do
      podman rm -f "$cname" >/dev/null 2>&1 || true
    done
    podman machine stop 2>/dev/null || true
    echo "🚀 Restarting Podman machine..."
    podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
    sleep 3
    _wire_podman_socket
    echo "✅ Podman machine restarted — proxy lock cleared"
  fi
}

# ── Apply unless-stopped restart policy to all project containers ─────────────
# podman-compose does not reliably apply the restart policy from the YAML.
# Call this after any up/start operation to ensure all containers auto-restart
# when the Podman machine restarts.
_apply_restart_policy() {
  local containers
  containers=$(podman ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  [[ -z "${containers// /}" ]] && return 0
  for cname in $containers; do
    podman update --restart unless-stopped "$cname" >/dev/null 2>&1 || true
  done
}

# ── Port conflict detection + tunnel-fallback override file ──────────────────
# When another project is already using a port (80, 8000, 3000, etc.) Podman
# silently fails to bind it and the container stays in "created" state forever,
# causing the long startup hang you see.
#
# This function:
#   1. Checks every host port in dev.yml with lsof
#   2. For any port already taken, generates a compose override that removes
#      the host-side binding (container still listens internally — Traefik/
#      internal networking still works)
#   3. Writes the override to /tmp/<project>-port-override.yml
#   4. Prints a warning and sets TUNNEL_FALLBACK_ACTIVE=true so _print_access_urls
#      knows to show the Cloudflare tunnel URL as the primary access URL
#
# Returns the override file path (empty string if no conflicts).
_port_conflict_override() {
  local conflicts=()
  local override_lines=()

  # Parse every service+port from dev.yml
  while IFS=' ' read -r svc port _rest; do
    [[ -z "$svc" || "$port" == "0" ]] && continue
    # Check if the port is already bound by a process outside our project.
    # Skip gvproxy and vpnkit — these are Podman's own VM port forwarders.
    # They hold the ports on behalf of the Podman VM, so seeing them means
    # the port is actually available to our containers, not taken by another app.
    local holder
    holder=$(_port_listener_info "$port" 2>/dev/null || true)
    if [[ -n "$holder" ]]; then
      conflicts+=("$svc:$port ($holder)")
      override_lines+=("  ${svc}:")
      override_lines+=("    ports: []")
    fi
  done < <(_parse_compose_services)

  if [[ ${#conflicts[@]} -eq 0 ]]; then
    # No conflicts — remove any stale override file
    rm -f "/tmp/${PROJECT_NAME}-port-override.yml"
    TUNNEL_FALLBACK_ACTIVE=false
    return 0
  fi

  # Print a clear warning
  echo "" >&2
  echo "⚠️  Port conflicts detected — another project is using these ports:" >&2
  for c in "${conflicts[@]}"; do
    echo "   • $c" >&2
  done
  echo "" >&2
  echo "   Removing conflicting host port bindings for this project." >&2
  echo "   Services will be accessible via Cloudflare Tunnel instead of localhost." >&2
  echo "" >&2

  # Write the override file
  local override_file="/tmp/${PROJECT_NAME}-port-override.yml"
  {
    echo "# Auto-generated port-conflict override — do not edit"
    echo "services:"
    for line in "${override_lines[@]}"; do
      echo "$line"
    done
  } > "$override_file"

  TUNNEL_FALLBACK_ACTIVE=true
  echo "$override_file"
}

# Global flag — set by _port_conflict_override, read by _print_access_urls
TUNNEL_FALLBACK_ACTIVE=false

# ── Pre-build base image if project.py COMPOSE_SERVICES defines a backend-base ─
# Some projects extend Dockerfile.development with a project-specific Dockerfile
_build_base_image_if_needed() {
  # Check if any compose file in COMPOSE_F defines a 'backend-base' service
  local _has_base=false
  for _f in "${COMPOSE_F[@]}"; do
    [[ "$_f" == "-f" ]] && continue
    if [[ -f "$_f" ]] && grep -q 'backend-base' "$_f" 2>/dev/null; then
      _has_base=true; break
    fi
  done
  [[ "$_has_base" == "false" ]] && return 0

  echo "🏗️  Building base image (backend-base)..."
  "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" --profile build-base build backend-base \
    >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || {
      echo "❌ backend-base build failed — check: tail -f /tmp/${PROJECT_NAME}-compose.log"
      return 1
    }
  echo "   ✅ Base image ready"
}

# ── Start services (already detached via Podman daemon) ──────────────────────
# podman-compose up -d runs containers inside the Podman VM which is a separate
# Linux process — containers survive terminal close without any wrapper.
dc_up_detached() {
  # Check for port conflicts before starting. If any host port is already taken,
  # generate an override that removes the binding so containers start immediately
  # instead of hanging in "created" state.
  local _override_file
  _override_file=$(_port_conflict_override)

  local _compose_args=()
  if [[ -n "$_override_file" && -f "$_override_file" ]]; then
    _compose_args+=("-f" "$_override_file")
  fi

  local _log="/tmp/${PROJECT_NAME}-compose.log"
  "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" "${_compose_args[@]}" up -d "$@" \
    >> "$_log" 2>&1 || {
      echo "⚠️  podman-compose up had errors — check: tail -f $_log"
      tail -5 "$_log" 2>/dev/null || true
    }

  # podman-compose 1.5.x bug: containers may be left in "created" state.
  # Explicitly start them so they actually run.
  sleep 2
  _start_created_containers
  _apply_restart_policy

  # Wait up to 30s for at least one project container to appear running.
  # Check both project-name prefix AND compose project label (covers container_name overrides).
  local i=0
  while [[ $i -lt 30 ]]; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_NAME}" || \
       podman ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" -q 2>/dev/null | grep -q .; then
      break
    fi
    sleep 1; i=$((i+1))
  done
}

# ── Ordered core startup ───────────────────────────────────────────────────────
# Starts infra (db, redis) first and waits for healthy, then backend, then
# frontend. This avoids podman-compose's unreliable handling of chained
# depends_on: condition: service_healthy across all versions.
dc_up_ordered() {
  local _log="/tmp/${PROJECT_NAME}-compose.log"
  local _override_file; _override_file=$(_port_conflict_override)
  local _compose_args=()
  [[ -n "$_override_file" && -f "$_override_file" ]] && _compose_args+=("-f" "$_override_file")

  # Ensure bind-mounted host directories exist before compose tries to mount them.
  # Missing dirs cause container start failures; creating them is always safe.
  mkdir -p \
           "$ROOT_DIR/backend/media" \
           "$ROOT_DIR/backend/config/staticfiles" 2>/dev/null || true

  # On WSL without systemd Podman does not schedule health checks itself. Start
  # the fallback before waiting for db/redis; otherwise every launch burns the
  # full 60-second infrastructure wait even though both services are ready.
  _start_healthcheck_runner

  # ── Stage 1: infrastructure (db + redis) ──────────────────────────────────
  local _infra_svcs=()
  while IFS=' ' read -r _s _p _cn; do
    [[ "$_s" == "db" || "$_s" == "redis" ]] && _infra_svcs+=("$_s")
  done < <(_parse_compose_services)

  if [[ ${#_infra_svcs[@]} -gt 0 ]]; then
    echo "   Starting infrastructure: ${_infra_svcs[*]}..."
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" "${_compose_args[@]}" up -d "${_infra_svcs[@]}" \
      >> "$_log" 2>&1 || true
    sleep 2; _start_created_containers

    # Wait up to 60s for db+redis to be healthy
    local _waited=0
    while [[ $_waited -lt 60 ]]; do
      local _all_healthy=true
      for _is in "${_infra_svcs[@]}"; do
        local _icname; _icname=$(_cname_from_cache "$(_build_cname_cache)" "$_is" "${PROJECT_NAME}-${_is}-1")
        local _istate; _istate=$(podman inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_icname" 2>/dev/null || echo "missing|none")
        local _state="${_istate%%|*}" _health="${_istate##*|}"
        if [[ "$_state" != "running" ]] || [[ "$_health" == "starting" || "$_health" == "unhealthy" ]]; then
          _all_healthy=false; break
        fi
      done
      $_all_healthy && break
      sleep 2; _waited=$((_waited + 2))
    done
    echo "   ✅ Infrastructure ready"
  fi

  # ── Stage 2: backend ───────────────────────────────────────────────────────
  local _backend_exists=false
  while IFS=' ' read -r _s _p _cn; do
    [[ "$_s" == "backend" ]] && _backend_exists=true
  done < <(_parse_compose_services)

  if $_backend_exists; then
    echo "   Starting backend..."
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" "${_compose_args[@]}" up -d backend \
      >> "$_log" 2>&1 || {
        echo "⚠️  backend failed to start — check: tail -f $_log"
        tail -10 "$_log" 2>/dev/null || true
      }
    sleep 3; _start_created_containers

    # Wait up to 90s for backend to be healthy
    local _bwaited=0
    local _bcname; _bcname=$(_cname_from_cache "$(_build_cname_cache)" "backend" "${PROJECT_NAME}-backend-1")
    echo -n "   ⏳ Waiting for backend"
    while [[ $_bwaited -lt 90 ]]; do
      local _binfo; _binfo=$(podman inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_bcname" 2>/dev/null || echo "missing|none")
      local _bstate="${_binfo%%|*}" _bhealth="${_binfo##*|}"
      if [[ "$_bstate" == "running" ]] && [[ "$_bhealth" == "healthy" || "$_bhealth" == "none" ]]; then
        echo ""; echo "   ✅ Backend ready"
        break
      elif [[ "$_bstate" == "exited" || "$_bstate" == "stopped" ]]; then
        echo ""
        echo "❌ Backend container exited — check logs:"
        podman logs --tail=20 "$_bcname" 2>/dev/null || true
        echo "   Tip: ./dev.sh logs backend"
        break
      fi
      printf "."
      sleep 3; _bwaited=$((_bwaited + 3))
    done
    [[ $_bwaited -ge 90 ]] && echo "" && echo "⚠️  Backend health check timed out — it may still be starting"
  fi

  # ── Stage 3: remaining services (frontend, etc.) ───────────────────────────
  local _remaining_svcs=()
  while IFS=' ' read -r _s _p _cn; do
    [[ "$_s" != "db" && "$_s" != "redis" && "$_s" != "backend" ]] && _remaining_svcs+=("$_s")
  done < <(_parse_compose_services)

  if [[ ${#_remaining_svcs[@]} -gt 0 ]]; then
    echo "   Starting remaining services: ${_remaining_svcs[*]}..."
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" "${_compose_args[@]}" up -d "${_remaining_svcs[@]}" \
      >> "$_log" 2>&1 || {
        echo "⚠️  Some services failed to start — check: tail -f $_log"
        tail -5 "$_log" 2>/dev/null || true
      }
    sleep 2; _start_created_containers
  fi

  _apply_restart_policy

  # Final wait: at least one project container running
  local _fi=0
  while [[ $_fi -lt 30 ]]; do
    podman ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" -q 2>/dev/null | grep -q . && break
    sleep 1; _fi=$((_fi + 1))
  done
}

dc_with_mobile() {
  local mobile_yaml tmp_file
  mobile_yaml="$(gen_mobile_yaml)"
  # Clean up any stale temp files from previous interrupted runs
  rm -f /tmp/mobile-compose-*.yml
  # mktemp on macOS doesn't support suffixes after X's — use a plain tmp file then rename
  tmp_file="$(mktemp /tmp/mobile-compose-XXXXXX)"
  local yml_file="${tmp_file}.yml"
  mv "$tmp_file" "$yml_file"
  echo "$mobile_yaml" > "$yml_file"
  $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" "$@"
  local exit_code=$?
  rm -f "$yml_file"
  return $exit_code
}

mobile_service_names() {
  discover_apps
  local names=()
  for folder in "${MOBILE_APPS[@]}"; do
    names+=("$(folder_to_service "$folder")")
  done
  echo "${names[*]}"
}

# ── Status dashboard ──────────────────────────────────────────────────────────

# _STATUS_ROWS is populated by _draw_status so the key-handler knows the URLs.
# Format: "label|cname|svc_url|log_url"
_STATUS_ROWS=()

# ── Container name resolution via labels ──────────────────────────────────────
# podman-compose always sets com.docker.compose.project and
# com.docker.compose.service labels, making this robust across all naming
# conventions (-  vs _ separator, different podman-compose versions, etc.).
#
# _build_cname_cache — returns multi-line "service_name|container_name" string
# for every container that belongs to this project.
# Uses com.docker.compose.service labels, which all podman-compose versions set.
# The | delimiter is safe: Docker/Podman forbid it in both service and container names.
# If podman is not reachable the cache is empty and lookups fall back to the
# constructed default name supplied by each call site.
_build_cname_cache() {
  podman ps -a \
    --format '{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.service"}}|{{.Names}}' \
    2>/dev/null \
    | awk -F'|' -v p="${PROJECT_NAME}" '$1 == p && $2 != "" {print $2 "|" $3}'
}

# _cname_from_cache <cache_content> <service_name> <fallback_name>
# Returns the actual container name for <service_name>, or <fallback_name>.
_cname_from_cache() {
  local cache="$1" svc="$2" fallback="$3"
  local n
  n=$(printf '%s\n' "$cache" | awk -F'|' -v s="$svc" '$1 == s {print $2; exit}')
  echo "${n:-$fallback}"
}

# ── Parse services from dev.yml dynamically ─────────────────────────────────
# Outputs one line per always-on service (no profiles): "name port container_name"
# Skips profile-gated services (backup, init, eas, etc.)
# Respects container_name overrides and ${VAR:-default} port syntax.
_parse_compose_services() {
  [[ -f "$COMPOSE_FILE" ]] || return
  local _s; _s=$(mktemp /tmp/_parse_compose_XXXXXX.py)
  printf '%s\n' \
    'import sys, re' \
    'lines = []' \
    'for path in sys.argv[1:]:' \
    '    with open(path, encoding="utf-8", errors="replace") as f:' \
    '        lines.extend(f.readlines())' \
    'services = {}' \
    'current_svc = None' \
    'in_services = False' \
    'in_ports = False' \
    'in_profiles = False' \
    'indent_services = 0' \
    'for line in lines:' \
    '    stripped = line.rstrip()' \
    '    if not stripped or stripped.lstrip().startswith("#"):' \
    '        in_ports = False; in_profiles = False; continue' \
    '    indent = len(line) - len(line.lstrip())' \
    '    if re.match(r"^services\s*:", stripped):' \
    '        in_services = True; indent_services = indent' \
    '        in_ports = False; in_profiles = False; continue' \
    '    # A Compose document can contain arbitrary top-level sections. Once' \
    '    # another one begins, none of its child keys are container services.' \
    '    if in_services and indent <= indent_services:' \
    '        in_services = False; current_svc = None' \
    '        in_ports = False; in_profiles = False; continue' \
    '    if not in_services:' \
    '        continue' \
    '    svc_match = re.match(r"\s+(\w[\w-]*)\s*:", stripped)' \
    '    if svc_match and indent == indent_services + 2:' \
    '        current_svc = svc_match.group(1)' \
    '        if current_svc not in ("volumes", "networks", "configs", "secrets"):' \
    '            services.setdefault(current_svc, {"ports": [], "profiles": [], "container_name": None})' \
    '        else:' \
    '            current_svc = None' \
    '        in_ports = False; in_profiles = False; continue' \
    '    if current_svc is None:' \
    '        continue' \
    '    pm = re.match(r"\s+profiles\s*:\s*\[([^\]]*)\]", stripped)' \
    '    if pm and indent == indent_services + 4:' \
    '        vals = [v.strip().strip("\"'"'"'") for v in pm.group(1).split(",") if v.strip()]' \
    '        services[current_svc]["profiles"].extend(vals)' \
    '        in_ports = False; in_profiles = False; continue' \
    '    if re.match(r"\s+profiles\s*:", stripped) and indent == indent_services + 4:' \
    '        in_profiles = True; in_ports = False; continue' \
    '    if re.match(r"\s+ports\s*:", stripped) and indent == indent_services + 4:' \
    '        in_ports = True; in_profiles = False; continue' \
    '    cn = re.match(r"\s+container_name\s*:\s*[\"'"'"']?([^\s\"'"'"']+)[\"'"'"']?", stripped)' \
    '    if cn and indent == indent_services + 4:' \
    '        services[current_svc]["container_name"] = cn.group(1)' \
    '        in_ports = False; in_profiles = False; continue' \
    '    item = re.match(r"\s+-\s+\"?([^\"]+)\"?", stripped)' \
    '    if item and indent >= indent_services + 4:' \
    '        val = item.group(1).strip()' \
    '        if in_profiles:' \
    '            services[current_svc]["profiles"].append(val)' \
    '        elif in_ports:' \
    '            port_part = val.split(":")[0].strip()' \
    '            port_part = re.sub(r"\$\{[^}]*:-(\d+)\}", r"\1", port_part)' \
    '            port_part = re.sub(r"\$\{[^}]+\}", "", port_part)' \
    '            if re.match(r"^\d+$", port_part):' \
    '                services[current_svc]["ports"].append(int(port_part))' \
    '        continue' \
    '    if indent <= indent_services + 4 and not item:' \
    '        in_ports = False; in_profiles = False' \
    'for svc, info in services.items():' \
    '    if info["profiles"]:' \
    '        continue' \
    '    port = info["ports"][0] if info["ports"] else 0' \
    '    cname = info["container_name"] or ""' \
    '    print(f"{svc} {port} {cname}")' \
    > "$_s"
  # Project-specific Compose snippets are separate files and therefore are not
  # visible to the dev.yml parser above. Include their always-on services so
  # ordered startup, health reporting, and rebuild commands can manage them.
  local _i _extra_file _service_files=("$COMPOSE_FILE")
  for ((_i=0; _i<${#COMPOSE_F[@]}; _i++)); do
    [[ "${COMPOSE_F[$_i]}" == "-f" ]] || continue
    _extra_file="${COMPOSE_F[$((_i + 1))]:-}"
    [[ -f "$_extra_file" && "$_extra_file" != "$COMPOSE_FILE" ]] || continue
    _service_files+=("$_extra_file")
  done
  # Merge discovery before printing so an overridden service appears once.
  python3 "$_s" "${_service_files[@]}"
  rm -f "$_s"
}

# Build the list of core services from dev.yml (excludes mobile, which are dynamic)
# Populates: CORE_SVCS array of service names
discover_core_svcs() {
  CORE_SVCS=()
  local svc
  while IFS= read -r svc; do
    svc=$(echo "$svc" | awk '{print $1}')
    [[ -n "$svc" ]] && CORE_SVCS+=("$svc")
  done < <(_parse_compose_services)
}

_draw_status() {
  # Clear stale rebuild status file so status display is accurate
  rm -f "/tmp/${PROJECT_NAME}-rebuild-status"

  discover_apps
  _STATUS_ROWS=()

  # Use label-based cache for reliable container name resolution
  local _cache; _cache=$(_build_cname_cache)

  local _row_idx=1
  local _lw=16

  # Use a simple string to track seen services
  local seen_services=""

  _srow() {
    local label="$1" cname="$2"
    # Skip if we've already seen this service
    if echo "$seen_services" | grep -q "|$label|"; then
      return
    fi
    seen_services="$seen_services|$label|"

    local state health dot color badge
    state=$(podman inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")
    health=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cname" 2>/dev/null || echo "-")
    case "$state" in
      running)
        case "$health" in
          healthy)  dot="●" color=$'\033[32m' badge="healthy"  ;;
          starting) dot="◐" color=$'\033[33m' badge="starting" ;;
          *)        dot="●" color=$'\033[32m' badge="running"  ;;
        esac ;;
      exited|stopped) dot="●" color=$'\033[31m'   badge="stopped" ;;
      missing)        dot="○" color=$'\033[2;37m' badge="missing" ;;
      *)              dot="◐" color=$'\033[33m'   badge="$state"  ;;
    esac
    _STATUS_ROWS+=("${label}|${cname}||")
    local _lbl="$label"
    [[ ${#_lbl} -gt $_lw ]] && _lbl="${_lbl:0:$((_lw-1))}…"
    printf "  %s%s\033[0m \033[2m%s\033[0m %-${_lw}s %s%s\033[0m\n" \
      "$color" "$dot" "$_row_idx" "$_lbl" "$color" "$badge"
    _row_idx=$((_row_idx + 1))
  }

  printf "\n  \033[1;34m⬡ %s\033[0m\n\n" "$PROJECT_DISPLAY_NAME"

  local _svc _port _cname_override _cname
  while IFS=' ' read -r _svc _port _cname_override; do
    [[ -z "$_svc" ]] && continue
    if [[ -n "$_cname_override" ]]; then
      _cname="$_cname_override"
    else
      _cname="$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")"
    fi
    _srow "$_svc" "$_cname"
  done < <(_parse_compose_services | sort -u)

  for folder in "${MOBILE_APPS[@]}"; do
    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local _svc; _svc=$(folder_to_service "$folder")
    local _mc; _mc=$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")
    _srow "$slug" "$_mc"
  done

  # Show global infrastructure containers (traefik) if running
  for _gcname in "traefik"; do
    if podman inspect "$_gcname" &>/dev/null 2>&1; then
      _srow "$_gcname" "$_gcname"
    fi
  done

  printf "\n  \033[2mCtrl+C quit  •  ./dev.sh logs <name>\033[0m\n\n"
}

_print_mobile_qrs() {
  discover_apps
  local port=8081 app scheme local_url remote_url url label payload
  local lan_ip; lan_ip=$(_get_lan_ip)
  for app in "${MOBILE_APPS[@]}"; do
    # Evaluate the same config that generates the installed development client.
    scheme=$(EXPO_PUBLIC_ENV=development node - "$MOBILE_DIR/$app" <<'QR_SCHEME'
const fs = require('fs'), path = require('path');
const dir = process.argv[2];
let cfg = JSON.parse(fs.readFileSync(path.join(dir, 'app.json'), 'utf8'));
const dynamic = path.join(dir, 'app.config.js');
if (fs.existsSync(dynamic)) {
  const value = require(dynamic);
  cfg = typeof value === 'function' ? value({config: cfg.expo || cfg}) : value;
}
cfg = cfg.expo || cfg;
console.log(Array.isArray(cfg.scheme) ? cfg.scheme[0] : cfg.scheme || `exp+${cfg.slug}`);
QR_SCHEME
    ) || { echo "Cannot read Expo scheme for $app"; port=$((port + 1)); continue; }
    local_url="http://${lan_ip}:${port}"
    remote_url=$(sed -n "s/^METRO_TUNNEL_URL_${port}=//p" "$ROOT_DIR/.env" | tr -d '\r')
    printf '\n  %s — SCAN WITH THE DEVELOPMENT APP INSTALLED\n' "$app"
    for label in LOCAL REMOTE; do
      url="$local_url"; [[ "$label" == REMOTE ]] && url="$remote_url"
      printf '\n  %s: %s\n' "$label" "${url:-Tunnel unavailable; retry ./dev.sh qr}"
      [[ -n "$url" ]] || continue
      payload=$(python3 -c 'import sys,urllib.parse; print(sys.argv[1]+"://expo-development-client/?url="+urllib.parse.quote(sys.argv[2],safe=""))' "$scheme" "$url")
      printf '  %s\n' "$payload"
      if command -v qrencode >/dev/null; then
        qrencode -t ANSIUTF8 -m 3 "$payload"
      else
        echo "  Install qrencode to display this QR (apt install qrencode / brew install qrencode)."
      fi
    done
    port=$((port + 1))
  done
}

_qr_page_link() {
  local root="$1" app="${2:-}" project state url host config dest port
  [[ -d "$root/frontend/mobile" ]] || return 1
  project=$(basename "$root" | tr -cd 'a-zA-Z0-9' | tr '[:upper:]' '[:lower:]')
  host=$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
  host="${host}.localhost"
  # The link is stable even while the local QR service is recovering.
  printf 'http://%s/qr' "$host"
  if [[ -n "$app" ]]; then
    printf '/%s' "$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].lower().replace(" ", "-"), safe=""))' "$app")"
  fi
  state="/tmp/${project}-qr-server-v3.url"
  url=$(cat "$state" 2>/dev/null || true)
  if [[ -z "$url" ]] || ! curl -fs --max-time 1 "$url/health" >/dev/null 2>&1; then
    rm -f "$state"
    # Keep the helper source in this entry point; only the runtime copy lives in /tmp.
    local qr_script="/tmp/${project}-qr-server.py"
    cat > "$qr_script" <<'QR_SERVER_PY'
"""Serve project-local development-client QR codes for the live monitor."""
import html
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse


def main():
    root, state = map(Path, sys.argv[1:3])
    lan_ip = sys.argv[3]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = unquote(urlparse(self.path).path)
            if path == '/health':
                self.respond('ok', 'text/plain')
                return
            apps = sorted((p for p in (root / 'frontend/mobile').iterdir()
                           if (p / 'app.json').is_file()), key=lambda p: p.name.lower())
            selected = apps if path.rstrip('/') == '/qr' else [
                p for p in apps if path == '/qr/' + p.name.lower().replace(' ', '-')]
            if not selected:
                self.send_error(404)
                return
            try:
                sections = ''.join(self.app_section(app, apps) for app in selected)
                project = html.escape(root.name)
                self.respond('<!doctype html><html lang="en"><meta charset="utf-8">'
                             '<meta name="viewport" content="width=device-width, initial-scale=1">'
                             f'<title>{project} · Mobile Apps</title><style>'
                             ':root{color-scheme:dark}*{box-sizing:border-box}'
                             'body{font:15px/1.5 system-ui;background:#14131a;color:#edeaf3;margin:0;padding:48px 24px}'
                             'main,header{max-width:1000px;margin:0 auto}header{margin-bottom:40px}'
                             '.eyebrow{color:#a995e8;font-size:12px;letter-spacing:.12em;text-transform:uppercase}'
                             'h1{font-size:32px;letter-spacing:-.04em;margin:8px 0}header p{color:#a9a3b5}'
                             'article{margin-bottom:36px}h2{font-size:19px;margin:0 0 14px}h3{font-size:14px;margin:0 0 18px}'
                             '.codes{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}'
                             'section{background:#1d1b25;border:1px solid #302c3c;padding:24px;border-radius:16px}'
                             'svg{display:block;width:100%;max-width:260px;height:auto;background:white;border-radius:8px}'
                             'a{color:#9fcfff;text-underline-offset:4px}small{display:block;color:#a9a3b5;overflow-wrap:anywhere}'
                             '@media(max-width:620px){body{padding:28px 18px}.codes{grid-template-columns:1fr}}'
                             f'</style><header><div class="eyebrow">{project}</div><h1>Mobile Apps</h1>'
                             '<p>Scan a code to open your development app. Use Local on the same Wi-Fi, '
                             'or Remote from anywhere.</p></header><main>' + sections + '</main></html>')
            except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                self.send_error(503, 'QR generation unavailable; check qrencode and the app configuration.')

        def app_section(self, app, apps):
            config = json.loads((app / 'app.json').read_text())['expo']
            if (app / 'app.config.js').is_file():
                result = subprocess.run(
                    ['node', '-e', 'const p=process.argv[1]; let c=require(p+"/app.json").expo; '
                     'let v=require(p+"/app.config.js"); v=typeof v==="function"?v({config:c}):v; '
                     'console.log(JSON.stringify(v.expo||v));', str(app)],
                    env={**os.environ, 'EXPO_PUBLIC_ENV': 'development'},
                    check=True, capture_output=True, text=True, timeout=10)
                config = json.loads(result.stdout)
            scheme = config.get('scheme') or 'exp+' + config['slug']
            if isinstance(scheme, list):
                scheme = scheme[0]
            port = 8081 + apps.index(app)
            env = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines()
                       if '=' in line and not line.lstrip().startswith('#'))
            cards = []
            for label, url in [('Local · same Wi-Fi', f'http://{lan_ip}:{port}'),
                               ('Remote', env.get(f'METRO_TUNNEL_URL_{port}', '').strip())]:
                if not url:
                    cards.append(f'<section><h3>{label}</h3><p>Tunnel unavailable.</p></section>')
                    continue
                payload = f'{scheme}://expo-development-client/?url={quote(url, safe="")}'
                svg = subprocess.run(['qrencode', '-t', 'SVG', '-o', '-', payload],
                                     check=True, capture_output=True, text=True, timeout=10).stdout
                svg = svg[svg.index('<svg'):]
                cards.append(f'<section><h3>{label}</h3>{svg}<p><a href="{html.escape(payload, quote=True)}">'
                             f'Open {html.escape(app.name)}</a></p><small>{html.escape(url)}</small></section>')
            return f'<article><h2>{html.escape(app.name)}</h2><div class="codes">' + ''.join(cards) + '</div></article>'

        def respond(self, body, content_type='text/html'):
            data = body.encode()
            self.send_response(200)
            self.send_header('Content-Type', content_type + '; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(('0.0.0.0' if '--proxy' in sys.argv else '127.0.0.1', 0), Handler)
    state.write_text(f'http://127.0.0.1:{server.server_port}')
    server.serve_forever()


if __name__ == '__main__':
    main()
QR_SERVER_PY
    _run_detached "/tmp/${project}-qr-server.log" "/tmp/${project}-qr-server.pid" \
      python3 "$qr_script" "$root" "$state" "$(_get_lan_ip)" --proxy
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [[ -s "$state" ]] && break
      sleep 0.1
    done
    url=$(cat "$state" 2>/dev/null || true)
  fi
  [[ -n "$url" ]] || return 1
  port="${url##*:}"
  dest="/tmp/traefik-dynamic/${project}-qr.yml"
  config=$(cat <<QR_ROUTE
http:
  routers:
    ${project}-qr:
      rule: 'Host(\`${host}\`) && (Path(\`/qr\`) || PathPrefix(\`/qr/\`))'
      entryPoints: [web]
      priority: 1000
      service: ${project}-qr
  services:
    ${project}-qr:
      loadBalancer:
        servers:
          - url: "http://host.containers.internal:${port}"
QR_ROUTE
)
  if [[ "$OS" == "mac" ]]; then
    # The file provider runs inside Podman's VM on macOS.
    local encoded
    encoded=$(printf '%s\n' "$config" | base64 | tr -d '\n')
    podman machine ssh "mkdir -p /tmp/traefik-dynamic; echo '$encoded' | base64 -d > '${dest}.tmp'; cmp -s '${dest}.tmp' '$dest' || mv '${dest}.tmp' '$dest'" >/dev/null 2>&1 || return 1
  else
    mkdir -p /tmp/traefik-dynamic
    if [[ ! -f "$dest" ]] || [[ "$(cat "$dest")" != "$config" ]]; then
      printf '%s\n' "$config" > "${dest}.tmp"
      mv "${dest}.tmp" "$dest"
    fi
  fi
}

_draw_status_live() {
  local _rows_file="$1"
  : > "$_rows_file"
  discover_apps

  local _lw=18 _tmp _sf
  _tmp="$(mktemp /tmp/${PROJECT_NAME}-draw-XXXXXX)"
  _sf="$(mktemp /tmp/${PROJECT_NAME}-stats-XXXXXX)"

  if command -v gtimeout &>/dev/null; then
    gtimeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  elif command -v timeout &>/dev/null; then
    timeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  else
    podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  fi

  local _all_containers
  _all_containers=$(podman ps -a \
    --format '{{.Names}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.service"}}' \
    2>/dev/null || true)

  # Size the shared column from complete display names so every row aligns.
  local _display_label _width_cn _width_proj _width_svc
  while IFS='|' read -r _width_cn _width_proj _width_svc; do
    _display_label="${_width_svc:-$_width_cn}"
    _display_label="${_display_label#mobile-}"
    [[ ${#_display_label} -gt $_lw ]] && _lw=${#_display_label}
  done <<< "$_all_containers"
  for _display_label in "${MOBILE_APPS[@]}"; do
    [[ ${#_display_label} -gt $_lw ]] && _lw=${#_display_label}
  done
  while read -r _width_svc _width_cn; do
    _display_label="${_width_svc#mobile-}"
    [[ ${#_display_label} -gt $_lw ]] && _lw=${#_display_label}
  done < <(_parse_compose_services)

  # Other compose projects (all except current)
  local _other_projects=()
  local _seen_other="|${PROJECT_NAME}|"
  while IFS='|' read -r _cn _proj _svc; do
    [[ -z "$_proj" ]] && continue
    case "$_seen_other" in *"|${_proj}|"*) continue ;; esac
    _seen_other="${_seen_other}|${_proj}|"
    _other_projects+=("$_proj")
  done <<< "$_all_containers"

  # Global infra (no compose project label)
  local _global_containers=()
  while IFS='|' read -r _cn _proj _svc; do
    [[ -z "$_proj" ]] && [[ -n "$_cn" ]] && _global_containers+=("$_cn")
  done <<< "$_all_containers"

  # Helper: resolve folder display name + root from project label
  local _projects_parent; _projects_parent="$(dirname "$ROOT_DIR")"
  _resolve_proj() {
    local _proj="$1" _var_display="$2" _var_root="$3"
    local _d="$_proj" _r="" _c _n
    for _c in "$_projects_parent"/*/; do
      _c="${_c%/}"
      _n=$(basename "$_c")
      # Stale WSL checkouts can contain CR bytes; never select them for display.
      [[ "$_n" == *[[:cntrl:]]* ]] && continue
      _n=$(printf '%s' "$_n" | tr -cd 'a-zA-Z0-9.' | tr '[:upper:]' '[:lower:]' | tr -d '.')
      if [[ "$_n" == "$_proj" ]]; then _d=$(basename "$_c"); _r="$_c"; break; fi
    done
    printf -v "$_var_display" '%s' "$_d"
    printf -v "$_var_root"    '%s' "$_r"
  }

  # Helper: wrap a URL as an OSC 8 terminal hyperlink with a short label
  # Usage: _hyperlink "https://..." "label"
  # Falls back to plain URL if the terminal doesn't support OSC 8
  _hyperlink() {
    local _url _label
    # Data must not inject cursor movement or terminate the OSC 8 sequence.
    _url=$(printf '%s' "$1" | tr -d '[:cntrl:]')
    _label=$(printf '%s' "$2" | tr -d '[:cntrl:]')
    # OSC 8 is supported by iTerm2, macOS Terminal 3.4+, VS Code, Warp, Hyper, etc.
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$_url" "$_label"
  }

  # Render rows first so the header reflects exactly the statuses in this frame.
  local _core_rows="${_tmp}.core" _mobile_rows="${_tmp}.mobile"
  local _section_ready _section_active _section_failed _header_icon _header_color _row_indent=""
  local _projects=("${_other_projects[@]}" "$PROJECT_NAME")
  {
    echo ""
    if [[ ${#_global_containers[@]} -gt 0 ]]; then
      _section_ready=true; _section_active=false; _section_failed=false
      local _infra_links=""
      : > "$_core_rows"
      for _gcn in "${_global_containers[@]}"; do
        printf '%s|%s\n' "$_gcn" "$_gcn" >> "$_rows_file"
        [[ "$_gcn" == "traefik" ]] && _infra_links="  $(_hyperlink "http://traefik.localhost" "traefik.localhost")"
        _draw_status_live_row "$_gcn" "$_gcn" "$_lw" "" "$_sf" >> "$_core_rows" || true
      done
      # Stopped sections stay hollow; failures take priority over startup.
      _header_icon='⬡'; _header_color=""
      if $_section_active; then
        _header_icon='⬢'
        if $_section_failed; then
          _header_color=$'\033[31m'
        elif ! $_section_ready; then
          _header_color=$'\033[33m'
        fi
      fi
      printf '  \033[1;35m%s%s\033[35m infrastructure\033[0m\033[37m%s\033[0m\n\n' "$_header_color" "$_header_icon" "$_infra_links"
      cat "$_core_rows"
      echo ""
    fi

    for _proj in "${_projects[@]}"; do
      local _display _root _host _tunnel _seen="|" _project_rows="" _label _cn _p _svc
      if [[ "$_proj" == "$PROJECT_NAME" ]]; then
        _display="$PROJECT_DISPLAY_NAME"; _root="$ROOT_DIR"; _host="${PROJECT_HOST}.localhost"
      else
        _resolve_proj "$_proj" _display _root
        _host="$(printf '%s' "$_display" | tr '[:upper:]' '[:lower:]').localhost"
      fi
      # Keep control bytes in paths/configuration out of terminal headers.
      _display=$(printf '%s' "$_display" | tr -d '[:cntrl:]')
      _host=$(printf '%s' "$_host" | tr -d '[:cntrl:]')
      _tunnel=$(sed -n 's/^CLOUDFLARE_TUNNEL_URL=//p' "$_root/.env" 2>/dev/null | tr -d '\r')
      while IFS='|' read -r _cn _p _svc; do
        [[ "$_p" == "$_proj" && -n "$_cn" ]] || continue
        _label="${_svc:-$_cn}"
        case "$_seen" in *"|${_label}|"*) continue ;; esac
        _seen+="${_label}|"
        _project_rows+="${_label}|${_cn}"$'\n'
      done <<< "$_all_containers"

      # Include expected services even before their containers have been created.
      if [[ "$_proj" == "$PROJECT_NAME" ]]; then
        local _port _override
        while read -r _svc _port _override; do
          [[ -n "$_svc" ]] || continue
          case "$_seen" in *"|${_svc}|"*) continue ;; esac
          _seen+="${_svc}|"
          _project_rows+="${_svc}|${_override:-${PROJECT_NAME}-${_svc}-1}"$'\n'
        done < <(_parse_compose_services | sort -u)
        for folder in "${MOBILE_APPS[@]}"; do
          _svc=$(folder_to_service "$folder")
          case "$_seen" in *"|${_svc}|"*) continue ;; esac
          _seen+="${_svc}|"
          _project_rows+="${_svc}|${PROJECT_NAME}-${_svc}-1"$'\n'
        done
      fi

      _section_ready=true; _section_active=false; _section_failed=false
      local _project_links=""
      : > "$_core_rows"; : > "$_mobile_rows"
      while IFS='|' read -r _label _cn; do
        [[ -n "$_cn" ]] || continue
        local _destination="$_core_rows"
        _row_indent=""
        if [[ "$_label" == "frontend" ]]; then
          _project_links="  $(_hyperlink "http://${_host}" "${_host}")"
          [[ -n "$_tunnel" ]] && _project_links+="  $(_hyperlink "$_tunnel" "tunnel")"
        fi
        if [[ "$_label" == mobile-* ]]; then
          _destination="$_mobile_rows"
        fi
        printf '%s|%s\n' "$_label" "$_cn" >> "$_rows_file"
        _draw_status_live_row "$_label" "$_cn" "$_lw" "" "$_sf" >> "$_destination" || true
      done <<< "$_project_rows"
      _row_indent=""
      # Stopped sections stay hollow; failures take priority over startup.
      _header_icon='⬡'; _header_color=""
      if $_section_active; then
        _header_icon='⬢'
        if $_section_failed; then
          _header_color=$'\033[31m'
        elif ! $_section_ready; then
          _header_color=$'\033[33m'
        fi
      fi
      if [[ -s "$_mobile_rows" ]]; then
        local _qr_url
        _qr_url=$(_qr_page_link "$_root" </dev/null) || true
        [[ -n "$_qr_url" ]] && _project_links+="  $(_hyperlink "$_qr_url" "QR")"
      fi
      printf '  \033[1;34m%s%s\033[34m %s\033[0m\033[37m%s\033[0m\n\n' "$_header_color" "$_header_icon" "$_display" "$_project_links"
      cat "$_core_rows"
      if [[ -s "$_mobile_rows" ]]; then
        echo ""
        cat "$_mobile_rows"
      fi
      echo ""
    done
    printf "  \033[2mCtrl+C to quit\033[0m\n\n"
  } > "$_tmp" 2>/dev/null
  cat "$_tmp"
  rm -f "$_tmp" "$_sf" "$_core_rows" "$_mobile_rows"
}

_draw_status_live_row() {
  local label="$1" cname="$2" lw="$3" port="$4" sf="$5"
  # $6 onward: optional link pairs encoded as "url TAB label", one per arg
  local _link_args=("${@:6}")
  local state health dot color badge uptime cpu mem last_log
  local _info
  local _rebuild_status_file="/tmp/${PROJECT_NAME}-rebuild-status"

  # Check if this service is being rebuilt
  local is_restarting=false
  if [[ -f "$_rebuild_status_file" ]] && grep -q "^${label}$" "$_rebuild_status_file" 2>/dev/null; then
    is_restarting=true
  fi

  # Use gtimeout (macOS coreutils) or timeout (Linux); fall back to plain call if neither exists
  if command -v gtimeout &>/dev/null; then
    _info=$(gtimeout 10 podman inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.StartedAt}}' "$cname" 2>/dev/null) || _info="missing|-|-"
  elif command -v timeout &>/dev/null; then
    _info=$(timeout 10 podman inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.StartedAt}}' "$cname" 2>/dev/null) || _info="missing|-|-"
  else
    _info=$(podman inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.StartedAt}}' "$cname" 2>/dev/null) || _info="missing|-|-"
  fi
  [[ -z "$_info" ]] && _info="missing|-|-"
  state=$(printf '%s' "$_info" | cut -d'|' -f1)
  health=$(printf '%s' "$_info" | cut -d'|' -f2)
  local started_at; started_at=$(printf '%s' "$_info" | cut -d'|' -f3)

  # Override status if service is being rebuilt
  if $is_restarting; then
    dot='◐' color=$'\033[33m' badge="restarting"
  else
    case "$state" in
      running)
        case "$health" in
          healthy)  dot='●' color=$'\033[32m' badge="healthy"  ;;
          unhealthy) dot='●' color=$'\033[31m' badge="unhealthy" ;;
          starting) dot='◐' color=$'\033[33m' badge="starting" ;;
          *)        dot='●' color=$'\033[32m' badge="running"  ;;
        esac ;;
      exited|stopped) dot='●' color=$'\033[31m'   badge="stopped" ;;
      missing)        dot='○' color=$'\033[2;37m' badge="missing" ;;
      *)              dot='◐' color=$'\033[33m'   badge="$state"  ;;
    esac
  fi

  # Dynamically scoped by the frame renderer; no extra container probes needed.
  case "$badge" in
    unhealthy|stopped|missing|dead) _section_failed=true ;;
  esac
  if [[ "$badge" != "healthy" && "$badge" != "running" ]]; then
    _section_ready=false
  fi
  if $is_restarting; then
    _section_active=true
  else
    case "$state" in
      missing|exited|stopped|created) ;;
      *) _section_active=true ;;
    esac
  fi

  uptime=""
  if [[ "$state" == "running" && -n "$started_at" && "$started_at" != "-" ]]; then
    local _se _ne _diff _dt
    _dt="${started_at:0:19}"
    # Cross-platform epoch conversion: try GNU date, then macOS date, then Python
    _se=$(date -d "$_dt" "+%s" 2>/dev/null \
       || date -j -f "%Y-%m-%dT%H:%M:%S" "$_dt" "+%s" 2>/dev/null \
       || python3 -c "import datetime,calendar; print(int(calendar.timegm(datetime.datetime.strptime('${_dt}','%Y-%m-%dT%H:%M:%S').timetuple())))" 2>/dev/null \
       || echo "")
    if [[ -n "$_se" ]]; then
      _ne=$(date +%s); _diff=$(( _ne - _se ))
      if   (( _diff < 60 ));    then uptime="${_diff}s"
      elif (( _diff < 3600 ));  then uptime="$(( _diff/60 ))m"
      elif (( _diff < 86400 )); then uptime="$(( _diff/3600 ))h"
      else uptime="$(( _diff/86400 ))d"; fi
    fi
  fi
  cpu=""; mem=""
  if [[ -f "$sf" ]]; then
    local _sl
    _sl=$(grep "^${cname}|" "$sf" 2>/dev/null | head -1 || true)
    if [[ -n "$_sl" ]]; then
      cpu=$(printf '%s' "$_sl" | cut -d'|' -f2)
      mem=$(printf '%s' "$_sl" | cut -d'|' -f3 | cut -d' ' -f1)
    fi
  fi
  # Keep service identifiers intact for actions; simplify only the display name.
  local lbl="${label#mobile-}"
  if [[ "$label" == mobile-* ]]; then
    case "$badge" in
      healthy|running) dot='◆' color=$'\033[32m' ;;
      starting|restarting) dot='◇' color=$'\033[33m' ;;
      *) dot='◇' color=$'\033[31m' ;;
    esac
  fi
  [[ ${#lbl} -gt $lw ]] && lw=${#lbl}
  local port_col=""
  [[ -n "$port" && "$port" != "0" ]] && port_col=":${port}"
  # Build optional link badges (appended after stats)
  local _links_str=""
  for _lp in "${_link_args[@]}"; do
    local _lurl="${_lp%%	*}"
    local _llabel="${_lp##*	}"

    # Check if this is a shell command (not a real URL)
    if [[ "$_lurl" =~ ^(powershell|shell):// ]]; then
      # Extract command from pseudo-protocol
      local _cmd="${_lurl#*://}"
      # Don't create a hyperlink, just show the label and command in a copyable format
      _links_str+="  $(printf '\033[2m[\033[0m\033[36m%s\033[0m\033[2m: %s]\033[0m' "$_llabel" "$_cmd")"
    else
      # Use printf to emit actual ESC bytes for OSC 8 hyperlink
      _links_str+="  $(printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$_lurl" "$_llabel")"
    fi
  done
  printf '%s' "${_row_indent:-}"
  printf "  %s%s\033[0m  %-${lw}s  %s%-9s\033[0m  \033[2m%-5s  %-7s  %-8s  %s\033[0m%s\n" \
    "$color" "$dot" "$lbl" "$color" "$badge" "$uptime" "$cpu" "$mem" "$port_col" "$_links_str"
  return 0
}

# ── print_status — one-shot rich status snapshot ─────────────────────────────
print_status() {
  _wire_podman_socket 2>/dev/null || true

  local _local_host="${PROJECT_HOST}.localhost"
  local _tunnel_url
  _tunnel_url=$(grep "^CLOUDFLARE_TUNNEL_URL=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")

  discover_apps

  local _cache; _cache=$(_build_cname_cache)
  local _sf; _sf="$(mktemp /tmp/${PROJECT_NAME}-stats-XXXXXX)"
  if command -v gtimeout &>/dev/null; then
    gtimeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  elif command -v timeout &>/dev/null; then
    timeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  else
    podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  fi

  local _lw=16
  local seen_services=""
  _seen_svc() { case "$seen_services" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }
  _mark_svc() { seen_services="$seen_services|$1|"; }

  echo ""
  printf "  \033[1;34m⬡ %s\033[0m\n" "$PROJECT_DISPLAY_NAME"
  echo ""
  printf "  \033[2m%-${_lw}s  %-9s  %-5s  %-7s  %-8s\033[0m\n" "SERVICE" "STATUS" "UP" "CPU" "MEM"
  printf "  \033[2m%s\033[0m\n" "$(printf '─%.0s' $(seq 1 58))"

  _prow() {
    local label="$1" cname="$2"
    _seen_svc "$label" && return
    _mark_svc "$label"
    _draw_status_live_row "$label" "$cname" "$_lw" "" "$_sf" || true
  }

  # Core services from dev.yml
  local _svc _port _cname_override _cname
  while IFS=' ' read -r _svc _port _cname_override; do
    [[ -z "$_svc" ]] && continue
    if [[ -n "$_cname_override" ]]; then _cname="$_cname_override"
    else _cname="$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")"; fi
    _prow "$_svc" "$_cname"
  done < <(_parse_compose_services | sort -u)

  # Mobile services
  for folder in "${MOBILE_APPS[@]}"; do
    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local _msvc; _msvc=$(folder_to_service "$folder")
    local _mc; _mc=$(_cname_from_cache "$_cache" "$_msvc" "${PROJECT_NAME}-${_msvc}-1")
    _prow "$slug" "$_mc"
  done

  # Global infra
  if podman inspect traefik &>/dev/null 2>&1; then
    _prow "traefik" "traefik"
  fi

  rm -f "$_sf"

  # ── URLs ──────────────────────────────────────────────────────────────────
  echo ""
  printf "  \033[2m%s\033[0m\n" "$(printf '─%.0s' $(seq 1 58))"
  printf "  \033[1mURLs\033[0m\n"
  echo ""
  printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n"  "Web:"     "https://${_local_host}"
  printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n"  "API:"     "https://${_local_host}/api"
  printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n"  "Admin:"   "https://${_local_host}/admin"
  printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n"  "Traefik:" "http://traefik.localhost"

  if [[ -n "$_tunnel_url" ]]; then
    echo ""
    printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n" "Tunnel:"    "$_tunnel_url"
    printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n" "Tunnel API:" "$_tunnel_url/api"
  fi

  local _port=8081
  for _app in "${MOBILE_APPS[@]}"; do
    local _lan_ip
    _lan_ip=$(_get_lan_ip)
    printf "  \033[2m%-14s\033[0m \033[36m%s\033[0m\n" "Metro (${_app}):" "http://${_lan_ip}:${_port}"
    _port=$((_port + 1))
  done

  # ── Traefik routes ────────────────────────────────────────────────────────
  local _routes
  _routes=$(podman exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null \
    | python3 -c "
import sys, json
try:
  routers = json.load(sys.stdin)
  rows = [(r.get('rule',''), r.get('status','')) for r in routers
          if not r.get('name','').endswith('@internal')
          and r.get('rule','')]
  rows.sort(key=lambda x: x[0])
  for rule, status in rows:
    color = '\033[32m' if status == 'enabled' else '\033[31m'
    print(f'  {color}●\033[0m  \033[2m{rule}\033[0m')
except: pass
" 2>/dev/null || true)

  if [[ -n "$_routes" ]]; then
    echo ""
    printf "  \033[2m%s\033[0m\n" "$(printf '─%.0s' $(seq 1 58))"
    printf "  \033[1mTraefik Routes\033[0m\n"
    echo ""
    echo "$_routes"
  fi

  echo ""
}

live_monitor() {
  # Clear stale rebuild status file so status display is accurate
  rm -f "/tmp/${PROJECT_NAME}-rebuild-status"

  # `status` can be launched directly, without passing through smart_launch.
  # Ensure WSL's no-systemd health fallback is active before drawing rows.
  _start_healthcheck_runner

  # Check if Podman machine exists and is running, but DON'T create or start it
  # Status command should only show status, not change anything
  local _machine_running=false
  if [[ "$OS" == "mac" ]]; then
    # Check if VM files exist
    if [[ -f "$HOME/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw" ]] || \
       [[ -f "$HOME/.local/share/containers/podman/machine/qemu/podman-machine-default_fedora-coreos.qcow2" ]]; then
      # VM exists, check if it's running
      if podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qi "running"; then
        _machine_running=true
      fi
    fi
  else
    # Linux/WSL - podman runs natively, no VM needed
    # Just verify Podman is responding
    if podman info >/dev/null 2>&1; then
      _machine_running=true
    fi
  fi

  if ! $_machine_running; then
    echo ""
    echo "⚠️  Podman machine is not running"
    echo ""
    echo "   Run './dev.sh' to start services"
    echo "   Or './dev.sh up' to start without building"
    echo ""
    return 0
  fi

  _wire_podman_socket 2>/dev/null || true

  local _rows_file
  _rows_file="$(mktemp /tmp/${PROJECT_NAME}-status-rows-XXXXXX)"
  local _SAVED_STTY
  _SAVED_STTY="$(stty -g 2>/dev/null || true)"

  _cleanup_monitor() {
    printf '\033[?25h'
    stty "$_SAVED_STTY" 2>/dev/null || true
    rm -f "$_rows_file"
    printf "\n\033[2m  Services keep running in the background.\033[0m\n\n"
    exit 0
  }
  trap '_cleanup_monitor' HUP INT TERM

  printf '\033[?25l'   # hide cursor

  # Infinite loop - keep monitoring until user presses Ctrl+C
  while true; do
    : > "$_rows_file"
    set +e
    # Capture the new frame, then clear + paint atomically to avoid flicker
    local _out_tmp
    _out_tmp="$(mktemp /tmp/${PROJECT_NAME}-monitor-out-XXXXXX)"
    _draw_status_live "$_rows_file" 2>/dev/null > "$_out_tmp"
    set -e
    clear
    cat "$_out_tmp"
    rm -f "$_out_tmp"
    sleep 3 2>/dev/null || true
  done

  _cleanup_monitor
}


# ── Single-service log view ────────────────────────────────────────────────────
_service_log_view() {
  local cname="$1"
  [[ -z "$cname" ]] && return 1
  tput smcup 2>/dev/null
  clear
  printf "  \033[1m📋 %s\033[0m  \033[2m— Ctrl+C to go back\033[0m\n\n" "$cname"
  trap 'tput rmcup 2>/dev/null; trap - INT; return 0' INT
  podman logs -f --names "$cname" 2>/dev/null
  tput rmcup 2>/dev/null
}


run_mobile() {
  if has_mobile_apps; then
    # Auto-update EXPO_PUBLIC_API_URL with current local IP
    update_mobile_ip

    local services
    services=$(mobile_service_names)
    echo "📱 Starting mobile services: $services"
    # Write a stable mobile compose file so the detached process can reference it
    local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
    gen_mobile_yaml > "$yml_file"
    # shellcheck disable=SC2086
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" up -d $services \
      >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true

    # podman-compose 1.5.x bug: containers may be left in "created" state.
    sleep 2
    _start_created_containers
    _apply_restart_policy

    # Wait up to 20s for the first mobile container to appear running
    local i=0
    while [[ $i -lt 20 ]]; do
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qE "^${PROJECT_NAME}[-_]mobile-"; then
        break
      fi
      sleep 1; i=$((i+1))
    done

    # Set up adb reverse so emulators/devices can reach Metro on localhost
    # This is a no-op if adb is not installed or no devices are connected.
    _setup_physical_devices 2>/dev/null || true
  else
    echo "⚠️  No mobile apps found in frontend/mobile/ — skipping."
  fi
}

build_mobile() {
  if has_mobile_apps; then
    local services
    services=$(mobile_service_names)
    echo "🏗️  Building mobile image..."
    # shellcheck disable=SC2086
    dc_with_mobile build $services
  else
    echo "⚠️  No mobile apps found in frontend/mobile/ — skipping."
  fi
}

build_mobile_no_cache() {
  if has_mobile_apps; then
    local services
    services=$(mobile_service_names)
    echo "🏗️  Building mobile image (no cache)..."
    # shellcheck disable=SC2086
    dc_with_mobile build --no-cache $services
  else
    echo "⚠️  No mobile apps found in frontend/mobile/ — skipping."
  fi
}

# ── Build native Android APKs locally via Gradle assembleDebug ───────────────
_build_native_apks_locally() {
  _setup_android_path

  if ! command -v java &>/dev/null; then
    echo "⚠️  Java not found — skipping native APK build."
    echo "   Install Java (Temurin) and re-run: ./dev.sh rebuild"
    return 0
  fi

  discover_apps
  local OUTPUT_DIR="$ROOT_DIR/frontend/mobile/builds"
  mkdir -p "$OUTPUT_DIR"
  local failed=()

  for folder in "${MOBILE_APPS[@]}"; do
    local android_dir="$MOBILE_DIR/$folder/android"
    local gradlew="$android_dir/gradlew"

    # Ensure android/ exists and is fully configured (idempotent)
    _ensure_android_dir "$folder" "$android_dir"

    if [[ ! -f "$gradlew" ]]; then
      echo "⚠️  No android/gradlew for '$folder' after setup — skipping native build."
      continue
    fi

    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local apk_out="$OUTPUT_DIR/${slug}.apk"

    echo ""
    echo "========================================="
    echo "🔨 Building native APK: $folder"
    echo "========================================="

    # Clean previous build output so we get a truly fresh APK
    "$gradlew" -p "$android_dir" clean 2>&1 || true

    if "$gradlew" -p "$android_dir" assembleDebug 2>&1; then
      local built_apk
      built_apk=$(find "$android_dir/app/build/outputs/apk/debug" -name "*.apk" 2>/dev/null | head -1)
      if [[ -n "$built_apk" ]]; then
        cp "$built_apk" "$apk_out"
        echo "✅ $folder → frontend/mobile/builds/${slug}.apk"
      else
        echo "❌ APK not found after build for '$folder'"
        failed+=("$folder")
      fi
    else
      echo "❌ Gradle build failed for '$folder'"
      failed+=("$folder")
    fi
  done

  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    echo "✅ All native APKs built successfully."
  else
    echo "⚠️  Native APK build failed for: ${failed[*]}"
    echo "   Metro JS bundle will still work — install APKs manually with:"
    echo "   ./dev.sh build <app> android local"
  fi
}

# ── Follow logs for all running project containers in parallel ───────────────
_follow_logs() {
  local filter="${1:-}"
  local pids=() cname matched=()

  # Collect project-scoped containers
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ -n "$filter" ]]; then
      # Strip the project-name prefix (e.g. "myproject_" or "myproject-") so that
      # `./dev.sh logs <service>` doesn't match every container (they all start
      # with the project name). Match the filter only against the service part.
      local service_part="${cname#${PROJECT_NAME}_}"
      service_part="${service_part#${PROJECT_NAME}-}"
      echo "$service_part" | grep -qi "$filter" || continue
    fi
    matched+=("$cname")
    podman logs -f --names "$cname" 2>&1 &
    pids+=($!)
  done < <(podman ps --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT_NAME}[-_]")

  # Also check global infrastructure containers (traefik)
  # when a filter is provided — they don't carry the project-name prefix.
  if [[ -n "$filter" ]]; then
    for _gcname in "traefik"; do
      echo "$_gcname" | grep -qi "$filter" || continue
      podman inspect "$_gcname" &>/dev/null 2>&1 || continue
      matched+=("$_gcname")
      podman logs -f --names "$_gcname" 2>&1 &
      pids+=($!)
    done
  fi

  if [[ ${#pids[@]} -eq 0 ]]; then
    if [[ -n "$filter" ]]; then
      echo "⚠️  No running containers found matching '$filter'."
      echo "    Available containers:"
      podman ps --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${PROJECT_NAME}[-_]" \
        | sed "s/^${PROJECT_NAME}[-_]/    /" || true
      echo "    traefik  (global)"
    else
      echo "⚠️  No running containers found."
    fi
    return
  fi

  if [[ -n "$filter" ]]; then
    echo "🔍 Tailing logs for: ${matched[*]}"
    echo ""
  fi

  trap 'kill "${pids[@]}" 2>/dev/null; trap - INT TERM; echo ""' INT TERM
  wait "${pids[@]}" 2>/dev/null
  trap - INT TERM
}

# ── Tunnel watchdog ───────────────────────────────────────────────────────────
# Detached watchdog: preserve live connectors during network/DNS/origin failures.
# Restart only exited processes or explicitly rejected quick-tunnel identities.
_start_tunnel_watchdog() {
  grep -Eq '^DISABLE_PUBLIC_TUNNELS=true\r?$' "$ROOT_DIR/.env" && return 0
  local watchdog_pid_file="/tmp/${PROJECT_NAME}-tunnel-watchdog.pid"

  # Keep an existing watchdog. Restarting it on every dev.sh run used to reset
  # Cloudflare's cooldown and repeatedly extend quick-tunnel rate limits.
  if [[ -f "$watchdog_pid_file" ]]; then
    local old_pid; old_pid=$(cat "$watchdog_pid_file" 2>/dev/null || true)
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
      if grep -q "preserve-identity-v5" "/tmp/${PROJECT_NAME}-tunnel-watchdog.sh" 2>/dev/null; then return 0; fi
      kill "$old_pid" 2>/dev/null || true
    fi
    rm -f "$watchdog_pid_file"
  fi

  # Don't start watchdog if cloudflared isn't installed
  command -v cloudflared &>/dev/null || return 0
  # A watchdog cannot repair project configuration; wait for preparation and
  # the runtime check to pass rather than launching a doomed recovery loop.
  if python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" has-exposure-check; then
    bash "$ROOT_DIR/dev.sh" _exposure_check_only >/dev/null 2>&1 || return 0
  fi

  # Capture all variables the watchdog loop needs now, before forking.
  # The double-fork (setsid + subshell) means the child has no parent to
  # inherit from at runtime — everything must be embedded at launch time.
  local _pname="$PROJECT_NAME"
  local _rdir="$ROOT_DIR"
  local _lhost="${PROJECT_HOST}.localhost"
  local _tlog="/tmp/${PROJECT_NAME}-tunnel.log"
  local _tpid="/tmp/${PROJECT_NAME}-tunnel.pid"
  local _wpid="$watchdog_pid_file"
  local _wlog="/tmp/${PROJECT_NAME}-tunnel-watchdog.log"
  # Named tunnel token — empty string if using quick tunnels
  local _wtok
  _wtok=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' || true)

  # Write watchdog logic to a temp script file and run it detached.
  # Writing to a file avoids bash 3.2's parser choking on quotes/parens inside
  # "$(cat <<EOF...EOF)" command substitutions — a known bash 3.2 limitation.
  local _wscript="/tmp/${PROJECT_NAME}-tunnel-watchdog.sh"
  cat > "$_wscript" <<'WATCHDOG_SCRIPT_EOF'
#!/bin/bash
# preserve-identity-v5
# Args: pname rdir lhost tlog tpid wpid [tunnel_token]
_pname="$1"; _rdir="$2"; _lhost="$3"; _tlog="$4"; _tpid="$5"; _wpid="$6"; _tok="${7:-}"
_retry_file="/tmp/${_pname}-tunnel-retry-after"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

echo $$ > "$_wpid"

# ── helpers ──────────────────────────────────────────────────────────────────

_tw_metrics_port() {
  grep -o 'metrics server on 127\.0\.0\.1:[0-9]*' "$_tlog" 2>/dev/null \
    | grep -o '[0-9]*$' | head -1
}

_tw_is_crash_looping() {
  local _lines _ha _port
  _lines=$(tail -30 "$_tlog" 2>/dev/null | grep -c "control stream encountered a failure"; true)
  _lines=$(echo "$_lines" | tr -d '[:space:]'); _lines=${_lines:-0}
  _port=$(_tw_metrics_port)
  _ha=1
  if [[ -n "$_port" ]]; then
    _ha=$(curl -sf --max-time 2 "http://127.0.0.1:${_port}/metrics" 2>/dev/null \
      | (grep '^cloudflared_tunnel_ha_connections ' || true) | awk '{print $2}')
    _ha="${_ha:-1}"
  fi
  [[ "$_lines" -ge 3 && "$_ha" = "0" ]]
}

_tw_flush_dns() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  sudo -n dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
  sudo -n killall -HUP mDNSResponder 2>/dev/null || killall -HUP mDNSResponder 2>/dev/null || true
}

# Write the Traefik dynamic config into the Podman VM (macOS) or host (Linux).
# Uses two separate SSH calls — a single combined call with && and pipe redirect
# is silently dropped by podman machine ssh on some macOS versions.
_tw_register_traefik() {
  local _url="$1"
  local _host="${_url#https://}"; _host="${_host%/}"
  local _fe="${_pname}_frontend_1"
  local _be="${_pname}_backend_1"
  local _dest="/tmp/traefik-dynamic/${_pname}.yml"
  local _b64
  # Build YAML via printf — avoids heredoc-within-heredoc limitations in the
  # watchdog script, and avoids bash 3.2 quoting issues with inline strings.
  _b64=$(printf '%s\n' \
    "http:" \
    "  routers:" \
    "    ${_pname}-tunnel-frontend:" \
    "      rule: \"Host(\`${_host}\`)\"" \
    "      entryPoints: [web]" \
    "      priority: 1" \
    "      service: ${_pname}-tunnel-frontend-svc" \
    "    ${_pname}-tunnel-api:" \
    "      rule: \"Host(\`${_host}\`) && PathPrefix(\`/api\`)\"" \
    "      entryPoints: [web]" \
    "      priority: 100" \
    "      middlewares:" \
    "        - ${_pname}-tunnel-strip-api" \
    "        - ${_pname}-compress" \
    "      service: ${_pname}-tunnel-backend-svc" \
    "    ${_pname}-tunnel-admin:" \
    "      rule: \"Host(\`${_host}\`) && PathPrefix(\`/admin\`)\"" \
    "      entryPoints: [web]" \
    "      priority: 100" \
    "      middlewares:" \
    "        - ${_pname}-compress" \
    "      service: ${_pname}-tunnel-backend-svc" \
    "    ${_pname}-tunnel-static:" \
    "      rule: \"Host(\`${_host}\`) && PathPrefix(\`/static\`)\"" \
    "      entryPoints: [web]" \
    "      priority: 100" \
    "      service: ${_pname}-tunnel-backend-svc" \
    "    ${_pname}-tunnel-media:" \
    "      rule: \"Host(\`${_host}\`) && PathPrefix(\`/media\`)\"" \
    "      entryPoints: [web]" \
    "      priority: 100" \
    "      service: ${_pname}-tunnel-backend-svc" \
    "  middlewares:" \
    "    ${_pname}-tunnel-strip-api:" \
    "      stripPrefix:" \
    "        prefixes: [\"/api\"]" \
    "    ${_pname}-compress:" \
    "      compress: {}" \
    "  services:" \
    "    ${_pname}-tunnel-frontend-svc:" \
    "      loadBalancer:" \
    "        servers:" \
    "          - url: \"http://${_fe}:3000\"" \
    "    ${_pname}-tunnel-backend-svc:" \
    "      loadBalancer:" \
    "        servers:" \
    "          - url: \"http://${_be}:8000\"" \
    | base64)
  [[ -z "$_b64" ]] && return 1
  if command -v podman &>/dev/null && podman machine ssh "true" 2>/dev/null; then
    # Two separate calls: mkdir, then write — avoids silent SSH pipe drop
    podman machine ssh "mkdir -p /tmp/traefik-dynamic" 2>/dev/null || true
    if ! podman machine ssh "echo '${_b64}' | base64 -d > ${_dest}" 2>/dev/null; then
      sleep 1
      podman machine ssh "mkdir -p /tmp/traefik-dynamic" 2>/dev/null || true
      podman machine ssh "echo '${_b64}' | base64 -d > ${_dest}" 2>/dev/null || return 1
    fi
    # Verify the file actually landed in the VM
    podman machine ssh "test -s ${_dest}" 2>/dev/null || return 1
  else
    mkdir -p /tmp/traefik-dynamic
    echo "$_b64" | base64 -d > "$_dest" || return 1
  fi
  return 0
}

# Save URL to .env — works on both macOS (sed -i '') and Linux (sed -i)
_tw_save_url() {
  local _url="$1"
  if grep -q "^CLOUDFLARE_TUNNEL_URL=" "$_rdir/.env" 2>/dev/null; then
    sed -i '' "s|^CLOUDFLARE_TUNNEL_URL=.*|CLOUDFLARE_TUNNEL_URL=${_url}|" "$_rdir/.env" 2>/dev/null \
      || sed -i "s|^CLOUDFLARE_TUNNEL_URL=.*|CLOUDFLARE_TUNNEL_URL=${_url}|" "$_rdir/.env" 2>/dev/null || true
  else
    echo "CLOUDFLARE_TUNNEL_URL=${_url}" >> "$_rdir/.env"
  fi
}

# Check that the tunnel URL resolves AND returns a non-5xx response from our app.
# A plain curl to trycloudflare.com can succeed even when Traefik config is stale
# (Cloudflare returns its own error page). We treat HTTP 5xx as a routing failure
# only after confirming DNS resolves — otherwise it's a transient app error.
_tw_url_healthy() {
  local _url="$1"
  [[ -z "$_url" ]] && return 1
  # First check: does the hostname resolve at all?
  local _host="${_url#https://}"; _host="${_host%%/*}"
  if ! python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], 443)' "$_host" 2>/dev/null; then
    return 1  # DNS failure — tunnel lease expired
  fi
  # Second check: HTTP response. Anything except connection refused / timeout is
  # considered "up" — a 502/503 means Traefik is routing but the app isn't ready,
  # which is a transient condition, not a dead tunnel.
  local _code
  _code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$_url" 2>/dev/null || true)
  [[ -n "$_code" && "$_code" != "000" ]]
}

# Confirm missing public DNS independently of the machine's DNS cache. Timeouts,
# SERVFAIL and transport errors are inconclusive and must preserve the tunnel.
_tw_dns_expired() {
  [[ -z "$_tok" && "$1" == https://*.trycloudflare.com ]] || return 1
  python3 - "$1" <<'DNS_CHECK'
import json, sys, urllib.parse, urllib.request
host = urllib.parse.urlsplit(sys.argv[1]).hostname
try:
    for resolver in ('https://dns.google/resolve', 'https://cloudflare-dns.com/dns-query'):
        url = resolver + '?' + urllib.parse.urlencode({'name': host, 'type': 'A'})
        request = urllib.request.Request(url, headers={'Accept': 'application/dns-json'})
        with urllib.request.urlopen(request, timeout=5) as response:
            if json.load(response).get('Status') != 3:
                sys.exit(1)
except Exception:
    sys.exit(1)
sys.exit(0)
DNS_CHECK
}

_tw_restart() {
  local _reason="$1"
  if python3 "$_rdir/backend/config/project_config.py" "$_rdir" has-exposure-check; then
    bash "$_rdir/dev.sh" _exposure_check_only || return 1
  fi

  # Quick-tunnel 429 responses are account/IP scoped. Preserve the cooldown
  # across launcher and watchdog restarts instead of requesting more tunnels.
  if [[ -z "$_tok" && -f "$_retry_file" ]]; then
    local _retry_after _now
    _retry_after=$(cat "$_retry_file" 2>/dev/null || echo 0)
    _now=$(date +%s)
    if [[ "$_retry_after" =~ ^[0-9]+$ ]] && [[ "$_retry_after" -gt "$_now" ]]; then
      sleep $(( _retry_after - _now ))
    fi
    rm -f "$_retry_file"
  fi

  echo "[watchdog $(date '+%H:%M:%S')] ${_reason} — restarting tunnel..."

  # Kill the existing cloudflared process
  local _old
  _old=$(cat "$_tpid" 2>/dev/null || true)
  [[ -n "$_old" ]] && kill "$_old" 2>/dev/null || true
  pkill -f "cloudflared tunnel.*--http-host-header ${_lhost}" 2>/dev/null || true
  rm -f "$_tpid" "$_tlog"
  sleep 1

  # Start fresh cloudflared — named tunnel if token provided, quick tunnel otherwise
  if [[ -n "$_tok" ]]; then
    nohup cloudflared tunnel \
      --protocol http2 \
      --no-autoupdate \
      run --token "$_tok" \
      >> "$_tlog" 2>&1 &
  else
    nohup cloudflared tunnel \
      --protocol http2 \
      --url "http://localhost:80" \
      --http-host-header "$_lhost" \
      --proxy-connect-timeout 30s \
      >> "$_tlog" 2>&1 &
  fi
  local _new=$!
  disown $_new 2>/dev/null || true
  echo $_new > "$_tpid"

  # Wait up to 90s for new URL
  local _url="" _i=0
  while [[ $_i -lt 90 ]]; do
    _url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$_tlog" 2>/dev/null | head -1 || true)
    # Named tunnel: look for stable domain or "registered" confirmation
    if [[ -z "$_url" ]] && [[ -n "$_tok" ]]; then
      _url=$(sed -n 's/^CLOUDFLARE_TUNNEL_URL=//p' "$_rdir/.env" | tr -d '\r')
    fi
    [[ -n "$_url" ]] && break
    if grep -q "429\|Too Many Requests\|error code: 1015" "$_tlog" 2>/dev/null; then
      break
    fi
    sleep 1; _i=$((_i+1))
  done

  if [[ -n "$_url" ]]; then
    rm -f "$_retry_file"
    _tw_save_url "$_url"
    _tw_flush_dns
    # Retry Traefik registration up to 3 times — SSH can be briefly unavailable
    local _reg_ok=false
    for _rt in 1 2 3; do
      if _tw_register_traefik "$_url"; then
        _reg_ok=true; break
      fi
      sleep 2
    done
    if [[ "$_reg_ok" == "true" ]]; then
      echo "[watchdog $(date '+%H:%M:%S')] Tunnel up: $_url"
    else
      echo "[watchdog $(date '+%H:%M:%S')] Tunnel started but Traefik registration failed — will retry next cycle"
    fi
    # The web watchdog can recover after dev.sh has already entered the live
    # monitor. Restore Metro tunnels too so their links return to that monitor.
    (cd "$_rdir" && bash dev.sh _metro_tunnels_only) || true
  else
    if grep -q "429\|Too Many Requests\|error code: 1015" "$_tlog" 2>/dev/null; then
      echo $(( $(date +%s) + 600 )) > "$_retry_file"
      echo "[watchdog $(date '+%H:%M:%S')] Cloudflare rate limited quick tunnels — backing off for 10 minutes"
    else
      echo "[watchdog $(date '+%H:%M:%S')] Tunnel did not come up — will retry next cycle"
    fi
  fi
}

# ── main watchdog loop ────────────────────────────────────────────────────────
_crash_streak=0
_bad_streak=0
_was_offline=false
_last_reg_attempt=0

while true; do
  sleep 20  # Check every 20s (down from 30s for faster recovery)

  if python3 "$_rdir/backend/config/project_config.py" "$_rdir" has-exposure-check; then
    if ! bash "$_rdir/dev.sh" _exposure_check_only; then
      _unsafe_pid=$(cat "$_tpid" 2>/dev/null || true)
      [[ "$_unsafe_pid" =~ ^[0-9]+$ ]] && kill "$_unsafe_pid" 2>/dev/null || true
      echo "Public connector stopped: project security check failed."
      exit 1
    fi
  fi

  # Skip if project containers aren't running
  _any=$(podman ps --filter "label=io.podman.compose.project=${_pname}" -q 2>/dev/null | head -1 || true)
  [[ -z "$_any" ]] && _crash_streak=0 && _bad_streak=0 && continue

  # Skip if no internet
  if ! curl -sf --max-time 5 https://cloudflare.com >/dev/null 2>&1; then
    _crash_streak=0; _bad_streak=0
    [[ "$_was_offline" == "false" ]] && echo "[watchdog $(date '+%H:%M:%S')] No network — will retry when online"
    _was_offline=true
    continue
  fi
  if [[ "$_was_offline" == "true" ]]; then
    echo "[watchdog $(date '+%H:%M:%S')] Network back — allowing existing tunnel to reconnect..."
    _tw_flush_dns
    _was_offline=false
    _crash_streak=0; _bad_streak=0
  fi

  # ── Check 1: is the cloudflared process alive? ────────────────────────────
  _pid=$(cat "$_tpid" 2>/dev/null || true)
  if [[ ! "$_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$_pid" 2>/dev/null || ! ps -p "$_pid" -o args= | grep -q "[c]loudflared tunnel"; then
    _tw_restart "Process gone"
    _crash_streak=0; _bad_streak=0
    continue
  fi

  # Only an explicit rejected quick-tunnel identity warrants replacing a live
  # connector. Network outages and origin failures must retain the same URL.
  if [[ -z "$_tok" ]] && tail -20 "$_tlog" | grep -q 'Unauthorized: Tunnel not found'; then
    _tw_restart "Cloudflare rejected expired tunnel identity"
    continue
  fi
  (cd "$_rdir" && bash dev.sh _metro_tunnels_only) >/dev/null 2>&1 || true

  # ── Check 3: is the saved URL still alive on Cloudflare's edge? ──────────
  _saved=$(grep "^CLOUDFLARE_TUNNEL_URL=" "$_rdir/.env" 2>/dev/null | cut -d= -f2- || true)
  if [[ -z "$_tok" ]]; then
    _live_url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$_tlog" | head -1 || true)
    if [[ -n "$_live_url" && "$_live_url" != "$_saved" ]]; then
      _saved="$_live_url"
      _tw_save_url "$_saved"
      _tw_register_traefik "$_saved" 2>/dev/null || true
      _bad_streak=0
    fi
  fi
  if [[ -n "$_saved" ]]; then
    if _tw_url_healthy "$_saved"; then
      # URL is healthy — make sure Traefik config is still in place
      # Re-register if enough time has passed since last attempt (every ~5min)
      _now=$(date +%s)
      if [[ $(( _now - _last_reg_attempt )) -gt 300 ]]; then
        _tw_register_traefik "$_saved" 2>/dev/null || true
        _last_reg_attempt=$_now
      fi
      _bad_streak=0
    else
      _bad_streak=$((_bad_streak+1))
      echo "[watchdog $(date '+%H:%M:%S')] URL not healthy (streak=${_bad_streak}): $_saved"
      if [[ "$_bad_streak" -eq 1 ]]; then
        # First failure: flush DNS and re-register Traefik — may be a transient glitch
        _tw_flush_dns
        sleep 3
        if _tw_url_healthy "$_saved"; then
          echo "[watchdog $(date '+%H:%M:%S')] Recovered after DNS flush"
          _tw_register_traefik "$_saved" 2>/dev/null || true
          _last_reg_attempt=$(date +%s)
          _bad_streak=0
        else
          _tw_register_traefik "$_saved" 2>/dev/null || true
          _last_reg_attempt=$(date +%s)
        fi
      elif [[ "$_bad_streak" -ge 3 ]]; then
        if _tw_dns_expired "$_saved"; then
          _tw_restart "Quick-tunnel hostname expired (confirmed by two public DNS resolvers)"
        else
          # Ordinary outages and origin failures retain the same identity.
          _tw_register_traefik "$_saved" 2>/dev/null || true
        fi
        _crash_streak=0; _bad_streak=0
      fi
    fi
  else
    # No URL saved at all — start a fresh tunnel
    # Keep the connector alive while it negotiates its URL.
    _crash_streak=0; _bad_streak=0
  fi
done
WATCHDOG_SCRIPT_EOF
  chmod +x "$_wscript"

  # Use the same waited double-fork as the tunnel processes; the launch must
  # finish detaching before a short-lived WSL invocation exits.
  _run_detached "$_wlog" "$_wpid" bash "$_wscript" \
    "$_pname" "$_rdir" "$_lhost" "$_tlog" "$_tpid" "$_wpid" "$_wtok"
}
_open_safari() {
  # Determine the URL to open: tunnel if available, otherwise project localhost
  local _tunnel_url _open_url
  _tunnel_url=$(grep "^CLOUDFLARE_TUNNEL_URL=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")

  if [[ -n "$_tunnel_url" ]]; then
    _open_url="$_tunnel_url"
  else
    _open_url="https://${PROJECT_HOST}.localhost"
  fi

  case "$OS" in
    mac)
      local already_open
      already_open=$(osascript 2>/dev/null <<ASEOF
tell application "Safari"
  set urlList to {}
  repeat with w in windows
    repeat with t in tabs of w
      set end of urlList to URL of t
    end repeat
  end repeat
  repeat with u in urlList
    if u starts with "${_open_url}" then
      return "yes"
    end if
  end repeat
  return "no"
end tell
ASEOF
      ) || true
      [[ "$already_open" != "yes" ]] && open -a Safari "$_open_url" 2>/dev/null || true
      ;;
    linux|wsl)
      # On WSL2: open in the Windows host browser via wslview or PowerShell.
      # Never block — always fire-and-forget with a 3s timeout.
      {
        if command -v wslview &>/dev/null; then
          wslview "$_open_url" 2>/dev/null &
        elif command -v powershell.exe &>/dev/null; then
          powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$_open_url'" 2>/dev/null &
        elif command -v xdg-open &>/dev/null; then
          timeout 3 xdg-open "$_open_url" 2>/dev/null &
        fi
      } &>/dev/null &
      disown $! 2>/dev/null || true
      ;;
    windows)
      # Git Bash / MSYS2 — start opens the default browser
      start "$_open_url" 2>/dev/null || true
      ;;
  esac
}

# ── Print access URLs ─────────────────────────────────────────────────────────
_print_access_urls() {
  local _tunnel_url
  _tunnel_url=$(grep "^CLOUDFLARE_TUNNEL_URL=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")

  # PROJECT_HOST is already the correct lowercase+dots form (e.g. myproject.com)
  local _local_host="${PROJECT_HOST}.localhost"

  echo "   🏠 Local (zero latency):"
  echo "      Web app:  https://${_local_host}"
  echo "      API:      https://${_local_host}/api"
  echo "      Admin:    https://${_local_host}/admin"
  echo "      Traefik:  http://localhost  (dashboard — all projects)"
  discover_apps
  local _port=8081
  for _app in "${MOBILE_APPS[@]}"; do
    local _lan_ip
    _lan_ip=$(_get_lan_ip)
    echo "      Metro ($_app):  http://${_lan_ip}:${_port}  (same WiFi / emulator)"
    _port=$((_port + 1))
  done

  if [[ -n "$_tunnel_url" ]]; then
    echo ""
    echo "   🌐 Tunnel (physical device on any network):"
    echo "      Web app:  $_tunnel_url"
    echo "      API:      $_tunnel_url/api"
    local _tport=8081
    for _app in "${MOBILE_APPS[@]}"; do
      local _metro_tunnel_url
      _metro_tunnel_url=$(grep "^METRO_TUNNEL_URL_${_tport}=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")
      if [[ -n "$_metro_tunnel_url" ]]; then
        echo "      Metro ($_app):  $_metro_tunnel_url"
        echo "         → Physical device: open Expo dev client → Enter URL manually → paste above"
      else
        echo "      Metro ($_app):  ⏳ tunnel starting... (check again in ~30s)"
      fi
      _tport=$((_tport + 1))
    done
    echo ""
    echo "   ℹ️  Both local AND tunnel are active simultaneously."
    echo "      Simulators/emulators use local. Physical devices use tunnel."
  else
    echo ""
    echo "   ⚠️  Tunnel not active — check the startup messages above. Local access still works."
    echo "      Simulators and same-WiFi devices will work."
  fi
}

# ── Start Android emulator + install all apps ────────────────────────────────
# Always installs the latest APK from builds/ on the emulator.
# If the emulator is not running, boots it first then installs.
# Pass "force" as $1 to force reinstall even if nothing changed.
_start_emulator_with_apps() {
  local force="${1:-}"
  has_mobile_apps || return 0
  _setup_android_path
  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"
  local emu_cmd="${ANDROID_HOME}/emulator/emulator"
  if [[ ! -x "$adb_cmd" ]] || [[ ! -x "$emu_cmd" ]]; then
    echo "🔧 Android SDK not found — installing now..."
    _install_android_sdk
    _setup_android_path
    adb_cmd="${ANDROID_HOME}/platform-tools/adb"
    emu_cmd="${ANDROID_HOME}/emulator/emulator"
  fi
  if [[ ! -x "$adb_cmd" ]] || [[ ! -x "$emu_cmd" ]]; then
    echo "❌ Android SDK install failed — skipping emulator launch."
    return 0
  fi

  local device=""

  if _emulator_running; then
    # Emulator already up — grab its serial and install/launch immediately
    device=$("$adb_cmd" devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
    echo "✅ Emulator already running ($device)"
    _setup_physical_devices 2>/dev/null || true
    _install_apps_on_device "$device"
  else
    # Boot the emulator — returns immediately, fully detached
    echo ""
    echo "📱 Starting Android emulator..."
    _ensure_emulator

    # Spawn a background watcher that installs apps once the emulator is ready.
    # No timeout — it will wait however long the first boot takes.
    local _adb="$adb_cmd"
    local _android_home="$ANDROID_HOME"
    (
      export ANDROID_HOME="$_android_home"
      export PATH="$_android_home/platform-tools:$_android_home/emulator:$_android_home/cmdline-tools/latest/bin:$PATH"
      echo "⏳ Waiting for emulator to boot (this can take a few minutes on first run)..."
      local _dev=""
      while true; do
        _dev=$("$_adb" devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
        if [[ -n "$_dev" ]]; then
          local _booted
          _booted=$("$_adb" -s "$_dev" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
          [[ "$_booted" == "1" ]] && break
        fi
        sleep 5
      done
      echo "✅ Emulator ready ($_dev) — setting up adb reverse and installing apps..."
      "$_adb" reverse tcp:8000 tcp:8000 2>/dev/null || true
      "$_adb" reverse tcp:8081 tcp:8081 2>/dev/null || true
      "$_adb" reverse tcp:8082 tcp:8082 2>/dev/null || true
      _install_apps_on_device "$_dev"
    ) >> /tmp/emulator-install.log 2>&1 &
    disown $! 2>/dev/null || true
    echo "   Background watcher started — apps will install automatically once booted."
    echo "   Tail the log: tail -f /tmp/emulator-install.log"
  fi
}

# ── Install all available APKs on a given device ────────────────────────────
_install_apps_on_device() {
  local device="$1"
  [[ -z "$device" ]] && return 0
  _setup_android_path
  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"

  local installed_app_slugs=()

  # ── PRIORITY 1: Install APKs from frontend/mobile/builds/ ─────────────────
  discover_apps
  local builds_apks=()
  for folder in "${MOBILE_APPS[@]}"; do
    local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local apk="$ROOT_DIR/frontend/mobile/builds/${app_key}-development.apk"
    if [[ ! -f "$apk" ]]; then apk="$ROOT_DIR/frontend/mobile/builds/${folder} (development).apk"; fi
    if [[ ! -f "$apk" ]]; then apk="$ROOT_DIR/frontend/mobile/builds/${app_key}.apk"; fi
    if [[ ! -f "$apk" ]]; then apk="$ROOT_DIR/frontend/mobile/builds/${folder}.apk"; fi
    if [[ -f "$apk" ]]; then builds_apks+=("$app_key:$apk"); fi
  done

  if [[ ${#builds_apks[@]} -gt 0 ]]; then
    echo ""
    # Only install the first app by default to avoid Metro auto-discovery conflicts
    # User can manually install other apps if needed
    local first_entry="${builds_apks[0]}"
    local first_app_key="${first_entry%%:*}"
    echo "📦 Installing ${first_app_key} from builds/ directory..."
    echo "   (Only installing first app to avoid Metro port conflicts)"
    echo "   To install other apps, use: ./dev.sh android-install <app-name>"
    _install_app_on_emulator "$first_app_key" "$device"
    installed_app_slugs+=("$first_app_key")
    echo "✅ Finished installing ${first_app_key}"
  fi

  # ── PRIORITY 2: Install locally built APKs (not in builds/) ───────────────
  local local_apks=()
  for folder in "${MOBILE_APPS[@]}"; do
    local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local skip_app=false
    for installed_slug in "${installed_app_slugs[@]}"; do
      [[ "$installed_slug" == "$app_key" ]] && skip_app=true && break
    done
    [[ "$skip_app" == true ]] && continue
    local local_apk="$MOBILE_DIR/$folder/android/app/build/outputs/apk/debug/app-debug.apk"
    [[ -f "$local_apk" ]] && local_apks+=("$app_key:$local_apk")
  done

  if [[ ${#local_apks[@]} -gt 0 ]]; then
    echo ""
    echo "📦 Installing ${#local_apks[@]} locally built APK(s)..."
    for entry in "${local_apks[@]}"; do
      local app_key="${entry%%:*}"
      local apk_path="${entry#*:}"
      echo "   📲 Installing $app_key (local build)..."
      "$adb_cmd" -s "$device" install -r "$apk_path" 2>/dev/null || echo "      ⚠️  Install failed"
    done
    echo "✅ Finished installing local APKs"
  fi

  if [[ ${#builds_apks[@]} -eq 0 && ${#local_apks[@]} -eq 0 ]]; then
    echo ""
    echo "⚠️  No APKs found in builds/ or local builds"
    echo "   Build an APK with: ./dev.sh build <app> android local"
  fi
}

# ── Open browser ─────────────────────────────────────────────────────────────
_open_devtools() {
  _open_safari
  # iOS physical device: start iproxy USB tunnels so the app can reach Metro
  # and the backend via localhost — same as adb reverse does for Android.
  _setup_ios_tunnel 2>/dev/null || true
}

# ── Rebuild helper (needs to be a function so `local` works) ─────────────────
_do_rebuild() {
  local specific_service="${1:-}"  # optional: rebuild only this service
  local _rebuild_status_file="/tmp/${PROJECT_NAME}-rebuild-status"

  if [[ -n "$specific_service" ]]; then
    # ── Rebuild a specific service ──────────────────────────────────────────
    echo "🔧 Rebuilding service: $specific_service"

    # Mark service as restarting in status file
    echo "$specific_service" >> "$_rebuild_status_file"

    # Check if it's a mobile service
    if [[ "$specific_service" == mobile-* ]]; then
      local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"

      # Derive the exact container name podman-compose uses
      local _cname="${PROJECT_NAME}_${specific_service}_1"

      echo "🗑️  Stopping and removing container..."
      podman stop "$_cname" 2>/dev/null || true
      podman rm   "$_cname" 2>/dev/null || true

      echo "🗑️  Removing service image..."
      podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^(localhost/)?(${PROJECT_NAME}_${specific_service}|${PROJECT_NAME}-${specific_service})" \
        | xargs -r podman rmi -f 2>/dev/null || true

      echo "📦 Rebuilding mobile service (no cache)..."
      $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" build --no-cache "$specific_service" 2>/dev/null || true

      echo "🚀 Starting service..."
      # Start only this service. We deliberately omit --force-recreate because
      # podman-compose has a bug where that flag restarts ALL services in the file.
      # Since we already stopped+removed the container above, a plain `up -d` will
      # create and start only the missing container without touching others.
      $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" up -d "$specific_service" \
        >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true
    else
      # Core service
      local _core_cname="${PROJECT_NAME}_${specific_service}_1"

      echo "🗑️  Stopping and removing container..."
      podman stop "$_core_cname" 2>/dev/null || true
      podman rm   "$_core_cname" 2>/dev/null || true

      echo "🗑️  Removing service image..."
      podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^(localhost/)?(${PROJECT_NAME}_${specific_service}|${PROJECT_NAME}-${specific_service})" \
        | xargs -r podman rmi -f 2>/dev/null || true

      echo "📦 Rebuilding core service (no cache)..."
      # If rebuilding the backend, ensure the base image is up to date first
      [[ "$specific_service" == "backend" ]] && _build_base_image_if_needed
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" build --no-cache "$specific_service" 2>/dev/null || true

      echo "🚀 Starting service..."
      # Start only this service. We deliberately omit --force-recreate because
      # podman-compose has a bug where that flag restarts ALL services in the file.
      # Since we already stopped+removed the container above, a plain `up -d` will
      # create and start only the missing container without touching others.
      $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" up --no-start "$specific_service" \
        >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || true
      podman start "$_core_cname" >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || true
    fi

    echo ""
    echo "✅ Service $specific_service rebuilt and restarted."
    echo "   (Live monitor will show 'restarting' status for a few more seconds)"
    echo ""

    # Wait so the live monitor can display the restarting status
    # (monitor refreshes every 3 seconds)
    sleep 5

    # Remove service from rebuild status file
    if [[ -f "$_rebuild_status_file" ]]; then
      grep -v "^${specific_service}$" "$_rebuild_status_file" > "${_rebuild_status_file}.tmp" 2>/dev/null || true
      mv "${_rebuild_status_file}.tmp" "$_rebuild_status_file" 2>/dev/null || true
      # Clean up empty file
      [[ ! -s "$_rebuild_status_file" ]] && rm -f "$_rebuild_status_file"
    fi

    _draw_status
    echo ""
    echo "   Run ./dev.sh status to monitor service health."
    echo ""
    return
  fi

  # ── Full rebuild (all services) ─────────────────────────────────────────
  echo "🧨 Rebuild: performing deep clean (same as ./dev.sh down)..."
  echo ""

  # Mark all services as restarting
  discover_apps
  discover_core_svcs
  : > "$_rebuild_status_file"

  # Mark all core services
  while IFS=' ' read -r _svc _port _cname_override; do
    [[ -n "$_svc" ]] && echo "$_svc" >> "$_rebuild_status_file"
  done < <(_parse_compose_services)

  # Mark all mobile services
  for folder in "${MOBILE_APPS[@]}"; do
    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    echo "$slug" >> "$_rebuild_status_file"
  done

  # ── Snapshot disk usage before cleanup ───────────────────────────────────
  _disk_before=$(podman system df --format '{{.Size}}' 2>/dev/null | awk '
    function to_bytes(s,   n, u) {
      n = s+0; u = s
      gsub(/[0-9.]+/, "", u)
      if      (u ~ /[Gg]B?$/) return n * 1073741824
      else if (u ~ /[Mm]B?$/) return n * 1048576
      else if (u ~ /[Kk]B?$/) return n * 1024
      else                    return n
    }
    { total += to_bytes($1) }
    END { printf "%d\n", total }
  ' 2>/dev/null || echo "0")

  echo "🛑 Stopping ${PROJECT_NAME} services..."
  _project_containers=$(podman ps -a --filter "label=io.podman.compose.project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  if [[ -n "${_project_containers// /}" ]]; then
    podman stop $_project_containers 2>/dev/null || true
    podman rm   $_project_containers 2>/dev/null || true
  fi
  podman network rm "${PROJECT_NAME}_default" 2>/dev/null || true

  echo "🗑️  Removing project images..."
  podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | { grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" || true; } \
    | xargs -r podman rmi -f 2>/dev/null || true

  echo "🗑️  Removing project volumes..."
  podman volume ls --format '{{.Name}}' 2>/dev/null \
    | { grep -E "^${PROJECT_NAME}_" || true; } \
    | xargs -r podman volume rm 2>/dev/null || true

  echo "🗑️  Removing dangling images (project-related)..."
  # Only remove dangling images that were produced by this project's build context.
  # Avoid `--filter dangling=true` alone — that removes dangling layers from ALL
  # projects, which would force every other project to re-download their base images.
  podman images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null \
    | awk '$2 == "<none>:<none>" {print $1}' \
    | while read -r _img_id; do
        # Keep the image if any other project's container references it
        _used_by=$(podman ps -a --format '{{.Image}}' 2>/dev/null | grep -c "$_img_id" || true)
        if [[ "$_used_by" -eq 0 ]]; then
          # Only remove if it was created as part of this project's build
          _labels=$(podman image inspect --format '{{json .Labels}}' "$_img_id" 2>/dev/null || echo '{}')
          if echo "$_labels" | grep -q "\"io.podman.compose.project\":\"${PROJECT_NAME}\"" 2>/dev/null; then
            podman rmi -f "$_img_id" 2>/dev/null || true
          fi
        fi
      done || true

  echo "🗑️  Pruning build cache (project layers only)..."
  # Prune only build-cache objects that belong to this project.
  # `podman builder prune -a -f` flushes the entire shared build cache, which
  # forces every other project to rebuild from scratch on their next `up`.
  # Instead, remove only the cache entries referenced by this project's images.
  podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" \
    | while read -r _img; do
        podman image inspect --format '{{.Id}}' "$_img" 2>/dev/null \
          | xargs -r podman builder prune --filter "until=0s" --filter "id=$_img" -f 2>/dev/null || true
      done || true
  # Also prune cache entries that are no longer referenced by any image at all
  podman builder prune -f 2>/dev/null || true

  echo "🗑️  Removing project-related containers (including exited)..."
  podman ps -a --filter "label=io.podman.compose.project=${PROJECT_NAME}" --format '{{.ID}}' 2>/dev/null \
    | xargs -r podman rm -f 2>/dev/null || true

  echo "🗑️  Cleaning temporary files..."
  rm -f "/tmp/${PROJECT_NAME}-mobile-compose.yml" "/tmp/${PROJECT_NAME}-compose.log" "/tmp/${PROJECT_NAME}-mobile.log"

  # Clean up any build artifacts in the project directory
  [[ -d "$ROOT_DIR/backend/__pycache__" ]] && rm -rf "$ROOT_DIR/backend/__pycache__"
  [[ -d "$ROOT_DIR/backend/.pytest_cache" ]] && rm -rf "$ROOT_DIR/backend/.pytest_cache"
  find "$ROOT_DIR/backend" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "$ROOT_DIR/backend" -type f -name "*.pyc" -delete 2>/dev/null || true

  # Clean up node_modules caches if they exist
  if [[ -d "$ROOT_DIR/frontend" ]]; then
    find "$ROOT_DIR/frontend" -type d -name ".expo" -exec rm -rf {} + 2>/dev/null || true
    find "$ROOT_DIR/frontend" -type d -name ".expo-shared" -exec rm -rf {} + 2>/dev/null || true
    find "$ROOT_DIR/frontend" -type d -name "node_modules/.cache" -exec rm -rf {} + 2>/dev/null || true
  fi

  # ── Reclaim disk space from Podman machine (macOS only) ─────────────────
  if [[ "$OS" == "mac" ]]; then
    if [[ "$_DOWN_ALL" == "true" ]]; then
      echo "💾 Deleting Podman machine (.raw removed, space fully reclaimed)..."
      podman machine stop 2>/dev/null || true
      podman machine rm --force 2>/dev/null || true
      echo "✅ Podman machine deleted. Run ./dev.sh to recreate it."
    else
      podman machine ssh -- sudo fstrim -av 2>/dev/null || true
    fi
  fi

  # ── Ensure Podman machine has enough disk space (macOS only) ─────────────
  if command -v podman &>/dev/null && [[ "$OS" == "mac" ]]; then
    local machine_disk
    machine_disk=$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null || echo "0")
    [[ "$machine_disk" =~ ^[0-9]+$ ]] || machine_disk=0
    if (( machine_disk < 150 )); then
      echo ""
      echo "⚠️  Podman machine disk is only ${machine_disk}GiB — recreating with 200GiB..."
      podman machine stop 2>/dev/null || true
      podman machine rm --force 2>/dev/null || true
      echo "🖥️  Creating new Podman machine with 200GiB disk..."
      podman machine init --cpus 4 --memory 8192 --disk-size 60 2>&1 || true
      podman machine start 2>&1 || true
      local _mw=0
      while [[ $_mw -lt 60 ]]; do
        podman ps >/dev/null 2>&1 && break
        sleep 2; _mw=$((_mw + 2))
      done
      _wire_podman_socket
      echo "✅ Podman machine ready (200GiB)"
      echo ""
    fi
  fi

  # ── Snapshot disk usage after cleanup and report delta ───────────────────
  if [[ "$_DOWN_ALL" == "true" && "$OS" == "mac" ]]; then
    _disk_after=0
  else
    _disk_after=$(podman system df --format '{{.Size}}' 2>/dev/null | awk '
      function to_bytes(s,   n, u) {
        n = s+0; u = s
        gsub(/[0-9.]+/, "", u)
        if      (u ~ /[Gg]B?$/) return n * 1073741824
        else if (u ~ /[Mm]B?$/) return n * 1048576
        else if (u ~ /[Kk]B?$/) return n * 1024
        else                    return n
      }
      { total += to_bytes($1) }
      END { printf "%d\n", total }
    ' 2>/dev/null || echo "0")
    # Guard against empty or non-numeric output
    [[ "$_disk_after" =~ ^[0-9]+$ ]] || _disk_after=0
  fi

  # Guard against empty or non-numeric _disk_before
  [[ "$_disk_before" =~ ^[0-9]+$ ]] || _disk_before=0

  _freed=$(( _disk_before - _disk_after ))
  if (( _freed > 0 )); then
    if   (( _freed >= 1073741824 )); then
      _freed_human="$(awk "BEGIN { printf \"%.1f GiB\", $_freed / 1073741824 }")"
    elif (( _freed >= 1048576 )); then
      _freed_human="$(awk "BEGIN { printf \"%.1f MiB\", $_freed / 1048576 }")"
    elif (( _freed >= 1024 )); then
      _freed_human="$(awk "BEGIN { printf \"%.1f KiB\", $_freed / 1024 }")"
    else
      _freed_human="${_freed} B"
    fi
    echo ""
    echo "💾 Space freed: ${_freed_human}"
  fi

  echo ""
  echo "✅ Deep clean complete. Rebuilding everything from scratch..."
  echo ""

  run_setup
  gen_app_json 2>/dev/null || true
  ensure_podman_running
  detect_compose
  _wire_podman_socket

  # Recreate shared Traefik network — it was wiped when the Podman machine was recreated
  _ensure_global_traefik

  echo "🏗️  Building core images (no cache)..."
  _build_base_image_if_needed
  "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" build --no-cache

  if has_mobile_apps; then
    build_mobile_no_cache
  fi

  echo ""
  echo "🚀 Starting all services..."
  dc_up_ordered
  if has_mobile_apps; then
    run_mobile
  fi

  echo ""
  echo "✅ Rebuild complete. Services are running in the background."
  echo ""

  # Clear rebuild status file
  rm -f "$_rebuild_status_file"

  # Drop into the live monitor, same as ./dev.sh
  set +e
  live_monitor
  set -e
}

# ── Smart launch helpers ──────────────────────────────────────────────────────

# Returns the container state: running, created, exited, missing, etc.
_container_state() {
  podman inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"
}

# Classify each container: "ok" | "starting" | "broken" | "missing"
_container_status() {
  local state; state=$(_container_state "$1")
  case "$state" in
    running)                    echo "ok" ;;
    created|paused|restarting)  echo "starting" ;;
    exited|stopped)             echo "broken" ;;
    missing)                    echo "missing" ;;
    *)                          echo "broken" ;;
  esac
}

# Check if Android emulator is running
_emulator_running() {
  _setup_android_path
  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"
  if [[ ! -x "$adb_cmd" ]]; then
    return 1
  fi
  local device
  device=$("$adb_cmd" devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1 || true)
  [[ -n "$device" ]]
}

# Ensure Android SDK + emulator tooling is on PATH
_patch_android_gradle() {
  # Patch the foojay-resolver plugin version after expo prebuild.
  # React Native 0.83 ships foojay-resolver-convention:0.5.0 inside its Gradle
  # plugin which crashes on Gradle 9 with "IBM_SEMERU field not found".
  # Version 1.0.0 (May 2025) fixes this and is fully Gradle 9 compatible.
  # The file lives in node_modules/@react-native/gradle-plugin/settings.gradle.kts
  local android_dir="$1"
  local app_dir; app_dir="$(dirname "$android_dir")"

  # Find the RN gradle plugin settings file (may be in app or workspace node_modules)
  local rn_settings=""
  for candidate in \
    "$app_dir/node_modules/@react-native/gradle-plugin/settings.gradle.kts" \
    "$(dirname "$app_dir")/node_modules/@react-native/gradle-plugin/settings.gradle.kts"; do
    [[ -f "$candidate" ]] && rn_settings="$candidate" && break
  done

  if [[ -n "$rn_settings" ]]; then
    if grep -q 'foojay-resolver-convention.*0\.[0-9]' "$rn_settings" 2>/dev/null; then
      # Delegate to helper script — bash 3.2 misparses inline sed/python with parens
      python3 "$ROOT_DIR/frontend/mobile/patch_foojay.py" "$rn_settings" 2>/dev/null \
        && echo "🔧 Patched foojay-resolver → 1.0.0 in $(basename "$(dirname "$rn_settings")")"
    fi
  fi

  # Also patch the app's own settings.gradle if it has foojay
  local app_settings="$android_dir/settings.gradle"
  if [[ -f "$app_settings" ]] && grep -q 'foojay-resolver' "$app_settings" 2>/dev/null; then
    python3 "$ROOT_DIR/frontend/mobile/patch_foojay.py" "$app_settings" 2>/dev/null \
      && echo "🔧 Patched foojay-resolver → 1.0.0 in settings.gradle"
  fi
}

_setup_android_path() {
  local sdk="${ANDROID_HOME:-$(_default_android_sdk)}"
  export ANDROID_HOME="$sdk"
  # Ensure standard system bins (timeout, ls, etc.) are always on PATH
  export PATH="$sdk/platform-tools:$sdk/emulator:$sdk/cmdline-tools/latest/bin:$sdk/cmdline-tools/bin:/usr/bin:/bin:$PATH"

  # JAVA_HOME for Android/Gradle builds on macOS.
  # Gradle 9 + foojay-resolver has a bug with JVM 25 (IBM_SEMERU field removed).
  # Always prefer Java 21 LTS for Android builds — it's the officially supported
  # version for React Native + Gradle 9. Fall back to any available JVM if 21 isn't found.
  if [[ "$OS" == "mac" ]]; then
    local jh=""
    # 1. Prefer Java 21 LTS (brew openjdk@21)
    for vm in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
              /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
              /Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home \
              /Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home; do
      [[ -x "$vm/bin/java" ]] && jh="$vm" && break
    done
    # 2. Fall back to any installed JVM 17+ (but not 25 which breaks foojay)
    if [[ -z "$jh" ]]; then
      for vm in /Library/Java/JavaVirtualMachines/*/Contents/Home \
                /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
                /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
                /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
                /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home; do
        [[ -x "$vm/bin/java" ]] && jh="$vm" && break
      done
    fi
    [[ -n "$jh" ]] && export JAVA_HOME="$jh" && export PATH="$JAVA_HOME/bin:$PATH"
  fi
}

# ── _install_android_sdk ───────────────────────────────────────────────────────
# Installs Android SDK command-line tools, platform-tools, emulator, a system
# image, and creates a default AVD — fully unattended.  Works on macOS, Linux
# and WSL.  Called by both `run_setup` and the `android` command so the SDK is
# always bootstrapped on demand without requiring a separate `./dev.sh setup`.
_install_android_sdk() {
  # Ensure standard tools (curl, unzip, timeout, etc.) are on PATH
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  local _sdk_dir; _sdk_dir="$(_default_android_sdk)"
  local _cmdline_dir="$_sdk_dir/cmdline-tools/latest"
  local _arch; _arch="$(uname -m)"
  local _sysimg
  if [[ "$_arch" == "arm64" || "$_arch" == "aarch64" ]]; then
    _sysimg="system-images;android-34;google_apis;arm64-v8a"
  else
    _sysimg="system-images;android-34;google_apis;x86_64"
  fi

  # ── 1. Java 21 ──────────────────────────────────────────────────────────────
  if [[ "$OS" == "mac" ]]; then
    if ! brew list --formula openjdk@21 &>/dev/null 2>&1; then
      echo "📦 Installing Java 21 LTS (required for Android SDK tools)..."
      yes | brew install openjdk@21 || true
      eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
    fi
    local _j21="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    [[ -x "$_j21/bin/java" ]] && export JAVA_HOME="$_j21" && export PATH="$_j21/bin:$PATH"
  else
    # Linux / WSL — use apt (Ubuntu/Debian) or available package manager
    if ! command -v java &>/dev/null; then
      echo "📦 Installing Java 21 LTS (required for Android SDK tools)..."
      if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        # Try temurin-21 first (Adoptium), fall back to openjdk-21
        if apt-cache show temurin-21-jdk &>/dev/null 2>&1; then
          sudo apt-get install -y -qq temurin-21-jdk || true
        else
          sudo apt-get install -y -qq openjdk-21-jdk-headless 2>/dev/null \
            || sudo apt-get install -y -qq default-jdk-headless || true
        fi
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y java-21-openjdk-headless || true
      fi
      hash -r 2>/dev/null || true
    fi
    local _java_bin; _java_bin="$(command -v java 2>/dev/null || true)"
    if [[ -n "$_java_bin" ]]; then
      local _jh; _jh="$(dirname "$(dirname "$(readlink -f "$_java_bin")")")"
      export JAVA_HOME="$_jh"
      export PATH="$_jh/bin:$PATH"
      echo "✅ Java: $("$_java_bin" -version 2>&1 | head -1)"
    else
      echo "⚠️  Java not found — Android SDK install may fail. Install manually: sudo apt-get install openjdk-21-jdk-headless"
    fi
  fi

  # ── 2. Android command-line tools ───────────────────────────────────────────
  if [[ ! -x "$_cmdline_dir/bin/sdkmanager" ]]; then
    echo "📦 Installing Android SDK command-line tools..."
    mkdir -p "$_cmdline_dir"
    local _cmdline_url
    if [[ "$OS" == "mac" ]]; then
      _cmdline_url="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
    else
      _cmdline_url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    fi
    local _tmp_zip; _tmp_zip="$(mktemp /tmp/android-cmdline-XXXXXX.zip)"
    local _tmp_dir; _tmp_dir="$(mktemp -d /tmp/android-cmdline-XXXXXX)"
    echo "   Downloading $(basename "$_cmdline_url")..."
    curl -fL --progress-bar "$_cmdline_url" -o "$_tmp_zip"
    if ! command -v unzip &>/dev/null; then
      sudo apt-get install -y -qq unzip 2>/dev/null || true
    fi
    unzip -q "$_tmp_zip" -d "$_tmp_dir"
    if [[ -d "$_tmp_dir/cmdline-tools" ]]; then
      cp -r "$_tmp_dir/cmdline-tools/." "$_cmdline_dir/"
    fi
    rm -rf "$_tmp_zip" "$_tmp_dir"
    echo "✅ Android command-line tools installed"
  else
    echo "✅ Android SDK command-line tools already installed"
  fi

  # ── 3. SDK packages ─────────────────────────────────────────────────────────
  export ANDROID_HOME="$_sdk_dir"
  export PATH="$_cmdline_dir/bin:$_sdk_dir/platform-tools:$_sdk_dir/emulator:$PATH"

  yes | sdkmanager --sdk_root="$_sdk_dir" --licenses >/dev/null 2>&1 || true

  local _need_sdk=false
  [[ ! -x "$_sdk_dir/platform-tools/adb" ]] && _need_sdk=true
  [[ ! -x "$_sdk_dir/emulator/emulator" ]]  && _need_sdk=true
  [[ ! -d "$_sdk_dir/platforms/android-34" ]] && _need_sdk=true
  if $_need_sdk; then
    echo "📦 Installing Android SDK packages (platform-tools, emulator, android-34)..."
    sdkmanager --sdk_root="$_sdk_dir" \
      "platform-tools" \
      "emulator" \
      "platforms;android-34" \
      "build-tools;34.0.0" \
      "$_sysimg" 2>&1 | grep -v "^Info:\|^Done\|^\[=" || true
    echo "✅ Android SDK packages installed"
  else
    echo "✅ Android SDK packages already installed"
    if [[ ! -d "$_sdk_dir/system-images/android-34" ]]; then
      echo "📦 Installing Android system image..."
      sdkmanager --sdk_root="$_sdk_dir" "$_sysimg" 2>&1 | grep -v "^Info:\|^Done\|^\[=" || true
    fi
  fi

  # ── 4. AVD ──────────────────────────────────────────────────────────────────
  # Ensure the current user has KVM access (needed for hardware-accelerated emulation)
  if [[ -e /dev/kvm ]]; then
    chmod 666 /dev/kvm 2>/dev/null || sudo chmod 666 /dev/kvm 2>/dev/null || true
    if ! groups 2>/dev/null | grep -q kvm; then
      sudo usermod -aG kvm "$(whoami)" 2>/dev/null || true
    fi
  fi
  local _avd_list
  _avd_list=$("$_sdk_dir/emulator/emulator" -list-avds 2>/dev/null || true)
  if [[ -z "$_avd_list" ]]; then
    echo "📱 Creating Android Virtual Device (dev_avd)..."
    yes | sdkmanager --sdk_root="$_sdk_dir" --licenses >/dev/null 2>&1 || true
    echo "no" | avdmanager create avd \
      --name "dev_avd" \
      --package "$_sysimg" \
      --device "pixel_6" \
      --force 2>/dev/null \
    || echo "no" | avdmanager create avd \
      --name "dev_avd" \
      --package "$_sysimg" \
      --force
    echo "✅ AVD 'dev_avd' created"
  else
    echo "✅ Android AVD already exists: $(echo "$_avd_list" | head -1)"
  fi
}

# Boot the Android emulator if not already running; returns the device serial
_ensure_emulator() {
  _setup_android_path

  # ── Ensure KVM is available (required for x86_64 emulator) ─────────────────
  if [[ "$OS" == "wsl" ]] || [[ "$OS" == "linux" ]]; then
    if [[ ! -e /dev/kvm ]]; then
      echo "🔧 Loading KVM kernel module..." >&2
      sudo modprobe kvm-intel 2>/dev/null || sudo modprobe kvm 2>/dev/null || true
      sudo chmod 666 /dev/kvm 2>/dev/null || true
    fi
  fi

  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"
  local emu_cmd="${ANDROID_HOME}/emulator/emulator"
  local avdmanager_cmd="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"
  local sdkmanager_cmd="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"

  # Already running? Quick single check — use a subshell with alarm so adb
  # never hangs if the server takes time to start.
  local dev
  dev=$(
    ( "$adb_cmd" devices 2>/dev/null & ADB_PID=$!
      sleep 5 & SLEEP_PID=$!
      wait -n 2>/dev/null || wait $ADB_PID 2>/dev/null
      kill $SLEEP_PID 2>/dev/null; kill $ADB_PID 2>/dev/null
    ) | grep "emulator" | grep "device$" | awk '{print $1}' | head -1 || true
  )
  if [[ -n "$dev" ]]; then
    echo "✅ Emulator already running ($dev)" >&2
    echo "$dev"
    return 0
  fi

  # Find or create AVD
  local avd
  avd=$( "$emu_cmd" -list-avds 2>/dev/null | head -1 || true )
  if [[ -z "$avd" ]]; then
    echo "📱 No AVD found — creating dev_avd..." >&2
    local arch; arch="$(uname -m)"
    local sysimg
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
      sysimg="system-images;android-34;google_apis;arm64-v8a"
    else
      sysimg="system-images;android-34;google_apis;x86_64"
    fi
    yes | "$sdkmanager_cmd" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
    "$sdkmanager_cmd" --sdk_root="$ANDROID_HOME" "platform-tools" "emulator" "platforms;android-34" "$sysimg" "build-tools;34.0.0"
    echo "no" | "$avdmanager_cmd" create avd --name "dev_avd" --package "$sysimg" --device "pixel_6" --force 2>/dev/null || \
    echo "no" | "$avdmanager_cmd" create avd --name "dev_avd" --package "$sysimg" --force
    avd="dev_avd"
    echo "✅ AVD 'dev_avd' created" >&2
  fi

  echo "🚀 Booting AVD: $avd" >&2

  # Install libpulse0 if missing (required by the emulator binary on Linux/WSL)
  if [[ "$OS" != "mac" ]] && ! ldconfig -p 2>/dev/null | grep -q 'libpulse.so.0'; then
    echo "📦 Installing libpulse0 (required by Android emulator)..." >&2
    sudo apt-get install -y -qq libpulse0 2>/dev/null || true
  fi

  local _emu_lib="${ANDROID_HOME}/emulator/lib64"

  echo "✅ Launching emulator in background (logs: /tmp/emulator.log)" >&2

  if [[ "$OS" == "mac" ]]; then
    # macOS: use nohup + disown
    nohup "$emu_cmd" -avd "$avd" -no-snapshot-load -gpu host \
      > /tmp/emulator.log 2>&1 &
    disown $! 2>/dev/null || true
  else
    # Linux/WSL: setsid + redirect stdin to /dev/null so the emulator is fully
    # detached from the terminal. Without closing stdin the process stays attached
    # to the pts and dies when the parent shell exits.
    export LD_LIBRARY_PATH="${_emu_lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    setsid "$emu_cmd" -avd "$avd" \
      -no-window -no-audio -no-boot-anim -no-snapshot-load \
      -gpu swiftshader_indirect -no-metrics \
      < /dev/null > /tmp/emulator.log 2>&1 &
    disown $! 2>/dev/null || true
  fi

  echo "   App install will happen automatically once it's ready." >&2
  # Return immediately
}

# Install + launch one app on the emulator
_install_app_on_emulator() {
  local app_key="$1"   # e.g. "my-app"
  local device="$2"    # e.g. "emulator-5554"
  local app_dir="$MOBILE_DIR"
  local METRO_BASE=8081
  local metro_port=$METRO_BASE

  _setup_android_path
  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"

  # Find the app folder and its metro port index
  discover_apps
  local idx=0
  local found_folder=""
  for folder in "${MOBILE_APPS[@]}"; do
    local k; k=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if [[ "$k" == "$app_key" ]]; then
      found_folder="$folder"
      metro_port=$((METRO_BASE + idx))
      break
    fi
    idx=$((idx + 1))
  done

  [[ -z "$found_folder" ]] && echo "⚠️  App '$app_key' not found, skipping install." && return 0

  local full_app_dir="$MOBILE_DIR/$found_folder"

  # Read slug + bundle_id from app.config.js (regex) or app.json (JSON parse).
  # app.config.js is the source of truth when present — app.json may be absent
  local slug bundle_id
  slug=$(node -e "
const fs=require('fs');
// 1. regex-parse app.config.js
try {
  const src=fs.readFileSync('$full_app_dir/app.config.js','utf8');
  const m=src.match(/slug\s*:\s*['\"]([^'\"]+)['\"]/);
  if(m){console.log(m[1]);process.exit(0);}
} catch(_){}
// 2. app.json
try {
  const d=JSON.parse(fs.readFileSync('$full_app_dir/app.json','utf8'));
  const s=(d.expo||d).slug||'';
  if(s){console.log(s);process.exit(0);}
} catch(_){}
console.log('$app_key');
" 2>/dev/null || echo "$app_key")

  bundle_id=$(node -e "
const fs=require('fs');
// 1. regex-parse app.config.js
try {
  const src=fs.readFileSync('$full_app_dir/app.config.js','utf8');
  const m=src.match(/package\s*:\s*['\"]([^'\"]+)['\"]/);
  if(m){console.log(m[1]);process.exit(0);}
} catch(_){}
// 2. app.json
try {
  const d=JSON.parse(fs.readFileSync('$full_app_dir/app.json','utf8'));
  const p=((d.expo||d).android||{}).package||'';
  if(p){console.log(p);process.exit(0);}
} catch(_){}
console.log('');
" 2>/dev/null || echo "")

  # Check for development APK first (hyphenated), then EAS-style "(development)", then production APK
  local apk_cache="$ROOT_DIR/frontend/mobile/builds/${app_key}-development.apk"
  if [[ ! -f "$apk_cache" ]]; then
    apk_cache="$ROOT_DIR/frontend/mobile/builds/${found_folder} (development).apk"
  fi
  if [[ ! -f "$apk_cache" ]]; then
    apk_cache="$ROOT_DIR/frontend/mobile/builds/${app_key}.apk"
  fi
  if [[ ! -f "$apk_cache" ]]; then
    apk_cache="$ROOT_DIR/frontend/mobile/builds/${found_folder}.apk"
  fi

  if [[ ! -f "$apk_cache" ]]; then
    echo "⚠️  No cached APK for '$app_key' at $apk_cache"
    echo "   Run: ./dev.sh build $app_key android local"
    echo "   Then re-run: ./dev.sh"
    return 0
  fi

  echo "📦 Installing $found_folder on emulator..."
  [[ -n "$bundle_id" ]] && "$adb_cmd" -s "$device" uninstall "$bundle_id" 2>/dev/null || true
  "$adb_cmd" -s "$device" install -r "$apk_cache"
  echo "✅ Installed $found_folder"

  # Launch app
  if [[ -n "$bundle_id" ]]; then
    echo "🎯 Launching $found_folder..."

    # Always setup adb reverse for emulators
    if [[ "$device" == emulator-* ]]; then
      # Emulator - use localhost with adb reverse
      echo "   🔌 Setting up adb reverse for port ${metro_port}..."
      "$adb_cmd" -s "$device" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
      "$adb_cmd" -s "$device" reverse "tcp:8000" "tcp:8000" 2>/dev/null || true
      metro_url_raw="http://10.0.2.2:${metro_port}"
      echo "   ✓ Using 10.0.2.2:${metro_port} (Android emulator host alias)"
    else
      # Physical device - check for tunnel URL
      local metro_tunnel_url
      metro_tunnel_url=$(grep "^METRO_TUNNEL_URL_${metro_port}=" "$ROOT_DIR/.env" 2>/dev/null | cut -d'=' -f2 || echo "")

      if [[ -n "$metro_tunnel_url" ]]; then
        metro_url_raw="$metro_tunnel_url"
        echo "   🌐 Using tunnel URL: $metro_tunnel_url"
      else
        echo "   ⚠️  No tunnel URL found - falling back to localhost"
        "$adb_cmd" -s "$device" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
        "$adb_cmd" -s "$device" reverse "tcp:8000" "tcp:8000" 2>/dev/null || true
        metro_url_raw="http://localhost:${metro_port}"
      fi
    fi

    # URL-encode the Metro URL for the deep link
    local metro_url; metro_url=$(printf '%s' "$metro_url_raw" | sed 's/:/%3A/g; s/\//%2F/g')

    echo "   📱 Connecting to Metro: $metro_url_raw"

    # Use the Expo Dev Client deep link to directly connect to Metro
    # This bypasses auto-discovery and connects immediately
    "$adb_cmd" -s "$device" shell am start \
      -a android.intent.action.VIEW \
      -d "exp+${slug}://expo-development-client/?url=${metro_url}" \
      "$bundle_id" 2>/dev/null || true

    # Small delay to ensure deep link is processed
    sleep 1

    # Now bring the app to foreground
    "$adb_cmd" -s "$device" shell am start -n "${bundle_id}/.MainActivity" 2>/dev/null || true

    echo "   ✅ App launched with automatic Metro connection"
  fi
}

# ── Set up port-forwarding for all connected Android devices/emulators ───────
# Both physical devices and emulators need `adb reverse` so that localhost:<port>
# on the device/emulator tunnels back to the host machine (Metro + backend API).
# Safe to call at any time — no-op if no devices are connected.
_setup_physical_devices() {
  discover_apps
  local METRO_BASE=8081

  # ── Backend proxy on localhost:8000 ──────────────────────────────────────
  # The Android emulator can't bind adb reverse on port 80 (privileged).
  # Instead we run a tiny proxy on Mac localhost:8000 that forwards requests
  # to Traefik (port 80) with the correct Host header for this project.
  # adb reverse tcp:8000 tcp:8000 then maps emulator localhost:8000 → this proxy.
  _start_backend_proxy

  # ── Android: adb reverse ─────────────────────────────────────────────────
  _setup_android_path
  local adb_cmd="${ANDROID_HOME}/platform-tools/adb"
  if [[ -x "$adb_cmd" ]]; then
    local all_devices=()
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local serial; serial=$(echo "$line" | awk '{print $1}')
      local state;  state=$(echo "$line"  | awk '{print $2}')
      [[ "$state" != "device" ]] && continue
      all_devices+=("$serial")
    done < <("$adb_cmd" devices 2>/dev/null | tail -n +2)

    for serial in "${all_devices[@]}"; do
      local idx=0
      for folder in "${MOBILE_APPS[@]}"; do
        local metro_port=$((METRO_BASE + idx))
        "$adb_cmd" -s "$serial" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
        idx=$((idx + 1))
      done
      "$adb_cmd" -s "$serial" reverse "tcp:8000" "tcp:8000" 2>/dev/null || true
      echo "🔌 Android ($serial): adb reverse active for Metro + API"
    done
  fi

  # ── iOS: iproxy USB tunnel ────────────────────────────────────────────────
  _setup_ios_tunnel
}

# ── Backend proxy: localhost:8000 → Traefik → Django ─────────────────────────
# Listens on 127.0.0.1:8000, rewrites Host → PROJECT_HOST.localhost, forwards
# to Traefik on port 80. This lets the Android emulator reach the backend via
# adb reverse tcp:8000 tcp:8000 without needing privileged port 80.
_start_backend_proxy() {
  local proxy_port=8000
  local target_host="${PROJECT_HOST}.localhost"
  local pid_file="/tmp/${PROJECT_NAME}-backend-proxy.pid"
  local proxy_script="/tmp/${PROJECT_NAME}-backend-proxy.py"
  local proxy_log="/tmp/${PROJECT_NAME}-backend-proxy.log"

  # Already running?
  if [[ -f "$pid_file" ]]; then
    local _epid; _epid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
      return 0
    fi
    rm -f "$pid_file"
  fi

  cat > "$proxy_script" << 'BACKEND_PROXY_EOF'
import sys, socket, threading, os, re

proxy_port  = int(sys.argv[1])
target_host = sys.argv[2].encode()
pid_file    = sys.argv[3] if len(sys.argv) > 3 else None
HOST_RE     = re.compile(rb"(?im)^Host:[ \t]*[^\r\n]*\r?\n")

def read_headers(sock):
    buf = b""
    sock.settimeout(30)
    while b"\r\n\r\n" not in buf:
        c = sock.recv(1)
        if not c: break
        buf += c
    return buf

def pipe(src, dst, ev):
    try:
        while not ev.is_set():
            src.settimeout(60)
            d = src.recv(65536)
            if not d: break
            dst.sendall(d)
    except Exception: pass
    finally:
        ev.set()
        try: src.shutdown(socket.SHUT_RD)
        except Exception: pass
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass

def connect_upstream():
    for port in (18080, 80):
        for host in ("127.0.0.1", "::1", "localhost"):
            try:
                return socket.create_connection((host, port), timeout=5)
            except OSError:
                continue
    raise OSError("Cannot connect to Traefik upstream")

def handle(client):
    up = None
    try:
        up = connect_upstream()
        data = read_headers(client)
        if not data: return
        if HOST_RE.search(data):
            data = HOST_RE.sub(b"Host: " + target_host + b"\r\n", data, count=1)
        else:
            i = data.find(b"\r\n")
            if i != -1: data = data[:i+2] + b"Host: " + target_host + b"\r\n" + data[i+2:]
        up.sendall(data)
        ev = threading.Event()
        t1 = threading.Thread(target=pipe, args=(up, client, ev), daemon=True)
        t2 = threading.Thread(target=pipe, args=(client, up, ev), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
    except Exception: pass
    finally:
        for s in (client, up):
            try: s and s.close()
            except Exception: pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: srv.bind(("127.0.0.1", proxy_port))
except OSError: sys.exit(1)
srv.listen(256)
if pid_file:
    with open(pid_file, "w") as f: f.write(str(os.getpid()) + "\n")
while True:
    try:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except Exception: pass
BACKEND_PROXY_EOF

  nohup python3 "$proxy_script" "$proxy_port" "$target_host" "$pid_file" \
    >> "$proxy_log" 2>&1 &
  disown $! 2>/dev/null || true

  # Wait up to 2s for it to bind
  local _w=0
  while [[ $_w -lt 10 ]]; do
    python3 -c "import socket; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',8000)); s.close()" 2>/dev/null && break
    sleep 0.2; _w=$((_w+1))
  done
}

# Tracks iproxy PIDs so we can restart them if the device is reconnected.
_IPROXY_PIDS_FILE="/tmp/${PROJECT_NAME}-iproxy.pids"

_setup_ios_tunnel() {
  # Requires iproxy (part of libimobiledevice). Install: brew install libimobiledevice
  if ! command -v iproxy &>/dev/null; then
    # Silent — don't spam the user if they have no iPhone connected
    return 0
  fi

  # Check if any iOS device is connected via USB
  local ios_devices=()
  if command -v idevice_id &>/dev/null; then
    while IFS= read -r udid; do
      [[ -n "$udid" ]] && ios_devices+=("$udid")
    done < <(idevice_id -l 2>/dev/null)
  fi

  [[ ${#ios_devices[@]} -eq 0 ]] && return 0

  # Kill any stale iproxy processes from a previous run
  if [[ -f "$_IPROXY_PIDS_FILE" ]]; then
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$_IPROXY_PIDS_FILE"
    rm -f "$_IPROXY_PIDS_FILE"
  fi

  discover_apps
  local METRO_BASE=8081
  local ports=()
  local idx=0
  for folder in "${MOBILE_APPS[@]}"; do
    ports+=($((METRO_BASE + idx)))
    idx=$((idx + 1))
  done
  [[ ${#ports[@]} -eq 0 ]] && ports=(8081)
  ports+=(8000)  # backend API

  : > "$_IPROXY_PIDS_FILE"
  for port in "${ports[@]}"; do
    # iproxy LOCAL_PORT DEVICE_PORT — forwards Mac:LOCAL_PORT → iPhone:DEVICE_PORT
    # The app on the iPhone connects to localhost:PORT, iproxy sends it to the
    # Mac's localhost:PORT where Metro/backend is listening.
    iproxy "$port" "$port" >/dev/null 2>&1 &
    echo "$!" >> "$_IPROXY_PIDS_FILE"
  done

  local port_list; port_list=$(printf '%s ' "${ports[@]}")
  echo "🔌 iPhone (${#ios_devices[@]} device): iproxy USB tunnel active for ports ${port_list% }"
  echo "   App connects to localhost on device → tunnels to Mac Metro + API"
}

# ── Auto-restart exited project containers ───────────────────────────────────
# Silently restarts any project containers that are in "exited" state.
# This covers the two most common "services disappeared" scenarios:
#
#   macOS: the Podman machine stopped (system sleep / reboot) and was just
#          restarted by ensure_podman_running.  Every container inside it is now
#          "exited".  `podman start` brings them back without any rebuild.
#
#   Linux: the systemd user slice was torn down when the last terminal closed
#          (before loginctl lingering took effect).  Same fix applies.
#
# Running `./dev.sh` (no args) means "bring everything up", so auto-restarting
# stopped-but-intact containers is the correct behaviour.  If a container can't
# be started (image removed, config changed) it stays "exited" and the normal
# rebuild path recreates it properly.
_auto_restart_exited_containers() {
  local exited
  exited=$(podman ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "status=exited" \
    --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  [[ -z "${exited// /}" ]] && return 0
  echo "🔄 Resuming stopped containers..."
  local _proxy_error=false
  for cname in $exited; do
    local _out
    _out=$(podman start "$cname" 2>&1) || {
      if echo "$_out" | grep -q "proxy already running"; then
        echo "  ⚠️  Stale proxy lock on $cname — will clear after machine restart"
        _proxy_error=true
      fi
    }
  done
  if $_proxy_error; then
    echo "🔄 Clearing stale proxy lock: restarting Podman machine..."
    podman machine stop 2>/dev/null || true
    echo "🚀 Restarting Podman machine..."
    podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
    sleep 3
    _wire_podman_socket
    echo "✅ Podman machine restarted — proxy lock cleared"
    # Retry starting the containers now that the lock is gone
    local still_exited
    still_exited=$(podman ps -a \
      --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
      --filter "status=exited" \
      --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    [[ -n "${still_exited// /}" ]] && podman start $still_exited >/dev/null 2>&1 || true
  fi
  # Brief pause so Podman's state store reflects "running" before we check status
  sleep 2
}

# ── Sync mobile containers to current tunnel URLs ────────────────────────────
# Metro always uses the Mac's LAN IP — stable, zero latency for emulator/simulator.
# No container restarts needed when tunnel URL changes.
_sync_mobile_tunnel_urls() {
  return 0
}

# ── WiFi port forwarding (deprecated) ────────────────────────────────────────
# This function is kept for backward compatibility but is no longer used.
# Mobile apps now use Cloudflare Tunnel or localhost instead.
run_wifi_forward() {
  echo "⚠️  wifi-forward is deprecated. Mobile apps now use Cloudflare Tunnel or localhost."
  return 0
}

# ── mDNS advertising (deprecated) ───────────────────────────────────────────
# This function is kept for backward compatibility but is no longer used.
# Mobile apps now use Cloudflare Tunnel or localhost instead.
run_mdns_advertise() {
  echo "⚠️  mdns-advertise is deprecated. Mobile apps now use Cloudflare Tunnel or localhost."
  return 0
}

# The main smart-launch entry point
smart_launch() {
  # Clear stale rebuild status file from previous runs
  rm -f "/tmp/${PROJECT_NAME}-rebuild-status"

  # Enable systemd lingering FIRST — this is idempotent and ensures containers
  # survive terminal close on Linux/WSL regardless of which path we take below
  # (first run, rebuild, or all-running).  loginctl enable-linger persists across
  # reboots so it only does real work the very first time per user account.
  _ensure_lingering
  _start_healthcheck_runner

  # On macOS: install a launchd agent so the Podman machine persists across
  # terminal sessions and reboots.  Without this the machine stops when the
  # last terminal closes and all containers appear "stopped" on next run.
  _ensure_podman_machine_autostart

  # ensure_podman_running is already called at the top-level entry point before
  # smart_launch is invoked — no need to call it again here.

  # Auto-restart any project containers that are in "exited" or "created" state.
  # "exited" = machine was stopped and restarted (macOS sleep/reboot).
  # "created" = podman-compose 1.5.x bug where up -d creates but doesn't start.
  _auto_restart_exited_containers
  _start_created_containers
  _apply_restart_policy

  discover_apps
  discover_core_svcs   # populates CORE_SVCS from dev.yml

  # After restarting exited containers, sync mobile containers to the current
  # tunnel URLs. Containers that were just podman-start'd have stale env vars
  # from their previous session — force-recreate any whose hostname is wrong.
  _sync_mobile_tunnel_urls

  # Build a label-based container name cache — single podman ps call, robust
  # across all podman-compose versions and separator conventions (- vs _).
  local _cache; _cache=$(_build_cname_cache)

  # Build container name list from CORE_SVCS, resolving names via labels
  local core_containers=()
  local core_services=()
  local _svc _port _cname_override
  while IFS=' ' read -r _svc _port _cname_override; do
    [[ -z "$_svc" ]] && continue
    core_services+=("$_svc")
    if [[ -n "$_cname_override" ]]; then
      core_containers+=("$_cname_override")
    else
      core_containers+=("$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")")
    fi
  done < <(_parse_compose_services)

  # Check individual service status
  local running_services=()
  local broken_services=()
  local missing_services=()
  local mobile_broken=()
  local mobile_missing=()

  # Check core services
  for i in "${!core_containers[@]}"; do
    local svc="${core_services[$i]}"
    local cname="${core_containers[$i]}"
    local status; status=$(_container_status "$cname")
    case "$status" in
      ok)       running_services+=("$svc") ;;
      broken)   broken_services+=("$svc") ;;
      missing)  missing_services+=("$svc") ;;
      starting) running_services+=("$svc") ;; # treat starting as ok
    esac
  done

  # Check mobile services
  for folder in "${MOBILE_APPS[@]}"; do
    local svc; svc=$(folder_to_service "$folder")
    local cname; cname=$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")
    local status; status=$(_container_status "$cname")
    case "$status" in
      ok|starting) ;; # mobile service is fine
      broken)   mobile_broken+=("$svc") ;;
      missing)  mobile_missing+=("$svc") ;;
    esac
  done

  # ── Everything running → check if tunnel URLs changed, then show status ───
  if [[ ${#broken_services[@]} -eq 0 && ${#missing_services[@]} -eq 0 && ${#mobile_broken[@]} -eq 0 && ${#mobile_missing[@]} -eq 0 ]]; then
    echo "✅ All services are running"

    # Start Cloudflare Tunnel if not already running
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _start_healthcheck_runner

    # Sync mobile containers to current tunnel URLs (handles tunnel restarts
    # where the trycloudflare.com hostname changes between sessions).
    _sync_mobile_tunnel_urls

    _open_safari

    echo ""
    # Start live monitor instead of just showing a snapshot
    set +e
    live_monitor
    set -e
    return 0
  fi

  # ── First run: no images built ───────────────────────────────────────────
  # Detect first run by checking if ALL core services are missing (no containers
  # exist at all for this project). This is more reliable than checking for images
  # because partial runs can leave images without running containers.
  local all_core_missing=true
  for cname in "${core_containers[@]}"; do
    if podman inspect "$cname" &>/dev/null 2>&1; then
      all_core_missing=false
      break
    fi
  done

  if [[ "$all_core_missing" == "true" ]]; then
    echo ""
    echo "🏗️  First run detected — building everything..."
    echo ""

    echo "🏗️  Building core images..."
    _build_base_image_if_needed
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" build

    if has_mobile_apps; then
      build_mobile
    fi

    echo ""
    echo "🚀 Starting core services..."
    dc_up_ordered

    if has_mobile_apps; then
      run_mobile
    fi

    # Start Cloudflare Tunnel after services are running
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _start_healthcheck_runner

    echo ""
    echo "✅ Everything is up! Services are running in the background."
    echo ""
    _print_access_urls
    echo ""
    echo "   Run './dev.sh status' to monitor live status."
    echo "   Run './dev.sh logs' to follow logs."
    echo "   Run './dev.sh stop' to stop all services."
    echo "   Run './dev.sh down' to stop and remove everything."
    echo ""
    _open_safari || true
    return 0
  fi

  # ── Selective rebuilding: only fix what's broken ────────────────────────────
  echo ""
  echo "🔍 Analyzing service status..."

  if [[ ${#running_services[@]} -gt 0 ]]; then
    echo "✅ Running services: ${running_services[*]}"
  fi

  local services_to_start=()
  local services_to_rebuild=()

  # Handle missing services (need to start)
  if [[ ${#missing_services[@]} -gt 0 ]]; then
    echo "🚀 Missing services (will start): ${missing_services[*]}"
    services_to_start+=("${missing_services[@]}")
  fi

  # Handle broken services (need to rebuild and restart)
  if [[ ${#broken_services[@]} -gt 0 ]]; then
    echo "🔧 Broken services (will rebuild): ${broken_services[*]}"
    services_to_rebuild+=("${broken_services[@]}")
  fi

  # Handle mobile services
  if [[ ${#mobile_missing[@]} -gt 0 ]]; then
    echo "📱 Missing mobile services: ${mobile_missing[*]}"
  fi

  if [[ ${#mobile_broken[@]} -gt 0 ]]; then
    echo "🔧 Broken mobile services: ${mobile_broken[*]}"
  fi

  echo ""

  # Rebuild broken services first (container exists but is stopped/crashed).
  # Prefer `podman start` — it is synchronous and does not remove/recreate the
  # container, so there is no window where the container appears "missing" to the
  # live status display.  Fall back to `--force-recreate` only when `podman start`
  # fails (e.g. the image was removed or the container config changed).
  for svc in "${services_to_rebuild[@]}"; do
    local cname; cname=$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")
    echo "🔧 Restarting service: $svc"
    if podman start "$cname" >/dev/null 2>&1; then
      echo "  ✅ $svc restarted"
    else
      # Container was removed or can't be started — recreate via podman-compose
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" up -d --no-deps --force-recreate "$svc" \
        >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || true
    fi
  done

  # Start missing services.
  # Use --no-deps so podman-compose doesn't try to re-resolve already-running
  # dependency containers (avoids "not a valid container" errors when deps are
  # running from a previous session).
  if [[ ${#services_to_start[@]} -gt 0 ]]; then
    echo "🚀 Starting missing services: ${services_to_start[*]}"
    dc_up_detached --no-deps "${services_to_start[@]}"
  fi

  # Handle mobile services
  local mobile_services_to_fix=()
  mobile_services_to_fix+=("${mobile_missing[@]}")
  mobile_services_to_fix+=("${mobile_broken[@]}")

  if [[ ${#mobile_services_to_fix[@]} -gt 0 ]]; then
    echo "📱 Fixing mobile services: ${mobile_services_to_fix[*]}"

    # Rebuild + restart only truly broken mobile services (not just missing/stopped)
    for svc in "${mobile_broken[@]}"; do
      echo "🔧 Rebuilding service: $svc"
      local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"

      echo "  🗑️  Stopping and removing container..."
      podman stop "${PROJECT_NAME}-${svc}-1" 2>/dev/null || true
      podman rm "${PROJECT_NAME}-${svc}-1" 2>/dev/null || true

      echo "  📦 Rebuilding mobile service (no cache)..."
      $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" build --no-cache "$svc" 2>/dev/null || true

      echo "  🚀 Starting service..."
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" up -d --force-recreate "$svc" \
        >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true

      echo "  ✅ Service $svc rebuilt"
    done

    # Start missing mobile services — build first since the image may not exist
    for svc in "${mobile_missing[@]}"; do
      echo "🔧 Building and starting missing service: $svc"
      local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"

      echo "  📦 Building mobile service (no cache)..."
      $DC_CMD -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" build --no-cache "$svc" 2>/dev/null || true

      echo "  🚀 Starting service..."
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" up -d "$svc" \
        >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true

      echo "  ✅ Service $svc started"
    done
  fi

  # Wait a moment for services to start
  if [[ ${#services_to_start[@]} -gt 0 || ${#services_to_rebuild[@]} -gt 0 || ${#mobile_services_to_fix[@]} -gt 0 ]]; then
    echo ""
    echo "⏳ Waiting for services to start..."
    sleep 5
  fi

  echo ""
  echo "✅ Service rebuild complete!"
  echo ""

  # Start Cloudflare Tunnel after services are running
  _start_cloudflare_tunnel
  _start_tunnel_watchdog
  _start_healthcheck_runner

  _open_safari || true

  # Drop straight into the live status monitor so you can see services come up
  set +e
  live_monitor
  set -e
}

# ── Ensure android/ directory is fully scaffolded and configured ─────────────
# Idempotent: safe to call even when android/ already exists.
# This function is the single source of truth for android/ setup.
# When you delete frontend/mobile/<AppName>/android, running:
#   ./dev.sh build <app> android local
# will automatically restore everything from:
#   - app.json (expo config)
#   - package.json (dependencies)
#   - frontend/web/public (icons/splash)
#   - .env (project environment values)
#
# Handles:
#   1. npm install (if node_modules missing)
#   2. expo prebuild (if android/ missing) — with .env vars exported
#   3. Inject Google Maps API key into AndroidManifest.xml
#   4. Copy icon + splash assets from frontend/web/public
#   5. Patch foojay-resolver → 1.0.0
#   6. Write local.properties with ANDROID_HOME
#   7. Make gradlew executable
_ensure_android_dir() {
  local build_folder="$1"
  local android_dir="$2"
  local app_dir="$MOBILE_DIR/$build_folder"
  local shared_assets="$ROOT_DIR/frontend/web/public"

  # ── 1. Install node_modules if missing or incomplete ────────────────────
  if [[ ! -d "$app_dir/node_modules" ]] || [[ ! -d "$app_dir/node_modules/expo" ]]; then
    echo "📦 Installing node_modules for '$build_folder'..."
    (cd "$app_dir" && npm install --legacy-peer-deps) || {
      echo "❌ npm install failed for '$build_folder'"
      exit 1
    }
    echo "✅ node_modules installed"
  fi

  # ── 2. Run expo prebuild if android/ is missing ──────────────────────────
  if [[ ! -d "$android_dir" ]]; then
    echo "📦 android/ not found — running expo prebuild for '$build_folder'..."
    if [[ ! -f "$app_dir/package.json" ]]; then
      echo "❌ No package.json found in $app_dir"
      exit 1
    fi
    # Ensure node_modules are fully installed — check for expo binary as a proxy
    if [[ ! -x "$app_dir/node_modules/.bin/expo" ]]; then
      echo "📦 node_modules not fully installed — running npm install for '$build_folder'..."
      (cd "$app_dir" && npm install --legacy-peer-deps) || {
        echo "❌ npm install failed for '$build_folder'."
        exit 1
      }
    fi
    # Load .env so app.config.js can read EXPO_PUBLIC_* vars (including project integrations)
    local _prebuild_env=()
    if [[ -f "$ROOT_DIR/.env" ]]; then
      while IFS= read -r _line; do
        [[ "$_line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        _prebuild_env+=("$_line")
      done < "$ROOT_DIR/.env"
    fi
    (cd "$app_dir" && env "${_prebuild_env[@]}" npx --yes expo prebuild --platform android) || {
      echo "❌ expo prebuild failed for '$build_folder'."
      echo "   Try manually: cd $app_dir && npm install && npx expo prebuild --platform android"
      exit 1
    }
    echo "✅ android/ directory generated by expo prebuild"
  fi

  # Project-native metadata is an optional literal mapping in project.py.
  python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" android-metadata "$android_dir"

  # ── 4. Copy assets from frontend/web/public ──────────────────────────
  # expo prebuild reads icon/splash from app.json paths relative to the app dir.
  # Those paths point to ../shared/assets (i.e. frontend/web/public).
  # If that folder is missing or the images aren't there, prebuild silently
  # skips them.  We copy them explicitly so the android res folder is always
  # populated correctly.
  if [[ -d "$shared_assets" ]]; then
    local slug; slug=$(echo "$build_folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    # Pick the PNG whose filename best matches this app's slug.
    # Multiple apps share the same assets folder, so we must match on slug
    # to avoid copying the wrong app's image.
    local icon_src=""
    icon_src=$(find "$shared_assets" -maxdepth 1 -name "${slug}*.png" | sort | head -1)

    if [[ -z "$icon_src" ]]; then
      echo "⚠️  No PNG matching '${slug}*.png' in frontend/web/public — skipping asset copy"
    else
      # Copy splash screen into every drawable density bucket
      for density in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
        local drawable_dir="$android_dir/app/src/main/res/drawable-${density}"
        if [[ -d "$drawable_dir" ]]; then
          cp -f "$icon_src" "$drawable_dir/splashscreen_logo.png"
        fi
      done

      # Copy adaptive icon foreground into every mipmap density bucket
      for density in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
        local mipmap_dir="$android_dir/app/src/main/res/mipmap-${density}"
        if [[ -d "$mipmap_dir" ]]; then
          # expo prebuild generates webp icons; we only copy if the foreground webp is missing
          if [[ ! -f "$mipmap_dir/ic_launcher_foreground.webp" ]]; then
            cp -f "$icon_src" "$mipmap_dir/ic_launcher_foreground.png" 2>/dev/null || true
          fi
        fi
      done
      echo "✅ Assets synced from frontend/web/public ($(basename "$icon_src"))"
    fi
  else
    echo "⚠️  frontend/web/public not found — skipping asset copy"
  fi

  # ── 5. Patch foojay-resolver → 1.0.0 ────────────────────────────────────
  _patch_android_gradle "$android_dir"

  # ── 6. Write local.properties ────────────────────────────────────────────
  echo "sdk.dir=$ANDROID_HOME" > "$android_dir/local.properties"
  echo "✅ local.properties written (sdk.dir=$ANDROID_HOME)"

  # ── 7. Make gradlew executable ───────────────────────────────────────────
  local gradlew="$android_dir/gradlew"
  [[ -f "$gradlew" ]] && chmod +x "$gradlew"
}

# ── EAS cloud build ──────────────────────────────────────────────────────────
# Usage: _do_eas_build <app> [android|ios|ios-simulator|all] [production]
# Runs `eas build` for the given app in the EAS cloud.
# Creates/re-links the EAS project if needed; signing setup can prompt on a terminal.
# Defaults: platform=all, profile=development (real device)
# Platforms:
#   - ios              → Real iOS device build (default for ios)
#   - ios-simulator    → iOS simulator build
#   - android          → Android APK (works on both emulator and device)
# Profiles:
#   - development          → Real device build with Metro hot reload (default)
#   - development-simulator → iOS simulator build with Metro hot reload
#   - production           → Production build for real devices
# Use 'production' flag for production builds
_do_eas_build() {
  local build_app="$1"
  local build_platform="${2:-all}"
  local eas_profile="development"
  local is_simulator=false

  # Strip optional "project/" prefix from app name (e.g. "myproject/myapp" → "myapp")
  if [[ "$build_app" == */* ]]; then
    build_app="${build_app##*/}"
  fi

  # ── Load .env file to get EXPO_TOKEN and other environment variables ─────
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a  # automatically export all variables
    source "$ROOT_DIR/.env"
    set +a
  fi

  # Check for 'ios-simulator' in platform argument first
  if [[ "$build_platform" == "ios-simulator" ]]; then
    is_simulator=true
    build_platform="ios"
  fi

  # Check for profile flags anywhere in the arguments
  shift 2 2>/dev/null || shift 1 2>/dev/null || true
  for _arg in "$@"; do
    if [[ "$_arg" == "production" ]]; then
      eas_profile="production"
      is_simulator=false  # production is always for real devices
      break
    elif [[ "$_arg" == "simulator" ]]; then
      # This comes from _do_build when it detects ios-simulator
      is_simulator=true
      break
    fi
  done

  # Apply simulator profile if needed
  if [[ "$is_simulator" == true ]]; then
    eas_profile="development-simulator"
  fi

  # ── Resolve app folder ───────────────────────────────────────────────────
  discover_apps
  local build_folder=""
  for folder in "${MOBILE_APPS[@]}"; do
    local k; k=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if [[ "$k" == "$build_app" ]] || echo "$folder" | grep -qi "$build_app"; then
      build_folder="$folder"
      break
    fi
  done

  if [[ -z "$build_folder" ]]; then
    echo "❌ No app matching '$build_app' found."
    echo "   Available apps:"
    for f in "${MOBILE_APPS[@]}"; do
      echo "   - $(echo "$f" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    done
    exit 1
  fi

  local app_dir="$MOBILE_DIR/$build_folder"
  local app_json="$app_dir/app.json"

  # ── Ensure eas-cli is installed ──────────────────────────────────────────
  if ! command -v eas &>/dev/null; then
    echo "📦 Installing eas-cli globally..."
    npm install -g eas-cli || {
      echo "❌ Failed to install eas-cli. Try: npm install -g eas-cli"
      exit 1
    }
    echo "✅ eas-cli installed"
  fi

  # ── Check EAS login ──────────────────────────────────────────────────────
  # Check for EXPO_TOKEN first (CI/programmatic access), then fall back to state.json
  local eas_user
  if [[ -n "${EXPO_TOKEN:-}" ]]; then
    # EXPO_TOKEN is set — verify it works and get the username
    eas_user=$(eas whoami 2>/dev/null | head -1 | awk '{print $1}' || true)
    if [[ -z "$eas_user" ]]; then
      echo ""
      echo "❌ EXPO_TOKEN is set but invalid."
      echo "   Get a new token from: https://expo.dev/accounts/[account]/settings/access-tokens"
      echo "   Then update EXPO_TOKEN in .env"
      exit 1
    fi
  else
    # No EXPO_TOKEN — check state.json for interactive login
    eas_user=$(node -e "
try {
  const os=require('os'),path=require('path'),fs=require('fs');
  const s=JSON.parse(fs.readFileSync(path.join(os.homedir(),'.expo','state.json'),'utf8'));
  console.log(s.auth?.username||'');
} catch(e){console.log('');}
" 2>/dev/null || true)
    if [[ -z "$eas_user" ]]; then
      echo ""
      echo "🔐 You need to log in to EAS first."
      echo "   Option 1: Run: eas login"
      echo "   Option 2: Set EXPO_TOKEN in .env (for CI/programmatic access)"
      echo "   Then re-run: ./dev.sh build $build_app $build_platform"
      exit 1
    fi
  fi
  echo "✅ EAS logged in as: $eas_user"

  # ── Ensure app.json has a valid projectId for this account ───────────────
  # Always verify the projectId belongs to the current account before building.
  # If it's missing, stale, or from a different account — create/link the project
  # automatically via `eas init --non-interactive`, then patch the config file.
  _eas_ensure_project_linked() {
    local app_config_js="$app_dir/app.config.js"

    # ── Read current projectId from app.config.js or app.json ────────────
    local current_id
    current_id=$(node -e "
const fs = require('fs');
// 1. Regex-parse app.config.js (safe — no require/eval)
try {
  const src = fs.readFileSync('$app_config_js', 'utf8');
  const m = src.match(/projectId\s*:\s*['\"]([0-9a-f-]{36})['\"]/) ;
  if (m) { console.log(m[1]); process.exit(0); }
} catch(_) {}
// 2. Try app.json (plain JSON)
try {
  const d = JSON.parse(fs.readFileSync('$app_dir/app.json', 'utf8'));
  const id = ((d.expo || d).extra || {}).eas?.projectId || '';
  if (id) { console.log(id); process.exit(0); }
} catch(_) {}
console.log('');
" 2>/dev/null || true)

    # If we have a projectId, verify it belongs to the current account
    if [[ "$current_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      # Try to query the project to see if it exists for this account
      local project_check
      project_check=$(cd "$app_dir" && eas project:info 2>&1 || true)

      if echo "$project_check" | grep -q "does not exist\|not found\|GraphQL request failed"; then
        echo "⚠️  Project ID $current_id doesn't belong to current account — will create new project"
        current_id=""
      else
        echo "✅ EAS project ID found: $current_id"
        return 0
      fi
    fi

    # ── Read slug ─────────────────────────────────────────────────────────
    local slug
    slug=$(node -e "
const fs = require('fs');
try {
  const src = fs.readFileSync('$app_config_js', 'utf8');
  const m = src.match(/slug\s*:\s*['\"]([^'\"]+)['\"]/);
  if (m) { console.log(m[1]); process.exit(0); }
} catch(_) {}
try {
  const d = JSON.parse(fs.readFileSync('$app_dir/app.json', 'utf8'));
  const s = (d.expo || d).slug || '';
  if (s) { console.log(s); process.exit(0); }
} catch(_) {}
console.log('');
" 2>/dev/null || true)

    echo "🔧 No EAS project ID found for '$build_folder' — linking project (slug: ${slug:-$build_app})..."

    # ── Use `eas init` to create/link the project non-interactively ───────
    # Slug comes from app.config.js / app.json. Output may include a new ID or
    # "Existing project found … (ID: …)" when the Expo account already has one.
    local init_out
    # Slug is read from app.config.js / app.json — eas init has no --slug flag.
    # --force flag creates the project if it doesn't exist on the Expo account.
    init_out=$(cd "$app_dir" && eas init \
      --non-interactive \
      --force \
      2>&1) || true

    echo "$init_out"

    # Extract the projectId from the init output (EAS prints it as a UUID)
    local new_id
    new_id=$(echo "$init_out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)

    # If eas init didn't print a UUID, try reading it from the config file
    # that eas init may have written (it updates app.json automatically)
    if [[ -z "$new_id" ]]; then
      new_id=$(node -e "
const fs = require('fs');
try {
  const src = fs.readFileSync('$app_config_js', 'utf8');
  const m = src.match(/projectId\s*:\s*['\"]([0-9a-f-]{36})['\"]/) ;
  if (m) { console.log(m[1]); process.exit(0); }
} catch(_) {}
try {
  const d = JSON.parse(fs.readFileSync('$app_dir/app.json', 'utf8'));
  const id = ((d.expo || d).extra || {}).eas?.projectId || '';
  if (id) { console.log(id); process.exit(0); }
} catch(_) {}
console.log('');
" 2>/dev/null || true)
    fi

    if [[ -z "$new_id" ]]; then
      echo "⚠️  Could not determine EAS project ID after init — build may prompt interactively."
      return 0
    fi

    echo "✅ EAS project ready (ID: $new_id)"

    # ── Get account name for the owner field ──────────────────────────────
    local account_name
    if [[ -n "${EXPO_TOKEN:-}" ]]; then
      # When using EXPO_TOKEN, get account from eas whoami
      account_name=$(eas whoami 2>/dev/null | grep -E "^•" | awk '{print $2}' | tr -d '()' | head -1 || echo "")
      [[ -z "$account_name" ]] && account_name="$eas_user"
    else
      # When using interactive login, read from state.json
      account_name=$(node -e "
try {
  const os=require('os'),path=require('path'),fs=require('fs');
  const s=JSON.parse(fs.readFileSync(path.join(os.homedir(),'.expo','state.json'),'utf8'));
  // accounts array or username fallback
  const accs = s.auth?.accounts || s.accounts || [];
  if (accs.length) { console.log(accs[0].name || accs[0].username || ''); process.exit(0); }
  console.log(s.auth?.username || s.username || '');
} catch(e){console.log('');}
" 2>/dev/null || echo "$eas_user")
      [[ -z "$account_name" ]] && account_name="$eas_user"
    fi

    # ── Patch app.config.js with projectId + owner ────────────────────────
    # Uses Node so we handle all inline/multiline eas:{} variants correctly.
    if [[ -f "$app_config_js" ]]; then
      node -e "
const fs = require('fs');
const filePath = '$app_config_js';
let src = fs.readFileSync(filePath, 'utf8');
const newId = '$new_id';
const owner  = '$account_name';

// ── projectId ──────────────────────────────────────────────────────────
if (/projectId\s*:/.test(src)) {
  // Replace existing value
  src = src.replace(/projectId\s*:\s*['\"].*?['\"]/, 'projectId: \"' + newId + '\"');
} else if (/eas\s*:\s*\{/.test(src)) {
  // eas: {} exists — insert projectId into it
  // Replace 'eas: {}' inline first
  src = src.replace(/eas\s*:\s*\{\s*\}/, 'eas: { projectId: \"' + newId + '\" }');
  // Then handle multiline 'eas: {' (only if the inline replace didn't match)
  if (!src.includes(newId)) {
    src = src.replace(/(eas\s*:\s*\{)/, '\$1\n        projectId: \"' + newId + '\",');
  }
} else {
  // No eas: {} section — create it inside extra: {}
  if (/extra\s*:\s*\{/.test(src)) {
    src = src.replace(/(extra\s*:\s*\{)/, '\$1\n      eas: { projectId: \"' + newId + '\" },');
  } else {
    console.error('⚠️  Could not find extra: {} section to add projectId');
  }
}

// ── owner ──────────────────────────────────────────────────────────────
if (/\bowner\s*:/.test(src)) {
  src = src.replace(/owner\s*:\s*['\"].*?['\"]/, 'owner: \"' + owner + '\"');
} else {
  // Insert owner right after 'expo: {'
  src = src.replace(/(expo\s*:\s*\{)/, '\$1\n    owner: \"' + owner + '\",');
}

fs.writeFileSync(filePath, src);
console.log('✅ app.config.js updated — owner: ' + owner + ', projectId: ' + newId);
" 2>/dev/null || echo "⚠️  Could not patch app.config.js — projectId: $new_id (add manually)"
    else
      # Fall back to patching app.json
      local _patch_s; _patch_s=$(mktemp /tmp/_patch_appjson_XXXXXX.py)
      printf '%s\n' \
        'import json, sys' \
        'path, new_id, account = sys.argv[1], sys.argv[2], sys.argv[3]' \
        'with open(path) as f:' \
        '    data = json.load(f)' \
        'expo = data.setdefault("expo", {})' \
        'expo["owner"] = account' \
        'expo.setdefault("extra", {}).setdefault("eas", {})["projectId"] = new_id' \
        'with open(path, "w") as f:' \
        '    json.dump(data, f, indent=2)' \
        '    f.write("\n")' \
        'print(f"✅ app.json updated — owner: {account}, projectId: {new_id}")' \
        > "$_patch_s"
      python3 "$_patch_s" "$app_dir/app.json" "$new_id" "$account_name"
      rm -f "$_patch_s"
    fi
  }

  _eas_ensure_project_linked

  # ── Resolve platform flag ────────────────────────────────────────────────
  local eas_platform_flag
  case "$build_platform" in
    android) eas_platform_flag="--platform android" ;;
    ios)     eas_platform_flag="--platform ios" ;;
    all|"")  eas_platform_flag="--platform all" ;;
    *)       eas_platform_flag="--platform all" ;;
  esac

  echo ""
  echo "========================================="
  echo "☁️  EAS Cloud Build: $build_folder"
  echo "   Profile:  $eas_profile"
  echo "   Platform: $build_platform"
  echo "========================================="
  echo ""

  # Run the build with --no-wait to return immediately after submission
  echo "🚀 Submitting build to EAS..."
  local _eas_output
  local _eas_exit
  local _eas_log

  # Change to app directory and run eas build
  cd "$app_dir"

  # `eas credentials` is an interactive manager, not a credential probe.
  # Let the build itself resolve signing, keeping stdin attached for prompts.
  local _eas_mode_args=(--non-interactive)
  if [[ -t 0 && ( "$build_platform" == "ios" || "$build_platform" == "all" ) && "$is_simulator" != true ]]; then
    _eas_mode_args=()
    echo "   Apple signing prompts will appear here if setup is needed."
  fi

  # Stream progress immediately, while retaining build URLs for downloads.
  # Save EAS's status inside each branch before PIPESTATUS is overwritten.
  _eas_log=$(mktemp "${TMPDIR:-/tmp}/eas-build.XXXXXX")
  if eas build \
    --profile "$eas_profile" \
    $eas_platform_flag \
    --no-wait \
    "${_eas_mode_args[@]}" \
    2>&1 | tee "$_eas_log"; then
    _eas_exit=${PIPESTATUS[0]}
  else
    _eas_exit=${PIPESTATUS[0]}
  fi
  _eas_output=$(cat "$_eas_log")
  rm -f "$_eas_log"

  # Go back to root
  cd "$ROOT_DIR"

  if [[ $_eas_exit -ne 0 ]]; then
    echo ""
    echo "❌ EAS build failed."
    echo "   Check the output above for details."
    echo "   Common fixes:"
    echo "     • Not logged in:   eas login"
    echo "     • iOS signing:    rerun this build in an interactive terminal to configure Apple credentials"
    echo "     • Wrong profile:   ./dev.sh build $build_app $build_platform production"
    echo "     • Build locally:   ./dev.sh build $build_app $build_platform local"
    exit 1
  fi

  echo ""
  echo "✅ EAS build submitted for '$build_folder'."

  # ── Auto-download APK and install on emulator ────────────────────────────
  # Only for android + development/device profiles (which produce APKs, not AABs)
  if [[ "$build_platform" == "android" || "$build_platform" == "all" ]]; then
    if [[ "$eas_profile" == "development" || "$eas_profile" == "development-simulator" || "$eas_profile" == "production" ]]; then
      echo ""
      echo "📥 Downloading APK from EAS..."

      # Extract build ID from the "See logs:" line in EAS output
      local build_id
      build_id=$(echo "$_eas_output" | grep -oE 'builds/[0-9a-f-]{36}' | head -1 | sed 's|builds/||' || true)

      # Extract direct APK URL if present in output
      local artifact_url
      artifact_url=$(echo "$_eas_output" | grep -oE 'https://[^ ]+\.apk' | head -1 || true)

      # If no direct URL, fetch from EAS CLI using the build ID
      if [[ -z "$artifact_url" && -n "$build_id" ]]; then
        echo "   Fetching download URL for build $build_id..."

        # Poll until artifact URL is available (build may still be finalizing)
        local waited=0
        while [[ $waited -lt 900 ]]; do
          local _eas_view_json
          _eas_view_json=$(cd "$MOBILE_DIR/$build_folder" && eas build:view "$build_id" --json 2>/dev/null || true)
          local _status
          _status=$(echo "$_eas_view_json" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).status||'')}catch(e){console.log('')}})" 2>/dev/null || true)
          if [[ "$_status" == "ERRORED" || "$_status" == "CANCELED" ]]; then
            echo "❌ Build $build_id ended with status: $_status"
            exit 1
          fi
          artifact_url=$(echo "$_eas_view_json" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const b=JSON.parse(d);console.log(b.artifacts?.applicationArchiveUrl||b.artifacts?.buildUrl||'')}catch(e){console.log('')}})" 2>/dev/null || true)
          [[ -n "$artifact_url" ]] && break
          echo "   ⏳ Waiting for artifact... (${waited}s / 900s max)"
          sleep 10; waited=$((waited + 10))
        done
      fi

      if [[ -z "$artifact_url" ]]; then
        echo "⚠️  Could not get APK download URL."
        echo "   Download manually from: https://expo.dev/accounts/$eas_user/projects"
      else
        local output_dir="$ROOT_DIR/frontend/mobile/builds"
        local apk_filename="${build_folder}.apk"
        if [[ "$eas_profile" != "production" ]]; then
          apk_filename="${build_folder} (${eas_profile}).apk"
        fi
        local apk_out="$output_dir/${apk_filename}"
        mkdir -p "$output_dir"

        echo "   Downloading → $apk_out"
        curl -L --progress-bar "$artifact_url" -o "$apk_out" && echo "✅ APK saved to frontend/mobile/builds/${apk_filename}"

        echo ""
        echo "   To install, run: ./dev.sh android"
      fi
    fi
  fi

  # ── Auto-download IPA for iOS ────────────────────────────────────────────
  # Download IPA for all iOS builds (both simulator and device)
  if [[ "$build_platform" == "ios" || "$build_platform" == "all" ]]; then
    if [[ "$eas_profile" == "development" || "$eas_profile" == "development-simulator" || "$eas_profile" == "production" ]]; then
      echo ""
      echo "📥 Downloading IPA from EAS..."

      # Extract build ID from the "See logs:" line in EAS output
      local build_id_ios
      build_id_ios=$(echo "$_eas_output" | grep -oE 'builds/[0-9a-f-]{36}' | tail -1 | sed 's|builds/||' || true)

      # Extract direct IPA URL if present in output
      local artifact_url_ios
      artifact_url_ios=$(echo "$_eas_output" | grep -oE 'https://[^ ]+\.ipa' | head -1 || true)

      # If no direct URL, fetch from EAS CLI using the build ID
      if [[ -z "$artifact_url_ios" && -n "$build_id_ios" ]]; then
        echo "   Fetching download URL for build $build_id_ios..."

        # Poll until artifact URL is available (build may still be finalizing)
        local waited=0
        while [[ $waited -lt 900 ]]; do
          local _eas_view_json_ios
          _eas_view_json_ios=$(cd "$MOBILE_DIR/$build_folder" && eas build:view "$build_id_ios" --json 2>/dev/null || true)
          local _status_ios
          _status_ios=$(echo "$_eas_view_json_ios" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).status||'')}catch(e){console.log('')}})" 2>/dev/null || true)
          if [[ "$_status_ios" == "ERRORED" || "$_status_ios" == "CANCELED" ]]; then
            echo "❌ Build $build_id_ios ended with status: $_status_ios"
            exit 1
          fi
          artifact_url_ios=$(echo "$_eas_view_json_ios" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const b=JSON.parse(d);console.log(b.artifacts?.applicationArchiveUrl||b.artifacts?.buildUrl||'')}catch(e){console.log('')}})" 2>/dev/null || true)
          [[ -n "$artifact_url_ios" ]] && break
          echo "   ⏳ Waiting for artifact... (${waited}s / 900s max)"
          sleep 10; waited=$((waited + 10))
        done
      fi

      if [[ -z "$artifact_url_ios" ]]; then
        echo "⚠️  Could not get IPA download URL."
        echo "   Download manually from: https://expo.dev/accounts/$eas_user/projects"
      else
        local output_dir="$ROOT_DIR/frontend/mobile/builds"
        local ipa_filename="${build_folder}.ipa"
        if [[ "$eas_profile" != "production" ]]; then
          ipa_filename="${build_folder} (${eas_profile}).ipa"
        fi
        local ipa_out="$output_dir/${ipa_filename}"
        mkdir -p "$output_dir"

        echo "   Downloading → $ipa_out"
        curl -L --progress-bar "$artifact_url_ios" -o "$ipa_out" && echo "✅ IPA saved to frontend/mobile/builds/${ipa_filename}"

        echo ""
        echo "   To install on simulator, run: ./dev.sh ios"
      fi
    fi
  fi

  echo ""
  echo "   Monitor at: https://expo.dev/accounts/$eas_user/projects"
}

# ── Build command: Podman images or native APK/IPA ───────────────────────────
# Usage: _do_build [<app> [android|ios|ios-simulator] [local] [production]]
#
# Without app name: builds core Podman images
# With app name + platform:
#   - ios          → EAS cloud build for real iOS device (default)
#   - ios-simulator → EAS cloud build for iOS simulator
#   - android      → EAS cloud build for Android (works on emulator and device)
#   - local        → Native local build (requires Xcode/Android Studio)
#   - production   → Production build (real devices only)
_do_build() {
  local build_app="${1:-}"
  local build_platform="android"
  local build_local=false
  local build_production=false
  local _extra_args=()

  # Strip optional "project/" prefix from app name (e.g. "myproject/myapp" → "myapp")
  if [[ "$build_app" == */* ]]; then
    build_app="${build_app##*/}"
  fi

  # Parse all arguments for flags
  for _arg in "$@"; do
    case "$_arg" in
      local)
        build_local=true
        ;;
      production)
        build_production=true
        _extra_args+=("production")
        ;;
      android)
        build_platform="android"
        ;;
      ios)
        build_platform="ios"
        ;;
      ios-simulator)
        build_platform="ios-simulator"
        _extra_args+=("simulator")
        ;;
    esac
  done

  if [[ -n "$build_app" && "$build_local" == true ]]; then
    # ── Native local build ────────────────────────────────────────────────
    _setup_android_path
    discover_apps

    local build_folder=""
    for folder in "${MOBILE_APPS[@]}"; do
      local k; k=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      if [[ "$k" == "$build_app" ]] || echo "$folder" | grep -qi "$build_app"; then
        build_folder="$folder"
        break
      fi
    done

    if [[ -z "$build_folder" ]]; then
      echo "❌ No app matching '$build_app' found."
      echo "   Available apps:"
      for f in "${MOBILE_APPS[@]}"; do
        echo "   - $(echo "$f" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
      done
      exit 1
    fi

    local slug; slug=$(echo "$build_folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local output_dir="$ROOT_DIR/frontend/mobile/builds"
    mkdir -p "$output_dir"

    if [[ "$build_platform" == "android" ]]; then
      local android_dir="$MOBILE_DIR/$build_folder/android"
      local gradlew="$android_dir/gradlew"

      # Ensure android/ exists and is fully configured (idempotent)
      _ensure_android_dir "$build_folder" "$android_dir"

      if [[ ! -f "$gradlew" ]]; then
        echo "❌ No android/gradlew found for '$build_folder'."
        echo "   The android/ directory may not have been generated correctly."
        echo "   Try running: cd $MOBILE_DIR/$build_folder && npx expo prebuild --platform android"
        exit 1
      fi

      if ! command -v java &>/dev/null; then
        echo "❌ Java not found. Install Java 21 and re-run."
        echo "   macOS: brew install openjdk@21"
        exit 1
      fi

      # Determine build type and environment based on production flag
      local build_type="Debug"
      local gradle_task="assembleDebug"
      local build_env="development"
      local api_url

      if [[ "$build_production" == true ]]; then
        build_type="Release"
        gradle_task="assembleRelease"
        build_env="production"
      fi

      api_url=$(python3 "$ROOT_DIR/backend/config/project_config.py" "$ROOT_DIR" \
        mobile-api-url "$build_env" "http://$(_get_lan_ip):8000") || return 1

      echo ""
      echo "========================================="
      echo "🔨 Building native APK: $build_folder"
      echo "   Platform: android  |  Mode: $build_type"
      echo "   Environment: $build_env"
      echo "   API URL: $api_url"
      echo "========================================="
      echo ""

      "$gradlew" -p "$android_dir" clean 2>&1 || true

      if EXPO_PUBLIC_API_URL="$api_url" python3 "$ROOT_DIR/backend/config/project_config.py" \
         "$ROOT_DIR" run-build "$build_env" "$gradlew" -p "$android_dir" "$gradle_task" 2>&1; then
        local built_apk
        if [[ "$build_production" == true ]]; then
          built_apk=$(find "$android_dir/app/build/outputs/apk/release" -name "*.apk" 2>/dev/null | head -1)
        else
          built_apk=$(find "$android_dir/app/build/outputs/apk/debug" -name "*.apk" 2>/dev/null | head -1)
        fi
        if [[ -n "$built_apk" ]]; then
          # Conditionally include profile in filename
          local apk_filename
          if [[ "$build_env" == "production" ]]; then
            apk_filename="${slug}.apk"
          else
            apk_filename="${slug}-${build_env}.apk"
          fi

          cp "$built_apk" "$output_dir/$apk_filename"
          echo ""
          echo "✅ APK built → frontend/mobile/builds/$apk_filename"
        else
          echo "❌ APK not found after build."
          exit 1
        fi
      else
        echo "❌ Gradle build failed."
        exit 1
      fi

    elif [[ "$build_platform" == "ios" ]]; then
      if [[ "$OS" != "mac" ]]; then
        echo "❌ iOS builds require macOS."
        exit 1
      fi
      if ! command -v xcodebuild &>/dev/null; then
        echo "❌ xcodebuild not found. Install Xcode from the App Store."
        echo "   Then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
      fi

      local ios_dir="$MOBILE_DIR/$build_folder/ios"
      if [[ ! -d "$ios_dir" ]]; then
        echo "⚙️  No ios/ directory found for '$build_folder'. Running expo prebuild..."
        if ! command -v npx &>/dev/null; then
          echo "❌ npx not found. Install Node.js first."
          exit 1
        fi
        # Install node_modules first if expo binary is missing — same logic as android path
        if [[ ! -x "$MOBILE_DIR/$build_folder/node_modules/.bin/expo" ]]; then
          echo "📦 node_modules not fully installed — running npm install for '$build_folder'..."
          (cd "$MOBILE_DIR/$build_folder" && npm install --legacy-peer-deps) || {
            echo "❌ npm install failed for '$build_folder'."
            exit 1
          }
          echo "✅ node_modules installed."
        fi
        (cd "$MOBILE_DIR/$build_folder" && npx --yes expo prebuild --platform ios --no-install) || {
          echo "❌ expo prebuild failed."
          exit 1
        }
        echo "✅ ios/ directory generated."
      fi

      # ── Patch React Native pod scripts for paths with spaces ─────────────
      # URI::File.build in rndependencies.rb / rncore.rb raises "bad component"
      # when the project path contains spaces. Replace with a manually encoded
      # file:// URI. This patch is idempotent — safe to apply on every run.
      local _rn_scripts="$MOBILE_DIR/$build_folder/node_modules/react-native/scripts/cocoapods"
      for _rb_file in "$_rn_scripts/rndependencies.rb" "$_rn_scripts/rncore.rb"; do
        if [[ -f "$_rb_file" ]] && grep -q 'URI::File.build' "$_rb_file"; then
          _sed_inplace \
            's|return {:http => URI::File.build(path: destinationDebug).to_s }|encoded_path = destinationDebug.gsub('"'"' '"'"', '"'"'%20'"'"'); return {:http => "file://#{encoded_path}" }|g' \
            "$_rb_file"
          echo "   🔧 Patched $(basename "$_rb_file") for space-in-path compatibility."
        fi
      done

      # Auto-install CocoaPods if missing
      # ── Install CocoaPods if missing ─────────────────────────────────────
      if ! command -v pod &>/dev/null; then
        echo "📦 CocoaPods not found. Installing via Homebrew..."
        if command -v brew &>/dev/null; then
          yes | brew install cocoapods || {
            echo "❌ Failed to install CocoaPods via Homebrew. Try: sudo gem install cocoapods"
            exit 1
          }
          eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
            || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
        else
          sudo gem install cocoapods || {
            echo "❌ Failed to install CocoaPods."
            exit 1
          }
        fi
        echo "✅ CocoaPods installed."
      fi

      # ── Patch hermes-utils.rb to survive DNS/network failures ────────────
      # Ruby's backtick curl and Net::HTTP both hang/crash when network checks
      # for Hermes tarballs time out (e.g. central.sonatype.com DNS failure or
      # Ruby 4.x curl backtick hang). We patch hermes_artifact_exists to use
      # a short curl timeout, and nightly_artifact_exists to rescue exceptions.
      local _hermes_utils="$MOBILE_DIR/$build_folder/node_modules/react-native/sdks/hermes-engine/hermes-utils.rb"
      if [[ -f "$_hermes_utils" ]] && ! grep -q 'HERMES_UTILS_NETWORK_PATCH' "$_hermes_utils" 2>/dev/null; then
        echo "🔧 Patching hermes-utils.rb for network resilience..."
        # Add --max-time 10 to curl so it doesn't hang indefinitely
        _sed_inplace \
          's|curl -o /dev/null --silent -Iw|curl --max-time 10 -o /dev/null --silent -Iw|g' \
          "$_hermes_utils"
        # Wrap the Net::HTTP nightly check in a rescue so a DNS failure returns ""
        _sed_inplace \
          's|def nightly_artifact_exists(version)|def nightly_artifact_exists(version) # HERMES_UTILS_NETWORK_PATCH|g' \
          "$_hermes_utils"
        python3 - "$_hermes_utils" << 'PATCH_HERMES_EOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
# Wrap the body of nightly_tarball_url in a begin/rescue so DNS errors return ""
old = r'(def nightly_tarball_url\(version\)\n)'
new = r'\1  begin\n'
src = re.sub(old, new, src)
# Find the end of nightly_tarball_url (the closing "end" before next def/end of file)
# Add rescue wrapper before the final "end" of the function
src = src.replace(
    '  return final_url\n  else\n    return ""\n  end\nend\n\ndef resolve_url_redirects',
    '  return final_url\n  else\n    return ""\n  end\n  rescue => _e\n    return ""\n  end\nend\n\ndef resolve_url_redirects'
)
open(path, 'w').write(src)
print("   ✅ hermes-utils.rb patched")
PATCH_HERMES_EOF
      fi

      # ── Ensure Podfile has deployment target fix for Xcode 26+ ────────────
      # Xcode 26 beta requires iOS ≥ 15.0. Some pods ship with 12.x minimums.
      # Inject the fix into the post_install hook if not already present.
      local _podfile="$ios_dir/Podfile"
      if [[ -f "$_podfile" ]] && ! grep -q "IPHONEOS_DEPLOYMENT_TARGET.*15.0" "$_podfile" 2>/dev/null; then
        echo "🔧 Patching Podfile: bumping pod deployment targets to iOS 15.0..."
        _sed_inplace '/react_native_post_install(/,/^  end$/{
/^  end$/{
i\
    installer.pods_project.targets.each do |t|\
      t.build_configurations.each do |c|\
        dv = c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"]\
        c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0" if dv && dv.to_f < 15.0\
      end\
    end
}
}' "$_podfile" 2>/dev/null || true
        # If sed didn't insert (complex heredoc), do it with Python as fallback
        if ! grep -q "IPHONEOS_DEPLOYMENT_TARGET.*15.0" "$_podfile" 2>/dev/null; then
          python3 - "$_podfile" << 'PATCH_PODFILE_EOF'
import sys, re
path = sys.argv[1]
src = open(path).read()
fix = """
    # Fix: bump pod deployment targets to iOS 15.0 for Xcode 26+ compatibility
    installer.pods_project.targets.each do |t|
      t.build_configurations.each do |c|
        dv = c.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
        c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' if dv && dv.to_f < 15.0
      end
    end"""
# Insert before the last 'end' inside post_install
src = re.sub(
    r'(  post_install do \|installer\|.*?)(  end\nend)',
    lambda m: m.group(1) + fix + '\n  end\nend',
    src, flags=re.DOTALL
)
open(path, 'w').write(src)
print("   ✅ Podfile patched")
PATCH_PODFILE_EOF
        fi
        # Re-run pod install so the new hook takes effect
        echo "📦 Re-running pod install to apply deployment target fix..."
        (cd "$ios_dir" && pod install 2>&1 | tail -5) || true
      fi

      # ── Run pod install if needed ─────────────────────────────────────────
      # Check Podfile.lock (not just Pods/) — Pods/ can exist partially after a
      # failed install. Podfile.lock is only written on full success.
      if [[ ! -f "$ios_dir/Podfile.lock" ]]; then
        echo "📦 Installing CocoaPods dependencies..."
        if ! (cd "$ios_dir" && pod install 2>&1); then
          echo "⚠️  pod install failed on first attempt, retrying..."
          (cd "$ios_dir" && pod install) || {
            echo "❌ pod install failed."
            exit 1
          }
        fi
        echo "✅ Pods installed."
      else
        echo "✅ CocoaPods dependencies already installed."
      fi

      # ── Find the workspace ────────────────────────────────────────────────
      local xcworkspace
      xcworkspace=$(find "$ios_dir" -maxdepth 1 -name "*.xcworkspace" | head -1)
      if [[ -z "$xcworkspace" ]]; then
        xcworkspace=$(find "$ios_dir" -maxdepth 1 -name "*.xcodeproj" | head -1)
      fi
      if [[ -z "$xcworkspace" ]]; then
        echo "❌ No .xcworkspace or .xcodeproj found in $ios_dir"
        exit 1
      fi

      # ── Resolve scheme (prefer scheme matching the folder name) ──────────
      local _xcw_flag _xcw_key
      if [[ "$xcworkspace" == *.xcworkspace ]]; then
        _xcw_flag="-workspace"; _xcw_key="$(basename "$xcworkspace")"
      else
        _xcw_flag="-project";   _xcw_key="$(basename "$xcworkspace")"
      fi

      local _scheme
      _scheme=$(xcodebuild $_xcw_flag "$xcworkspace" -list 2>/dev/null \
        | awk '/Schemes:/,0' | grep -v "Schemes:" | awk '{$1=$1;print}' \
        | grep -i "$(echo "$build_folder" | tr ' ' '-')" | head -1 || true)
      # Fallback: first non-pod scheme
      if [[ -z "$_scheme" ]]; then
        _scheme=$(xcodebuild $_xcw_flag "$xcworkspace" -list 2>/dev/null \
          | awk '/Schemes:/,0' | grep -v "Schemes:" | awk '{$1=$1;print}' \
          | grep -v "^$\|Pods-\|EAS\|EX\|Expo\|React\|hermes\|RNSVG\|RNC\|RNS\|expo-\|react-native-\|Yoga\|UMApp\|Yoga" \
          | head -1 || true)
      fi
      [[ -z "$_scheme" ]] && _scheme="$build_folder"

      # ── Pick booted simulator (or first available iPhone) ─────────────────
      local _sim_udid _sim_name
      _sim_udid=$(xcrun simctl list devices booted 2>/dev/null \
        | grep "iPhone" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()' || true)
      if [[ -z "$_sim_udid" ]]; then
        _sim_udid=$(xcrun simctl list devices available iPhone 2>/dev/null \
          | grep "iPhone" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()' || true)
      fi
      _sim_name=$(xcrun simctl list devices 2>/dev/null \
        | grep "$_sim_udid" | sed 's/^[[:space:]]*//' | cut -d'(' -f1 | xargs || true)

      # ── Build output dir ──────────────────────────────────────────────────
      local _build_out="$ios_dir/build/simulator"
      mkdir -p "$_build_out"

      echo ""
      echo "========================================="
      echo "🔨 Building for simulator: $build_folder"
      echo "   Workspace: $(basename "$xcworkspace")"
      echo "   Scheme:    $_scheme"
      echo "   Simulator: ${_sim_name:-iPhone}"
      echo "========================================="
      echo ""

      # Boot simulator now so it's ready when install runs
      if [[ -n "$_sim_udid" ]]; then
        xcrun simctl boot "$_sim_udid" 2>/dev/null || true
      fi

      # ── xcodebuild ───────────────────────────────────────────────────────
      if xcodebuild \
          $_xcw_flag "$xcworkspace" \
          -scheme "$_scheme" \
          -configuration Debug \
          -destination "platform=iOS Simulator,id=${_sim_udid:-booted}" \
          -derivedDataPath "$_build_out" \
          CODE_SIGNING_ALLOWED=NO \
          CODE_SIGN_IDENTITY="" \
          CODE_SIGNING_REQUIRED=NO \
          build 2>&1 | grep -E "^(error:|warning: |Build succeeded|FAILED|❌|\.swift:|\.m:)"; then

        # ── Locate built .app ─────────────────────────────────────────────
        local _built_app
        _built_app=$(find "$_build_out/Build/Products" -name "*.app" \
          -not -path "*.dSYM*" -maxdepth 3 2>/dev/null | head -1)

        if [[ -n "$_built_app" && -d "$_built_app" ]]; then
          # Copy to builds/ so ./dev.sh ios picks it up
          local _output_dir="$ROOT_DIR/frontend/mobile/builds"
          mkdir -p "$_output_dir"
          rm -rf "$_output_dir/${build_folder}.app"
          cp -R "$_built_app" "$_output_dir/${build_folder}.app"

          echo ""
          echo "✅ Build succeeded → frontend/mobile/builds/${build_folder}.app"
          echo ""
          echo "   Install on simulator now:"
          echo "   ./dev.sh ios"
        else
          echo ""
          echo "⚠️  Build succeeded but .app not found in $_build_out"
          echo "   Try running: ./dev.sh ios"
        fi
      else
        echo ""
        echo "❌ Build failed. Opening Xcode for manual signing/build..."
        open "$xcworkspace"
        echo ""
        echo "   In Xcode:"
        echo "   1. Select the '$_scheme' scheme"
        echo "   2. Signing & Capabilities → enable Automatically manage signing"
        echo "   3. Set your Team"
        echo "   4. Press ⌘R"
      fi
    else
      echo "❌ Unknown platform '$build_platform'. Use android or ios."
      exit 1
    fi

  else
    # ── EAS cloud build (app name given, no 'local' flag) ────────────────
    if [[ -n "$build_app" ]]; then
      _do_eas_build "$build_app" "$build_platform" "${_extra_args[@]}"
    else
      # ── Podman images only (no app name) ──────────────────────────────
      echo "🏗️  Building core images..."
      _build_base_image_if_needed
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" build
      if has_mobile_apps; then build_mobile; fi
    fi
  fi
}



# ── Commands ──────────────────────────────────────────────────────────────────
case "$CMD" in
  expose)
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _print_access_urls
    ;;

  init)
    echo "🔧 Initializing frontend..."
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" --profile init run --rm frontend-init
    echo "🔧 Initializing backend..."
    "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" --profile init run --rm backend-init
    ;;

  build)
    _do_build "${@:2}"
    ;;

  build-all)
    # ── ./dev.sh build-all [android|ios] [development|production] [testflight] ────────────
    # Start builds for all mobile apps (sequential, but you can open multiple terminals for parallel)
    BUILD_PLATFORM="${2:-ios}"
    BUILD_PROFILE="${3:-development}"
    TESTFLIGHT_FLAG="${4:-}"

    # If testflight flag is provided, use development-testflight profile
    if [[ "$TESTFLIGHT_FLAG" == "testflight" ]]; then
      if [[ "$BUILD_PROFILE" == "development" ]]; then
        BUILD_PROFILE="development-testflight"
        echo ""
        echo "📱 TestFlight mode enabled: using development-testflight profile"
        echo "   • Development client with Metro hot reload"
        echo "   • Auto-submit to TestFlight after build"
        echo ""
      else
        echo ""
        echo "⚠️  TestFlight flag only works with development profile"
        echo "   Using $BUILD_PROFILE profile instead"
        echo ""
      fi
    fi

    echo ""
    echo "🚀 Building all apps for $BUILD_PLATFORM ($BUILD_PROFILE profile)"
    echo "──────────────────────────────────────────────────────────────────"
    echo ""
    echo "💡 TIP: For parallel builds, open multiple terminals and run:"
    echo ""

    # Get list of mobile apps
    APPS=()
    if [[ -d "$MOBILE_DIR" ]]; then
      while IFS= read -r -d '' folder; do
        app_name=$(basename "$folder")
        # Skip node_modules, shared, scripts, and hidden folders
        [[ "$app_name" =~ ^(node_modules|shared|scripts|packages|\.) ]] && continue
        # Only include folders with package.json
        if [[ -f "$folder/package.json" ]]; then
          APPS+=("$app_name")
          app_slug=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
          echo "   Terminal $(( ${#APPS[@]} )): ./dev.sh build $app_slug $BUILD_PLATFORM $BUILD_PROFILE"
        fi
      done < <(find "$MOBILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    if [[ ${#APPS[@]} -eq 0 ]]; then
      echo "❌ No mobile apps found in $MOBILE_DIR"
      exit 1
    fi

    echo ""
    echo "──────────────────────────────────────────────────────────────────"
    echo ""
    echo "Building ${#APPS[@]} app(s) sequentially..."
    echo ""

    # Build each app
    FAILED=()
    SUCCEEDED=()

    for app in "${APPS[@]}"; do
      app_slug=$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "📦 Building: $app"
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""

      # Use absolute path to call dev.sh
      if bash "$ROOT_DIR/dev.sh" build "$app_slug" "$BUILD_PLATFORM" "$BUILD_PROFILE"; then
        SUCCEEDED+=("$app")
        echo ""
        echo "✅ $app build completed successfully"
      else
        FAILED+=("$app")
        echo ""
        echo "❌ $app build failed"
      fi
    done

    # Print summary
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "📊 Build Summary"
    echo "══════════════════════════════════════════════════════════════════"
    echo "Total apps: ${#APPS[@]}"
    echo "Succeeded: ${#SUCCEEDED[@]} (${SUCCEEDED[*]:-none})"
    echo "Failed: ${#FAILED[@]} (${FAILED[*]:-none})"
    echo "══════════════════════════════════════════════════════════════════"

    if [[ ${#FAILED[@]} -gt 0 ]]; then
      echo ""
      echo "⚠️  Some builds failed."
      exit 1
    fi

    echo ""
    echo "🎉 All builds completed successfully!"
    ;;

  eas)
    # ── ./dev.sh eas [whoami|login|logout] ───────────────────────────────────
    # Interactive EAS authentication management
    EAS_CMD="${2:-whoami}"

    # Ensure EAS CLI is available
    if ! command -v eas &>/dev/null; then
      echo "📦 Installing EAS CLI..."
      npm install -g eas-cli
    fi

    case "$EAS_CMD" in
      whoami|who)
        echo ""
        echo "📱 EAS Account Information"
        echo "──────────────────────────────────────────────────────────────────"

        # Check EXPO_TOKEN first
        if [[ -n "${EXPO_TOKEN:-}" ]]; then
          echo "   Authentication: EXPO_TOKEN (from .env)"
          EAS_USER=$(eas whoami 2>/dev/null | head -1 | awk '{print $1}' || echo "")
          if [[ -n "$EAS_USER" ]]; then
            echo "   Logged in as: $EAS_USER"
            # Get account/organization info
            EAS_ORG=$(eas whoami 2>/dev/null | grep -E "^•" | awk '{print $2}' | tr -d '()' | head -1 || echo "")
            [[ -n "$EAS_ORG" ]] && echo "   Organization: $EAS_ORG"
          else
            echo "   ❌ EXPO_TOKEN is set but invalid"
            echo "   Update EXPO_TOKEN in .env or unset it to use interactive login"
          fi
        else
          # Check interactive login state
          EAS_USER=$(node -e "
try {
  const os=require('os'),path=require('path'),fs=require('fs');
  const s=JSON.parse(fs.readFileSync(path.join(os.homedir(),'.expo','state.json'),'utf8'));
  console.log(s.auth?.username||'');
} catch(e){console.log('');}
" 2>/dev/null || echo "")

          if [[ -n "$EAS_USER" ]]; then
            echo "   Authentication: Interactive (from ~/.expo/state.json)"
            echo "   Logged in as: $EAS_USER"
            # Try to get organization info
            EAS_ORG=$(eas whoami 2>/dev/null | grep -E "^•" | awk '{print $2}' | tr -d '()' | head -1 || echo "")
            [[ -n "$EAS_ORG" ]] && echo "   Organization: $EAS_ORG"
          else
            echo "   ❌ Not logged in"
            echo ""
            echo "   To log in, run: ./dev.sh eas login"
            echo "   Or set EXPO_TOKEN in .env for CI/automation"
          fi
        fi
        echo "──────────────────────────────────────────────────────────────────"
        echo ""
        ;;

      login)
        if [[ -n "${EXPO_TOKEN:-}" ]]; then
          echo "⚠️  EXPO_TOKEN is set in .env"
          echo "   Using token-based authentication. To use interactive login:"
          echo "   1. Remove or comment out EXPO_TOKEN in .env"
          echo "   2. Run: ./dev.sh eas login"
          exit 1
        fi

        echo ""
        echo "🔐 Logging in to EAS..."
        echo ""
        cd "$MOBILE_DIR" && eas login
        echo ""
        echo "✅ Login successful!"
        # Show who we're logged in as
        "$0" eas whoami
        ;;

      logout)
        if [[ -n "${EXPO_TOKEN:-}" ]]; then
          echo "⚠️  Using EXPO_TOKEN authentication"
          echo "   To log out, remove or comment out EXPO_TOKEN in .env"
          exit 1
        fi

        echo ""
        echo "👋 Logging out from EAS..."
        cd "$MOBILE_DIR" && eas logout
        echo ""
        echo "✅ Logged out successfully"
        ;;

      *)
        echo "Usage: ./dev.sh eas [whoami|login|logout]"
        echo ""
        echo "Commands:"
        echo "  whoami  - Show current EAS account"
        echo "  login   - Log in to EAS interactively"
        echo "  logout  - Log out from EAS"
        echo ""
        echo "Authentication methods:"
        echo "  1. Interactive: Use 'eas login' for manual auth (default)"
        echo "  2. Token: Set EXPO_TOKEN in .env for CI/automation"
        exit 1
        ;;
    esac
    ;;

  up)
    echo "🚀 Starting core services..."
    dc_up_ordered
    if has_mobile_apps; then run_mobile; fi
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _start_healthcheck_runner
    echo ""
    echo "✅ Services started in the background."
    _draw_status
    ;;

  core)
    echo "🚀 Starting core services (no mobile)..."
    dc_up_ordered
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _start_healthcheck_runner
    echo ""
    echo "✅ Core services started in the background."
    _draw_status
    ;;

  qr)
    _print_mobile_qrs
    ;;

  status|monitor)
    # Disable errexit for the monitor so errors don't kill the loop
    set +e
    live_monitor
    # This line should never be reached
    set -e
    ;;

  _status_only)
    _wire_podman_socket 2>/dev/null || true
    detect_compose 2>/dev/null || true
    _rows=$(mktemp /tmp/${PROJECT_NAME}-status-rows-XXXXXX)
    _draw_status_live "$_rows"
    rm -f "$_rows"
    ;;

  _metro_tunnels_only)
    # Internal recovery command used by the tunnel watchdog after Cloudflare's
    # cooldown expires. It does not rebuild or recreate app containers.
    _ensure_metro_proxies 2>/dev/null || true
    _ensure_metro_tunnels
    ;;

  service-logs)
    # ./dev.sh service-logs <container_name>
    _wire_podman_socket 2>/dev/null || true
    _service_log_view "${2:-}"
    ;;

  heal)
    # Redirect to rebuild command
    echo "⚠️  The 'heal' command has been removed."
    echo "   Use: ./dev.sh rebuild <service_name>"
    echo ""
    if [[ -n "${2:-}" ]]; then
      echo "   Running: ./dev.sh rebuild ${2}"
      exec "$0" rebuild "${2}"
    fi
    exit 1
    ;;

  check)
    # ./dev.sh check [service_name]
    discover_apps
    discover_core_svcs

    _cache=$(_build_cname_cache)

    if [[ -n "${2:-}" ]]; then
      # Check specific service
      svc="$2"
      cname=""

      # Check if it's a core service
      found=false
      _line="" _check_svc="" _port="" _cname_override=""
      while IFS=' ' read -r _check_svc _port _cname_override; do
        [[ -z "$_check_svc" ]] && continue
        if [[ "$_check_svc" == "$svc" ]]; then
          if [[ -n "$_cname_override" ]]; then
            cname="$_cname_override"
          else
            cname="$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")"
          fi
          found=true
          break
        fi
      done < <(_parse_compose_services)

      # Check if it's a mobile service
      if ! $found; then
        for folder in "${MOBILE_APPS[@]}"; do
          mobile_svc=$(folder_to_service "$folder")
          if [[ "$mobile_svc" == "$svc" ]]; then
            cname="$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")"
            found=true
            break
          fi
        done
      fi

      if ! $found; then
        echo "❌ Service '$svc' not found"
        exit 1
      fi

      status=$(_container_status "$cname")
      state=$(_container_state "$cname")
      echo "Service: $svc"
      echo "Container: $cname"
      echo "Status: $status ($state)"

      if [[ "$status" == "broken" ]]; then
        echo ""
        echo "💡 To fix this service, run: ./dev.sh rebuild $svc"
      fi
    else
      # Check all services
      echo "🔍 Service Status Check"
      echo ""

      echo "Core Services:"
      _line="" _svc="" _port="" _cname_override=""
      while IFS=' ' read -r _svc _port _cname_override; do
        [[ -z "$_svc" ]] && continue
        cname=""
        if [[ -n "$_cname_override" ]]; then
          cname="$_cname_override"
        else
          cname="$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")"
        fi
        status=$(_container_status "$cname")
        icon=""
        case "$status" in
          ok)       icon="✅" ;;
          starting) icon="🔄" ;;
          broken)   icon="❌" ;;
          missing)  icon="⚪" ;;
        esac
        printf "  %s %-15s %s\n" "$icon" "$_svc" "$status"
      done < <(_parse_compose_services)

      if has_mobile_apps; then
        echo ""
        echo "Mobile Services:"
        for folder in "${MOBILE_APPS[@]}"; do
          svc=$(folder_to_service "$folder")
          cname="$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")"
          status=$(_container_status "$cname")
          icon=""
          case "$status" in
            ok)       icon="✅" ;;
            starting) icon="🔄" ;;
            broken)   icon="❌" ;;
            missing)  icon="⚪" ;;
          esac
          printf "  %s %-15s %s\n" "$icon" "$svc" "$status"
        done
      fi

      echo ""
      echo "Emulator:"
      if _emulator_running; then
        echo "  ✅ Android emulator running"
      else
        echo "  ⚪ Android emulator not running"
      fi
    fi
    ;;

  rebuild)
    # ./dev.sh rebuild [service_name]
    if [[ -n "${2:-}" ]]; then
      # Rebuild specific service
      svc_to_rebuild="$2"

      # Validate service exists
      discover_apps
      discover_core_svcs

      found=false

      # Check core services
      _line="" _check_svc="" _port="" _cname_override=""
      while IFS=' ' read -r _check_svc _port _cname_override; do
        [[ -z "$_check_svc" ]] && continue
        if [[ "$_check_svc" == "$svc_to_rebuild" ]]; then
          found=true
          break
        fi
      done < <(_parse_compose_services)

      # Check mobile services
      if ! $found && has_mobile_apps; then
        for folder in "${MOBILE_APPS[@]}"; do
          mobile_svc=$(folder_to_service "$folder")
          if [[ "$mobile_svc" == "$svc_to_rebuild" ]]; then
            found=true
            break
          fi
        done
      fi

      if ! $found; then
        echo "❌ Service '$svc_to_rebuild' not found"
        echo ""
        echo "Available services:"
        for svc in "${CORE_SVCS[@]}"; do
          echo "  $svc"
        done
        if has_mobile_apps; then
          echo ""
          echo "Mobile services:"
          for folder in "${MOBILE_APPS[@]}"; do
            echo "  $(folder_to_service "$folder")"
          done
        fi
        exit 1
      fi

      _do_rebuild "$svc_to_rebuild"
    else
      # Rebuild all services
      _do_rebuild
    fi
    ;;

  adb-reverse)
    # ./dev.sh adb-reverse — manually set up port-forwarding for physical Android devices
    # Run this any time you plug in a device or after restarting Metro.
    _setup_android_path
    _adb_cmd="${ANDROID_HOME}/platform-tools/adb"
    if [[ ! -x "$_adb_cmd" ]] && ! command -v adb &>/dev/null; then
      echo "❌ adb not found. Make sure Android SDK platform-tools are installed."
      exit 1
    fi
    _setup_physical_devices
    ;;

  verify-ios)
    # ./dev.sh verify-ios — verify iOS networking configuration
    echo "🔍 iOS Networking Configuration Verification"
    echo "=============================================="
    echo ""

    # 1. Check Mac's IP address
    echo "1️⃣  Checking Mac's local IP address..."
    LOCAL_IP=$(_get_lan_ip)
    if [[ -z "$LOCAL_IP" || "$LOCAL_IP" == "localhost" ]]; then
      echo "   ❌ Could not detect local IP address"
      echo "   → Make sure you're connected to WiFi or Ethernet"
      exit 1
    else
      echo "   ✅ Local IP: $LOCAL_IP"
    fi
    echo ""

    # 2. Check each discovered mobile app config
    discover_apps
    local _app_step=2
    local _app_port=8081
    declare -A _APP_APIS
    for _app_folder in "${MOBILE_APPS[@]}"; do
      echo "${_app_step}️⃣  Checking ${_app_folder} app configuration..."
      if [[ -d "$MOBILE_DIR/$_app_folder" ]]; then
        _APP_API=$(cd "$MOBILE_DIR/$_app_folder" && node -e "const config = require('./app.config.js'); console.log(config.expo.extra.apiUrl);" 2>/dev/null || echo "")
        _APP_WS=$(cd "$MOBILE_DIR/$_app_folder" && node -e "const config = require('./app.config.js'); console.log(config.expo.extra.wsUrl);" 2>/dev/null || echo "")
        _APP_APIS["$_app_folder"]="$_APP_API"
        if [[ "$_APP_API" == *"$LOCAL_IP"* ]]; then
          echo "   ✅ API URL: $_APP_API"
          echo "   ✅ WS URL:  $_APP_WS"
        else
          echo "   ❌ API URL is not using local IP: $_APP_API"
          echo "   → Expected: http://$LOCAL_IP:8000"
        fi
      else
        echo "   ⚠️  ${_app_folder} app not found"
      fi
      echo ""
      _app_step=$((_app_step + 1))
      _app_port=$((_app_port + 1))
    done

    # Next step number after apps
    local _next_step=$_app_step

    # Check if backend is running
    echo "${_next_step}️⃣  Checking if backend is accessible..."
    if curl -s -o /dev/null -w "%{http_code}" "http://$LOCAL_IP:8000" 2>/dev/null | grep -q "200\|301\|302\|404"; then
      echo "   ✅ Backend is accessible at http://$LOCAL_IP:8000"
    else
      echo "   ⚠️  Backend is not responding at http://$LOCAL_IP:8000"
      echo "   → Start backend with: ./dev.sh"
    fi
    echo ""
    _next_step=$((_next_step + 1))

    # Check Metro bundler ports
    echo "${_next_step}️⃣  Checking Metro bundler ports..."
    local _metro_port=8081
    for _app_folder in "${MOBILE_APPS[@]}"; do
      if _port_in_use "${_metro_port}"; then
        echo "   ✅ Metro running on port ${_metro_port} (${_app_folder})"
      else
        echo "   ⚠️  Metro not running on port ${_metro_port} (${_app_folder})"
        echo "   → Will start automatically when you run ./dev.sh ios"
      fi
      _metro_port=$((_metro_port + 1))
    done
    echo ""

    # Summary
    echo "📋 Summary"
    echo "=========="
    echo "Your Mac's IP:     $LOCAL_IP"
    for _app_folder in "${MOBILE_APPS[@]}"; do
      [[ -n "${_APP_APIS[$_app_folder]:-}" ]] && echo "${_app_folder} API:      ${_APP_APIS[$_app_folder]}"
    done
    echo ""
    echo "Expected Metro URLs for iOS simulator:"
    local _metro_port=8081
    for _app_folder in "${MOBILE_APPS[@]}"; do
      printf "  • %-20s http://%s:%d\n" "${_app_folder}:" "$LOCAL_IP" "$_metro_port"
      _metro_port=$((_metro_port + 1))
    done
    echo ""
    echo "✅ Configuration looks good!"
    echo ""
    echo "Next steps:"
    echo "  1. Start services:  ./dev.sh"
    echo "  2. Build iOS apps:  ./dev.sh ios"
    echo ""
    echo "The iOS simulator will be able to:"
    echo "  ✓ Connect to backend at http://$LOCAL_IP:8000"
    echo "  ✓ Connect to Metro at http://$LOCAL_IP:8081 and :8082"
    echo "  ✓ Receive live updates from Metro bundler"
    ;;

  wifi-forward)
    # Uses pfctl rdr rules to redirect WiFi IP traffic → 127.0.0.1 so gvproxy
    # forwards it into the Podman VM.  Lets iPhones on the same WiFi reach Metro.
    run_wifi_forward "${2:-start}"
    ;;

  mdns-advertise)
    # ./dev.sh mdns-advertise [start|stop|status]
    # Registers _expo._tcp Bonjour services via dns-sd so the Expo dev client
    # on a physical iPhone can discover Metro running inside the Podman container.
    run_mdns_advertise "${2:-start}"
    ;;

  logs)
    _log_filter="${2:-}"
    if [[ -n "$_log_filter" ]]; then
      echo "📋 Following logs for '$_log_filter' (Ctrl+C to stop)..."
    else
      echo "📋 Following logs (Ctrl+C to stop)..."
    fi
    echo ""
    _follow_logs "$_log_filter"
    ;;

  mobile)
    if has_mobile_apps; then
      # Auto-update EXPO_PUBLIC_API_URL with current local IP
      update_mobile_ip

      mobile_svcs=$(mobile_service_names)
      echo "📱 Starting mobile services: $mobile_svcs"
      yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"
      # shellcheck disable=SC2086
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" -f "$yml_file" up -d --force-recreate $mobile_svcs \
        >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true
      echo ""
      echo "✅ Mobile services started in the background."
      # Set up adb reverse so emulators/devices can reach Metro on localhost
      _setup_physical_devices 2>/dev/null || true
      _draw_status
    else
      echo "⚠️  No mobile apps found."
    fi
    ;;

  "")
    # Always ensure services are built and running
    # Check if this is a fresh start (no containers exist)
    discover_core_svcs
    any_containers=false
    # Use label-based lookup — podman-compose uses underscores (project_svc_1)
    # but the fallback name uses dashes (project-svc-1). Check both, and also
    # check via compose project label to be robust across all versions.
    for svc in "${CORE_SVCS[@]}"; do
      if podman ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
           --filter "label=com.docker.compose.service=${svc}" -q 2>/dev/null | grep -q .; then
        any_containers=true
        break
      fi
      # Fallback: try both separator conventions
      for cname in "${PROJECT_NAME}_${svc}_1" "${PROJECT_NAME}-${svc}-1"; do
        if podman inspect "$cname" &>/dev/null 2>&1; then
          any_containers=true
          break 2
        fi
      done
    done

    if [[ "$any_containers" == "false" ]]; then
      # Fresh start - build and start everything
      echo "🏗️  First run detected — building everything..."
      echo ""
      echo "🏗️  Building core images..."
      _build_base_image_if_needed
      "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" build

      if has_mobile_apps; then
        build_mobile
      fi

      echo ""
      echo "🚀 Starting core services..."
      dc_up_ordered

      if has_mobile_apps; then
        run_mobile
      fi

      # Start Cloudflare Tunnel after services are running
      _start_cloudflare_tunnel
      _start_tunnel_watchdog
      _start_healthcheck_runner

      echo ""
      echo "✅ Everything is up! Services are running in the background."
      echo ""
      _print_access_urls
      echo ""
      echo "   Run './dev.sh status' to monitor live status."
      echo "   Run './dev.sh logs' to follow logs."
      echo "   Run './dev.sh stop' to stop all services."
      echo "   Run './dev.sh down' to stop and remove everything."
      echo ""
      _open_safari || true
      set +e
      live_monitor
      set -e
    else
      # Containers exist - use smart launch to fix/start them
      smart_launch
    fi
    ;;

  release)
    RELEASE_PLATFORM="${2:-android}"  # Default to android
    RELEASE_SETUP="false"
    RELEASE_LOCAL="false"

    # Check for 'setup' and 'local' flags
    for arg in "$@"; do
      if [[ "$arg" == "setup" ]]; then
        RELEASE_SETUP="true"
      elif [[ "$arg" == "local" ]]; then
        RELEASE_LOCAL="true"
      fi
    done

    # Handle setup mode for iOS (interactive credential setup)
    if [[ "$RELEASE_SETUP" == "true" && "$RELEASE_PLATFORM" == "ios" ]]; then
      echo ""
      echo "🔐 iOS Credential Setup (Interactive)"
      echo "   This will configure iOS certificates and provisioning profiles"
      echo ""

      discover_apps
      for folder in "${MOBILE_APPS[@]}"; do
        slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        app_dir="$MOBILE_DIR/$folder"

        echo "========================================="
        echo "📱 Setting up iOS credentials: $folder"
        echo "========================================="
        echo ""

        cd "$app_dir" || exit 1
        eas build --platform ios --profile production
        echo ""
      done

      echo "✅ iOS credential setup complete!"
      exit 0
    fi

    # Handle setup mode for Android (keystore generation)
    if [[ "$RELEASE_SETUP" == "true" && "$RELEASE_PLATFORM" == "android" ]]; then
      SETUP_APP="${3:-}"

      # Setup Java environment
      _setup_java_env || exit 1

      # Load keystore passwords from .env
      if [[ -f "$ROOT_DIR/.env" ]]; then
        KEYSTORE_PASS=$(grep "^ANDROID_KEYSTORE_PASSWORD=" "$ROOT_DIR/.env" | cut -d'=' -f2 || echo "android")
        KEY_PASS=$(grep "^ANDROID_KEY_PASSWORD=" "$ROOT_DIR/.env" | cut -d'=' -f2 || echo "android")
      else
        echo "⚠️  .env file not found. Using default passwords."
        KEYSTORE_PASS="android"
        KEY_PASS="android"
      fi

      discover_apps
      for folder in "${MOBILE_APPS[@]}"; do
        if [[ -z "$SETUP_APP" ]] || echo "$folder" | grep -qi "$SETUP_APP"; then
          slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

          # Read package name from app.config.js or app.json
          app_config_js="$MOBILE_DIR/$folder/app.config.js"
          app_json="$MOBILE_DIR/$folder/app.json"
          package_name=""

          if [[ -f "$app_config_js" ]]; then
            # Extract package name from app.config.js
            package_name=$(node -e "
              const config = require('$app_config_js');
              const pkg = config.expo?.android?.package || config.android?.package || '';
              console.log(pkg);
            " 2>/dev/null || echo "")
          fi

          if [[ -z "$package_name" && -f "$app_json" ]]; then
            # Extract package name from app.json
            package_name=$(node -e "
              const config = require('$app_json');
              const pkg = config.expo?.android?.package || config.android?.package || '';
              console.log(pkg);
            " 2>/dev/null || echo "")
          fi

          # Fallback to slug-based package name
          if [[ -z "$package_name" ]]; then
            package_name="com.${slug//-/}"
          fi

          keystore_path="$MOBILE_DIR/$folder/android/app/${slug}-release.keystore"
          props_file="$MOBILE_DIR/$folder/android/gradle.properties"

          if [[ -f "$keystore_path" ]]; then
            echo "⚠️  Keystore already exists for '$folder'"
            echo "   Package: $package_name"
            echo "   Keystore: $keystore_path"
            echo ""
            echo "   To regenerate, delete the keystore first:"
            echo "   rm \"$keystore_path\""
            continue
          fi

          echo "🔑 Generating release keystore for '$folder'..."
          echo "   Package: $package_name"
          echo "   Keystore: ${slug}-release.keystore"
          echo ""

          keytool -genkey -v \
            -storetype PKCS12 \
            -keystore "$keystore_path" \
            -alias "${slug}-release" \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -storepass "$KEYSTORE_PASS" \
            -keypass "$KEY_PASS" \
            -dname "CN=$folder, OU=Mobile, O=$PROJECT_DISPLAY_NAME, L=Unknown, ST=Unknown, C=US"

          echo ""
          echo "✅ Keystore created for '$folder'"
          echo ""
          echo "📋 Certificate Fingerprints:"
          echo ""

          # Get SHA-1 fingerprint
          SHA1=$(keytool -list -v -keystore "$keystore_path" -alias "${slug}-release" -storepass "$KEYSTORE_PASS" 2>/dev/null | grep "SHA1:" | sed 's/.*SHA1: //' || echo "")

          # Get SHA-256 fingerprint
          SHA256=$(keytool -list -v -keystore "$keystore_path" -alias "${slug}-release" -storepass "$KEYSTORE_PASS" 2>/dev/null | grep "SHA256:" | sed 's/.*SHA256: //' || echo "")

          if [[ -n "$SHA1" ]]; then
            echo "   SHA-1:   $SHA1"
          fi
          if [[ -n "$SHA256" ]]; then
            echo "   SHA-256: $SHA256"
          fi

          echo ""
          echo "   Location: $keystore_path"
          echo ""

          # Update gradle.properties
          { echo ""; echo "# Release signing"
            echo "RELEASE_STORE_FILE=${slug}-release.keystore"
            echo "RELEASE_KEY_ALIAS=${slug}-release"
            echo "RELEASE_STORE_PASSWORD=$KEYSTORE_PASS"
            echo "RELEASE_KEY_PASSWORD=$KEY_PASS"
          } >> "$props_file"
        fi
      done
      exit 0
    fi

    # Cloud build (default) - uses EAS with production profile
    if [[ "$RELEASE_LOCAL" == "false" ]]; then
      discover_apps
      [[ ${#MOBILE_APPS[@]} -eq 0 ]] && echo "⚠️  No mobile apps found." && exit 1

      echo ""
      echo "☁️  Building release for $RELEASE_PLATFORM in the cloud (EAS)..."
      echo "   Use 'local' flag to build locally instead"
      echo ""

      for folder in "${MOBILE_APPS[@]}"; do
        slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

        # Reuse _do_eas_build so project linking is handled automatically
        _do_eas_build "$slug" "$RELEASE_PLATFORM" "production"
      done

      echo ""
      echo "✅ Cloud builds submitted!"
      echo "   Download from: https://expo.dev"
      exit 0
    fi

    # Local build - uses Gradle (Android only)
    if [[ "$RELEASE_PLATFORM" != "android" ]]; then
      echo "❌ Local builds are only supported for Android."
      echo "   For iOS, use cloud builds: ./dev.sh release ios"
      exit 1
    fi

    discover_apps
    [[ ${#MOBILE_APPS[@]} -eq 0 ]] && echo "⚠️  No mobile apps found." && exit 1

    # Setup Java environment for Gradle
    _setup_java_env || exit 1

    ANDROID_HOME="${ANDROID_HOME:-$(_default_android_sdk)}"
    OUTPUT_DIR="$ROOT_DIR/frontend/mobile/builds"
    mkdir -p "$OUTPUT_DIR"
    failed=()

    echo ""
    echo "🖥️  Building release AAB locally (Gradle)..."
    echo ""

    for folder in "${MOBILE_APPS[@]}"; do
      android_dir="$MOBILE_DIR/$folder/android"
      slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

      # Ensure android directory exists and is properly configured
      if [[ ! -d "$android_dir" ]] || [[ ! -f "$android_dir/gradlew" ]]; then
        echo "📦 Preparing android directory for '$folder'..."
        _ensure_android_dir "$folder" "$android_dir"
      fi

      # Verify android directory was created successfully
      if [[ ! -f "$android_dir/gradlew" ]]; then
        echo "❌ Failed to prepare android directory for '$folder'"
        failed+=("$folder")
        continue
      fi

      echo ""
      echo "========================================="
      echo "📦 Building release AAB: $folder"
      echo "========================================="
      echo "sdk.dir=$ANDROID_HOME" > "$android_dir/local.properties"

      # Load every public project variable and apply *_PRODUCTION overrides.
      # Project integrations require no names or credentials in this template.
      if ! ANDROID_HOME="$ANDROID_HOME" python3 "$ROOT_DIR/backend/config/project_config.py" \
          "$ROOT_DIR" run-build production "$android_dir/gradlew" -p "$android_dir" bundleRelease 2>&1; then
        echo "❌ Build failed for '$folder'"
        failed+=("$folder")
        continue
      fi
      aab="$android_dir/app/build/outputs/bundle/release/app-release.aab"
      if [[ -f "$aab" ]]; then
        cp "$aab" "$OUTPUT_DIR/${slug}-release.aab"
        echo "✅ $folder → frontend/mobile/builds/${slug}-release.aab"
      else
        echo "❌ Build failed for '$folder'"
        failed+=("$folder")
      fi
    done

    echo ""
    if [[ ${#failed[@]} -eq 0 ]]; then
      echo "🎉 All builds complete! AABs in: frontend/mobile/builds/"
      ls -lh "$OUTPUT_DIR"/*.aab 2>/dev/null
    else
      echo "❌ Failed: ${failed[*]}"
      exit 1
    fi
    ;;

  run)
    echo "❌ 'run' command has been removed."
    echo "   To build a native APK/IPA locally:"
    echo "   ./dev.sh build <app> [android|ios] local"
    echo ""
    echo "   Example:"
    echo "   ./dev.sh build <app-name> android local"
    exit 1
    ;;

  android)
    # ./dev.sh android — Start Android emulator, reverse ports, install and open apps
    echo "📱 Starting Android development environment..."
    echo ""

    # Auto-install SDK if missing — no need to run ./dev.sh setup separately
    _setup_android_path
    _adb_bin="${ANDROID_HOME}/platform-tools/adb"
    _emu_bin="${ANDROID_HOME}/emulator/emulator"

    if [[ ! -x "$_adb_bin" ]] || [[ ! -x "$_emu_bin" ]]; then
      echo "🔧 Android SDK not found — installing now..."
      echo ""
      _install_android_sdk
      _setup_android_path
      _adb_bin="${ANDROID_HOME}/platform-tools/adb"
      _emu_bin="${ANDROID_HOME}/emulator/emulator"
    fi

    if [[ ! -x "$_adb_bin" ]] || [[ ! -x "$_emu_bin" ]]; then
      echo "❌ Android SDK install failed. Check the output above for errors."
      exit 1
    fi

    # Start emulator if not running
    if ! _emulator_running; then
      echo "🚀 Starting Android emulator..."
      _start_emulator_with_apps
    else
      echo "✅ Android emulator already running"
      # Still set up adb reverse and install apps
      _setup_physical_devices

      # Install apps if they exist
      discover_apps
      if has_mobile_apps; then
        for folder in "${MOBILE_APPS[@]}"; do
          _apk_path="$MOBILE_DIR/$folder/android/app/build/outputs/apk/debug/app-debug.apk"
          if [[ -f "$_apk_path" ]]; then
            echo "📦 Installing $folder..."
            "$_adb_bin" install -r "$_apk_path" 2>/dev/null || echo "  ⚠️  Install failed (app may already be installed)"
          fi
        done
      fi
    fi

    echo ""
    echo "✅ Android environment ready!"
    echo "   Emulator is running with port forwarding configured"
    ;;

  disk)
    echo "💾 Disk Usage Analysis"
    echo ""

    # Podman system usage
    echo "📊 Podman Resources:"
    podman system df 2>/dev/null || echo "   (Podman not running)"
    echo ""

    # Podman machine disk (macOS/Windows)
    if [[ "$OS" == "mac" || "$OS" == "windows" ]]; then
      echo "🖥️  Podman Machine Disk:"
      _machine_disk=$(find ~/.local/share/containers/podman/machine -name "*.raw" 2>/dev/null | head -1)
      if [[ -n "$_machine_disk" && -f "$_machine_disk" ]]; then
        _disk_size=$(du -sh "$_machine_disk" 2>/dev/null | awk '{print $1}')
        _disk_allocated=$(ls -lh "$_machine_disk" 2>/dev/null | awk '{print $5}')
        echo "   Location: $_machine_disk"
        echo "   Actual size: $_disk_size"
        echo "   Allocated: $_disk_allocated"
        echo ""
        echo "   💡 Run './dev.sh down' to clean and compact this disk"
      else
        echo "   No machine disk found"
      fi
      echo ""
    fi

    # Project directory caches
    echo "📁 Project Directory Caches:"
    _total_cache=0

    if [[ -d "$ROOT_DIR/backend" ]]; then
      _pycache=$(find "$ROOT_DIR/backend" -type d -name "__pycache__" -exec du -sk {} + 2>/dev/null | awk '{sum+=$1} END {print sum}')
      if [[ -n "$_pycache" && "$_pycache" -gt 0 ]]; then
        echo "   Python __pycache__: $(numfmt --to=iec --suffix=B $((_pycache * 1024)) 2>/dev/null || echo \"${_pycache}K\")"
        _total_cache=$((_total_cache + _pycache))
      fi
    fi

    if [[ -d "$ROOT_DIR/frontend" ]]; then
      _expo_cache=$(find "$ROOT_DIR/frontend" -type d -name ".expo" -exec du -sk {} + 2>/dev/null | awk '{sum+=$1} END {print sum}')
      if [[ -n "$_expo_cache" && "$_expo_cache" -gt 0 ]]; then
        echo "   Expo cache: $(numfmt --to=iec --suffix=B $((_expo_cache * 1024)) 2>/dev/null || echo \"${_expo_cache}K\")"
        _total_cache=$((_total_cache + _expo_cache))
      fi

      _node_cache=$(find "$ROOT_DIR/frontend" -type d -path "*/node_modules/.cache" -exec du -sk {} + 2>/dev/null | awk '{sum+=$1} END {print sum}')
      if [[ -n "$_node_cache" && "$_node_cache" -gt 0 ]]; then
        echo "   Node modules cache: $(numfmt --to=iec --suffix=B $((_node_cache * 1024)) 2>/dev/null || echo \"${_node_cache}K\")"
        _total_cache=$((_total_cache + _node_cache))
      fi
    fi

    if [[ $_total_cache -gt 0 ]]; then
      echo "   Total project caches: $(numfmt --to=iec --suffix=B $((_total_cache * 1024)) 2>/dev/null || echo \"${_total_cache}K\")"
    else
      echo "   No significant caches found"
    fi
    echo ""
    echo "💡 Run './dev.sh down' to clean everything and reclaim disk space"
    ;;

  ios)
    # ./dev.sh ios [<app>] — Boot simulator, install cached builds/IPAs, launch apps
    # Optional second argument filters to a specific app (case-insensitive substring match).
    _ios_filter="${2:-}"
    echo "📱 Starting iOS development environment..."
    echo ""

    if [[ "$OS" != "mac" ]]; then
      echo "❌ iOS simulator is only available on macOS"
      exit 1
    fi

    # Require full Xcode — simctl is not available in Command Line Tools alone
    if ! xcrun simctl list &>/dev/null 2>&1; then
      echo "❌ Xcode is required. Install it from the App Store, then:"
      echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
      exit 1
    fi

    # ── Discover and filter apps ──────────────────────────────────────────────
    discover_apps
    if [[ ${#MOBILE_APPS[@]} -eq 0 ]]; then
      echo "❌ No mobile apps found in frontend/mobile/"
      exit 1
    fi

    if [[ -n "$_ios_filter" && "$_ios_filter" != "--rebuild" ]]; then
      _filtered=()
      for _fa in "${MOBILE_APPS[@]}"; do
        echo "$_fa" | grep -qi "$_ios_filter" && _filtered+=("$_fa")
      done
      if [[ ${#_filtered[@]} -eq 0 ]]; then
        echo "❌ No app matching '$_ios_filter' found. Available apps:"
        for _fa in "${MOBILE_APPS[@]}"; do echo "   - $_fa"; done
        exit 1
      fi
      MOBILE_APPS=("${_filtered[@]}")
      echo "   Targeting: ${MOBILE_APPS[*]}"
      echo ""
    fi

    # ── Pick simulator ────────────────────────────────────────────────────────
    # Prefer already-booted; then exact "iPhone 17 (" (excludes Pro/Max/Plus); then any iPhone
    _sim_line=$(xcrun simctl list devices available iPhone | grep "Booted" | head -1 || true)
    if [[ -z "$_sim_line" ]]; then
      _sim_line=$(xcrun simctl list devices available iPhone | grep -E '^\s+iPhone 17 \(' | head -1 || true)
    fi
    [[ -z "$_sim_line" ]] && _sim_line=$(xcrun simctl list devices available iPhone | grep "iPhone" | head -1 || true)

    _sim_name=$(echo "$_sim_line" | sed 's/^[[:space:]]*//' | cut -d'(' -f1 | xargs)
    _sim_udid=$(echo "$_sim_line" | grep -oE '\([A-F0-9-]+\)' | head -1 | tr -d '()')

    if [[ -z "$_sim_udid" ]]; then
      echo "❌ No iPhone simulator found. Create one in Xcode → Window → Devices and Simulators."
      exit 1
    fi

    echo "   Using: $_sim_name ($_sim_udid)"

    # ── Open simulator app ────────────────────────────────────────────────────
    # Tries every known location so it works across Xcode versions including
    # Xcode 26+ beta where Simulator.app was replaced by DeviceHub.
    _open_simulator() {
      local _xdev; _xdev=$(xcode-select -p 2>/dev/null || true)
      # Standard Xcode (≤15): Simulator.app lives inside the developer dir
      [[ -n "$_xdev" && -d "$_xdev/Applications/Simulator.app" ]] && \
        open "$_xdev/Applications/Simulator.app" 2>/dev/null && return 0
      # Older Xcode: open by bundle ID
      open -b com.apple.iphonesimulator 2>/dev/null && return 0
      # Generic App Store name
      open -a Simulator 2>/dev/null && return 0
      # Xcode 26+ beta: Simulator.app removed, DeviceHub is the simulator UI
      [[ -n "$_xdev" && -d "$_xdev/../Applications/DeviceHub.app" ]] && \
        open "$_xdev/../Applications/DeviceHub.app" 2>/dev/null && return 0
      true
    }

    # ── Boot if needed ────────────────────────────────────────────────────────
    _sim_state=$(xcrun simctl list devices | grep "$_sim_udid" | grep -oE '\(Booted\)' || true)
    if [[ -z "$_sim_state" ]]; then
      echo "   Booting simulator (this can take up to 90s on first boot)..."
      _open_simulator
      xcrun simctl boot "$_sim_udid" 2>/dev/null || true
      _boot_waited=0
      while [[ $_boot_waited -lt 90 ]]; do
        _sim_state=$(xcrun simctl list devices | grep "$_sim_udid" | grep -oE '\(Booted\)' || true)
        [[ -n "$_sim_state" ]] && break
        sleep 2; _boot_waited=$((_boot_waited + 2))
        (( _boot_waited % 10 == 0 )) && printf "   ⏳ Still booting... (%ds)\n" "$_boot_waited"
      done
      [[ -n "$_sim_state" ]] && echo "   ✅ $_sim_name booted" || echo "   ⚠️  Boot timed out — may still be starting"
    else
      _open_simulator
      echo "   ✅ $_sim_name already running"
    fi

    # ── Install IPAs from builds/ first ──────────────────────────────────────
    # IPAs are produced by EAS / `./dev.sh build <app> ios`. Installing them
    # before the per-app loop means the loop can skip apps already covered.
    _builds_dir="$ROOT_DIR/frontend/mobile/builds"
    _ipa_files=()
    if [[ -d "$_builds_dir" ]]; then
      while IFS= read -r -d '' _ipa; do
        _ipa_files+=("$_ipa")
      done < <(find "$_builds_dir" -maxdepth 1 -name "*.ipa" -print0 2>/dev/null)
    fi

    # Track installed app slugs so the per-app loop can skip them
    _installed_app_slugs=()

    if [[ ${#_ipa_files[@]} -gt 0 ]]; then
      echo ""
      echo "📦 Installing ${#_ipa_files[@]} IPA(s) from builds/..."

      for _ipa in "${_ipa_files[@]}"; do
        _ipa_name=$(basename "$_ipa")
        echo ""
        echo "📲 Installing $_ipa_name..."

        # IPAs are just zip files — extract the .app from Payload/
        _tmp=$(mktemp -d)
        unzip -q "$_ipa" -d "$_tmp" 2>/dev/null || {
          echo "   ⚠️  Failed to extract IPA"
          rm -rf "$_tmp"
          continue
        }

        _app_path=$(find "$_tmp/Payload" -name "*.app" -maxdepth 1 | head -1)
        if [[ -z "$_app_path" ]]; then
          echo "   ⚠️  No .app found in IPA"
          rm -rf "$_tmp"
          continue
        fi

        if xcrun simctl install "$_sim_udid" "$_app_path" 2>/dev/null; then
          echo "   ✅ Installed $_ipa_name"

          # Track slug: "MyApp (development).ipa" → "MyApp"
          _ipa_slug=$(basename "$_ipa" .ipa | sed 's/ ([^)]*)$//')
          _installed_app_slugs+=("$_ipa_slug")

          # Launch immediately
          _ipa_bundle_id=$(defaults read "$_app_path/Info.plist" CFBundleIdentifier 2>/dev/null || true)
          if [[ -n "$_ipa_bundle_id" ]]; then
            echo "   🚀 Launching $_ipa_bundle_id..."
            xcrun simctl launch "$_sim_udid" "$_ipa_bundle_id" 2>/dev/null || true
          fi
        else
          echo "   ⚠️  Failed to install $_ipa_name"
        fi

        rm -rf "$_tmp"
      done

      echo ""
      echo "✅ Finished installing IPAs from builds/"
    fi

    # ── Per-app: locate build → install → report Metro status ────────────────
    _any_installed=false
    for folder in "${MOBILE_APPS[@]}"; do
      _ios_app_dir="$MOBILE_DIR/$folder"

      # Skip if already installed from an IPA above
      for _slug in "${_installed_app_slugs[@]}"; do
        if [[ "$_slug" == "$folder" ]]; then
          echo ""
          echo "⏭️  Skipping '$folder' (already installed from IPA)"
          continue 2
        fi
      done

      _ios_app_to_install=""

      # 1. .app cached in builds/
      if [[ -d "$_builds_dir/${folder}.app" ]]; then
        _ios_app_to_install="$_builds_dir/${folder}.app"
      fi

      # 2. Local build output (ios/build/simulator) — produced by ./dev.sh build <app> ios local
      if [[ -z "$_ios_app_to_install" ]]; then
        _local_sim_build=$(find "$_ios_app_dir/ios/build/simulator/Build/Products" \
          -name "*.app" -not -path "*.dSYM*" -maxdepth 3 2>/dev/null | head -1 || true)
        [[ -n "$_local_sim_build" && -d "$_local_sim_build" ]] && \
          _ios_app_to_install="$_local_sim_build"
      fi

      # 3. DerivedData — scoped to this app's bundle ID to avoid cross-app collisions
      if [[ -z "$_ios_app_to_install" ]]; then
        _bid=$(node -e "
          try { const c=require('$_ios_app_dir/app.config.js'); const e=c.expo||c; console.log((e.ios&&e.ios.bundleIdentifier)||''); }
          catch(e) { try { const j=JSON.parse(require('fs').readFileSync('$_ios_app_dir/app.json','utf8')); const ex=j.expo||j; console.log((ex.ios&&ex.ios.bundleIdentifier)||''); } catch(e2){console.log('');} }
        " 2>/dev/null || true)
        while IFS= read -r _c; do
          [[ -z "$_c" ]] && continue
          # Skip empty .app stubs (Index.noindex builds only have Frameworks/, no binary)
          _c_binary=$(find "$_c" -maxdepth 1 -type f -perm +0111 2>/dev/null | head -1 || true)
          [[ -z "$_c_binary" ]] && continue
          _cbid=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$_c/Info.plist" 2>/dev/null \
            || defaults read "$_c/Info.plist" CFBundleIdentifier 2>/dev/null || true)
          # Match by bundle ID when known; fall back to first hit when unknown
          if [[ -n "$_bid" && "$_cbid" == "$_bid" ]] || [[ -z "$_bid" ]]; then
            _ios_app_to_install="$_c"; break
          fi
        done < <(find ~/Library/Developer/Xcode/DerivedData \
          -name "*.app" -path "*iphonesimulator*" -not -path "*.dSYM*" 2>/dev/null)
      fi

      if [[ -n "$_ios_app_to_install" && -d "$_ios_app_to_install" ]]; then
        echo ""
        echo "📲 Installing '$folder'..."
        xcrun simctl install "$_sim_udid" "$_ios_app_to_install" 2>/dev/null && {
          _ios_bundle_id=$(defaults read "$_ios_app_to_install/Info.plist" CFBundleIdentifier 2>/dev/null || true)
          [[ -n "$_ios_bundle_id" ]] && xcrun simctl launch "$_sim_udid" "$_ios_bundle_id" 2>/dev/null || true
          echo "   ✅ '$folder' installed and launched"
          _any_installed=true
        } || echo "   ⚠️  Failed to install '$folder'"
      fi
    done

    # ── Metro status (check only — use ./dev.sh mobile to start) ─────────────
    echo ""
    _port=8081
    for folder in "${MOBILE_APPS[@]}"; do
      if _port_in_use "$_port"; then
        echo "✅ Metro running for '$folder' on port $_port"
      else
        echo "ℹ️  Metro not running for '$folder' — start with: ./dev.sh mobile"
      fi
      _port=$((_port + 1))
    done

    echo ""
    echo "✅ Simulator: $_sim_name"
    [[ "$_any_installed" == "false" ]] && echo "   No builds found — run './dev.sh build <app> ios local' to build"
    ;;


  backup)
    # ── ./dev.sh backup [db] ─────────────────────────────────────────────────
    # backup      → full snapshot (DB + media) saved as .tar.gz in backend/backup/start/
    # backup db   → DB-only backup (.sql.gz) saved in backend/backup/start/
    #
    # Only ONE file is kept in start/ at a time — the new file replaces any
    # existing one.  Commit the file to git and production will auto-restore on
    # next deploy (backup.sh checks start/ on container startup).
    _BACKUP_SUBCOMMAND="${2:-full}"
    _BACKUP_START_DIR="$ROOT_DIR/backend/backup/start"
    _BACKUP_DIR="$ROOT_DIR/backend/backup"

    if [[ "$_BACKUP_SUBCOMMAND" == "list" ]]; then
      # ── List all backups ───────────────────────────────────────────────────
      echo ""
      echo "📦 Backups in backend/backup/start/  (committed to git → auto-restore on deploy)"
      echo "──────────────────────────────────────────────────────────────────"
      _found_start=false
      for f in "$_BACKUP_START_DIR"/backup_*.sql.gz "$_BACKUP_START_DIR"/snapshot_*.tar.gz; do
        [[ -f "$f" ]] || continue
        _found_start=true
        _fname=$(basename "$f")
        _size=$(du -sh "$f" 2>/dev/null | cut -f1)
        # Mark if it's the active seed (only file in start/)
        printf "  %-45s  %s\n" "$_fname" "$_size"
      done
      $_found_start || echo "  (none)"

      echo ""
      echo "🗄  Backups in backend/backup/  (local rotation, not committed)"
      echo "──────────────────────────────────────────────────────────────────"
      _found_local=false
      for f in "$_BACKUP_DIR"/backup_*.sql.gz "$_BACKUP_DIR"/snapshot_*.tar.gz; do
        [[ -f "$f" ]] || continue
        _found_local=true
        _fname=$(basename "$f")
        _size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %-45s  %s\n" "$_fname" "$_size"
      done
      $_found_local || echo "  (none)"

      echo ""
      exit 0
    fi

    # Ensure db is running
    echo "🔍 Checking database is running..."
    if ! "$DC_CMD" -p "$PROJECT_NAME" "${COMPOSE_F[@]}" ps db 2>/dev/null | grep -q "running\|Up\|healthy"; then
      echo "⚠️  Database is not running. Starting core services first..."
      dc_up_ordered
      echo "⏳ Waiting for database to be healthy..."
      sleep 5
    fi

    if [[ "$_BACKUP_SUBCOMMAND" == "db" ]]; then
      # ── DB-only backup ────────────────────────────────────────────────────
      echo ""
      echo "💾 Creating DB-only backup..."
      echo "   This runs pg_dump inside a temporary container — no local postgres needed."
      echo ""

      _BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
      _BACKUP_OUTFILE="backup_${_BACKUP_TIMESTAMP}.sql.gz"

      # Use podman run directly — join the compose network so the temp container
      # can reach the db service by hostname.
      _DB_NETWORK="${PROJECT_NAME}_default"

      podman run --rm \
        -e PGPASSWORD="${DB_PASSWORD:-postgres}" \
        -v "$ROOT_DIR/backend:/backend" \
        --network "$_DB_NETWORK" \
        postgres:17 \
        sh -c "
          pg_dump \
            --host='${DB_HOST:-db}' \
            --port='${DB_PORT:-5432}' \
            --username='${DB_USER:-postgres}' \
            --dbname='${DB_NAME:-postgres}' \
            --clean --if-exists --encoding=UTF8 \
            | gzip > '/backend/backup/${_BACKUP_OUTFILE}' &&
          echo '✅ DB backup written: ${_BACKUP_OUTFILE}'
        "

      _BACKUP_FULL_PATH="$ROOT_DIR/backend/backup/${_BACKUP_OUTFILE}"
      if [[ ! -f "$_BACKUP_FULL_PATH" ]]; then
        echo "❌ Backup failed — file not found at: $_BACKUP_FULL_PATH"
        exit 1
      fi

      echo "📂 Moving to backend/backup/start/ (clearing any previous seed)..."
      find "$_BACKUP_START_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete
      mv "$_BACKUP_FULL_PATH" "$_BACKUP_START_DIR/${_BACKUP_OUTFILE}"

      echo ""
      echo "✅ DB backup saved to: backend/backup/start/${_BACKUP_OUTFILE}"
      echo ""
      echo "   Next steps:"
      echo "     git add backend/backup/start/${_BACKUP_OUTFILE}"
      echo "     git commit -m 'chore: update seed DB backup'"
      echo "     git push"
      echo ""
      echo "   Production will auto-restore this backup on the next deploy."

    else
      # ── Full snapshot (DB + media) ────────────────────────────────────────
      echo ""
      echo "📦 Creating full snapshot (DB + media)..."
      echo "   This runs inside a temporary container — no local postgres needed."
      echo ""

      _BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

      # Use podman run directly — join the compose network so the temp container
      # can reach the db service by hostname.
      # Podman-compose uses underscores: <project>_default
      _DB_NETWORK="${PROJECT_NAME}_default"

      podman run --rm \
        -e DB_HOST="${DB_HOST:-db}" \
        -e DB_PORT="${DB_PORT:-5432}" \
        -e DB_NAME="${DB_NAME:-postgres}" \
        -e DB_USER="${DB_USER:-postgres}" \
        -e DB_PASSWORD="${DB_PASSWORD:-postgres}" \
        -e DJANGO_DEBUG="true" \
        -e FULL_BACKUP="true" \
        -v "$ROOT_DIR/backend:/backend" \
        --network "$_DB_NETWORK" \
        postgres:17 \
        sh -c "
          apt-get update -qq > /dev/null 2>&1 &&
          apt-get install -y -qq gzip tar cpio > /dev/null 2>&1 &&
          /backend/backup/backup.sh snapshot
        "

      _LATEST_SNAPSHOT=$(ls -1t "$ROOT_DIR/backend/backup"/snapshot_*.tar.gz 2>/dev/null | head -1)
      if [[ -z "$_LATEST_SNAPSHOT" ]]; then
        echo "❌ Snapshot failed — no snapshot_*.tar.gz found in backend/backup/"
        exit 1
      fi

      _SNAPSHOT_FILENAME=$(basename "$_LATEST_SNAPSHOT")

      echo "📂 Moving to backend/backup/start/ (clearing any previous seed)..."
      find "$_BACKUP_START_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete
      mv "$_LATEST_SNAPSHOT" "$_BACKUP_START_DIR/${_SNAPSHOT_FILENAME}"

      echo ""
      echo "✅ Full snapshot saved to: backend/backup/start/${_SNAPSHOT_FILENAME}"
      echo ""
      echo "   Next steps:"
      echo "     git add backend/backup/start/${_SNAPSHOT_FILENAME}"
      echo "     git commit -m 'chore: update seed snapshot'"
      echo "     git push"
      echo ""
      echo "   Production will auto-restore this snapshot on the next deploy."
    fi
    ;;

  qr)
    # ── ./dev.sh qr [app-name] ──────────────────────────────────────────────────
    # Display QR codes for a specific mobile app or all apps
    APP_NAME="${2:-}"

    if [[ -z "$APP_NAME" ]]; then
      # No app specified - show QR codes for all apps
      discover_apps
      if [[ ${#MOBILE_APPS[@]} -eq 0 ]]; then
        echo "❌ No mobile apps found in $MOBILE_DIR"
        exit 1
      fi
      _print_mobile_qrs
    else
      # Show QR codes for specific app by running show-qr.sh
      if [[ ! -f "$ROOT_DIR/show-qr.sh" ]]; then
        echo "❌ show-qr.sh script not found"
        exit 1
      fi
      bash "$ROOT_DIR/show-qr.sh" "$APP_NAME"
    fi
    ;;

  *)
    # Default behavior: start core services (works even without mobile config)
    echo "🚀 Starting core services..."
    dc_up_ordered
    if has_mobile_apps; then run_mobile; fi
    _start_cloudflare_tunnel
    _start_tunnel_watchdog
    _start_healthcheck_runner
    echo ""
    echo "✅ Services started in the background."
    _draw_status
    ;;
esac
