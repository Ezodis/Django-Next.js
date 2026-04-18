#!/usr/bin/env bash
# dev.sh — Cross-platform dev launcher (macOS, Linux, Windows WSL/Git Bash)
#
# macOS prerequisite: Install Xcode from the App Store, then:
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# Usage:
#   ./dev.sh            — smart launch:
#                                  • First run / everything down → build all, start all, open Android emulator, install all apps
#                                  • Some services down          → rebuild + restart only broken services
#                                  • Everything running          → show live status + follow logs
#   ./dev.sh rebuild    — nuclear clean rebuild: stop all, wipe images/volumes/cache, rebuild everything fresh
#   ./dev.sh setup      — install all dependencies
#   ./dev.sh build      — build Podman images only
#   ./dev.sh build <app> [android|ios] --local — build native APK/IPA locally
#   ./dev.sh up         — start core + mobile services
#   ./dev.sh core       — start core services only (no mobile)
#   ./dev.sh mobile     — start only mobile services
#   ./dev.sh release    — build release AABs
#   ./dev.sh release --setup — generate release keystores
#   ./dev.sh init       — one-time scaffold
#   ./dev.sh stop       — stop all containers (keeps images/volumes/cache)
#   ./dev.sh down       — stop + wipe everything: images, volumes, cache (full reset)
#   ./dev.sh logs       — follow logs
#   ./dev.sh status     — follow containers status

set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/dev.yml"
MOBILE_DIR="$ROOT_DIR/frontend/mobile"

# Always declare MOBILE_APPS so it exists as an array
MOBILE_APPS=()

export DOCKER_CONFIG="$ROOT_DIR/.docker"
export DOCKER_BUILDKIT=1

# Project name derived from the repo folder (lowercase, alphanumeric only)
PROJECT_NAME="$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"

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

