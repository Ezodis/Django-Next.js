#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  dev.sh — Cross-platform dev launcher (macOS · Linux · Windows WSL/Git Bash)║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  macOS prerequisite: Install Xcode from the App Store, then:                ║
# ║    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer          ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  USAGE                                                                       ║
# ║    ./dev.sh                      Smart launch:                               ║
# ║                                    • First run / all down → build + start   ║
# ║                                    • Some down → heal only broken services  ║
# ║                                    • All running → show status + open tools ║
# ║    ./dev.sh setup                Install all dependencies                   ║
# ║    ./dev.sh build                Build Podman images only                   ║
# ║    ./dev.sh build <app> [android|ios] --local  Build native APK/IPA locally ║
# ║    ./dev.sh build <app> [android|ios]          EAS cloud build (default: dev)║
# ║    ./dev.sh build <app> [android|ios] --profile <p>  EAS build with profile ║
# ║    ./dev.sh up                   Start core + mobile services               ║
# ║    ./dev.sh core                 Start core services only (no mobile)        ║
# ║    ./dev.sh mobile               Start only mobile services                 ║
# ║    ./dev.sh status               Live status monitor (Ctrl+C to quit)       ║
# ║    ./dev.sh rebuild              Nuclear clean rebuild (wipes all caches)   ║
# ║    ./dev.sh heal <svc>           Rebuild + restart a specific broken service ║
# ║    ./dev.sh check [svc]          Check status of all services or one        ║
# ║    ./dev.sh adb-reverse          Port-forward for physical Android devices  ║
# ║    ./dev.sh release              Build release AABs                         ║
# ║    ./dev.sh release --setup      Generate release keystores                 ║
# ║    ./dev.sh init                 One-time scaffold                          ║
# ║    ./dev.sh stop                 Stop all containers (keep images/volumes)  ║
# ║    ./dev.sh down                 Stop + wipe everything (full reset)        ║
# ║    ./dev.sh logs                 Follow logs for all running containers     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

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

      # Podman machine
      if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
        if ! podman machine list 2>/dev/null | grep -q "default"; then
          echo "🖥️  Creating Podman machine..."
          podman machine init --cpus 4 --memory 8192 --disk-size 200 2>&1 | grep -v "rootless mode" | grep -v "Docker API socket" | grep -v "DOCKER_HOST" || true
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
        brew install openjdk@21 2>&1 || \
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
        brew install node
        # Re-wire PATH so node is available immediately in this session
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
          || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
      else
        echo "✅ Node.js already installed ($(node --version))"
      fi

      # ── Android SDK + Emulator ──────────────────────────────────────────────
      # Install command-line tools, platform-tools, emulator, and create a
      # default AVD so `./dev.sh` can launch the emulator on first run.
      # Requires Java 21 — ensure it's on PATH for sdkmanager/avdmanager.
      local _sdk_dir="$HOME/Library/Android/sdk"
      local _cmdline_dir="$_sdk_dir/cmdline-tools/latest"
      local _arch; _arch="$(uname -m)"
      local _sysimg
      if [[ "$_arch" == "arm64" || "$_arch" == "aarch64" ]]; then
        _sysimg="system-images;android-34;google_apis;arm64-v8a"
      else
        _sysimg="system-images;android-34;google_apis;x86_64"
      fi

      # Ensure Java 21 is installed (needed by sdkmanager/avdmanager below)
      if ! brew list --formula openjdk@21 &>/dev/null 2>&1; then
        echo "📦 Installing Java 21 LTS (required for Android SDK tools)..."
        brew install openjdk@21 || true
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
      fi
      # Put Java 21 on PATH for the rest of this setup block
      local _j21="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
      [[ -x "$_j21/bin/java" ]] && export JAVA_HOME="$_j21" && export PATH="$_j21/bin:$PATH"

      if [[ ! -x "$_cmdline_dir/bin/sdkmanager" ]]; then
        echo "📦 Installing Android SDK command-line tools..."
        mkdir -p "$_cmdline_dir"
        local _cmdline_url="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
        local _tmp_zip; _tmp_zip="$(mktemp /tmp/android-cmdline-XXXXXX.zip)"
        curl -L --progress-bar "$_cmdline_url" -o "$_tmp_zip"
        local _tmp_dir; _tmp_dir="$(mktemp -d /tmp/android-cmdline-XXXXXX)"
        unzip -q "$_tmp_zip" -d "$_tmp_dir"
        # The zip extracts to cmdline-tools/ — move its contents into latest/
        if [[ -d "$_tmp_dir/cmdline-tools" ]]; then
          cp -r "$_tmp_dir/cmdline-tools/." "$_cmdline_dir/"
        fi
        rm -rf "$_tmp_zip" "$_tmp_dir"
        echo "✅ Android command-line tools installed"
      else
        echo "✅ Android SDK command-line tools already installed"
      fi

      # Put sdkmanager/avdmanager on PATH for the rest of this session
      export ANDROID_HOME="$_sdk_dir"
      export PATH="$_cmdline_dir/bin:$_sdk_dir/platform-tools:$_sdk_dir/emulator:$PATH"

      # Accept licenses non-interactively
      yes | sdkmanager --sdk_root="$_sdk_dir" --licenses >/dev/null 2>&1 || true

      # Install required SDK packages if not already present
      local _need_sdk=false
      [[ ! -x "$_sdk_dir/platform-tools/adb" ]]    && _need_sdk=true
      [[ ! -x "$_sdk_dir/emulator/emulator" ]]      && _need_sdk=true
      [[ ! -d "$_sdk_dir/platforms/android-34" ]]   && _need_sdk=true
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
        # Still install system image if missing (needed for AVD)
        if [[ ! -d "$_sdk_dir/system-images/android-34" ]]; then
          echo "📦 Installing Android system image..."
          sdkmanager --sdk_root="$_sdk_dir" "$_sysimg" 2>&1 | grep -v "^Info:\|^Done\|^\[=" || true
        fi
      fi

      # Create default AVD if none exists
      export PATH="$_sdk_dir/cmdline-tools/latest/bin:$PATH"
      local _avd_list
      _avd_list=$(emulator -list-avds 2>/dev/null || true)
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

      # Enable systemd lingering so rootless Podman containers survive terminal close
      _ensure_lingering
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
            podman machine init --cpus 4 --memory 8192 --disk-size 200 2>&1 | grep -v "rootless mode" | grep -v "Docker API socket" | grep -v "DOCKER_HOST" || true
          fi
          echo "🚀 Starting Podman machine..."
          podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
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
    mac|windows)
      local sock
      sock="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo "")"
      if [[ -n "$sock" && -S "$sock" ]]; then
        export DOCKER_HOST="unix://$sock"
      else
        # Fallback: try to find the socket manually
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
      local uid_sock="/run/user/$(id -u)/podman/podman.sock"
      if [[ -S "$uid_sock" ]]; then
        export DOCKER_HOST="unix://$uid_sock"
        export PODMAN_SOCK="$uid_sock"
      fi
      ;;
  esac
}