_default_android_sdk() {
  case "$OS" in
    mac)     echo "$HOME/Library/Android/sdk" ;;
    linux)   echo "$HOME/Android/Sdk" ;;
    wsl)     echo "$HOME/Android/Sdk" ;;
    windows) echo "$HOME/AppData/Local/Android/Sdk" ;;
    *)       echo "$HOME/Android/Sdk" ;;
  esac
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
        brew install podman
      else
        echo "✅ Podman already installed ($(podman --version))"
      fi

      # podman-compose
      if ! command -v podman-compose &>/dev/null; then
        echo "📦 Installing podman-compose..."
        brew install podman-compose
      else
        echo "✅ podman-compose already installed"
      fi

      # docker-compose (more reliable than podman-compose for up -d on macOS)
      if ! command -v docker-compose &>/dev/null; then
        echo "📦 Installing docker-compose..."
        brew install docker-compose
      else
        echo "✅ docker-compose already installed"
      fi

      # Podman machine
      if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
        if ! podman machine list 2>/dev/null | grep -q "default"; then
          echo "🖥️  Creating Podman machine..."
          podman machine init --cpus 4 --memory 8192 --disk-size 60
        fi
        echo "🚀 Starting Podman machine..."
        podman machine start
      else
        echo "✅ Podman machine already running"
      fi

      # Java (required for Android SDK tools)
      # Check /usr/libexec/java_home first, then scan Homebrew openjdk paths
      _find_java_home_mac() {
        local jh
        jh="$(/usr/libexec/java_home 2>/dev/null || true)"
        [ -n "$jh" ] && [ -x "$jh/bin/java" ] && echo "$jh" && return
        for vm in /Library/Java/JavaVirtualMachines/*/Contents/Home \
                  /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                  /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
          [ -x "$vm/bin/java" ] && echo "$vm" && return
        done
      }
      _JAVA_HOME="$(_find_java_home_mac)"
      if [ -z "$_JAVA_HOME" ]; then
        echo "📦 Installing Java (Temurin)..."
        brew install --cask temurin
        _JAVA_HOME="$(_find_java_home_mac)"
      else
        echo "✅ Java already installed ($_JAVA_HOME)"
      fi
      export JAVA_HOME="${_JAVA_HOME:-}"
      [ -n "$JAVA_HOME" ] && export PATH="$JAVA_HOME/bin:$PATH"

      # Node.js
      if ! command -v node &>/dev/null; then
        echo "�� Installing Node.js..."
        brew install node
      else
        echo "✅ Node.js already installed ($(node --version))"
      fi
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
        if command -v pip3 &>/dev/null; then pip3 install --user podman-compose
        elif command -v pip &>/dev/null; then pip install --user podman-compose
        else echo "❌ pip not found. Install Python first."; exit 1
        fi
        export PATH="$HOME/.local/bin:$PATH"
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
      ;;

    windows)
      echo "🪟 Windows detected (Git Bash / MSYS2)"
      PKG_MGR=""
      if command -v winget &>/dev/null; then PKG_MGR="winget"; fi
      if command -v scoop  &>/dev/null; then PKG_MGR="scoop";  fi
      if command -v choco  &>/dev/null; then PKG_MGR="choco";  fi
      if [[ -z "$PKG_MGR" ]]; then
        echo "⚠️  No package manager found. Install Scoop: https://scoop.sh"
        exit 1
      fi
      echo "   Using: $PKG_MGR"

      if ! command -v podman &>/dev/null; then
        echo "📦 Installing Podman..."
        case "$PKG_MGR" in
          winget) winget install -e --id RedHat.Podman ;;
          scoop)  scoop install podman ;;
          choco)  choco install podman -y ;;
        esac
      else
        echo "✅ Podman already installed ($(podman --version))"
      fi

      if ! command -v podman-compose &>/dev/null; then
        echo "📦 Installing podman-compose..."
        pip3 install podman-compose || { echo "❌ pip3 not found."; exit 1; }
      else
        echo "✅ podman-compose already installed"
      fi

      if command -v podman &>/dev/null; then
        if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
          if ! podman machine list 2>/dev/null | grep -q "default"; then
            echo "🖥️  Creating Podman machine..."
            podman machine init --cpus 4 --memory 8192 --disk-size 60
          fi
          echo "🚀 Starting Podman machine..."
          podman machine start
        else
          echo "✅ Podman machine already running"
        fi
      fi

      if ! command -v git &>/dev/null; then
        echo "📦 Installing Git..."
        case "$PKG_MGR" in
          winget) winget install -e --id Git.Git ;;
          scoop)  scoop install git ;;
          choco)  choco install git -y ;;
        esac
      else
        echo "✅ Git already installed ($(git --version))"
      fi

      if ! command -v node &>/dev/null; then
        echo "📦 Installing Node.js..."
        case "$PKG_MGR" in
          winget) winget install -e --id OpenJS.NodeJS.LTS ;;
          scoop)  scoop install nodejs-lts ;;
          choco)  choco install nodejs-lts -y ;;
        esac
      else
        echo "✅ Node.js already installed ($(node --version))"
      fi
      ;;

    *)
      echo "❌ Unsupported OS: $_UNAME"
      exit 1
      ;;
  esac

  # ── Install anything listed in dev.txt that isn't already present ──────────
  local dev_reqs="$ROOT_DIR/backend/requirements/dev.txt"
  if [[ -f "$dev_reqs" ]] && command -v brew &>/dev/null; then
    while IFS= read -r line; do
      # Strip comments and blank lines
      line="${line%%#*}"; line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue

      if [[ "$line" == brew:* ]]; then
        local formula="${line#brew:}"
        if ! brew list --formula "$formula" &>/dev/null 2>&1; then
          echo "📦 Installing $formula..."
          brew install "$formula"
        else
          echo "✅ $formula already installed"
        fi

      elif [[ "$line" == brew-cask:* ]]; then
        local cask="${line#brew-cask:}"
        if ! brew list --cask "$cask" &>/dev/null 2>&1; then
          echo "📦 Installing $cask (cask)..."
          brew install --cask "$cask"
        else
          echo "✅ $cask already installed"
        fi
      fi
      # custom: entries are handled by the OS-specific blocks above — skip here
    done < "$dev_reqs"
  fi

  _wire_podman_socket

  echo ""
  echo "✅ All dependencies ready!"
  command -v podman         &>/dev/null && echo "   Podman:         $(podman --version)"
  command -v podman-compose &>/dev/null && echo "   podman-compose: $(podman-compose --version 2>/dev/null | head -1)"
  command -v node           &>/dev/null && echo "   Node:           $(node --version)"
  command -v git            &>/dev/null && echo "   Git:            $(git --version)"
  command -v tmux           &>/dev/null && echo "   tmux:           $(tmux -V)"
  echo ""

}

# ── Wire Podman socket ────────────────────────────────────────────────────────
_wire_podman_socket() {
  if ! command -v podman &>/dev/null; then return; fi
  case "$OS" in
    mac|windows)
      local sock
      sock="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo "")"
      if [[ -n "$sock" ]]; then
        export DOCKER_HOST="unix://$sock"
      fi
      # Use the root Podman socket inside the VM (world-readable, accessible by containers)
      # export PODMAN_SOCK="/run/podman/podman.sock"  # no longer needed (file provider used)
      ;;
    linux|wsl)
      local uid_sock="/run/user/$(id -u)/podman/podman.sock"
      if [[ -S "$uid_sock" ]]; then
        export DOCKER_HOST="unix://$uid_sock"
        export PODMAN_SOCK="$uid_sock"
      fi
      ;;
  esac
}

# ── Detect compose command ────────────────────────────────────────────────────
detect_compose() {
  if command -v docker-compose &>/dev/null; then
    DC_CMD="docker-compose"
  elif command -v podman-compose &>/dev/null; then
    DC_CMD="podman-compose"
  elif docker compose version &>/dev/null 2>&1; then
    DC_CMD="docker compose"
  else
    echo "❌ No compose tool found. Run: ./dev.sh setup"
    exit 1
  fi
  _wire_podman_socket
}

# ── Ensure Podman machine is running ─────────────────────────────────────────
ensure_podman_running() {
  if ! command -v podman &>/dev/null; then return; fi
  case "$OS" in
    mac|windows)
      if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
        echo "🚀 Starting Podman machine..."
        podman machine start
        # Wait for socket to be ready (up to 30s)
        local waited=0
        while [[ $waited -lt 30 ]]; do
          if podman ps >/dev/null 2>&1; then
            break
          fi
          sleep 2; waited=$((waited + 2))
        done
      fi
      ;;
  esac
}

# ── Entry point ───────────────────────────────────────────────────────────────
CMD="${1:-}"

if [[ "$CMD" == "setup" ]]; then
  run_setup
  exit 0
fi

# Commands that don't need dependency checks or app discovery preamble
_SKIP_SETUP=false
case "$CMD" in
  status|logs|down|stop|rebuild|_status_only|service-logs) _SKIP_SETUP=true ;;
esac

_deps_installed() {
  command -v podman         &>/dev/null || return 1
  command -v podman-compose &>/dev/null || command -v docker-compose &>/dev/null || return 1
  command -v node           &>/dev/null || return 1
  command -v git            &>/dev/null || return 1
  return 0
}

if [[ "$_SKIP_SETUP" == "false" ]]; then
  if ! _deps_installed; then
    run_setup
  fi
  if [[ -d "$MOBILE_DIR" ]]; then
    node "$MOBILE_DIR/scripts/gen-app-json.js" 2>/dev/null || true
  fi
fi

# stop/down — handle early before ensure_podman_running
if [[ "$CMD" == "stop" || "$CMD" == "down" ]]; then
  _wire_podman_socket
  detect_compose

  echo "🛑 Stopping all services..."
  podman stop $(podman ps -q) 2>/dev/null || true
  podman rm   $(podman ps -aq) 2>/dev/null || true
  podman network rm "${PROJECT_NAME}_default" 2>/dev/null || true
  echo "✅ All services stopped."

  if [[ "$CMD" == "down" ]]; then
    echo ""
    echo "🗑️  Removing project images..."
    podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" \
      | xargs -r podman rmi -f 2>/dev/null || true

    echo "🗑️  Removing project volumes..."
    podman volume ls --format '{{.Name}}' 2>/dev/null \
      | grep -E "^${PROJECT_NAME}_" \
      | xargs -r podman volume rm 2>/dev/null || true

    echo "🗑️  Pruning build cache..."
    podman system prune -f --volumes 2>/dev/null || true

    rm -f "/tmp/${PROJECT_NAME}-mobile-compose.yml" "/tmp/${PROJECT_NAME}-compose.log" "/tmp/${PROJECT_NAME}-mobile.log"

    echo ""
    echo "✅ Everything wiped. Run ./dev.sh to start fresh."
  fi
  exit 0
fi

ensure_podman_running
detect_compose
_wire_podman_socket
DC="$DC_CMD -f $COMPOSE_FILE"

# ── Mobile app discovery ──────────────────────────────────────────────────────
discover_apps() {
  MOBILE_APPS=()
  [[ -d "$MOBILE_DIR" ]] || return
  while IFS= read -r -d '' dir; do
    local name
    name=$(basename "$dir")
    [[ "$name" == "node_modules" || "$name" == "shared" ]] && continue
    [[ -f "$dir/package.json" ]] || continue
    MOBILE_APPS+=("$name")
  done < <(find "$MOBILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
}

has_mobile_apps() {
  discover_apps
  [[ ${#MOBILE_APPS[@]} -gt 0 ]]
}

folder_to_service() {
  echo "mobile-$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
}

gen_mobile_yaml() {
  discover_apps
  local port=8081

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
    echo "      REACT_NATIVE_PACKAGER_HOSTNAME: \"\${REACT_NATIVE_PACKAGER_HOSTNAME:-10.0.2.2}\""
    echo "      EXPO_PUBLIC_API_URL: \"\${EXPO_PUBLIC_API_URL:-http://10.0.2.2:8000}\""
    echo "      EXPO_PUBLIC_ENV: \"development\""
    echo "      NODE_ENV: \"development\""
    echo "      NODE_OPTIONS: \"--max-old-space-size=4096\""
    echo "      EXPO_NO_INSPECTOR_PROXY: \"1\""
    echo "    volumes:"
    for vdir in "${MOBILE_APPS[@]}"; do
      # Map spaced folder name to slug path inside container
      local vslug
      vslug=$(echo "$vdir" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      echo "      - \"${ROOT_DIR}/frontend/mobile/${vdir}:/app/${vslug}:delegated\""
    done
    echo "      - \"${ROOT_DIR}/frontend/mobile/shared:/app/shared:delegated\""
    echo "      - /app/node_modules"
    echo "    ports:"
    echo "      - \"${port}:8081\""
    echo "    depends_on:"
    echo "      backend:"
    echo "        condition: service_healthy"
    echo "    healthcheck:"
    echo "      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:8081\"]"
    echo "      interval: 10s"
    echo "      timeout: 5s"
    echo "      retries: 5"
    echo "      start_period: 60s"
    echo "    labels:"
    echo "      - \"traefik.enable=false\""
    echo "    restart: on-failure"
    echo "    stdin_open: true"
    echo "    tty: true"
    port=$((port + 1))
  done
}

# ── Start services detached (survives terminal close on macOS + Linux) ────────
dc_up_detached() {
  # Redirect stdin to /dev/null so the process has no controlling terminal.
  # This is the portable macOS+Linux alternative to setsid.
  nohup $DC_CMD -f "$COMPOSE_FILE" up -d "$@" \
    </dev/null >>"/tmp/${PROJECT_NAME}-compose.log" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  # Wait up to 30s for at least one of the requested containers to appear
  local i=0
  while [[ $i -lt 30 ]]; do
    if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_NAME}"; then
      break
    fi
    sleep 1; i=$((i+1))
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
  $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" "$@"
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

_draw_status() {
  discover_apps
  local log_base="http://localhost:19999"
  _STATUS_ROWS=()

  printf "\n"
  printf "  \033[1;34m⬡ edy.chat\033[0m\n"
  printf "\n"

  local _row_idx=1

  _srow() {
    local label="$1" cname="$2" svc_url="$3"
    local state health dot color badge
    state=$(podman inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")
    health=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cname" 2>/dev/null || echo "-")
    case "$state" in
      running)
        case "$health" in
          healthy)  dot="●" color="\033[32m" badge="healthy"  ;;
          starting) dot="◐" color="\033[33m" badge="starting" ;;
          *)        dot="●" color="\033[32m" badge="running"  ;;
        esac ;;
      exited|stopped) dot="●" color="\033[31m" badge="stopped" ;;
      missing)        dot="○" color="\033[2;37m" badge="missing" ;;
      *)              dot="◐" color="\033[33m"   badge="$state"  ;;
    esac

    local log_url="$log_base/logs/$cname"
    [[ -n "$svc_url" ]] && log_url="${log_url}?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$svc_url" 2>/dev/null || true)"

    # Store row metadata for key-handler
    _STATUS_ROWS+=("${label}|${cname}|${svc_url}|${log_url}")

    # Compact row: dot  idx  label  badge — truncate label to fit narrow panes
    local _cols; _cols=$(tput cols 2>/dev/null || echo 80)
    # Left pane is ~35% of terminal; clamp label width between 8 and 16 chars
    local _pane_w=$(( _cols * 35 / 100 ))
    local _lw=$(( _pane_w - 14 ))   # subtract dot(1)+spaces(3)+idx(1)+spaces(2)+badge(8)
    [[ $_lw -lt 8  ]] && _lw=8
    [[ $_lw -gt 16 ]] && _lw=16
    # Truncate label if needed
    local _lbl="$label"
    if [[ ${#_lbl} -gt $_lw ]]; then
      _lbl="${_lbl:0:$(( _lw - 1 ))}…"
    fi
    printf "  ${color}${dot}\033[0m \033[2m%s\033[0m %-${_lw}s ${color}%s\033[0m\n" \
      "$_row_idx" "$_lbl" "$badge"
    _row_idx=$(( _row_idx + 1 ))
  }

  _srow "traefik"     "${PROJECT_NAME}_traefik_1"              "http://localhost:8080"
  _srow "database"    "${PROJECT_NAME}_db_1"                   ""
  _srow "backend"     "${PROJECT_NAME}_backend_1"              "http://localhost:8000"
  _srow "frontend"    "${PROJECT_NAME}_frontend_1"             "http://localhost:3000"

  local mport=8081
  for folder in "${MOBILE_APPS[@]}"; do
    local svc; svc=$(folder_to_service "$folder")
    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    _srow "$slug" "${PROJECT_NAME}_${svc}_1" "http://localhost:${mport}"
    mport=$((mport + 1))
  done

  printf "\n"
  printf "  \033[2m[1-9] logs  [0] all  [o+n] browser\033[0m\n"
  printf "  \033[2mCtrl+C quit\033[0m\n"
  printf "\n"
}

# ── Log viewer server (port 19999) ────────────────────────────────────────────
_start_log_server() {
  pkill -f "${PROJECT_NAME}-log-server" 2>/dev/null || true
  # Also kill anything holding port 19999
  lsof -ti:19999 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
  python3 - <<'PYEOF' &
import http.server, subprocess, sys, os
from urllib.parse import urlparse, parse_qs, unquote

PORT = 19999

HTML = """<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Logs: {n}</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:#0d1117;color:#e6edf3;font:13px/1.6 'SF Mono',monospace;display:flex;flex-direction:column;height:100vh}}
header{{padding:10px 16px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;gap:12px;flex-shrink:0;flex-wrap:wrap}}
.back{{color:#8b949e;text-decoration:none;font-size:12px;white-space:nowrap}}
.back:hover{{color:#58a6ff}}
h1{{font-size:13px;font-weight:600;color:#58a6ff;flex:1}}
.svc-url{{font-size:11px;color:#8b949e;text-decoration:none;border:1px solid #30363d;padding:2px 8px;border-radius:4px;white-space:nowrap}}
.svc-url:hover{{color:#58a6ff;border-color:#58a6ff}}
#log{{flex:1;overflow-y:auto;padding:12px 16px;white-space:pre-wrap;word-break:break-all;font-size:12px}}
</style></head><body>
<header>
  <a class="back" href="javascript:history.back()">← back</a>
  <h1>📋 {n}</h1>
  {url_btn}
</header>
<div id="log"></div>
<script>
const d=document.getElementById('log');
let stick=true;
d.addEventListener('scroll',()=>{{stick=d.scrollTop+d.clientHeight>=d.scrollHeight-40}});
new EventSource('/stream/{n}').onmessage=e=>{{
  const p=document.createElement('div');
  p.textContent=e.data;
  d.appendChild(p);
  if(stick)d.scrollTop=d.scrollHeight;
}};
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path.startswith('/logs/'):
            n = path[6:]
            svc_url = qs.get('url', [''])[0]
            url_btn = ''
            if svc_url:
                url_btn = f'<a class="svc-url" href="{svc_url}" target="_blank">↗ {svc_url}</a>'
            self.send_response(200)
            self.send_header('Content-Type','text/html;charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML.format(n=n, url_btn=url_btn).encode())

        elif path.startswith('/stream/'):
            n = path[8:]
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Cache-Control','no-cache')
            self.end_headers()
            try:
                p=subprocess.Popen(['podman','logs','-f','--names',n],
                    stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
                for line in p.stdout:
                    self.wfile.write(b'data: '+line.rstrip()+b'\n\n')
                    self.wfile.flush()
            except:pass
        else:
            self.send_response(404);self.end_headers()

sys.argv[0]='${PROJECT_NAME}-log-server'
os.setpgrp()
class ReuseServer(http.server.HTTPServer):
    allow_reuse_address = True
srv = ReuseServer(('127.0.0.1',PORT),H)
srv.serve_forever()
PYEOF
  disown
}

# Count lines _draw_status produces
_status_line_count() {
  discover_apps
  # blank(1) + title(1) + blank(1) + 4 core + mobile + blank(1) + hint1(1) + hint2(1) + blank(1)
  echo $(( 8 + 4 + ${#MOBILE_APPS[@]} ))
}

live_monitor() {
  local session="${PROJECT_NAME}-dev"
  local logfile="/tmp/${PROJECT_NAME}-all.log"
  local urlmap="/tmp/${PROJECT_NAME}-urlmap-$$.tsv"

  # ── No-tmux fallback ──────────────────────────────────────────────────────
  if ! command -v tmux &>/dev/null; then
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null; tput ed 2>/dev/null; exit 0' INT TERM
    while true; do
      tput cup 0 0
      MOBILE_APPS=(); _draw_status
      tput ed 2>/dev/null || true
      sleep 3
    done
    return
  fi
  # ── Write self-contained left-pane script ─────────────────────────────────
  local ms="/tmp/${PROJECT_NAME}-mon-$$.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export DOCKER_HOST=%q\n' "${DOCKER_HOST:-}"
    printf 'ROOT_DIR=%q\n'   "$ROOT_DIR"
    printf 'MOBILE_DIR=%q\n' "$MOBILE_DIR"
    printf 'URLMAP=%q\n'     "$urlmap"
    declare -f folder_to_service
    declare -f discover_apps
    declare -f _draw_status
    # The rest is literal — single-quoted heredoc inside the { } block
    cat <<'PANE_SCRIPT'
MOBILE_APPS=()
_STATUS_ROWS=()
printf "\033[?25l"
trap "printf \"\033[?25h\"; exit 0" INT TERM

# After every draw, flush _STATUS_ROWS to the urlmap file so the
# tmux key-handler can look up container names and URLs by number.
_flush_urlmap() {
  : > "$URLMAP"
  local _i=0
  for _row in "${_STATUS_ROWS[@]}"; do
    _i=$(( _i + 1 ))
    local _label _cname _surl _lurl
    _label=$(printf '%s' "$_row" | cut -d'|' -f1)
    _cname=$(printf '%s' "$_row" | cut -d'|' -f2)
    _surl=$(printf '%s'  "$_row" | cut -d'|' -f3)
    _lurl=$(printf '%s'  "$_row" | cut -d'|' -f4)
    printf '%s\t%s\t%s\t%s\n' "$_i" "$_cname" "$_surl" "$_lurl" >> "$URLMAP"
  done
}

while true; do
  tput cup 0 0
  MOBILE_APPS=()
  _STATUS_ROWS=()
  _draw_status
  _flush_urlmap
  tput ed 2>/dev/null || true
  sleep 3
done
PANE_SCRIPT
  } > "$ms"
  chmod +x "$ms"

  # ── Launch tmux ───────────────────────────────────────────────────────────
  tmux kill-session -t "$session" 2>/dev/null || true
  _start_log_server

  tmux set-option -g history-limit 50000 2>/dev/null || true

  tmux new-session -d -s "$session" \
    -x "$(tput cols)" -y "$(tput lines)" \
    "bash '$ms'"

  # Right pane (62%): scrollable logs
  tmux split-window -t "$session:0.0" -h -p 62

  # Stream all container logs into a file, view with less +F (scrollable)
  : > "$logfile"
  local cname
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    tmux send-keys -t "$session:0.1" \
      "podman logs -f --names '$cname' >> '$logfile' 2>&1 &" Enter
  done < <(podman ps --format '{{.Names}}' 2>/dev/null | grep "^${PROJECT_NAME}_" || true)
  tmux send-keys -t "$session:0.1" "tail -f '$logfile'" Enter

  # ── Style ─────────────────────────────────────────────────────────────────
  tmux set-option -t "$session" status off
  tmux set-option -t "$session" pane-border-style        "fg=#30363d"
  tmux set-option -t "$session" pane-active-border-style "fg=#58a6ff"
  tmux set-option -t "$session" pane-border-lines single
  tmux set-option -t "$session" mouse on
  # Show pane titles in the border
  tmux set-option -t "$session" pane-border-status top
  # Right pane title shows scroll position when scrolled up
  tmux set-option -t "$session" pane-border-format "#{?#{==:#{pane_index},1},#{?scroll_position, #{pane_title}  ↑ #{scroll_position} lines , #{pane_title} }, #{pane_title} }"
  tmux set-option -t "$session" status-interval 1
  tmux select-pane -t "$session:0.0" -T "Monitor"
  tmux select-pane -t "$session:0.1" -T "logs"
  # Disable the [0/0] window index display
  tmux set-option -t "$session" set-titles off 2>/dev/null || true
  # Mouse wheel enters copy-mode on right pane for scrolling
  tmux set-option -t "$session" -w mode-keys vi

  local _um="$urlmap"
  local _lf="$logfile"
  local _sess="$session"

  # ── Write a helper script that the key-bindings call ──────────────────────
  # Using a file avoids all inline quoting nightmares.
  local _ks="/tmp/${PROJECT_NAME}-keys-$$.sh"
  # Write the path variables (expand now), then the static body (quoted heredoc)
  printf '#!/usr/bin/env bash\nUM=%s\nLF=%s\nSESS=%s\n' \
    "$_um" "$_lf" "$_sess" > "$_ks"
  cat >> "$_ks" <<'KEYSCRIPT'
ACTION="$1"
N="$2"

case "$ACTION" in
  show)
    # Filter right pane to one service — no layout change, no zoom
    CNAME=$(awk -v n="$N" -F'\t' '$1==n{print $2; exit}' "$UM" 2>/dev/null)
    [ -z "$CNAME" ] && exit 0
    tmux send-keys -t "${SESS}:0.1" C-c ""
    sleep 0.2
    tmux send-keys -t "${SESS}:0.1" "clear; podman logs -f --names \"$CNAME\" 2>&1" Enter
    tmux select-pane -t "${SESS}:0.1" -T "$CNAME"
    ;;
  back)
    # Restore all-logs view — no layout change
    tmux send-keys -t "${SESS}:0.1" C-c ""
    sleep 0.2
    tmux send-keys -t "${SESS}:0.1" "tail -f \"$LF\"" Enter
    tmux select-pane -t "${SESS}:0.1" -T "logs"
    ;;
  click)
    PANE_IDX="$2"
    MOUSE_LINE="$3"
    # Always exit 0 — never show an error on click
    if [ "$PANE_IDX" = "0" ] && [ -n "$MOUSE_LINE" ]; then
      IDX=$(( MOUSE_LINE - 3 ))
      [ "$IDX" -ge 1 ] && bash "$0" show "$IDX"
    fi
    exit 0
    ;;
  open)
    URL=$(awk -v n="$N" -F'\t' '$1==n{print $3; exit}' "$UM" 2>/dev/null)
    [ -n "$URL" ] && open "$URL" 2>/dev/null &
    ;;
esac
exit 0
KEYSCRIPT
  chmod +x "$_ks"

  # ── Ctrl+C → kill the whole session ───────────────────────────────────────
  tmux bind-key -T root C-c run-shell "tmux kill-session -t '${_sess}' 2>/dev/null; true"

  # ── Mouse wheel + PgUp/PgDn: scroll right pane ──────────────────────────
  # WheelUp enters copy-mode; scroll position shows in pane title border
  tmux bind-key -T root WheelUpPane    run-shell "tmux copy-mode -t '${_sess}:0.1'; tmux send-keys -t '${_sess}:0.1' -X scroll-up"
  tmux bind-key -T root WheelDownPane  run-shell "tmux send-keys -t '${_sess}:0.1' -X scroll-down 2>/dev/null || true"
  tmux bind-key -T root PageUp         run-shell "tmux copy-mode -t '${_sess}:0.1'; tmux send-keys -t '${_sess}:0.1' -X halfpage-up"
  tmux bind-key -T root PageDown       run-shell "tmux send-keys -t '${_sess}:0.1' -X halfpage-down 2>/dev/null || true"
  # q or Escape exits copy-mode (back to live tail)
  tmux bind-key -T copy-mode-vi q      send-keys -X cancel
  tmux bind-key -T copy-mode-vi Escape send-keys -X cancel

  # ── Number keys 1-9: show service logs (works from either pane) ───────────
  # 0: go back to all-logs
  for _n in 1 2 3 4 5 6 7 8 9; do
    tmux bind-key -T root "$_n" run-shell "bash '${_ks}' show $_n"
  done
  tmux bind-key -T root "0" run-shell "bash '${_ks}' back"

  # ── Click a row in the left pane → show that service's logs ───────────────
  # Row layout: blank(1) title(2) blank(3) → services start at line 4
  # service index = mouse_line - 3
  tmux bind-key -T root MouseDown1Pane run-shell "bash '${_ks}' click #{pane_index} #{mouse_line}"

  # ── o+number → open service URL in browser ────────────────────────────────
  tmux bind-key -T root o switch-client -T open_svc_t
  for _n in 1 2 3 4 5 6 7 8 9; do
    tmux bind-key -T open_svc_t "$_n" run-shell "bash '${_ks}' open $_n"
  done
  tmux attach-session -t "$session"

  tmux kill-session -t "$session" 2>/dev/null || true
  pkill -f "${PROJECT_NAME}-log-server" 2>/dev/null || true
  rm -f "$logfile" "$ms" "$urlmap" "${ms}.bak" /tmp/${PROJECT_NAME}-keys-*.sh
}


# ── Single-service log view ────────────────────────────────────────────────────
# Usage: ./dev.sh service-logs <container_name>
# When inside the dev tmux session: zooms to full window, any key restores
# When outside tmux: full-screen log view, Ctrl+C to exit
_service_log_view() {
  local cname="$1"
  [[ -z "$cname" ]] && return 1
  local session="${PROJECT_NAME}-dev"

  # ── Inside the tmux session: zoom to full window ───────────────────────────
  if [[ "${TMUX_PANE:-}" != "" ]] && [[ "$(tmux display-message -p '#S' 2>/dev/null)" == "$session" ]]; then
    # Kill current log jobs in bottom pane, replace with single-service logs
    tmux send-keys -t "$session:0.1" C-c "" Enter
    tmux send-keys -t "$session:0.1" \
      "clear; printf '\033[1m  📋 $cname\033[0m  \033[2m— press q or Ctrl+C to go back\033[0m\n\n'; podman logs -f --names '$cname' 2>/dev/null" \
      Enter
    # Zoom the bottom pane to full window
    tmux resize-pane -t "$session:0.1" -Z
    # Wait for q or Ctrl+C in the bottom pane, then unzoom and restore all logs
    tmux select-pane -t "$session:0.1"
    return 0
  fi

  # ── Outside tmux: plain full-screen view ──────────────────────────────────
  tput smcup 2>/dev/null
  tput civis 2>/dev/null
  trap '
    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
    echo ""
    exit 0
  ' INT TERM
  clear
  printf '\033[1m  📋 Logs: %s\033[0m  \033[2m(Ctrl+C to exit)\033[0m\n\n' "$cname"
  podman logs -f --names "$cname" 2>/dev/null
}

run_mobile() {
  if has_mobile_apps; then
    local services
    services=$(mobile_service_names)
    echo "📱 Starting mobile services: $services"
    # Write a stable mobile compose file so the detached process can reference it
    local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
    gen_mobile_yaml > "$yml_file"
    # Redirect stdin to /dev/null — portable macOS+Linux detachment (no setsid needed)
    # shellcheck disable=SC2086
    nohup $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" up -d $services \
      </dev/null >>/tmp/${PROJECT_NAME}-mobile.log 2>&1 &
    disown
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

    if [[ ! -f "$gradlew" ]]; then
      echo "⚠️  No android/gradlew for '$folder' — skipping native build."
      continue
    fi

    local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local apk_out="$OUTPUT_DIR/${slug}-android.apk"

    echo ""
    echo "========================================="
    echo "🔨 Building native APK: $folder"
    echo "========================================="

    # Write local.properties so Gradle can find the SDK
    echo "sdk.dir=$ANDROID_HOME" > "$android_dir/local.properties"
    chmod +x "$gradlew"

    # Clean previous build output so we get a truly fresh APK
    "$gradlew" -p "$android_dir" clean 2>&1 || true

    if "$gradlew" -p "$android_dir" assembleDebug 2>&1; then
      local built_apk
      built_apk=$(find "$android_dir/app/build/outputs/apk/debug" -name "*.apk" 2>/dev/null | head -1)
      if [[ -n "$built_apk" ]]; then
        cp "$built_apk" "$apk_out"
        echo "✅ $folder → frontend/mobile/builds/${slug}-android.apk"
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
    echo "   ./dev.sh build <app> android --local"
  fi
}

# ── Follow logs for all running project containers in parallel ───────────────
_follow_logs() {
  local pids=() cname
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    podman logs -f --names "$cname" 2>/dev/null &
    pids+=($!)
  done < <(podman ps --format '{{.Names}}' 2>/dev/null | grep "^${PROJECT_NAME}_")

  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "⚠️  No running containers found."
    return
  fi

  trap 'kill "${pids[@]}" 2>/dev/null; trap - INT TERM; echo ""' INT TERM
  wait "${pids[@]}" 2>/dev/null
  trap - INT TERM
}

# ── Open browser + Android emulator with all apps ────────────────────────────
_open_devtools() {
  # Safari at localhost — only if not already showing localhost
  if [[ "$OS" == "mac" ]]; then
    local already_open
    already_open=$(osascript 2>/dev/null <<'ASEOF'
tell application "Safari"
  set urlList to {}
  repeat with w in windows
    repeat with t in tabs of w
      set end of urlList to URL of t
    end repeat
  end repeat
  repeat with u in urlList
    if u starts with "http://localhost" or u starts with "https://localhost" then
      return "yes"
    end if
  end repeat
  return "no"
end tell
ASEOF
    ) || true
    if [[ "$already_open" != "yes" ]]; then
      open -a Safari "http://localhost" 2>/dev/null || true
    fi
  fi

  # Android emulator — start if not already running (only when mobile apps exist)
  has_mobile_apps || return 0
  _setup_android_path
  command -v adb &>/dev/null || return 0
  command -v emulator &>/dev/null || return 0

  local device
  device=$(adb devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1 || true)
  if [[ -z "$device" ]]; then
    device=$(_ensure_emulator)
    [[ -n "$device" ]] && _EMULATOR_JUST_STARTED=1
  fi
  [[ -n "$device" ]] || return 0

  # Install + launch all apps (only if emulator was just started this session)
  [[ -n "${_EMULATOR_JUST_STARTED:-}" ]] || return 0
  discover_apps
  for folder in "${MOBILE_APPS[@]}"; do
    local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    _install_app_on_emulator "$app_key" "$device"
  done
  return 0
}

# ── Rebuild helper (needs to be a function so `local` works) ─────────────────
_do_rebuild() {
  echo "🧨 Rebuild: stopping all services..."
  podman stop $(podman ps -q) 2>/dev/null || true
  podman rm   $(podman ps -aq) 2>/dev/null || true
  podman network rm ${PROJECT_NAME}_default 2>/dev/null || true

  echo "🗑️  Removing project images..."
  podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^(localhost/)?(${PROJECT_NAME}_|${PROJECT_NAME}-)" \
    | xargs -r podman rmi -f 2>/dev/null || true

  echo "🗑️  Removing project volumes..."
  podman volume ls --format '{{.Name}}' 2>/dev/null \
    | grep -E "^${PROJECT_NAME}_" \
    | xargs -r podman volume rm 2>/dev/null || true

  echo "🗑️  Pruning build cache..."
  podman system prune -f --volumes 2>/dev/null || true

  echo "🗑️  Clearing temp compose files..."
  rm -f /tmp/${PROJECT_NAME}-mobile-compose.yml /tmp/${PROJECT_NAME}-compose.log /tmp/${PROJECT_NAME}-mobile.log

  echo ""
  echo "✅ Clean slate. Rebuilding everything from scratch..."
  echo ""

  run_setup
  if [[ -d "$MOBILE_DIR" ]]; then
    node "$MOBILE_DIR/scripts/gen-app-json.js" 2>/dev/null || true
  fi
  ensure_podman_running
  detect_compose
  _wire_podman_socket
  DC="$DC_CMD -f $COMPOSE_FILE"

  echo "🏗️  Building core images (no cache)..."
  $DC build --no-cache

  build_mobile_no_cache

  echo ""
  echo "🔨 Building native Android APKs locally..."
  _build_native_apks_locally

  echo ""
  echo "🚀 Starting all services..."
  dc_up_detached traefik db backend frontend
  run_mobile

  if has_mobile_apps; then
    _setup_android_path
    if command -v adb &>/dev/null && command -v emulator &>/dev/null; then
      echo ""
      echo "📱 Setting up Android emulator..."
      local device
      device=$(_ensure_emulator)
      if [[ -n "$device" ]]; then
        discover_apps
        echo ""
        echo "📲 Installing all mobile apps on emulator..."
        for folder in "${MOBILE_APPS[@]}"; do
          local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
          _install_app_on_emulator "$app_key" "$device"
        done
      fi
    fi
  fi

  echo ""
  echo "✅ Rebuild complete. Services are running in the background."
  echo ""
  _draw_status
  echo ""
  echo "   Run ./dev.sh again to see status and follow logs."
  echo "   Run ./dev.sh down to stop everything."
  echo ""
}

# ── Smart launch helpers ──────────────────────────────────────────────────────

# Returns the container state: running, created, exited, missing, etc.
_container_state() {
  podman inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"
}

# Returns 0 if container exists in any live state (running, created, paused)
_container_exists() {
  local state; state=$(_container_state "$1")
  case "$state" in
    running|created|paused) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 if container is fully running (not just created)
_container_running() {
  [[ "$(_container_state "$1")" == "running" ]]
}

# Classify each container: "ok" | "starting" | "broken" | "missing"
_container_status() {
  local state; state=$(_container_state "$1")
  case "$state" in
    running)        echo "ok" ;;
    created|paused) echo "starting" ;;
    exited|stopped) echo "broken" ;;
    missing)        echo "missing" ;;
    *)              echo "broken" ;;
  esac
}

# Ensure Android SDK + emulator tooling is on PATH
_setup_android_path() {
  local sdk="${ANDROID_HOME:-$(_default_android_sdk)}"
  export ANDROID_HOME="$sdk"
  export PATH="$sdk/platform-tools:$sdk/emulator:$sdk/cmdline-tools/latest/bin:$sdk/cmdline-tools/bin:$PATH"

  # JAVA_HOME on macOS
  if [[ "$OS" == "mac" ]] && [[ -z "${JAVA_HOME:-}" ]]; then
    local jh
    jh="$(/usr/libexec/java_home 2>/dev/null || true)"
    if [[ -z "$jh" ]] || [[ ! -x "$jh/bin/java" ]]; then
      for vm in /Library/Java/JavaVirtualMachines/*/Contents/Home \
                /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
        [[ -x "$vm/bin/java" ]] && jh="$vm" && break
      done
    fi
    [[ -n "$jh" ]] && export JAVA_HOME="$jh" && export PATH="$JAVA_HOME/bin:$PATH"
  fi
}

# Boot the Android emulator if not already running; returns the device serial
_ensure_emulator() {
  _setup_android_path

  # Already running? Retry a few times — adb server may need a moment after machine start
  local dev
  local retries=3
  while [[ $retries -gt 0 ]]; do
    dev=$(adb devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
    [[ -n "$dev" ]] && break
    sleep 2; retries=$((retries - 1))
  done
  if [[ -n "$dev" ]]; then
    echo "✅ Emulator already running ($dev)" >&2
    echo "$dev"
    return 0
  fi

  # Find or create AVD
  local avd
  avd=$(emulator -list-avds 2>/dev/null | head -1)
  if [[ -z "$avd" ]]; then
    echo "📱 No AVD found — creating dev_avd..." >&2
    local arch; arch="$(uname -m)"
    local sysimg
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
      sysimg="system-images;android-34;google_apis;arm64-v8a"
    else
      sysimg="system-images;android-34;google_apis;x86_64"
    fi
    yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
    sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "emulator" "platforms;android-34" "$sysimg" "build-tools;34.0.0"
    echo "no" | avdmanager create avd --name "dev_avd" --package "$sysimg" --device "pixel_6" --force 2>/dev/null || \
    echo "no" | avdmanager create avd --name "dev_avd" --package "$sysimg" --force
    avd="dev_avd"
    echo "✅ AVD 'dev_avd' created" >&2
  fi

  echo "🚀 Booting AVD: $avd" >&2
  nohup emulator -avd "$avd" -no-snapshot-load -gpu host >/tmp/emulator.log 2>&1 &

  # Wait for device with a 60s timeout (adb wait-for-device can hang forever)
  local wait_pid
  adb wait-for-device &
  wait_pid=$!
  local t=0
  while kill -0 "$wait_pid" 2>/dev/null && [[ $t -lt 60 ]]; do
    sleep 2; t=$((t + 2))
  done
  kill "$wait_pid" 2>/dev/null || true

  local waited=0
  while [[ $waited -lt 120 ]]; do
    local booted
    booted=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [[ "$booted" == "1" ]] && break
    sleep 3; waited=$((waited + 3))
  done
  sleep 2
  dev=$(adb devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
  if [[ -n "$dev" ]]; then
    echo "✅ Emulator ready ($dev)" >&2
    echo "$dev"
  else
    echo "⚠️  Emulator did not come up in time — skipping app install." >&2
    echo ""
  fi
}

# Install + launch one app on the emulator
_install_app_on_emulator() {
  local app_key="$1"   # e.g. "my-app"
  local device="$2"    # e.g. "emulator-5554"
  local app_dir="$MOBILE_DIR"
  local metro_port=8081

  # Find the app folder and its metro port index
  discover_apps
  local idx=0
  local found_folder=""
  for folder in "${MOBILE_APPS[@]}"; do
    local k; k=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if [[ "$k" == "$app_key" ]]; then
      found_folder="$folder"
      metro_port=$((8081 + idx))
      break
    fi
    idx=$((idx + 1))
  done

  [[ -z "$found_folder" ]] && echo "⚠️  App '$app_key' not found, skipping install." && return 0

  local full_app_dir="$MOBILE_DIR/$found_folder"
  local app_json="$full_app_dir/app.json"
  local slug; slug=$(python3 -c "import json; d=json.load(open('$app_json')); print(d['expo'].get('slug','$app_key'))" 2>/dev/null || echo "$app_key")
  local bundle_id; bundle_id=$(python3 -c "import json; d=json.load(open('$app_json')); print(d['expo'].get('android',{}).get('package',''))" 2>/dev/null || echo "")
  local apk_cache="$ROOT_DIR/frontend/mobile/builds/${app_key}-android.apk"

  if [[ ! -f "$apk_cache" ]]; then
    echo "⚠️  No cached APK for '$app_key' at $apk_cache"
    echo "   Run: ./dev.sh build $app_key android --local"
    echo "   Then re-run: ./dev.sh"
    return 0
  fi

  echo "📦 Installing $found_folder on emulator..."
  [[ -n "$bundle_id" ]] && adb -s "$device" uninstall "$bundle_id" 2>/dev/null || true
  adb -s "$device" install -r "$apk_cache"
  echo "✅ Installed $found_folder"

  # Launch app
  if [[ -n "$bundle_id" ]]; then
    echo "🎯 Launching $found_folder..."
    adb -s "$device" shell am start -n "${bundle_id}/.MainActivity" 2>/dev/null || true
    # Port-forward Metro
    adb -s "$device" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
    sleep 2
    local metro_url; metro_url="http%3A%2F%2Flocalhost%3A${metro_port}"
    adb -s "$device" shell am start \
      -a android.intent.action.VIEW \
      -d "exp+${slug}://expo-development-client/?url=${metro_url}" \
      "$bundle_id" 2>/dev/null || true
  fi
}

# Rebuild + restart a single broken service
_heal_service() {
  local svc="$1"
  echo "🔧 Healing service: $svc"
  if [[ "$svc" == mobile-* ]]; then
    local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
    gen_mobile_yaml > "$yml_file"
    $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" build "$svc" 2>/dev/null || true
    nohup $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" up -d --force-recreate "$svc" \
      </dev/null >>/tmp/${PROJECT_NAME}-mobile.log 2>&1 &
    disown
  else
    $DC build "$svc" 2>/dev/null || true
    nohup $DC_CMD -f "$COMPOSE_FILE" up -d --force-recreate "$svc" \
      </dev/null >>/tmp/${PROJECT_NAME}-compose.log 2>&1 &
    disown
  fi
}

# The main smart-launch entry point
smart_launch() {
  # Podman machine must be running before we can inspect container states
  ensure_podman_running

  discover_apps

  local core_svcs=("traefik" "db" "backend" "frontend")
  local core_containers=("${PROJECT_NAME}_traefik_1" "${PROJECT_NAME}_db_1" "${PROJECT_NAME}_backend_1" "${PROJECT_NAME}_frontend_1")

  # Count running vs not-running containers (core only — mobile may lag behind)
  local running_count=0
  local needs_build=0   # truly missing (image never built)
  local mobile_missing=0

  for i in "${!core_svcs[@]}"; do
    local raw; raw=$(podman inspect --format '{{.State.Status}}' "${core_containers[$i]}" 2>/dev/null || echo "missing")
    case "$raw" in
      running|created|paused) running_count=$((running_count + 1)) ;;
      missing)                needs_build=$((needs_build + 1)) ;;
    esac
  done

  for folder in "${MOBILE_APPS[@]}"; do
    local svc; svc=$(folder_to_service "$folder")
    local raw; raw=$(podman inspect --format '{{.State.Status}}' "${PROJECT_NAME}_${svc}_1" 2>/dev/null || echo "missing")
    [[ "$raw" == "missing" ]] && mobile_missing=$((mobile_missing + 1))
  done

  # ── Everything running (core + mobile) → live status monitor ─────────────
  if [[ $running_count -ge ${#core_svcs[@]} && $mobile_missing -eq 0 ]]; then
    _open_devtools
    live_monitor
    return 0
  fi

  # ── Core running but mobile missing → just start mobile ──────────────────
  if [[ $running_count -ge ${#core_svcs[@]} && $mobile_missing -gt 0 ]]; then
    echo ""
    echo "📱 Core services running — starting missing mobile services..."
    run_mobile
    echo ""
    echo "🔄 Waiting for mobile services to come up..."
    local w=0
    while [[ $w -lt 60 ]]; do
      sleep 3; w=$((w + 3))
      local still_missing=0
      for folder in "${MOBILE_APPS[@]}"; do
        local svc; svc=$(folder_to_service "$folder")
        local raw; raw=$(podman inspect --format '{{.State.Status}}' "${PROJECT_NAME}_${svc}_1" 2>/dev/null || echo "missing")
        [[ "$raw" == "missing" ]] && still_missing=1 && break
      done
      [[ $still_missing -eq 0 ]] && break
    done
    _open_devtools
    live_monitor
    return 0
  fi

  # ── First run: core images never built ───────────────────────────────────
  # Verify by checking if the backend image actually exists, not just container state
  local backend_image_exists=0
  if podman image exists localhost/${PROJECT_NAME}_backend 2>/dev/null || \
     podman images --format '{{.Repository}}' 2>/dev/null | grep -q "${PROJECT_NAME}_backend"; then
    backend_image_exists=1
  fi

  if [[ $needs_build -ge ${#core_svcs[@]} && $backend_image_exists -eq 0 ]]; then
    echo ""
    echo "🏗️  First run detected — building everything..."
    echo ""

    echo "🏗️  Building core images..."
    $DC build

    build_mobile

    echo ""
    echo "🚀 Starting core services..."
    dc_up_detached traefik db backend frontend

    run_mobile

    if has_mobile_apps; then
      _setup_android_path
      if command -v adb &>/dev/null && command -v emulator &>/dev/null; then
        echo ""
        echo "📱 Setting up Android emulator..."
        local device
        device=$(_ensure_emulator)

        if [[ -n "$device" ]]; then
          local lat="" lon="" src=""
          if [[ "$OS" == "mac" ]]; then
            local _loc
            _loc=$(python3 - 2>/dev/null <<'PYEOF'
import time
try:
    import objc
    from CoreLocation import CLLocationManager
    mgr = CLLocationManager.alloc().init()
    mgr.startUpdatingLocation()
    time.sleep(2)
    loc = mgr.location()
    if loc:
        c = loc.coordinate()
        print(f"{c.latitude} {c.longitude}")
except Exception:
    pass
PYEOF
            )
            if [[ -n "$_loc" ]]; then
              lat=$(echo "$_loc" | awk '{print $1}'); lon=$(echo "$_loc" | awk '{print $2}'); src="CoreLocation"
            fi
          fi
          if [[ -z "$lat" ]]; then
            local _geo
            _geo=$(curl -sf --max-time 5 "https://ipapi.co/json/" 2>/dev/null \
              | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['latitude'], d['longitude'])" 2>/dev/null || echo "")
            if [[ -n "$_geo" ]]; then
              lat=$(echo "$_geo" | awk '{print $1}'); lon=$(echo "$_geo" | awk '{print $2}'); src="IP geolocation"
            fi
          fi
          [[ -n "$lat" && -n "$lon" ]] && adb -s "$device" emu geo fix "$lon" "$lat" 2>/dev/null || true

          echo ""
          echo "📲 Installing all mobile apps on emulator..."
          for folder in "${MOBILE_APPS[@]}"; do
            local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            _install_app_on_emulator "$app_key" "$device"
          done
        fi
      fi
    fi

    echo ""
    echo "✅ Everything is up! Services are running in the background."
    echo ""
    _open_devtools
    live_monitor
    return 0
  fi

  # ── Not first run, not all running → start/restart whatever is needed ────
  echo ""
  echo "🔄 Starting services..."
  echo ""

  dc_up_detached traefik db backend frontend
  run_mobile

  if has_mobile_apps; then
    _setup_android_path
    if command -v adb &>/dev/null && command -v emulator &>/dev/null; then
      echo ""
      echo "📱 Setting up Android emulator..."
      local device
      device=$(_ensure_emulator)
      if [[ -n "$device" ]]; then
        echo ""
        echo "📲 Installing all mobile apps on emulator..."
        for folder in "${MOBILE_APPS[@]}"; do
          local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
          _install_app_on_emulator "$app_key" "$device"
        done
      fi
    fi
  fi

  echo ""
  echo "✅ Everything is up! Services are running in the background."
  echo ""
  _open_devtools
  live_monitor
}

# ── Build command: Podman images or native APK/IPA ───────────────────────────
# Usage: _do_build [<app> [android|ios] --local]
_do_build() {
  local build_app="${1:-}"
  local build_platform="android"
  local build_local=false

  for _arg in "$@"; do
    [[ "$_arg" == "--local" ]]                    && build_local=true
    [[ "$_arg" == "android" || "$_arg" == "ios" ]] && build_platform="$_arg"
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

      if [[ ! -f "$gradlew" ]]; then
        echo "❌ No android/gradlew found for '$build_folder'."
        echo "   The android/ directory may not have been generated yet."
        exit 1
      fi

      if ! command -v java &>/dev/null; then
        echo "❌ Java not found. Install Temurin and re-run."
        echo "   macOS: brew install --cask temurin"
        exit 1
      fi

      echo ""
      echo "========================================="
      echo "🔨 Building native APK: $build_folder"
      echo "   Platform: android  |  Mode: debug"
      echo "========================================="

      echo "sdk.dir=$ANDROID_HOME" > "$android_dir/local.properties"
      chmod +x "$gradlew"

      "$gradlew" -p "$android_dir" clean 2>&1 || true

      if "$gradlew" -p "$android_dir" assembleDebug 2>&1; then
        local built_apk
        built_apk=$(find "$android_dir/app/build/outputs/apk/debug" -name "*.apk" 2>/dev/null | head -1)
        if [[ -n "$built_apk" ]]; then
          cp "$built_apk" "$output_dir/${slug}-android.apk"
          echo ""
          echo "✅ APK built → frontend/mobile/builds/${slug}-android.apk"
          echo ""
          echo "   Install on a connected device / emulator:"
          echo "   adb install -r frontend/mobile/builds/${slug}-android.apk"
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
        echo "❌ No ios/ directory found for '$build_folder'."
        exit 1
      fi

      local xcworkspace; xcworkspace=$(find "$ios_dir" -maxdepth 1 -name "*.xcworkspace" | head -1)
      local xcodeproj;   xcodeproj=$(find "$ios_dir"   -maxdepth 1 -name "*.xcodeproj"   | head -1)
      local scheme_name; scheme_name="$(basename "$MOBILE_DIR/$build_folder")"
      local build_dir="$ios_dir/build"
      local build_src

      if [[ -n "$xcworkspace" ]]; then
        build_src="-workspace $xcworkspace"
      elif [[ -n "$xcodeproj" ]]; then
        build_src="-project $xcodeproj"
      else
        echo "❌ No .xcworkspace or .xcodeproj found in ios/."
        exit 1
      fi

      echo ""
      echo "========================================="
      echo "🔨 Building native app: $build_folder"
      echo "   Platform: ios  |  Mode: debug (simulator)"
      echo "========================================="

      # shellcheck disable=SC2086
      xcodebuild $build_src -scheme "$scheme_name" -configuration Debug \
        -sdk iphonesimulator -derivedDataPath "$build_dir" build 2>&1

      local found_app
      found_app=$(find "$build_dir" -name "*.app" -path "*/iphonesimulator*" -maxdepth 6 | head -1)
      if [[ -z "$found_app" ]]; then
        echo "❌ .app bundle not found after build."
        exit 1
      fi

      local app_cache="$output_dir/${slug}-ios.app"
      rm -rf "$app_cache"
      cp -r "$found_app" "$app_cache"
      echo ""
      echo "✅ App built → frontend/mobile/builds/${slug}-ios.app"
      echo ""
      echo "   Install on simulator:"
      echo "   xcrun simctl install booted frontend/mobile/builds/${slug}-ios.app"
    else
      echo "❌ Unknown platform '$build_platform'. Use android or ios."
      exit 1
    fi

  else
    # ── Podman images only ──────────────────────────────────────────────
    echo "🏗️  Building core images..."
    $DC build
    build_mobile
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "$CMD" in
  init)
    echo "�🔧 Initializing frontend..."
    $DC --profile init run --rm frontend-init
    echo "🔧 Initializing backend..."
    $DC --profile init run --rm backend-init
    ;;

  build)
    _do_build "${@:2}"
    ;;

  up)
    echo "🚀 Starting core services..."
    dc_up_detached traefik db backend frontend
    run_mobile
    echo ""
    echo "✅ Services started in the background."
    _draw_status
    ;;

  core)
    echo "🚀 Starting core services (no mobile)..."
    dc_up_detached traefik db backend frontend
    echo ""
    echo "✅ Core services started in the background."
    _draw_status
    ;;

  status)
    live_monitor
    ;;

  _status_only)
    _wire_podman_socket 2>/dev/null || true
    detect_compose 2>/dev/null || true
    _draw_status
    ;;

  service-logs)
    # ./dev.sh service-logs <container_name>
    _wire_podman_socket 2>/dev/null || true
    _service_log_view "${2:-}"
    ;;

  rebuild)
    _do_rebuild
    ;;

  logs)
    echo "📋 Following logs (Ctrl+C to stop)..."
    echo ""
    _follow_logs
    ;;

  mobile)
    if has_mobile_apps; then
      mobile_svcs=$(mobile_service_names)
      echo "📱 Starting mobile services: $mobile_svcs"
      local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"
      # shellcheck disable=SC2086
      nohup $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" up -d --force-recreate $mobile_svcs \
        </dev/null >>/tmp/${PROJECT_NAME}-mobile.log 2>&1 &
      disown
      echo ""
      echo "✅ Mobile services started in the background."
      _draw_status
    else
      echo "⚠️  No mobile apps found."
    fi
    ;;

  "")
    smart_launch
    ;;

  release)
    RELEASE_SEARCH="${2:-}"
    RELEASE_SETUP="${2:-}"

    if [[ "$RELEASE_SETUP" == "--setup" ]]; then
      SETUP_APP="${3:-}"
      discover_apps
      for folder in "${MOBILE_APPS[@]}"; do
        if [[ -z "$SETUP_APP" ]] || echo "$folder" | grep -qi "$SETUP_APP"; then
          slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
          keystore_path="$MOBILE_DIR/$folder/android/app/${slug}-release.keystore"
          props_file="$MOBILE_DIR/$folder/android/gradle.properties"
          if [[ -f "$keystore_path" ]]; then
            echo "⚠️  Keystore already exists for '$folder'"
            continue
          fi
          echo "🔑 Generating release keystore for '$folder'..."
          keytool -genkey -v \
            -keystore "$keystore_path" \
            -alias "$slug" \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -dname "CN=$folder, OU=Mobile, O=${PROJECT_NAME}, L=Unknown, S=Unknown, C=US"
          { echo ""; echo "# Release signing"
            echo "RELEASE_STORE_FILE=${slug}-release.keystore"
            echo "RELEASE_KEY_ALIAS=${slug}"
            echo "RELEASE_STORE_PASSWORD=android"
            echo "RELEASE_KEY_PASSWORD=android"
          } >> "$props_file"
          echo "✅ Keystore created for '$folder'"
          echo "   ⚠️  Change passwords in $props_file before publishing!"
        fi
      done
      exit 0
    fi

    discover_apps
    [[ ${#MOBILE_APPS[@]} -eq 0 ]] && echo "⚠️  No mobile apps found." && exit 1

    ANDROID_HOME="${ANDROID_HOME:-$(_default_android_sdk)}"
    OUTPUT_DIR="$ROOT_DIR/frontend/mobile/builds"
    mkdir -p "$OUTPUT_DIR"
    failed=()

    for folder in "${MOBILE_APPS[@]}"; do
      if [[ -n "$RELEASE_SEARCH" ]] && ! echo "$folder" | grep -qi "$RELEASE_SEARCH"; then
        continue
      fi
      android_dir="$MOBILE_DIR/$folder/android"
      if [[ ! -f "$android_dir/gradlew" ]]; then
        echo "⚠️  No android/ directory for '$folder', skipping."
        continue
      fi
      slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      echo ""
      echo "========================================="
      echo "📦 Building release AAB: $folder"
      echo "========================================="
      echo "sdk.dir=$ANDROID_HOME" > "$android_dir/local.properties"
      ANDROID_HOME="$ANDROID_HOME" "$android_dir/gradlew" -p "$android_dir" bundleRelease 2>&1
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
    echo "   ./dev.sh build <app> [android|ios] --local"
    echo ""
    echo "   Example:"
    echo "   ./dev.sh build <app-name> android --local"
    exit 1
    ;;

  android)
    echo "❌ 'android' command has been removed."
    echo "   To build a native APK locally:"
    echo "   ./dev.sh build <app> android --local"
    echo ""
    echo "   Example:"
    echo "   ./dev.sh build <app-name> android --local"
    exit 1
    ;;

  *)
    echo "Unknown command: $CMD"
    echo ""
    echo "Usage: $0 [setup|build|up|core|mobile|status|rebuild|release|init|stop|down|logs]"
    echo "       $0 build <app> [android|ios] --local  — build native APK/IPA locally"
    exit 1
    ;;
esac