# ── Detached double-fork helper ───────────────────────────────────────────────
# Usage: _run_detached <log_file> <cmd> [args...]
# Runs the given command completely detached from the terminal (survives close).
_run_detached() {
  local log_file="$1"; shift
  python3 - "$log_file" "$@" <<'PYEOF'
import sys, os, signal
log_file = sys.argv[1]
cmd      = sys.argv[2:]
pid = os.fork()
if pid > 0:
    os.waitpid(pid, 0); sys.exit(0)
os.setsid()
pid2 = os.fork()
if pid2 > 0:
    sys.exit(0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
devnull = os.open(os.devnull, os.O_RDWR)
os.dup2(devnull, 0)
log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(log_fd, 1); os.dup2(log_fd, 2)
os.execvp(cmd[0], cmd)
PYEOF
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
  # Only relevant on Linux / WSL with systemd
  [[ "$OS" == "linux" || "$OS" == "wsl" ]] || return 0
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

# ── Detect compose command ────────────────────────────────────────────────────
detect_compose() {
  if command -v podman-compose &>/dev/null; then
    DC_CMD="podman-compose"
  else
    echo "❌ podman-compose not found. Run: ./dev.sh setup"
    exit 1
  fi
  _wire_podman_socket
}

# ── Ensure Podman machine is running ─────────────────────────────────────────
ensure_podman_running() {
  if ! command -v podman &>/dev/null; then return; fi
  case "$OS" in
    mac|windows)
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
        echo "🚀 Starting Podman machine..."
        podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
        # Wait for socket to be ready (up to 30s)
        local waited=0
        while [[ $waited -lt 30 ]]; do
          if podman ps >/dev/null 2>&1; then
            break
          fi
          sleep 2; waited=$((waited + 2))
        done
        # Verify the machine is actually running
        if ! podman ps >/dev/null 2>&1; then
          echo "⚠️  Podman machine failed to start properly. Trying to restart..."
          podman machine stop 2>/dev/null || true
          sleep 2
          podman machine start 2>&1 | grep -E "(started successfully|Machine.*started)" || true
          sleep 5
        fi
      fi
      # Allow Podman VM to bind privileged ports (80, 443) so localhost works without a port number
      # This is idempotent — only writes if not already set
      local _sysctl_applied
      _sysctl_applied=$(podman machine ssh "cat /etc/sysctl.d/99-podman.conf 2>/dev/null" 2>/dev/null || echo "")
      if ! echo "$_sysctl_applied" | grep -q "ip_unprivileged_port_start=80"; then
        echo "🔧 Allowing Podman to bind port 80 (one-time setup)..."
        podman machine ssh "echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-podman.conf > /dev/null && sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80 > /dev/null" 2>/dev/null || true
        echo "✅ Port 80 unlocked"
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

# For `build <app> <platform> --local` we don't need Podman at all
# For `build <app> <platform>` (EAS cloud) we also don't need Podman
_BUILD_LOCAL=false
_BUILD_EAS=false
if [[ "$CMD" == "build" ]]; then
  for _a in "$@"; do [[ "$_a" == "--local" ]] && _BUILD_LOCAL=true; done
  # EAS build: has an app name argument and no --local flag
  _build_arg2="${2:-}"
  if [[ -n "$_build_arg2" && "$_build_arg2" != "--local" && "$_BUILD_LOCAL" == "false" ]]; then
    _BUILD_EAS=true
  fi
fi

_deps_installed() {
  command -v podman         &>/dev/null || return 1
  command -v podman-compose &>/dev/null || return 1
  command -v node           &>/dev/null || return 1
  command -v git            &>/dev/null || return 1
  return 0
}

# Wire brew PATH before dependency check — after a Mac restart, brew-installed
# binaries (node, podman-compose, etc.) won't be in PATH until shellenv is eval'd
if [[ "$OS" == "mac" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null \
    || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
fi

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

if [[ "$CMD" != "status" && "$CMD" != "_status_only" && "$CMD" != "rebuild" && "$_BUILD_LOCAL" != "true" && "$_BUILD_EAS" != "true" ]]; then
  ensure_podman_running
fi
detect_compose
_wire_podman_socket
DC="$DC_CMD -f $COMPOSE_FILE"

# ── Mobile app discovery ──────────────────────────────────────────────────────
discover_apps() {
  MOBILE_APPS=()
  [[ -d "$MOBILE_DIR" ]] || return
  # Collect names first, then sort alphabetically so port assignment is
  # stable and matches mobile.sh's `_app_keys` (which also sorts).
  local _names=()
  while IFS= read -r -d '' dir; do
    local name
    name=$(basename "$dir")
    [[ "$name" == "node_modules" || "$name" == "shared" || "$name" == "scripts" || "$name" == "builds" ]] && continue
    [[ -f "$dir/package.json" ]] || continue
    _names+=("$name")
  done < <(find "$MOBILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
  # Sort alphabetically (case-insensitive) to match mobile.sh port ordering
  while IFS= read -r name; do
    MOBILE_APPS+=("$name")
  done < <(printf '%s\n' "${_names[@]}" | sort -f)
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
    echo "      REACT_NATIVE_PACKAGER_HOSTNAME: \"\${REACT_NATIVE_PACKAGER_HOSTNAME:-localhost}\""
    echo "      EXPO_PUBLIC_API_URL: \"\${EXPO_PUBLIC_API_URL:-http://localhost:8000}\""
    echo "      EXPO_PUBLIC_GOOGLE_MAPS_API_KEY: \"\${EXPO_PUBLIC_GOOGLE_MAPS_API_KEY:-}\""
    echo "      EXPO_PUBLIC_ENV: \"development\""
    echo "      NODE_ENV: \"development\""
    echo "      NODE_OPTIONS: \"--max-old-space-size=4096\""
    echo "      EXPO_NO_INSPECTOR_PROXY: \"1\""
    echo "      METRO_PORT: \"${port}\""
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
    echo "    volumes:"
    for vdir in "${MOBILE_APPS[@]}"; do
      # Mount using the original folder name so mobile.sh finds it correctly
      echo "      - \"${ROOT_DIR}/frontend/mobile/${vdir}:/app/${vdir}:z\""
      # Protect each app's node_modules from being overwritten by the host mount
      # (anonymous volume takes precedence over the bind mount above)
      echo "      - \"/app/${vdir}/node_modules\""
    done
    echo "      - \"${ROOT_DIR}/frontend/mobile/shared:/app/shared:z\""
    # Mount packages so shared code changes are picked up live
    echo "      - \"${ROOT_DIR}/frontend/packages:/app/packages:z\""
    echo "      - /app/node_modules"
    # Mount mobile.sh so script changes are picked up without rebuilding the image
    echo "      - \"${ROOT_DIR}/frontend/mobile/scripts/mobile.sh:/mobile.sh:ro\""
    echo "    ports:"
    echo "      - \"${port}:${port}\""
    echo "    depends_on:"
    echo "      backend:"
    echo "        condition: service_started"
    echo "    healthcheck:"
    echo "      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:${port}\"]"
    echo "      interval: 10s"
    echo "      timeout: 5s"
    echo "      retries: 5"
    echo "      start_period: 120s"
    echo "    labels:"
    echo "      - \"traefik.enable=false\""
    echo "    restart: unless-stopped"
    echo "    stdin_open: true"
    echo "    tty: true"
    port=$((port + 1))
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
echo "\$(date): Starting Podman machine..." >> "\$LOG"
"\$PODMAN" machine start >> "\$LOG" 2>&1 || true
# Wait up to 60s for the socket to be ready
for i in \$(seq 1 30); do
  "\$PODMAN" ps >/dev/null 2>&1 && break
  sleep 2
done
echo "\$(date): Starting all stopped/created containers..." >> "\$LOG"
STOPPED=\$("\$PODMAN" ps -a --filter "status=exited" --filter "status=created" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
if [ -n "\$STOPPED" ]; then
  echo "\$(date): Starting: \$STOPPED" >> "\$LOG"
  \$PODMAN start \$STOPPED >> "\$LOG" 2>&1 || true
fi
echo "\$(date): Done." >> "\$LOG"
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
  <key>StandardOutPath</key>
  <string>/tmp/podman-autostart.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/podman-autostart.log</string>
</dict>
</plist>
PLIST
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load  "$plist" 2>/dev/null || true
  echo "✅ Podman autostart agent installed — services survive terminal close and Mac reboots"
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
  for cname in $created; do
    # Ensure unless-stopped restart policy before starting
    podman update --restart unless-stopped "$cname" >/dev/null 2>&1 || true
    podman start "$cname" >/dev/null 2>&1 || true
  done
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

# ── Start services (already detached via Podman daemon) ──────────────────────
# podman-compose up -d runs containers inside the Podman VM which is a separate
# Linux process — containers survive terminal close without any wrapper.
dc_up_detached() {
  "$DC_CMD" -f "$COMPOSE_FILE" up -d "$@" \
    >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || true

  # podman-compose 1.5.x bug: containers may be left in "created" state.
  # Explicitly start them so they actually run.
  sleep 2
  _start_created_containers
  _apply_restart_policy

  # Wait up to 30s for at least one of the requested containers to appear running
  local i=0
  while [[ $i -lt 30 ]]; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_NAME}"; then
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
  python3 - "$COMPOSE_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

services = {}
current_svc = None
in_services = False
in_ports = False
in_profiles = False
indent_services = 0

for line in lines:
    stripped = line.rstrip()
    if not stripped or stripped.lstrip().startswith('#'):
        in_ports = False; in_profiles = False; continue
    indent = len(line) - len(line.lstrip())

    if re.match(r'^services\s*:', stripped):
        in_services = True; indent_services = indent
        in_ports = False; in_profiles = False; continue
    if not in_services:
        continue

    svc_match = re.match(r'^  (\w[\w-]*)\s*:', stripped)
    if svc_match and indent == indent_services + 2:
        current_svc = svc_match.group(1)
        if current_svc not in ('volumes', 'networks', 'configs', 'secrets'):
            services.setdefault(current_svc, {'ports': [], 'profiles': [], 'container_name': None})
        else:
            current_svc = None
        in_ports = False; in_profiles = False; continue
    if current_svc is None:
        continue

    # profiles: ["init"]  inline array
    pm = re.match(r'\s+profiles\s*:\s*\[([^\]]*)\]', stripped)
    if pm and indent == indent_services + 4:
        vals = [v.strip().strip('"\'') for v in pm.group(1).split(',') if v.strip()]
        services[current_svc]['profiles'].extend(vals)
        in_ports = False; in_profiles = False; continue

    # profiles: block list
    if re.match(r'\s+profiles\s*:', stripped) and indent == indent_services + 4:
        in_profiles = True; in_ports = False; continue

    # ports:
    if re.match(r'\s+ports\s*:', stripped) and indent == indent_services + 4:
        in_ports = True; in_profiles = False; continue

    # container_name:
    cn = re.match(r'\s+container_name\s*:\s*["\']?([^\s"\']+)["\']?', stripped)
    if cn and indent == indent_services + 4:
        services[current_svc]['container_name'] = cn.group(1)
        in_ports = False; in_profiles = False; continue

    # list items
    item = re.match(r'\s+-\s+"?([^"]+)"?', stripped)
    if item and indent >= indent_services + 4:
        val = item.group(1).strip()
        if in_profiles:
            services[current_svc]['profiles'].append(val)
        elif in_ports:
            port_part = val.split(':')[0].strip()
            port_part = re.sub(r'\$\{[^}]*:-(\d+)\}', r'\1', port_part)
            port_part = re.sub(r'\$\{[^}]+\}', '', port_part)
            if re.match(r'^\d+$', port_part):
                services[current_svc]['ports'].append(int(port_part))
        continue

    if indent <= indent_services + 4 and not item:
        in_ports = False; in_profiles = False

for svc, info in services.items():
    if info['profiles']:
        continue
    port = info['ports'][0] if info['ports'] else 0
    cname = info['container_name'] or ''
    print(f"{svc} {port} {cname}")
PYEOF
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

  printf "\n  \033[1;34m⬡ %s\033[0m\n\n" "$PROJECT_NAME"

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

  printf "\n  \033[2mCtrl+C quit  •  ./dev.sh logs <name>\033[0m\n\n"
}

_draw_status_live() {
  local _rows_file="$1"
  : > "$_rows_file"
  discover_apps
  
  # Build a label-based container name cache — one podman ps call, works for
  # all podman-compose versions regardless of separator convention.
  local _cache; _cache=$(_build_cname_cache)
  
  local _lw=18 _tmp _sf
  _tmp="$(mktemp /tmp/${PROJECT_NAME}-draw-XXXXXX)"
  _sf="$(mktemp /tmp/${PROJECT_NAME}-stats-XXXXXX)"
  # Collect stats with timeout so it never hangs
  if command -v gtimeout &>/dev/null; then
    gtimeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  elif command -v timeout &>/dev/null; then
    timeout 3 podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  else
    podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null > "$_sf" || true
  fi
  
  # bash 3.2-compatible deduplication via a plain string sentinel
  local seen_services=""

  _seen_svc() { case "$seen_services" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }
  _mark_svc() { seen_services="$seen_services|$1|"; }

  {
    printf "\n  \033[1;34m⬡ %s\033[0m\n\n" "$PROJECT_NAME"
    
    # Process core services from dev.yml
    local _svc _port _cname_override _cname
    while IFS=' ' read -r _svc _port _cname_override; do
      [[ -z "$_svc" ]] && continue
      # Skip if we've already seen this service
      _seen_svc "$_svc" && continue
      _mark_svc "$_svc"
      
      if [[ -n "$_cname_override" ]]; then
        _cname="$_cname_override"
      else
        _cname="$(_cname_from_cache "$_cache" "$_svc" "${PROJECT_NAME}-${_svc}-1")"
      fi
      printf '%s|%s\n' "$_svc" "$_cname" >> "$_rows_file"
      _draw_status_live_row "$_svc" "$_cname" "$_lw" "$_port" "$_sf" || true
    done < <(_parse_compose_services | sort -u)
    
    # Process mobile services
    for folder in "${MOBILE_APPS[@]}"; do
      local slug; slug=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      # Skip if we've already seen this service
      _seen_svc "$slug" && continue
      _mark_svc "$slug"
      
      local _msvc; _msvc=$(folder_to_service "$folder")
      local _mc; _mc=$(_cname_from_cache "$_cache" "$_msvc" "${PROJECT_NAME}-${_msvc}-1")
      printf '%s|%s\n' "$slug" "$_mc" >> "$_rows_file"
      _draw_status_live_row "$slug" "$_mc" "$_lw" "" "$_sf" || true
    done
    
    printf "\n  \033[2mCtrl+C quit  •  ./dev.sh logs <name>\033[0m\n\n"
  } > "$_tmp" 2>/dev/null
  rm -f "$_sf"
  printf '\033[H'
  cat "$_tmp"
  rm -f "$_tmp"
}
_draw_status_live_row() {
  local label="$1" cname="$2" lw="$3" port="$4" sf="$5"
  local state health dot color badge uptime cpu mem last_log
  local _info
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
  case "$state" in
    running)
      case "$health" in
        healthy)  dot='●' color=$'\033[32m' badge="healthy"  ;;
        starting) dot='◐' color=$'\033[33m' badge="starting" ;;
        *)        dot='●' color=$'\033[32m' badge="running"  ;;
      esac ;;
    exited|stopped) dot='●' color=$'\033[31m'   badge="stopped" ;;
    missing)        dot='○' color=$'\033[2;37m' badge="missing" ;;
    *)              dot='◐' color=$'\033[33m'   badge="$state"  ;;
  esac
  uptime=""
  if [[ "$state" == "running" && -n "$started_at" && "$started_at" != "-" ]]; then
    local _se _ne _diff _dt
    _dt="${started_at:0:19}"
    _se=$(date -j -f "%Y-%m-%d %H:%M:%S" "$_dt" "+%s" 2>/dev/null || echo "")
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
  local lbl="$label"
  [[ ${#lbl} -gt $lw ]] && lbl="${lbl:0:$(( lw - 1 ))}…"
  local port_col=""
  [[ -n "$port" && "$port" != "0" ]] && port_col=":${port}"
  printf "  %s%s\033[0m  %-${lw}s  %s%-9s\033[0m  \033[2m%-5s  %-7s  %-8s  %s\033[0m\n" \
    "$color" "$dot" "$lbl" "$color" "$badge" "$uptime" "$cpu" "$mem" "$port_col"
  return 0
}

live_monitor() {
  # Ensure the Podman machine is up so containers are visible even after a
  # macOS restart where the machine may still be stopped.
  ensure_podman_running 2>/dev/null || true
  _wire_podman_socket

  local _rows_file
  _rows_file="$(mktemp /tmp/${PROJECT_NAME}-status-rows-XXXXXX)"
  local _SAVED_STTY
  _SAVED_STTY="$(stty -g 2>/dev/null || true)"

  _cleanup_monitor() {
    stty "$_SAVED_STTY" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    rm -f "$_rows_file"
    printf "\n\033[2m  Terminal closed — services keep running in the background.\033[0m\n\n"
    # Containers are owned by the Podman daemon — nothing to stop here.
    exit 0
  }
  # Trap HUP (terminal close) + INT/TERM so the monitor exits cleanly.
  # No EXIT trap — that's re-entrant and dangerous.
  trap '_cleanup_monitor' HUP INT TERM
  tput civis 2>/dev/null || true
  clear

  while true; do
    : > "$_rows_file"
    set +e
    _draw_status_live "$_rows_file" 2>/dev/null
    set -e
    sleep 3 2>/dev/null || true
  done
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
    local services
    services=$(mobile_service_names)
    echo "📱 Starting mobile services: $services"
    # Write a stable mobile compose file so the detached process can reference it
    local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
    gen_mobile_yaml > "$yml_file"
    # shellcheck disable=SC2086
    "$DC_CMD" -f "$COMPOSE_FILE" -f "$yml_file" up -d $services \
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
    local apk_out="$OUTPUT_DIR/${slug}-android.apk"

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
  local filter="${1:-}"
  local pids=() cname matched=()
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ -n "$filter" ]]; then
      # Strip the project-name prefix (e.g. "elitecar_" or "elitecar-") so that
      # `./dev.sh logs elitecar` doesn't match every container (they all start
      # with the project name). Match the filter only against the service part.
      local service_part="${cname#${PROJECT_NAME}_}"
      service_part="${service_part#${PROJECT_NAME}-}"
      echo "$service_part" | grep -qi "$filter" || continue
    fi
    matched+=("$cname")
    podman logs -f --names "$cname" 2>&1 &
    pids+=($!)
  done < <(podman ps --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT_NAME}[-_]")

  if [[ ${#pids[@]} -eq 0 ]]; then
    if [[ -n "$filter" ]]; then
      echo "⚠️  No running containers found matching '$filter'."
      echo "    Available containers:"
      podman ps --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${PROJECT_NAME}[-_]" \
        | sed "s/^${PROJECT_NAME}[-_]/    /" || true
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

# ── Open Safari at localhost (macOS only, no-op if already showing localhost) ─
_open_safari() {
  [[ "$OS" != "mac" ]] && return 0
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
  [[ "$already_open" != "yes" ]] && open -a Safari "http://localhost" 2>/dev/null || true
}

# ── Start Android emulator + install all apps ────────────────────────────────
# No-op if the emulator is already running (pass "force" as $1 to skip that check,
# e.g. after a rebuild when fresh APKs need to be installed).
_start_emulator_with_apps() {
  local force="${1:-}"
  has_mobile_apps || return 0
  [[ "$force" != "force" ]] && _emulator_running && return 0
  _setup_android_path
  command -v adb &>/dev/null && _setup_physical_devices
  command -v adb &>/dev/null && command -v emulator &>/dev/null || return 0
  echo ""
  echo "📱 Setting up Android emulator..."
  local device; device=$(_ensure_emulator)
  [[ -n "$device" ]] || return 0
  discover_apps
  echo ""
  echo "📲 Installing all mobile apps on emulator..."
  for folder in "${MOBILE_APPS[@]}"; do
    local app_key; app_key=$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    _install_app_on_emulator "$app_key" "$device"
  done
}

# ── Open browser + Android emulator with all apps ────────────────────────────
_open_devtools() {
  _open_safari
  _start_emulator_with_apps
}

# ── Patch Google Maps API key into AndroidManifest after prebuild ─────────────
# expo prebuild regenerates AndroidManifest.xml and strips the Maps meta-data.
# This function re-injects it so the key is always present before Gradle runs.
_patch_google_maps_key() {
  local maps_key
  maps_key="${EXPO_PUBLIC_GOOGLE_MAPS_API_KEY:-}"

  # Fall back to reading directly from .env if not already in environment
  if [[ -z "$maps_key" && -f "$ROOT_DIR/.env" ]]; then
    maps_key=$(grep -E '^EXPO_PUBLIC_GOOGLE_MAPS_API_KEY=' "$ROOT_DIR/.env" \
               | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
  fi

  if [[ -z "$maps_key" ]]; then
    echo "⚠️  EXPO_PUBLIC_GOOGLE_MAPS_API_KEY not set — skipping Maps key patch."
    return 0
  fi

  discover_apps
  for folder in "${MOBILE_APPS[@]}"; do
    local manifest="$MOBILE_DIR/$folder/android/app/src/main/AndroidManifest.xml"
    [[ -f "$manifest" ]] || continue

    # Skip if already patched with this key
    if grep -q "com.google.android.geo.API_KEY" "$manifest"; then
      echo "✅ Google Maps key already present in $folder/AndroidManifest.xml"
      continue
    fi

    # Inject after the last expo.modules.updates meta-data line
    local insert_after='expo.modules.updates.EXPO_UPDATES_LAUNCH_WAIT_MS'
    if grep -q "$insert_after" "$manifest"; then
      sed -i.bak "/$insert_after/a\\
    <meta-data android:name=\"com.google.android.geo.API_KEY\" android:value=\"${maps_key}\"/>" "$manifest"
      rm -f "${manifest}.bak"
      echo "✅ Patched Google Maps API key into $folder/AndroidManifest.xml"
    else
      echo "⚠️  Could not find insertion point in $folder/AndroidManifest.xml — patching manually"
      sed -i.bak "s|</application>|    <meta-data android:name=\"com.google.android.geo.API_KEY\" android:value=\"${maps_key}\"/>\n  </application>|" "$manifest"
      rm -f "${manifest}.bak"
    fi
  done
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

  # ── Ensure Podman machine has enough disk space ───────────────────────────
  # Podman machine disk is separate from macOS disk. If it's too small or full,
  # we recreate it with 200GB so builds never run out of space.
  if command -v podman &>/dev/null && [[ "$OS" == "mac" || "$OS" == "windows" ]]; then
    local machine_disk
    machine_disk=$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null || echo "0")
    # DiskSize is in GiB; recreate if under 150GiB
    if [[ "$machine_disk" -lt 150 ]] 2>/dev/null; then
      echo ""
      echo "⚠️  Podman machine disk is only ${machine_disk}GiB — recreating with 200GiB..."
      podman machine stop 2>/dev/null || true
      podman machine rm --force 2>/dev/null || true
      echo "🖥️  Creating new Podman machine with 200GiB disk..."
      podman machine init --cpus 4 --memory 8192 --disk-size 200
      podman machine start
      _wire_podman_socket
      echo "✅ Podman machine ready (200GiB)"
      echo ""
    fi
  fi

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
  echo "🚀 Starting all services..."
  dc_up_detached $(_parse_compose_services | awk '{print $1}' | tr '\n' ' ')
  run_mobile

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
# _container_exists() — removed (unused)

# Returns 0 if container is fully running (not just created)
# _container_running() — removed (unused)

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
  if ! command -v adb &>/dev/null; then
    return 1
  fi
  local device
  device=$(adb devices 2>/dev/null | grep "emulator" | grep "device$" | awk '{print $1}' | head -1 || true)
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
      sed -i.bak \
        's/id("org.gradle.toolchains.foojay-resolver-convention").version("[^"]*")/id("org.gradle.toolchains.foojay-resolver-convention").version("1.0.0")/g' \
        "$rn_settings" && rm -f "${rn_settings}.bak"
      echo "🔧 Patched foojay-resolver → 1.0.0 in $(basename "$(dirname "$rn_settings")")"
    fi
  fi

  # Also patch the app's own settings.gradle if it has foojay
  local app_settings="$android_dir/settings.gradle"
  if [[ -f "$app_settings" ]] && grep -q 'foojay-resolver' "$app_settings" 2>/dev/null; then
    sed -i.bak \
      's/id("org.gradle.toolchains.foojay-resolver-convention") version "[^"]*"/id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"/g' \
      "$app_settings" && rm -f "${app_settings}.bak"
    echo "🔧 Patched foojay-resolver → 1.0.0 in settings.gradle"
  fi
}

_setup_android_path() {
  local sdk="${ANDROID_HOME:-$(_default_android_sdk)}"
  export ANDROID_HOME="$sdk"
  export PATH="$sdk/platform-tools:$sdk/emulator:$sdk/cmdline-tools/latest/bin:$sdk/cmdline-tools/bin:$PATH"

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
  # Double-fork via Python to fully escape the terminal's process group.
  # bash's `disown` is ineffective when called inside a subshell (command
  # substitution), because it only removes the job from the *subshell's*
  # job table — the emulator's PGID is still the script's process group and
  # will receive SIGHUP when the terminal closes.
  # Python's os.setsid() creates a brand-new session with a new PGID, so
  # the emulator is completely detached from the terminal before exec.
  local _emu_bin
  _emu_bin="$(command -v emulator)"
  python3 - "$_emu_bin" "$avd" <<'PYEOF'
import sys, os, signal
emu_bin = sys.argv[1]
avd     = sys.argv[2]
pid = os.fork()
if pid > 0:
    os.waitpid(pid, 0)
    sys.exit(0)
os.setsid()
pid2 = os.fork()
if pid2 > 0:
    sys.exit(0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
devnull = os.open(os.devnull, os.O_RDWR)
os.dup2(devnull, 0)
log_fd = os.open('/tmp/emulator.log', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(log_fd, 1)
os.dup2(log_fd, 2)
os.execv(emu_bin, [emu_bin, '-avd', avd, '-no-snapshot-load', '-gpu', 'host'])
PYEOF

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
  local METRO_BASE=8081
  local metro_port=$METRO_BASE

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
    # Port-forward Metro (app→localhost:<port> → host Metro container)
    adb -s "$device" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
    # Port-forward backend API (app→localhost:8000 → host backend container)
    adb -s "$device" reverse "tcp:8000" "tcp:8000" 2>/dev/null || true
    sleep 2
    local metro_url; metro_url="http%3A%2F%2Flocalhost%3A${metro_port}"
    adb -s "$device" shell am start \
      -a android.intent.action.VIEW \
      -d "exp+${slug}://expo-development-client/?url=${metro_url}" \
      "$bundle_id" 2>/dev/null || true
  fi
}

# ── Set up port-forwarding for all connected Android devices/emulators ───────
# Both physical devices and emulators need `adb reverse` so that localhost:<port>
# on the device/emulator tunnels back to the host machine (Metro + backend API).
# Safe to call at any time — no-op if no devices are connected.
_setup_physical_devices() {
  _setup_android_path
  command -v adb &>/dev/null || return 0

  # Collect all connected devices (both physical and emulators), skip offline
  local all_devices=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local serial; serial=$(echo "$line" | awk '{print $1}')
    local state;  state=$(echo "$line"  | awk '{print $2}')
    [[ "$state" != "device" ]] && continue
    all_devices+=("$serial")
  done < <(adb devices 2>/dev/null | tail -n +2)

  [[ ${#all_devices[@]} -eq 0 ]] && return 0

  discover_apps
  local METRO_BASE=8081

  for serial in "${all_devices[@]}"; do
    # Metro ports — one per app; reset idx for each device so ports are consistent
    local idx=0
    for folder in "${MOBILE_APPS[@]}"; do
      local metro_port=$((METRO_BASE + idx))
      echo "🔌 adb reverse tcp:${metro_port} → host:${metro_port}  ($serial)"
      adb -s "$serial" reverse "tcp:${metro_port}" "tcp:${metro_port}" 2>/dev/null || true
      idx=$((idx + 1))
    done
    # Backend API port — so localhost:8000 on device reaches the backend container
    echo "🔌 adb reverse tcp:8000 → host:8000  ($serial)"
    adb -s "$serial" reverse "tcp:8000" "tcp:8000" 2>/dev/null || true
  done

  echo "✅ Port-forwarding set up for ${#all_devices[@]} device(s). Metro and API reachable at localhost on device."
}

# Rebuild + restart a single broken service
_heal_service() {
  local svc="$1"
  local force_rebuild="${2:-false}"  # pass "true" to force image rebuild
  echo "🔧 Healing service: $svc"
  if [[ "$svc" == mobile-* ]]; then
    local yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
    gen_mobile_yaml > "$yml_file"
    if [[ "$force_rebuild" == "true" ]]; then
      echo "  📦 Rebuilding mobile service: $svc"
      $DC_CMD -f "$COMPOSE_FILE" -f "$yml_file" build --no-cache "$svc" 2>/dev/null || true
    fi
    echo "  🚀 Restarting mobile service: $svc"
    "$DC_CMD" -f "$COMPOSE_FILE" -f "$yml_file" up -d --no-deps --force-recreate "$svc" \
      >> "/tmp/${PROJECT_NAME}-mobile.log" 2>&1 || true
  else
    if [[ "$force_rebuild" == "true" ]]; then
      echo "  📦 Rebuilding core service: $svc"
      $DC build "$svc" 2>/dev/null || true
    fi
    echo "  🚀 Restarting core service: $svc"
    "$DC_CMD" -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$svc" \
      >> "/tmp/${PROJECT_NAME}-compose.log" 2>&1 || true
  fi
  echo "  ✅ Service $svc healing initiated"
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
# healing path recreates it properly.
_auto_restart_exited_containers() {
  local exited
  exited=$(podman ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "status=exited" \
    --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  [[ -z "${exited// /}" ]] && return 0
  echo "🔄 Resuming stopped containers..."
  # shellcheck disable=SC2086
  podman start $exited >/dev/null 2>&1 || true
  # Brief pause so Podman's state store reflects "running" before we check status
  sleep 2
}

# The main smart-launch entry point
smart_launch() {
  # Enable systemd lingering FIRST — this is idempotent and ensures containers
  # survive terminal close on Linux/WSL regardless of which path we take below
  # (first run, heal, or all-running).  loginctl enable-linger persists across
  # reboots so it only does real work the very first time per user account.
  _ensure_lingering

  # On macOS: install a launchd agent so the Podman machine persists across
  # terminal sessions and reboots.  Without this the machine stops when the
  # last terminal closes and all containers appear "stopped" on next run.
  _ensure_podman_machine_autostart

  # Podman machine must be running before we can inspect container states
  ensure_podman_running

  # Auto-restart any project containers that are in "exited" or "created" state.
  # "exited" = machine was stopped and restarted (macOS sleep/reboot).
  # "created" = podman-compose 1.5.x bug where up -d creates but doesn't start.
  _auto_restart_exited_containers
  _start_created_containers
  _apply_restart_policy

  discover_apps
  discover_core_svcs   # populates CORE_SVCS from dev.yml

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

  # ── Everything running → show status and optionally open emulator ───────────
  if [[ ${#broken_services[@]} -eq 0 && ${#missing_services[@]} -eq 0 && ${#mobile_broken[@]} -eq 0 && ${#mobile_missing[@]} -eq 0 ]]; then
    echo "✅ All services are running"
    _open_safari
    _start_emulator_with_apps

    # Show current status
    _draw_status
    echo ""
    echo "   Services are running in the background."
    echo "   Run './dev.sh status' to monitor live status."
    echo "   Run './dev.sh logs' to follow logs."
    echo "   Run './dev.sh stop' to stop all services."
    echo "   Run './dev.sh down' to stop and remove everything."
    echo ""
    return 0
  fi

  # ── First run: no images built ───────────────────────────────────────────
  local backend_image_exists=0
  if podman image exists localhost/${PROJECT_NAME}-backend 2>/dev/null || \
     podman image exists localhost/${PROJECT_NAME}_backend 2>/dev/null || \
     podman images --format '{{.Repository}}' 2>/dev/null | grep -qE "${PROJECT_NAME}[-_]backend"; then
    backend_image_exists=1
  fi

  if [[ ${#missing_services[@]} -eq ${#core_services[@]} && $backend_image_exists -eq 0 ]]; then
    echo ""
    echo "🏗️  First run detected — building everything..."
    echo ""

    echo "🏗️  Building core images..."
    $DC build

    build_mobile

    echo ""
    echo "🚀 Starting core services..."
    dc_up_detached "${core_services[@]}"

    run_mobile
    _start_emulator_with_apps

    echo ""
    echo "✅ Everything is up! Services are running in the background."
    echo ""
    echo "   Run './dev.sh status' to monitor live status."
    echo "   Run './dev.sh logs' to follow logs."
    echo "   Run './dev.sh stop' to stop all services."
    echo "   Run './dev.sh down' to stop and remove everything."
    echo ""
    _open_safari || true
    return 0
  fi

  # ── Selective healing: only fix what's broken ────────────────────────────
  echo ""
  echo "🔍 Analyzing service status..."
  
  if [[ ${#running_services[@]} -gt 0 ]]; then
    echo "✅ Running services: ${running_services[*]}"
  fi

  local services_to_start=()
  local services_to_heal=()

  # Handle missing services (need to start)
  if [[ ${#missing_services[@]} -gt 0 ]]; then
    echo "🚀 Missing services (will start): ${missing_services[*]}"
    services_to_start+=("${missing_services[@]}")
  fi

  # Handle broken services (need to rebuild and restart)
  if [[ ${#broken_services[@]} -gt 0 ]]; then
    echo "🔧 Broken services (will heal): ${broken_services[*]}"
    services_to_heal+=("${broken_services[@]}")
  fi

  # Handle mobile services
  if [[ ${#mobile_missing[@]} -gt 0 ]]; then
    echo "📱 Missing mobile services: ${mobile_missing[*]}"
  fi

  if [[ ${#mobile_broken[@]} -gt 0 ]]; then
    echo "🔧 Broken mobile services: ${mobile_broken[*]}"
  fi

  echo ""

  # Heal broken services first (container exists but is stopped/crashed).
  # Prefer `podman start` — it is synchronous and does not remove/recreate the
  # container, so there is no window where the container appears "missing" to the
  # live status display.  Fall back to `--force-recreate` only when `podman start`
  # fails (e.g. the image was removed or the container config changed).
  for svc in "${services_to_heal[@]}"; do
    local cname; cname=$(_cname_from_cache "$_cache" "$svc" "${PROJECT_NAME}-${svc}-1")
    echo "🔧 Restarting service: $svc"
    if podman start "$cname" >/dev/null 2>&1; then
      echo "  ✅ $svc restarted"
    else
      # Container was removed or can't be started — recreate via podman-compose
      "$DC_CMD" -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$svc" \
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
      _heal_service "$svc"
    done

    # Start missing mobile services without rebuilding
    if [[ ${#mobile_missing[@]} -gt 0 ]]; then
      run_mobile
    fi
  fi

  # Start emulator if not already running and we have mobile apps
  # (regardless of whether mobile services needed fixing — emulator may have been closed)
  _start_emulator_with_apps

  # Wait a moment for services to start
  if [[ ${#services_to_start[@]} -gt 0 || ${#services_to_heal[@]} -gt 0 || ${#mobile_services_to_fix[@]} -gt 0 ]]; then
    echo ""
    echo "⏳ Waiting for services to start..."
    sleep 5
  fi

  echo ""
  echo "✅ Service healing complete!"
  echo ""
  echo "   Services are running in the background."
  echo "   Run './dev.sh status' to monitor live status."
  echo "   Run './dev.sh logs' to follow logs."
  echo ""
  _open_safari || true
}

# ── Ensure android/ directory is fully scaffolded and configured ─────────────
# Idempotent: safe to call even when android/ already exists.
# This function is the single source of truth for android/ setup.
# When you delete frontend/mobile/EliteCar/android, running:
#   ./dev.sh build elitecar android --local
# will automatically restore everything from:
#   - app.json (expo config)
#   - package.json (dependencies)
#   - frontend/packages/assets (icons/splash)
#   - .env (Google Maps API key)
#
# Handles:
#   1. npm install (if node_modules missing)
#   2. expo prebuild (if android/ missing)
#   3. Copy icon + splash assets from frontend/packages/assets
#   4. Inject Google Maps API key into strings.xml
#   5. Patch foojay-resolver → 1.0.0
#   6. Write local.properties with ANDROID_HOME
#   7. Make gradlew executable
_ensure_android_dir() {
  local build_folder="$1"
  local android_dir="$2"
  local app_dir="$MOBILE_DIR/$build_folder"
  local packages_assets="$ROOT_DIR/frontend/packages/assets"

  # ── 1. Install node_modules if missing ──────────────────────────────────
  if [[ ! -d "$app_dir/node_modules" ]]; then
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
    (cd "$app_dir" && npx expo prebuild --platform android --no-install) || {
      echo "❌ expo prebuild failed for '$build_folder'."
      echo "   Try manually: cd $app_dir && npm install && npx expo prebuild --platform android"
      exit 1
    }
    echo "✅ android/ directory generated by expo prebuild"
  fi

  # ── 3. Copy assets from frontend/packages/assets ────────────────────────
  # expo prebuild reads icon/splash from app.json paths relative to the app dir.
  # Those paths point to ../packages/assets (i.e. frontend/packages/assets).
  # If that folder is missing or the images aren't there, prebuild silently
  # skips them.  We copy them explicitly so the android res folder is always
  # populated correctly.
  if [[ -d "$packages_assets" ]]; then
    local icon_src="$packages_assets/elitecar-icon.png"
    local splash_src="$packages_assets/elitecar-icon.png"  # same image used for splash

    # Copy splash screen images into every drawable density bucket
    for density in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
      local drawable_dir="$android_dir/app/src/main/res/drawable-${density}"
      if [[ -d "$drawable_dir" && -f "$splash_src" ]]; then
        cp -f "$splash_src" "$drawable_dir/splashscreen_logo.png"
      fi
    done

    # Copy adaptive icon foreground into every mipmap density bucket
    for density in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
      local mipmap_dir="$android_dir/app/src/main/res/mipmap-${density}"
      if [[ -d "$mipmap_dir" && -f "$icon_src" ]]; then
        # expo prebuild generates webp icons; we only copy if the foreground webp is missing
        if [[ ! -f "$mipmap_dir/ic_launcher_foreground.webp" ]]; then
          cp -f "$icon_src" "$mipmap_dir/ic_launcher_foreground.png" 2>/dev/null || true
        fi
      fi
    done
    echo "✅ Assets synced from frontend/packages/assets"
  else
    echo "⚠️  frontend/packages/assets not found — skipping asset copy"
  fi

  # ── 4. Inject Google Maps API key into strings.xml ───────────────────────
  local maps_key="${EXPO_PUBLIC_GOOGLE_MAPS_API_KEY:-}"
  if [[ -z "$maps_key" && -f "$ROOT_DIR/.env" ]]; then
    maps_key=$(grep -E '^EXPO_PUBLIC_GOOGLE_MAPS_API_KEY=' "$ROOT_DIR/.env" \
               | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
  fi

  local strings_xml="$android_dir/app/src/main/res/values/strings.xml"
  if [[ -n "$maps_key" && -f "$strings_xml" ]]; then
    if grep -q 'google_maps_api_key' "$strings_xml"; then
      # Update existing key value
      sed -i.bak "s|<string name=\"google_maps_api_key\"[^>]*>[^<]*</string>|<string name=\"google_maps_api_key\" translatable=\"false\">${maps_key}</string>|g" \
        "$strings_xml" && rm -f "${strings_xml}.bak"
    else
      # Insert before closing </resources>
      sed -i.bak "s|</resources>|  <string name=\"google_maps_api_key\" translatable=\"false\">${maps_key}</string>\n</resources>|" \
        "$strings_xml" && rm -f "${strings_xml}.bak"
    fi
    echo "✅ Google Maps API key set in strings.xml"
  elif [[ -n "$maps_key" && ! -f "$strings_xml" ]]; then
    # strings.xml doesn't exist yet — create it
    mkdir -p "$(dirname "$strings_xml")"
    cat > "$strings_xml" <<STREOF
<resources>
  <string name="app_name">$(echo "$build_folder" | sed 's/ /_/g')</string>
  <string name="google_maps_api_key" translatable="false">${maps_key}</string>
</resources>
STREOF
    echo "✅ Created strings.xml with Google Maps API key"
  fi

  # Also ensure AndroidManifest.xml references the key via @string/google_maps_api_key
  _patch_google_maps_key

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
# Usage: _do_eas_build <app> [android|ios|all] [--profile <profile>]
# Runs `eas build` for the given app in the EAS cloud.
# Fully automatic — creates/re-links the EAS project if needed, no prompts.
# Defaults: platform=all, profile=development
# Override profile: ./dev.sh build elitecar android --profile preview
_do_eas_build() {
  local build_app="$1"
  local build_platform="${2:-all}"
  local eas_profile="development"

  # Allow --profile <name> anywhere in the original args
  local _orig_args=("${@:3}")
  local i=0
  while [[ $i -lt ${#_orig_args[@]} ]]; do
    if [[ "${_orig_args[$i]}" == "--profile" ]]; then
      i=$((i + 1))
      eas_profile="${_orig_args[$i]:-development}"
    fi
    i=$((i + 1))
  done

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
  # Read username directly from state.json — `eas whoami` returns two lines
  # (username + email) which breaks variable interpolation
  local eas_user
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
    echo "   Run: eas login"
    echo "   Then re-run: ./dev.sh build $build_app $build_platform"
    exit 1
  fi
  echo "✅ EAS logged in as: $eas_user"

  # ── Ensure app.json has a valid projectId for this account ───────────────
  # Always verify the projectId belongs to the current account before building.
  # If it's missing, stale, or from a different account — create a new project
  # automatically via the EAS GraphQL API (no interactive prompts).
  _eas_ensure_project_linked() {
    local slug account_id account_name new_id

    # Support both app.json and app.config.js
    local app_config_js="$app_dir/app.config.js"
    if [[ ! -f "$app_json" && -f "$app_config_js" ]]; then
      app_json="$app_config_js"
    fi

    # Read slug and current projectId — handles both app.json and app.config.js
    slug=$(node -e "
try {
  // app.config.js exports a module; app.json is plain JSON
  const cfg = require('$app_dir/app.config.js');
  const expo = cfg.expo || cfg;
  console.log(expo.slug || '');
} catch(e) {
  try {
    const d = JSON.parse(require('fs').readFileSync('$app_dir/app.json','utf8'));
    console.log((d.expo||d).slug || '');
  } catch(e2) { console.log(''); }
}
" 2>/dev/null || true)

    local current_id
    current_id=$(node -e "
try {
  const cfg = require('$app_dir/app.config.js');
  const expo = cfg.expo || cfg;
  console.log((expo.extra||{}).eas?.projectId || '');
} catch(e) {
  try {
    const d = JSON.parse(require('fs').readFileSync('$app_dir/app.json','utf8'));
    const expo = d.expo || d;
    console.log((expo.extra||{}).eas?.projectId || '');
  } catch(e2) { console.log(''); }
}
" 2>/dev/null || true)

    # Get session token from ~/.expo/state.json
    local eas_token
    eas_token=$(node -e "
try {
  const os=require('os'),path=require('path'),fs=require('fs');
  const s=JSON.parse(fs.readFileSync(path.join(os.homedir(),'.expo','state.json'),'utf8'));
  console.log(s.auth?.sessionSecret||s.sessionSecret||s.auth?.token||s.token||'');
} catch(e){console.log('');}
" 2>/dev/null || true)

    if [[ -z "$eas_token" ]]; then
      echo "⚠️  Could not read EAS session — skipping project ID verification."
      return 0
    fi

    # Get account id + name via GraphQL
    local me_resp
    me_resp=$(node -e "
const https=require('https'),fs=require('fs');
const body=JSON.stringify({query:'{ me { username accounts { id name } } }'});
const req=https.request({hostname:'api.expo.dev',path:'/graphql',method:'POST',
  headers:{'Content-Type':'application/json','expo-session':'$eas_token'}},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>console.log(d));});
req.write(body);req.end();
" 2>/dev/null || true)

    account_id=$(echo "$me_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
accs=d.get('data',{}).get('me',{}).get('accounts',[])
print(accs[0]['id'] if accs else '')
" 2>/dev/null || true)

    account_name=$(echo "$me_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
accs=d.get('data',{}).get('me',{}).get('accounts',[])
print(accs[0]['name'] if accs else '')
" 2>/dev/null || true)

    if [[ -z "$account_id" ]]; then
      echo "⚠️  Could not determine EAS account — skipping project ID verification."
      return 0
    fi

    # Check if current projectId is valid for this account
    local id_valid=false
    if [[ -n "$current_id" ]]; then
      local check_resp
      check_resp=$(node -e "
const https=require('https');
const body=JSON.stringify({query:'{ app { byId(appId: \"$current_id\") { id } } }'});
const req=https.request({hostname:'api.expo.dev',path:'/graphql',method:'POST',
  headers:{'Content-Type':'application/json','expo-session':'$eas_token'}},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>console.log(d));});
req.write(body);req.end();
" 2>/dev/null || true)
      if echo "$check_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('app',{}).get('byId',{}).get('id',''))
" 2>/dev/null | grep -q "$current_id"; then
        id_valid=true
      fi
    fi

    if $id_valid; then
      echo "✅ EAS project ID verified: $current_id"
      return 0
    fi

    echo "🔧 Creating new EAS project for '$build_folder' (slug: $slug, account: $account_name)..."

    # Try to create the project (uses accountId as required by the API)
    local create_resp
    create_resp=$(node -e "
const https=require('https');
const body=JSON.stringify({
  query:'mutation { app { createApp(appInput: { accountId: \"$account_id\", projectName: \"$slug\" }) { id fullName } } }'
});
const req=https.request({hostname:'api.expo.dev',path:'/graphql',method:'POST',
  headers:{'Content-Type':'application/json','expo-session':'$eas_token'}},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>console.log(d));});
req.write(body);req.end();
" 2>/dev/null || true)

    new_id=$(echo "$create_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('app',{}).get('createApp',{}).get('id',''))
" 2>/dev/null || true)

    # If creation failed (project already exists), look it up by fullName
    if [[ -z "$new_id" ]]; then
      local lookup_resp
      lookup_resp=$(node -e "
const https=require('https');
const body=JSON.stringify({query:'{ app { byFullName(fullName: \"$account_name/$slug\") { id } } }'});
const req=https.request({hostname:'api.expo.dev',path:'/graphql',method:'POST',
  headers:{'Content-Type':'application/json','expo-session':'$eas_token'}},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>console.log(d));});
req.write(body);req.end();
" 2>/dev/null || true)
      new_id=$(echo "$lookup_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('app',{}).get('byFullName',{}).get('id',''))
" 2>/dev/null || true)
    fi

    if [[ -z "$new_id" ]]; then
      echo "⚠️  Could not create or find EAS project — build may fail."
      return 0
    fi

    echo "✅ EAS project ready (ID: $new_id)"

    # Write new projectId + owner back into app.config.js or app.json
    if [[ -f "$app_dir/app.config.js" ]]; then
      # Patch app.config.js using node — sed the projectId and owner fields
      node -e "
const fs = require('fs');
const path = '$app_dir/app.config.js';
let src = fs.readFileSync(path, 'utf8');
// Update or insert projectId inside eas: { ... }
if (src.includes('projectId:')) {
  src = src.replace(/projectId:\s*['\"].*?['\"]/, 'projectId: \"$new_id\"');
} else {
  src = src.replace(/(eas:\s*\{)/, '\$1\n        projectId: \"$new_id\",');
}
// Update or insert owner
if (src.includes('owner:')) {
  src = src.replace(/owner:\s*['\"].*?['\"]/, 'owner: \"$account_name\"');
} else {
  src = src.replace(/(expo:\s*\{)/, '\$1\n    owner: \"$account_name\",');
}
fs.writeFileSync(path, src);
console.log('✅ app.config.js updated — owner: $account_name, projectId: $new_id');
" 2>/dev/null || echo "⚠️  Could not update app.config.js with new projectId"
    else
      python3 - "$app_json" "$new_id" "$account_name" <<'PYEOF'
import json, sys
path, new_id, account = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
expo = data.setdefault("expo", {})
expo["owner"] = account
expo.setdefault("extra", {}).setdefault("eas", {})["projectId"] = new_id
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"✅ app.json updated — owner: {account}, projectId: {new_id}")
PYEOF
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

  # Run the build and capture the build URL from output
  local _eas_output
  # shellcheck disable=SC2086
  _eas_output=$(cd "$app_dir" && eas build \
    --profile "$eas_profile" \
    $eas_platform_flag \
    --non-interactive \
    2>&1) && _eas_exit=0 || _eas_exit=$?
  echo "$_eas_output"

  if [[ $_eas_exit -ne 0 ]]; then
    echo ""
    echo "❌ EAS build failed."
    echo "   Check the output above for details."
    echo "   Common fixes:"
    echo "     • Not logged in:   eas login"
    echo "     • Wrong profile:   ./dev.sh build $build_app $build_platform --profile <profile>"
    echo "     • Build locally:   ./dev.sh build $build_app $build_platform --local"
    exit 1
  fi

  echo ""
  echo "✅ EAS build complete for '$build_folder'."

  # ── Auto-download APK and install on emulator ────────────────────────────
  # Only for android + development/device profiles (which produce APKs, not AABs)
  if [[ "$build_platform" == "android" || "$build_platform" == "all" ]]; then
    if [[ "$eas_profile" == "development" || "$eas_profile" == "device" || "$eas_profile" == "preview" ]]; then
      echo ""
      echo "📥 Downloading APK from EAS..."

      # Extract build ID from the "See logs:" line in EAS output
      local build_id
      build_id=$(echo "$_eas_output" | grep -oE 'builds/[0-9a-f-]{36}' | head -1 | sed 's|builds/||' || true)

      # Extract direct APK URL if present in output
      local artifact_url
      artifact_url=$(echo "$_eas_output" | grep -oE 'https://[^ ]+\.apk' | head -1 || true)

      # If no direct URL, fetch from EAS API using the build ID
      if [[ -z "$artifact_url" && -n "$build_id" ]]; then
        echo "   Fetching download URL for build $build_id..."
        local eas_token
        eas_token=$(node -e "
try {
  const os=require('os'),path=require('path'),fs=require('fs');
  const s=JSON.parse(fs.readFileSync(path.join(os.homedir(),'.expo','state.json'),'utf8'));
  console.log(s.auth?.sessionSecret||'');
} catch(e){console.log('');}
" 2>/dev/null || true)

        # Poll until artifact URL is available (build may still be finalizing)
        local waited=0
        while [[ $waited -lt 120 ]]; do
          artifact_url=$(node -e "
const https=require('https');
const body=JSON.stringify({query:'{ builds { byId(buildId: \"$build_id\") { artifacts { applicationArchiveUrl } status } } }'});
const req=https.request({hostname:'api.expo.dev',path:'/graphql',method:'POST',
  headers:{'Content-Type':'application/json','expo-session':'$eas_token'}},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>{
    try {
      const r=JSON.parse(d);
      const b=r.data?.builds?.byId;
      if(b?.status==='ERRORED'){process.stdout.write('ERROR');return;}
      console.log(b?.artifacts?.applicationArchiveUrl||'');
    } catch(e){console.log('');}
  });
});
req.write(body);req.end();
" 2>/dev/null || true)
          [[ "$artifact_url" == "ERROR" ]] && echo "❌ Build errored on EAS." && exit 1
          [[ -n "$artifact_url" ]] && break
          echo "   ⏳ Waiting for artifact... (${waited}s)"
          sleep 10; waited=$((waited + 10))
        done
      fi

      if [[ -z "$artifact_url" ]]; then
        echo "⚠️  Could not get APK download URL."
        echo "   Download manually from: https://expo.dev/accounts/$eas_user/projects"
      else
        local output_dir="$ROOT_DIR/frontend/mobile/builds"
        local slug; slug=$(echo "$build_folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        local apk_out="$output_dir/${slug}-android.apk"
        mkdir -p "$output_dir"

        echo "   Downloading → $apk_out"
        curl -L --progress-bar "$artifact_url" -o "$apk_out" && echo "✅ APK saved to frontend/mobile/builds/${slug}-android.apk"

        # Install on connected emulator/device
        _setup_android_path
        if command -v adb &>/dev/null; then
          local connected_device
          connected_device=$(adb devices 2>/dev/null | grep -E '\s+device$' | awk '{print $1}' | head -1 || true)
          if [[ -n "$connected_device" ]]; then
            echo ""
            echo "📲 Installing on $connected_device..."
            _install_app_on_emulator "$slug" "$connected_device"
          else
            echo ""
            echo "   No emulator running. Start one with: ./dev.sh"
            echo "   Then install with: adb install -r frontend/mobile/builds/${slug}-android.apk"
          fi
        fi
      fi
    fi
  fi

  echo ""
  echo "   Monitor at: https://expo.dev/accounts/$eas_user/projects"
}

# ── Build command: Podman images or native APK/IPA ───────────────────────────
# Usage: _do_build [<app> [android|ios] [--local] [--profile <name>]]
_do_build() {
  local build_app="${1:-}"
  local build_platform="android"
  local build_local=false
  local _extra_args=("${@:2}")

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

      echo ""
      echo "========================================="
      echo "🔨 Building native APK: $build_folder"
      echo "   Platform: android  |  Mode: debug"
      echo "========================================="

      "$gradlew" -p "$android_dir" clean 2>&1 || true

      if "$gradlew" -p "$android_dir" assembleDebug 2>&1; then
        local built_apk
        built_apk=$(find "$android_dir/app/build/outputs/apk/debug" -name "*.apk" 2>/dev/null | head -1)
        if [[ -n "$built_apk" ]]; then
          cp "$built_apk" "$output_dir/${slug}-android.apk"
          echo ""
          echo "✅ APK built → frontend/mobile/builds/${slug}-android.apk"

          # ── Auto-install on connected device/emulator ────────────────────
          if command -v adb &>/dev/null; then
            local connected_device
            connected_device=$(adb devices 2>/dev/null | grep -E '\s+device$' | awk '{print $1}' | head -1 || true)
            if [[ -n "$connected_device" ]]; then
              echo ""
              echo "📲 Auto-installing on $connected_device..."
              _install_app_on_emulator "$slug" "$connected_device"

              # Set up adb reverse for Metro so the app connects via localhost
              # (works for both emulator 10.0.2.2 tunnelling and physical devices)
              discover_apps
              local idx=0 metro_port
              for f in "${MOBILE_APPS[@]}"; do
                local fk; fk=$(echo "$f" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
                if [[ "$fk" == "$slug" ]]; then
                  metro_port=$((8081 + idx))
                  break
                fi
                idx=$((idx + 1))
              done
              echo "🔌 Setting up adb reverse for Metro (port ${metro_port:-8081})..."
              adb -s "$connected_device" reverse "tcp:${metro_port:-8081}" "tcp:${metro_port:-8081}" 2>/dev/null || true
              echo "✅ Device ready. Metro available at localhost:${metro_port:-8081} on device."
            else
              echo ""
              echo "   No device/emulator connected. To install manually:"
              echo "   adb install -r frontend/mobile/builds/${slug}-android.apk"
            fi
          fi

          # ── Check Metro status ───────────────────────────────────────────
          echo ""
          local mobile_svc="mobile-${slug}"
          local mobile_container="${PROJECT_NAME}-${mobile_svc}-1"
          local metro_state; metro_state=$(_container_state "$mobile_container")
          if [[ "$metro_state" == "running" ]]; then
            echo "✅ Metro is already running ($mobile_container)."
          else
            echo "⚠️  Metro is not running. Start it with:"
            echo "   ./dev.sh mobile    — start all Metro services"
            echo "   ./dev.sh logs      — follow Metro logs"
          fi
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
    # ── EAS cloud build (app name given, no --local) ─────────────────────
    if [[ -n "$build_app" ]]; then
      _do_eas_build "$build_app" "$build_platform" "${_extra_args[@]}"
    else
      # ── Podman images only (no app name) ──────────────────────────────
      echo "🏗️  Building core images..."
      $DC build
      build_mobile
    fi
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "$CMD" in
  init)
    echo "🔧 Initializing frontend..."
    $DC --profile init run --rm frontend-init
    echo "🔧 Initializing backend..."
    $DC --profile init run --rm backend-init
    ;;

  build)
    _do_build "${@:2}"
    ;;

  up)
    echo "🚀 Starting core services..."
    dc_up_detached $(_parse_compose_services | awk '{print $1}' | tr '\n' ' ')
    run_mobile
    echo ""
    echo "✅ Services started in the background."
    _draw_status
    ;;

  core)
    echo "🚀 Starting core services (no mobile)..."
    dc_up_detached $(_parse_compose_services | awk '{print $1}' | tr '\n' ' ')
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
    _rows=$(mktemp /tmp/${PROJECT_NAME}-status-rows-XXXXXX)
    _draw_status_live "$_rows"
    rm -f "$_rows"
    ;;

  service-logs)
    # ./dev.sh service-logs <container_name>
    _wire_podman_socket 2>/dev/null || true
    _service_log_view "${2:-}"
    ;;

  heal)
    # ./dev.sh heal <service_name>
    if [[ -z "${2:-}" ]]; then
      echo "Usage: ./dev.sh heal <service_name>"
      echo ""
      echo "Available services:"
      discover_core_svcs
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
    
    svc_to_heal="$2"
    echo "🔧 Healing individual service: $svc_to_heal"
    _heal_service "$svc_to_heal" "true"
    echo "✅ Service healing initiated. Run './dev.sh status' to monitor progress."
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
        echo "💡 To fix this service, run: ./dev.sh heal $svc"
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
    _do_rebuild
    ;;

  adb-reverse)
    # ./dev.sh adb-reverse — manually set up port-forwarding for physical Android devices
    # Run this any time you plug in a device or after restarting Metro.
    _setup_android_path
    if ! command -v adb &>/dev/null; then
      echo "❌ adb not found. Make sure Android SDK platform-tools are installed."
      exit 1
    fi
    _setup_physical_devices
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
      mobile_svcs=$(mobile_service_names)
      echo "📱 Starting mobile services: $mobile_svcs"
      yml_file="/tmp/${PROJECT_NAME}-mobile-compose.yml"
      gen_mobile_yaml > "$yml_file"
      # shellcheck disable=SC2086
      "$DC_CMD" -f "$COMPOSE_FILE" -f "$yml_file" up -d --force-recreate $mobile_svcs \
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
    smart_launch
    # Show the live status dashboard. The monitor runs in the foreground so
    # you can see service health. Closing the terminal kills the monitor but
    # NOT the containers — they run inside the Podman daemon (macOS VM or
    # Linux rootless Podman with lingering enabled by smart_launch).
    live_monitor
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
    echo "Usage: $0 [setup|build|up|core|mobile|status|rebuild|release|init|stop|down|logs|heal|check]"
    echo "       $0 build                              — build Podman images only"
    echo "       $0 build <app> [android|ios]          — EAS cloud build (profile: development)"
    echo "       $0 build <app> [android|ios] --profile <p>  — EAS cloud build with profile"
    echo "       $0 build <app> [android|ios] --local  — build native APK/IPA locally"
    echo "       $0 heal <service>                     — rebuild and restart a specific service"
    echo "       $0 check [service]                    — check status of all services or a specific one"
    exit 1
    ;;
esac
