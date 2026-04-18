#!/usr/bin/env bash
# frontend/mobile/scripts/mobile.sh
#
# Single entry-point for all mobile script operations.
#
# Subcommands:
#   gen-app-json          — auto-generate app.json for every app folder
#   start                 — container entrypoint: sync app.json then start Expo (Docker CMD)
#   run <app> [platform]  — cross-platform EAS/local launcher (macOS, Linux, WSL)
#   eas-build             — run EAS cloud builds (called by eas-build service in dev.yml)
#
# Usage:
#   ./mobile.sh gen-app-json
#   ./mobile.sh start
#   ./mobile.sh run [list|<app-key>] [ios|android] [--rebuild] [--prebuild] [--device] [--local]
#   ./mobile.sh eas-build
#
# Environment variables for eas-build:
#   APP       — specific app type to build (e.g. "driver"), or "all" / unset for every app
#   PLATFORM  — ios | android | all  (default: ios)
#   PROFILE   — EAS build profile       (default: development)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$MOBILE_DIR/../.." && pwd)"
BUILDS_DIR="$ROOT_DIR/frontend/mobile/builds"

# ── OS detection ──────────────────────────────────────────────────────────────
_UNAME="$(uname -s)"
case "$_UNAME" in
  Darwin)  RUN_OS="mac" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      RUN_OS="wsl"
    else
      RUN_OS="linux"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*) RUN_OS="windows" ;;
  *) RUN_OS="linux" ;;
esac

# Default Android SDK path per OS
_default_android_sdk() {
  case "$RUN_OS" in
    mac)     echo "$HOME/Library/Android/sdk" ;;
    windows) echo "$HOME/AppData/Local/Android/Sdk" ;;
    *)       echo "$HOME/Android/Sdk" ;;
  esac
}

# Get LAN IP cross-platform
_lan_ip() {
  case "$RUN_OS" in
    mac)
      ipconfig getifaddr en0 2>/dev/null \
        || ipconfig getifaddr en1 2>/dev/null \
        || echo "localhost"
      ;;
    wsl)
      cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}' | head -1 \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || echo "localhost"
      ;;
    *)
      hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
      ;;
  esac
}

# Open a URL / app cross-platform
_open() {
  case "$RUN_OS" in
    mac)     open "$1" ;;
    linux)   xdg-open "$1" 2>/dev/null || true ;;
    wsl)     cmd.exe /c start "" "$1" 2>/dev/null || true ;;
    windows) start "" "$1" 2>/dev/null || true ;;
  esac
}

# Temp file that works everywhere
_tmpfile() { mktemp 2>/dev/null || echo "/tmp/mobile-$-$RANDOM"; }

# ════════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: gen-app-json
# Auto-generates app.json for every app folder. Ported from gen-app-json.js.
# ════════════════════════════════════════════════════════════════════════════════
cmd_gen_app_json() {
  # Delegate to the embedded Node.js implementation below
  node - "$MOBILE_DIR" << 'NODEEOF'
const fs   = require('fs');
const path = require('path');

const MOBILE_DIR = process.argv[2] || path.resolve(__dirname, '..');
const SKIP = new Set(['node_modules', 'shared', 'scripts']);

const toSlug = (name) => name.toLowerCase().replace(/\s+/g, '-');
const toId   = (name) => name.toLowerCase().replace(/\s+/g, '');

const dig = (obj, ...keys) => keys.reduce((o, k) => (o && o[k] !== undefined ? o[k] : null), obj);

const folders = fs.readdirSync(MOBILE_DIR).filter((name) => {
  if (SKIP.has(name)) return false;
  const dir = path.join(MOBILE_DIR, name);
  return fs.statSync(dir).isDirectory() && fs.existsSync(path.join(dir, 'package.json'));
});

if (folders.length === 0) {
  console.log('⚠️  No app folders found.');
  process.exit(0);
}

for (const name of folders) {
  const appDir  = path.join(MOBILE_DIR, name);
  const appJson = path.join(appDir, 'app.json');
  const slug    = toSlug(name);
  const bundleId = `com.${toId(name)}`;

  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(appJson, 'utf8')); } catch (_) {}

  const projectId = dig(existing, 'expo', 'extra', 'eas', 'projectId') || null;
  const owner     = dig(existing, 'expo', 'owner') || null;

  const isBare = fs.existsSync(path.join(appDir, 'android')) ||
                 fs.existsSync(path.join(appDir, 'ios'));

  let config;
  if (isBare) {
    config = {
      expo: {
        name,
        slug,
        version: dig(existing, 'expo', 'version') || '1.0.0',
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
      },
    };
  } else {
    const splashImage = fs.existsSync(path.join(appDir, 'assets', 'splash-icon.png'))
      ? './assets/splash-icon.png'
      : './assets/icon.png';

    config = {
      expo: {
        name,
        slug,
        scheme: slug,
        version: dig(existing, 'expo', 'version') || '1.0.0',
        orientation: 'portrait',
        icon: './assets/icon.png',
        userInterfaceStyle: 'light',
        splash: {
          image: splashImage,
          resizeMode: 'contain',
          backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000',
        },
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ios: {
          supportsTablet: true,
          bundleIdentifier: bundleId,
          infoPlist: {
            NSLocationWhenInUseUsageDescription: `${name} needs your location.`,
            NSLocationAlwaysAndWhenInUseUsageDescription: `${name} needs your location in the background.`,
            ITSAppUsesNonExemptEncryption: false,
            ...dig(existing, 'expo', 'ios', 'infoPlist'),
            NSLocationWhenInUseUsageDescription: `${name} needs your location.`,
            NSLocationAlwaysAndWhenInUseUsageDescription: `${name} needs your location in the background.`,
          },
        },
        android: {
          adaptiveIcon: {
            foregroundImage: './assets/icon.png',
            backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000',
          },
          package: bundleId,
          ...(dig(existing, 'expo', 'android', 'permissions')
            ? { permissions: dig(existing, 'expo', 'android', 'permissions') }
            : {}),
        },
        web: { favicon: './assets/favicon.png' },
        plugins: dig(existing, 'expo', 'plugins') || [
          ['expo-location', {
            locationAlwaysAndWhenInUsePermission: `Allow ${name} to use your location.`,
            locationWhenInUsePermission: `Allow ${name} to use your location.`,
          }],
        ],
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
      },
    };
  }

  fs.writeFileSync(appJson, JSON.stringify(config, null, 2) + '\n');
  console.log(`✅ ${name}  →  ${bundleId}  (${slug})`);
}
NODEEOF
}

# ════════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: start
# Container entrypoint — syncs app.json then launches Expo dev client.
# Used as Docker CMD.
# ════════════════════════════════════════════════════════════════════════════════
cmd_start() {
  echo "🚀 Starting mobile app..."

  echo "🔄 Syncing app.json files..."
  # When running inside Docker, MOBILE_DIR is /app/scripts/.. = /app
  cmd_gen_app_json 2>/dev/null || true

  APP_DIR="/app/${APP_TYPE}"

  if [ ! -d "$APP_DIR" ]; then
    echo "❌ No directory found for APP_TYPE='${APP_TYPE}'"
    echo "   Available apps:"
    ls /app | grep -v node_modules
    exit 1
  fi

  echo "========================================"
  echo "📱 ${APP_TYPE}"
  echo "========================================"

  cd "$APP_DIR"

  exec env REACT_NATIVE_PACKAGER_HOSTNAME="${REACT_NATIVE_PACKAGER_HOSTNAME:-10.0.2.2}" \
    npx expo start --dev-client --port 8081 --non-interactive
}

# ════════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: eas-build
# Runs EAS builds for all (or a specific) app found in frontend/mobile/.
# Called by the eas-build service in dev.yml.
#
# Environment variables:
#   APP       — specific app type to build (e.g. "driver"), or "all" / unset for every app
#   PLATFORM  — ios | android | all  (default: ios)
#   PROFILE   — EAS build profile       (default: development)
# ════════════════════════════════════════════════════════════════════════════════
cmd_eas_build() {
  local _MOBILE_DIR="/app"
  local _PLATFORM="${PLATFORM:-ios}"
  local _PROFILE="${PROFILE:-development}"
  local _TARGET_APP="${APP:-all}"

  # Collect app dirs
  local apps=()
  while IFS= read -r -d '' dir; do
    local name
    name=$(basename "$dir")
    [[ "$name" == "node_modules" || "$name" == "shared" ]] && continue
    [[ -f "$dir/package.json" ]] || continue
    apps+=("$name")
  done < <(find "$_MOBILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ ${#apps[@]} -eq 0 ]]; then
    echo "❌ No app directories found in $_MOBILE_DIR"
    exit 1
  fi

  echo "🔐 Logging into Expo..."
  eas whoami || { echo "❌ EXPO_TOKEN is not set or invalid in .env"; exit 1; }

  for folder in "${apps[@]}"; do
    if [[ "$_TARGET_APP" != "all" ]]; then
      if ! echo "$folder" | grep -qi "$_TARGET_APP"; then
        echo "⏭️  Skipping '$folder' (APP=$_TARGET_APP)"
        continue
      fi
    fi

    echo ""
    echo "========================================="
    echo "📦 EAS build: $folder | platform=$_PLATFORM | profile=$_PROFILE"
    echo "========================================="

    cd "$_MOBILE_DIR/$folder"

    if [[ "$_PLATFORM" == "all" ]]; then
      eas build --profile "$_PROFILE" --platform all --non-interactive
    else
      eas build --profile "$_PROFILE" --platform "$_PLATFORM" --non-interactive
    fi

    cd "$_MOBILE_DIR"
  done

  echo ""
  echo "✅ EAS build(s) complete."
}

# ════════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: run
# Cross-platform EAS/local launcher (macOS, Linux, Windows WSL/Git Bash).
# ════════════════════════════════════════════════════════════════════════════════
cmd_run() {

# ── Discover apps ─────────────────────────────────────────────────────────────
APP_RECORDS=""
_TMP_FIND="$(_tmpfile)"
find "$MOBILE_DIR" -maxdepth 2 -name "app.json" -not -path "*/node_modules/*" > "$_TMP_FIND"
while IFS= read -r app_json; do
  [ -z "$app_json" ] && continue
  folder="$(dirname "$app_json")"
  folder_name="$(basename "$folder")"
  key="$(echo "$folder_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  slug="$(python3 -c "import json; d=json.load(open('$app_json')); print(d['expo'].get('slug','$key'))" 2>/dev/null || echo "$key")"
  APP_RECORDS="${APP_RECORDS}${key}|${folder}|${slug}
"
done < "$_TMP_FIND"
rm -f "$_TMP_FIND"

_app_dir()  { printf '%s' "$APP_RECORDS" | awk -F'|' -v k="$1" '$1==k{print $2; exit}'; }
_app_slug() { printf '%s' "$APP_RECORDS" | awk -F'|' -v k="$1" '$1==k{print $3; exit}'; }
_app_keys() { printf '%s' "$APP_RECORDS" | awk -F'|' 'NF>=3{print $1}' | sort; }

# ── List command ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "list" ]; then
  echo "Available apps:"
  printf '%s\n' "$APP_RECORDS" | while IFS='|' read -r key folder slug; do
    [ -z "$key" ] && continue
    echo "  $key  →  $folder  ($slug)"
  done
  return 0
fi

# ── Parse args ────────────────────────────────────────────────────────────────
local APP="${1:-}"
local PLATFORM="${2:-ios}"
local REBUILD=""
local REAL_DEVICE=false
local PREBUILD=false
local LOCAL_BUILD=false
local PROFILE="development"

if [ -z "$APP" ]; then
  echo "Usage: ./mobile.sh run [list|<app-key>] [ios|android] [--rebuild] [--prebuild] [--device] [--local]"
  echo ""
  echo "  --local   Build on this machine using Gradle/Xcode instead of EAS cloud"
  echo ""
  echo "Available apps:"
  _app_keys
  return 1
fi

for arg in "${@:3}"; do
  case "$arg" in
    --rebuild)  REBUILD="--rebuild" ;;
    --device)   REAL_DEVICE=true ;;
    --prebuild) PREBUILD=true ;;
    --local)    LOCAL_BUILD=true ;;
  esac
done

if [ "$PLATFORM" = "--rebuild" ]; then REBUILD="--rebuild"; PLATFORM="ios"; fi
if [ "$PLATFORM" = "--device" ];  then REAL_DEVICE=true;   PLATFORM="ios"; fi

# ── Validate app key ──────────────────────────────────────────────────────────
local APP_DIR
APP_DIR="$(_app_dir "$APP")"
if [ -z "$APP_DIR" ]; then
  echo "❌ Unknown app: '$APP'"
  echo ""
  echo "Available apps:"
  _app_keys
  return 1
fi

local APP_JSON="$APP_DIR/app.json"

# ── Read config from app.json ─────────────────────────────────────────────────
read_app_json() {
  python3 - "$APP_JSON" "$1" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
expo = data.get("expo", {})
parts = sys.argv[2].split(".")
val = expo
for p in parts:
    val = val.get(p, {}) if isinstance(val, dict) else {}
print(val if isinstance(val, str) else "")
PYEOF
}

local BUNDLE_ID_IOS BUNDLE_ID_ANDROID SCHEME APP_SLUG
BUNDLE_ID_IOS="$(read_app_json "ios.bundleIdentifier")"
BUNDLE_ID_ANDROID="$(read_app_json "android.package")"
SCHEME="$(read_app_json "scheme")"
APP_SLUG="$(_app_slug "$APP")"

if [ -z "$BUNDLE_ID_ANDROID" ] && [ -f "$APP_DIR/android/app/build.gradle" ]; then
  BUNDLE_ID_ANDROID=$(grep -E '^\s*applicationId\s' "$APP_DIR/android/app/build.gradle" | head -1 | sed "s/.*applicationId[[:space:]]*['\"]//;s/['\"].*//")
fi
if [ -z "$BUNDLE_ID_IOS" ] && [ -f "$APP_DIR/ios/$(basename "$APP_DIR").xcodeproj/project.pbxproj" ]; then
  BUNDLE_ID_IOS=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER' "$APP_DIR/ios/$(basename "$APP_DIR").xcodeproj/project.pbxproj" | sed 's/.*= //;s/;//')
fi
if [ -z "$SCHEME" ]; then SCHEME="$(read_app_json "slug")"; fi

[ -z "$BUNDLE_ID_IOS" ]     && BUNDLE_ID_IOS="$BUNDLE_ID_ANDROID"
[ -z "$BUNDLE_ID_ANDROID" ] && BUNDLE_ID_ANDROID="$BUNDLE_ID_IOS"
[ -z "$SCHEME" ]             && SCHEME="$APP_SLUG"

# ── Metro port: stable per-app port based on sorted index ────────────────────
local METRO_BASE=8081
local METRO_PORT=$METRO_BASE
local i=0
local _TMP_KEYS
_TMP_KEYS="$(_tmpfile)"
_app_keys > "$_TMP_KEYS"
while IFS= read -r k; do
  [ -z "$k" ] && continue
  if [ "$k" = "$APP" ]; then
    METRO_PORT=$((METRO_BASE + i))
    break
  fi
  i=$((i + 1))
done < "$_TMP_KEYS"
rm -f "$_TMP_KEYS"

# ── Platform / profile setup ──────────────────────────────────────────────────
local BUNDLE_ID
if [ "$PLATFORM" = "android" ]; then
  BUNDLE_ID="$BUNDLE_ID_ANDROID"
else
  BUNDLE_ID="$BUNDLE_ID_IOS"
fi

if [ "$REAL_DEVICE" = true ] && [ "$PLATFORM" = "ios" ]; then PROFILE="device"; fi

# ── Cache paths ───────────────────────────────────────────────────────────────
local APP_CACHE
if [ "$PLATFORM" = "android" ]; then
  APP_CACHE="$BUILDS_DIR/${APP}-android.apk"
elif [ "$REAL_DEVICE" = true ]; then
  APP_CACHE="$BUILDS_DIR/${APP}-ios-device.ipa"
else
  APP_CACHE="$BUILDS_DIR/${APP}-ios.app"
fi

echo ""
echo "   OS:         $RUN_OS"
echo "   App:        $APP"
echo "   Platform:   $PLATFORM"
echo "   Bundle ID:  $BUNDLE_ID"
echo "   Metro port: $METRO_PORT"
echo ""

# ── 1. Load EXPO_TOKEN ────────────────────────────────────────────────────────
set -a
[ -f "$ROOT_DIR/.env" ] && . "$ROOT_DIR/.env"
set +a

if [ -z "${EXPO_TOKEN:-}" ]; then
  echo "❌ EXPO_TOKEN not set."
  echo "   Add it to .env at the repo root — see EXPO_TOKEN in that file."
  echo "   Get token: https://expo.dev/settings/access-tokens"
  return 1
fi

mkdir -p "$BUILDS_DIR"

# ── 2. Android tooling check + auto-install ───────────────────────────────────
if [ "$PLATFORM" = "android" ]; then
  local ANDROID_SDK="${ANDROID_HOME:-$(_default_android_sdk)}"
  export ANDROID_HOME="$ANDROID_SDK"
  export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator:$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/cmdline-tools/bin:$PATH"

  if [ "$RUN_OS" = "mac" ] && [ -z "${JAVA_HOME:-}" ]; then
    local _jh
    _jh="$(/usr/libexec/java_home 2>/dev/null || true)"
    if [ -z "$_jh" ] || [ ! -x "$_jh/bin/java" ]; then
      for _vm in /Library/Java/JavaVirtualMachines/*/Contents/Home \
                 /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                 /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
        if [ -x "$_vm/bin/java" ]; then _jh="$_vm"; break; fi
      done
    fi
    if [ -n "$_jh" ] && [ -x "$_jh/bin/java" ]; then
      export JAVA_HOME="$_jh"
      export PATH="$JAVA_HOME/bin:$PATH"
    fi
  fi

  _install_android_sdk() {
    echo "📦 Android SDK not found. Installing via command-line tools..."

    _ensure_java_home() {
      if [ "$RUN_OS" = "mac" ]; then
        local jh
        jh="$(/usr/libexec/java_home 2>/dev/null || true)"
        if [ -n "$jh" ] && [ -x "$jh/bin/java" ]; then
          export JAVA_HOME="$jh"; export PATH="$JAVA_HOME/bin:$PATH"; return 0
        fi
        local vm
        for vm in /Library/Java/JavaVirtualMachines/*/Contents/Home; do
          if [ -x "$vm/bin/java" ]; then
            export JAVA_HOME="$vm"; export PATH="$JAVA_HOME/bin:$PATH"; return 0
          fi
        done
        for vm in /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
                  /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
          if [ -x "$vm/bin/java" ]; then
            export JAVA_HOME="$vm"; export PATH="$JAVA_HOME/bin:$PATH"; return 0
          fi
        done
        return 1
      fi
      command -v java >/dev/null 2>&1
    }

    if ! _ensure_java_home; then
      echo "📦 Installing Java (required for Android SDK)..."
      case "$RUN_OS" in
        mac)
          command -v brew >/dev/null 2>&1 || { echo "❌ Homebrew required. Run: ./dev.sh setup"; exit 1; }
          local pkg
          pkg="$(find /opt/homebrew/Caskroom/temurin -name '*.pkg' 2>/dev/null | head -1)"
          if [ -n "$pkg" ]; then
            echo "   Found Temurin pkg, running installer (requires sudo)..."
            sudo installer -pkg "$pkg" -target /
          else
            brew install openjdk@21
            local jh="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
            [ -d "$jh" ] || jh="/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
            if [ -x "$jh/bin/java" ]; then
              export JAVA_HOME="$jh"; export PATH="$JAVA_HOME/bin:$PATH"
            fi
          fi
          if ! _ensure_java_home; then
            echo "❌ Java still not found after install."
            echo "   Run manually: sudo installer -pkg \"\$(find /opt/homebrew/Caskroom/temurin -name '*.pkg' | head -1)\" -target /"
            echo "   Or: brew install openjdk@21"
            exit 1
          fi
          ;;
        linux|wsl)
          if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y default-jdk
          elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y java-17-openjdk
          else
            echo "❌ Cannot auto-install Java. Install from: https://adoptium.net"; exit 1
          fi
          ;;
        windows)
          if command -v winget >/dev/null 2>&1; then
            winget install -e --id EclipseAdoptium.Temurin.17.JDK
          elif command -v choco >/dev/null 2>&1; then
            choco install temurin17 -y
          else
            echo "❌ Cannot auto-install Java. Install from: https://adoptium.net"; exit 1
          fi
          ;;
      esac
    fi

    local CMDLINE_TOOLS_DIR="$ANDROID_SDK/cmdline-tools/latest"
    mkdir -p "$CMDLINE_TOOLS_DIR"

    local CMDLINE_URL
    case "$RUN_OS" in
      mac) CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip" ;;
      *)   CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" ;;
    esac

    local TMP_ZIP="/tmp/android-cmdline-tools.zip"
    echo "   Downloading Android command-line tools..."
    curl -L "$CMDLINE_URL" -o "$TMP_ZIP" --progress-bar
    local TMP_EXTRACT="/tmp/android-cmdline-extract"
    rm -rf "$TMP_EXTRACT" && mkdir -p "$TMP_EXTRACT"
    unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT"
    [ -d "$TMP_EXTRACT/cmdline-tools" ] && cp -r "$TMP_EXTRACT/cmdline-tools/." "$CMDLINE_TOOLS_DIR/"
    rm -rf "$TMP_ZIP" "$TMP_EXTRACT"
    export PATH="$CMDLINE_TOOLS_DIR/bin:$PATH"

    echo "   Accepting licenses and installing SDK packages..."
    yes | sdkmanager --sdk_root="$ANDROID_SDK" --licenses >/dev/null 2>&1 || true
    local _HOST_ARCH
    _HOST_ARCH="$(uname -m)"
    local _SYS_IMAGE
    if [ "$_HOST_ARCH" = "arm64" ] || [ "$_HOST_ARCH" = "aarch64" ]; then
      _SYS_IMAGE="system-images;android-34;google_apis;arm64-v8a"
    else
      _SYS_IMAGE="system-images;android-34;google_apis;x86_64"
    fi
    sdkmanager --sdk_root="$ANDROID_SDK" \
      "platform-tools" "emulator" "platforms;android-34" "$_SYS_IMAGE" "build-tools;34.0.0"

    export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator:$CMDLINE_TOOLS_DIR/bin:$PATH"
    echo "✅ Android SDK installed at $ANDROID_SDK"
  }

  _ensure_avd() {
    local AVD_NAME="dev_avd"
    if ! emulator -list-avds 2>/dev/null | grep -q "$AVD_NAME"; then
      echo "📱 No AVD found. Creating '$AVD_NAME'..."
      local _HOST_ARCH _SYS_IMAGE
      _HOST_ARCH="$(uname -m)"
      if [ "$_HOST_ARCH" = "arm64" ] || [ "$_HOST_ARCH" = "aarch64" ]; then
        _SYS_IMAGE="system-images;android-34;google_apis;arm64-v8a"
      else
        _SYS_IMAGE="system-images;android-34;google_apis;x86_64"
      fi
      sdkmanager --sdk_root="$ANDROID_SDK" "$_SYS_IMAGE" 2>/dev/null || true
      echo "no" | avdmanager create avd \
        --name "$AVD_NAME" --package "$_SYS_IMAGE" --device "pixel_6" --force 2>/dev/null || \
      echo "no" | avdmanager create avd \
        --name "$AVD_NAME" --package "$_SYS_IMAGE" --force
      echo "✅ AVD '$AVD_NAME' created"
    fi
  }

  if ! command -v adb >/dev/null 2>&1; then
    if [ -f "$ANDROID_SDK/platform-tools/adb" ]; then
      export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator:$PATH"
    else
      _install_android_sdk
    fi
  fi

  [ ! command -v emulator >/dev/null 2>&1 ] && export PATH="$ANDROID_SDK/emulator:$PATH" || true

  if [ "$REAL_DEVICE" = false ]; then
    _ensure_avd
  fi
fi

# ── 3. iOS platform guard ─────────────────────────────────────────────────────
if [ "$PLATFORM" = "ios" ] && [ "$RUN_OS" != "mac" ]; then
  echo "❌ iOS builds require macOS. You are on: $RUN_OS"
  echo "   Use EAS cloud builds instead: ./mobile.sh run $APP ios"
  echo "   Or switch to Android: ./mobile.sh run $APP android"
  return 1
fi

# ── 4. Local build (--local flag) ─────────────────────────────────────────────
local CACHE_EXISTS=false
if [ "$LOCAL_BUILD" = true ]; then
  echo "🔨 Building locally (skipping EAS)..."

  if [ "$PLATFORM" = "android" ]; then
    local GRADLEW="$APP_DIR/android/gradlew"
    if [ ! -f "$GRADLEW" ]; then
      echo "❌ No android/gradlew found. Run --prebuild first."; return 1
    fi
    echo "   Running Gradle assembleDebug..."
    echo "sdk.dir=$ANDROID_SDK" > "$APP_DIR/android/local.properties"
    chmod +x "$GRADLEW"
    "$GRADLEW" -p "$APP_DIR/android" assembleDebug 2>&1
    local LOCAL_APK
    LOCAL_APK=$(find "$APP_DIR/android/app/build/outputs/apk/debug" -name "*.apk" | head -1)
    [ -z "$LOCAL_APK" ] && echo "❌ APK not found after build." && return 1
    cp "$LOCAL_APK" "$APP_CACHE"
    echo "✅ Built and cached at $APP_CACHE"
  else
    if ! command -v xcodebuild >/dev/null 2>&1; then
      echo "❌ xcodebuild not found. Install Xcode from the App Store."; return 1
    fi
    local XCWORKSPACE XCODEPROJ SCHEME_NAME BUILD_DIR BUILD_SRC FOUND_APP
    XCWORKSPACE=$(find "$APP_DIR/ios" -name "*.xcworkspace" -maxdepth 1 | head -1)
    XCODEPROJ=$(find "$APP_DIR/ios" -name "*.xcodeproj" -maxdepth 1 | head -1)
    SCHEME_NAME="$(basename "$APP_DIR")"
    BUILD_DIR="$APP_DIR/ios/build"

    if [ -n "$XCWORKSPACE" ]; then
      BUILD_SRC="-workspace $XCWORKSPACE"
    elif [ -n "$XCODEPROJ" ]; then
      BUILD_SRC="-project $XCODEPROJ"
    else
      echo "❌ No .xcworkspace or .xcodeproj found. Run --prebuild first."; return 1
    fi

    if [ "$REAL_DEVICE" = true ]; then
      # shellcheck disable=SC2086
      xcodebuild $BUILD_SRC -scheme "$SCHEME_NAME" -configuration Debug \
        -destination "generic/platform=iOS" -derivedDataPath "$BUILD_DIR" build 2>&1
      FOUND_APP=$(find "$BUILD_DIR" -name "*.app" -maxdepth 6 | head -1)
    else
      # shellcheck disable=SC2086
      xcodebuild $BUILD_SRC -scheme "$SCHEME_NAME" -configuration Debug \
        -sdk iphonesimulator -derivedDataPath "$BUILD_DIR" build 2>&1
      FOUND_APP=$(find "$BUILD_DIR" -name "*.app" -path "*/iphonesimulator*" -maxdepth 6 | head -1)
    fi

    [ -z "$FOUND_APP" ] && echo "❌ .app not found after build." && return 1
    rm -rf "$APP_CACHE" && cp -r "$FOUND_APP" "$APP_CACHE"
    echo "✅ Built and cached at $APP_CACHE"
  fi

  CACHE_EXISTS=true
fi

# ── 5. EAS Build ──────────────────────────────────────────────────────────────
if [ "$PLATFORM" = "android" ] && [ -f "$APP_CACHE" ]; then
  CACHE_EXISTS=true
elif [ "$PLATFORM" = "ios" ] && [ "$REAL_DEVICE" = true ] && [ -f "$APP_CACHE" ]; then
  CACHE_EXISTS=true
elif [ "$PLATFORM" = "ios" ] && [ "$REAL_DEVICE" = false ] && [ -d "$APP_CACHE" ]; then
  CACHE_EXISTS=true
fi

if ! command -v eas >/dev/null 2>&1; then
  echo "📦 Installing eas-cli..."
  npm install -g eas-cli
fi

_eas_cloud_artifact() {
  EXPO_TOKEN="$EXPO_TOKEN" eas build:list \
    --profile "$PROFILE" --platform "$PLATFORM" \
    --status finished --limit 5 --non-interactive --json 2>/dev/null \
  | python3 -c "
import json, sys
try:
    builds = json.load(sys.stdin)
    if not isinstance(builds, list): builds = [builds]
    for b in builds:
        if b.get('status','').upper() != 'FINISHED': continue
        url = (b.get('artifacts') or {}).get('buildUrl') or b.get('artifactUrl') or ''
        if url: print(url); sys.exit(0)
except: pass
" 2>/dev/null || echo ""
}

local ARTIFACT_URL=""

if [ "$REBUILD" = "--rebuild" ]; then
  echo "🔨 --rebuild flag set, forcing a new EAS build..."
elif [ "$CACHE_EXISTS" = true ]; then
  echo "✅ Using cached build at $APP_CACHE"
  echo "   (run with --rebuild to force a new EAS build)"
else
  echo "🔍 Checking EAS cloud for an existing build..."
  cd "$APP_DIR"
  ARTIFACT_URL=$(_eas_cloud_artifact)
  cd - > /dev/null
  [ -n "$ARTIFACT_URL" ] && echo "✅ Found existing build on EAS cloud." || echo "   No existing build found."
fi

if [ "$CACHE_EXISTS" = false ] && [ -z "$ARTIFACT_URL" ]; then
  echo "🔨 Building dev client on EAS cloud (~5-10 min)..."
  echo "   App: $APP | Profile: $PROFILE | Platform: $PLATFORM"
  echo ""
  cd "$APP_DIR"

  local WORKSPACE_NM="$MOBILE_DIR/node_modules"
  if [ ! -d "node_modules/expo-dev-client" ]; then
    if [ -d "$WORKSPACE_NM/expo-dev-client" ]; then
      echo "🔗 Linking workspace node_modules into app dir..."
      rm -rf node_modules
      ln -s "$WORKSPACE_NM" node_modules
    else
      echo "📦 Installing workspace dependencies..."
      npm install --no-audit --no-fund --legacy-peer-deps --prefix "$MOBILE_DIR"
      rm -rf node_modules
      ln -s "$WORKSPACE_NM" node_modules
    fi
    echo ""
  fi

  if [ "$PREBUILD" = true ]; then
    echo "🔧 Running expo prebuild --clean..."
    npx expo install expo-dev-client
    npx expo prebuild --clean
    echo ""
  fi

  if [ "$PLATFORM" = "android" ]; then
    local KEYSTORE_PATH="$APP_DIR/android/app/debug.keystore"
    if [ ! -f "$KEYSTORE_PATH" ]; then
      echo "🔑 Generating debug.keystore..."
      local JAVA_BIN="${JAVA_HOME:-}/bin/keytool"
      if [ ! -x "$JAVA_BIN" ]; then JAVA_BIN="keytool"; fi
      "$JAVA_BIN" -genkeypair -v \
        -keystore "$KEYSTORE_PATH" \
        -storepass android -alias androiddebugkey -keypass android \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" 2>&1
      echo "✅ debug.keystore created"
    fi
  fi

  local WHOAMI
  WHOAMI=$(EXPO_TOKEN="$EXPO_TOKEN" eas whoami 2>&1 || true)
  if echo "$WHOAMI" | grep -q "Not logged in\|invalid\|expired\|error"; then
    echo "❌ EAS authentication failed: $WHOAMI"
    echo "   Get a fresh token at: https://expo.dev/settings/access-tokens"
    return 1
  fi
  echo "   Authenticated as: $WHOAMI"

  local BUILD_LOG="/tmp/eas-build-${APP}-${PLATFORM}.log"
  EXPO_TOKEN="$EXPO_TOKEN" eas build \
    --profile "$PROFILE" --platform "$PLATFORM" \
    --non-interactive --wait --json 2>&1 | tee "$BUILD_LOG"

  ARTIFACT_URL=$(python3 -c "
import json, re, sys
log = open('$BUILD_LOG').read()
for m in reversed(re.findall(r'(\{.*\}|\[.*\])', log, re.DOTALL)):
    try:
        data = json.loads(m)
        builds = data if isinstance(data, list) else [data]
        for b in builds:
            url = (b.get('artifacts') or {}).get('buildUrl') or b.get('artifactUrl') or ''
            if url: print(url); sys.exit(0)
    except: pass
" 2>/dev/null || echo "")

  cd - > /dev/null
  [ -z "$ARTIFACT_URL" ] && echo "❌ Could not get build artifact URL from EAS." && return 1
fi

# ── 6. Download artifact ──────────────────────────────────────────────────────
if [ -n "$ARTIFACT_URL" ] && [ "$CACHE_EXISTS" = false ]; then
  echo ""
  echo "📥 Downloading artifact..."
  if [ "$PLATFORM" = "android" ]; then
    curl -L "$ARTIFACT_URL" -o "$APP_CACHE" --progress-bar
    echo "✅ Cached at $APP_CACHE"
  else
    local ARCHIVE="$BUILDS_DIR/${APP}-dev-client.tar.gz"
    curl -L "$ARTIFACT_URL" -o "$ARCHIVE" --progress-bar
    local EXTRACT_DIR="$BUILDS_DIR/${APP}-extracted"
    rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
    tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" 2>/dev/null || unzip -q "$ARCHIVE" -d "$EXTRACT_DIR" 2>/dev/null || true
    local FOUND_APP
    FOUND_APP=$(find "$EXTRACT_DIR" -name "*.app" -maxdepth 3 | head -1)
    [ -z "$FOUND_APP" ] && echo "❌ Could not find .app bundle in downloaded archive." && return 1
    rm -rf "$APP_CACHE" && cp -r "$FOUND_APP" "$APP_CACHE"
    echo "✅ Cached at $APP_CACHE"
  fi
fi

# ── 7. Launch ─────────────────────────────────────────────────────────────────
local LAN_IP
LAN_IP="$(_lan_ip)"

if [ "$PLATFORM" = "android" ]; then
  echo ""
  echo "📱 Starting Android..."

  local RUNNING_DEVICE
  if [ "$REAL_DEVICE" = true ]; then
    RUNNING_DEVICE=$(adb devices | grep -v "emulator" | grep "device$" | awk '{print $1}' | head -1)
    if [ -z "$RUNNING_DEVICE" ]; then
      echo "❌ No Android device detected via USB."
      echo "   Enable USB debugging and trust this computer on your phone."
      return 1
    fi
    echo "   Found device: $RUNNING_DEVICE"
  else
    RUNNING_DEVICE=$(adb devices | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
    if [ -z "$RUNNING_DEVICE" ]; then
      local AVD_NAME
      AVD_NAME=$(emulator -list-avds 2>/dev/null | head -1)
      [ -z "$AVD_NAME" ] && AVD_NAME="dev_avd"
      echo "   Booting AVD: $AVD_NAME"
      emulator -avd "$AVD_NAME" -no-snapshot-load -gpu host >/tmp/emulator.log 2>&1 &
      echo "   Waiting for emulator to boot..."
      adb wait-for-device
      local _boot_wait=0
      while [ "$_boot_wait" -lt 90 ]; do
        local BOOT_DONE
        BOOT_DONE=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT_DONE" = "1" ] && break
        sleep 3
        _boot_wait=$((_boot_wait + 3))
      done
      sleep 2
      RUNNING_DEVICE=$(adb devices | grep "emulator" | grep "device$" | awk '{print $1}' | head -1)
    fi
    echo "   Emulator ready: $RUNNING_DEVICE"

    _push_real_location() {
      local lat="" lon="" src=""
      if [ "$RUN_OS" = "mac" ]; then
        local _loc
        _loc=$(python3 - 2>/dev/null <<'PYEOF'
import time, sys
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
        if [ -n "$_loc" ]; then
          lat=$(echo "$_loc" | awk '{print $1}')
          lon=$(echo "$_loc" | awk '{print $2}')
          src="CoreLocation"
        fi
      fi

      if [ -z "$lat" ]; then
        local _geo
        _geo=$(curl -sf --max-time 5 "https://ipapi.co/json/" 2>/dev/null \
          | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['latitude'], d['longitude'])" 2>/dev/null || echo "")
        if [ -n "$_geo" ]; then
          lat=$(echo "$_geo" | awk '{print $1}')
          lon=$(echo "$_geo" | awk '{print $2}')
          src="IP geolocation (approximate)"
        fi
      fi

      if [ -n "$lat" ] && [ -n "$lon" ]; then
        echo "   📍 Setting emulator location: $lat, $lon (via $src)"
        adb -s "$RUNNING_DEVICE" emu geo fix "$lon" "$lat" 2>/dev/null || true
      else
        echo "   ⚠️  Could not determine host location — emulator will use its default."
        echo "      Grant Terminal location access in: System Settings → Privacy & Security → Location Services"
      fi
    }
    _push_real_location
  fi

  echo ""
  echo "📦 Installing APK..."
  adb -s "$RUNNING_DEVICE" uninstall "$BUNDLE_ID" 2>/dev/null || true
  adb -s "$RUNNING_DEVICE" install -r "$APP_CACHE"
  echo "✅ Installed!"

  echo "🎯 Launching app..."
  adb -s "$RUNNING_DEVICE" shell am start -n "${BUNDLE_ID}/.MainActivity"

  adb -s "$RUNNING_DEVICE" reverse "tcp:${METRO_PORT}" "tcp:${METRO_PORT}"
  echo "   Port forwarded: device:${METRO_PORT} → host:${METRO_PORT}"

  sleep 3
  local METRO_URL="http%3A%2F%2Flocalhost%3A${METRO_PORT}"
  adb -s "$RUNNING_DEVICE" shell am start \
    -a android.intent.action.VIEW \
    -d "exp+${SCHEME}://expo-development-client/?url=${METRO_URL}" \
    "${BUNDLE_ID}"

else
  # ── iOS ──────────────────────────────────────────────────────────────────
  if [ "$REAL_DEVICE" = true ]; then
    echo ""
    echo "📱 Installing on real iPhone..."
    local DEVICE_UDID
    DEVICE_UDID=$(xcrun xctrace list devices 2>/dev/null \
      | grep -v "Simulator" \
      | grep -E "\([0-9A-Fa-f]{40,}\)" \
      | head -1 \
      | grep -oE "[0-9A-Fa-f]{40,}" \
      | head -1)

    if [ -z "$DEVICE_UDID" ]; then
      echo "❌ No iPhone detected via USB."
      echo "   Or drag the .ipa onto your device in Xcode → Devices and Simulators:"
      echo "   $APP_CACHE"
      return 1
    fi

    echo "✅ Installed on iPhone!"
    echo "👉 Open the dev client and enter: http://${LAN_IP}:${METRO_PORT}"

  else
    echo ""
    echo "📱 Opening iOS Simulator..."
    open -a Simulator

    local BOOTED_UDID=""
    local _sim_wait=0
    while [ "$_sim_wait" -lt 30 ]; do
      BOOTED_UDID=$(xcrun simctl list devices | grep "Booted" | grep -o '[A-F0-9-]\{36\}' | head -1)
      [ -n "$BOOTED_UDID" ] && break
      sleep 2
      _sim_wait=$((_sim_wait + 2))
    done

    if [ -z "$BOOTED_UDID" ]; then
      local DEFAULT_SIM
      DEFAULT_SIM=$(xcrun simctl list devices available | grep "iPhone" | grep -v "unavailable" | tail -1 | grep -o '[A-F0-9-]\{36\}')
      if [ -z "$DEFAULT_SIM" ]; then
        echo "❌ No available iPhone simulator found."; return 1
      fi
      xcrun simctl boot "$DEFAULT_SIM"
      open -a Simulator
      sleep 5
      BOOTED_UDID="$DEFAULT_SIM"
    fi

    echo "   Simulator ready: $BOOTED_UDID"
    echo "📲 Installing..."
    xcrun simctl install "$BOOTED_UDID" "$APP_CACHE"
    echo "✅ Installed!"

    echo "🎯 Launching app..."
    xcrun simctl launch "$BOOTED_UDID" "$BUNDLE_ID"

    sleep 6
    local METRO_URL="http%3A%2F%2F${LAN_IP}%3A${METRO_PORT}"
    xcrun simctl openurl "$BOOTED_UDID" "exp+${SCHEME}://expo-development-client/?url=${METRO_URL}" 2>/dev/null || {
      echo "   Retrying deep-link in 4s..."
      sleep 4
      xcrun simctl openurl "$BOOTED_UDID" "exp+${SCHEME}://expo-development-client/?url=${METRO_URL}"
    }
  fi
fi

echo ""
echo "✅ Done!"
echo "   App:      $APP ($BUNDLE_ID)"
echo "   Platform: $PLATFORM$([ "$REAL_DEVICE" = true ] && echo ' (real device)')"
echo "   Metro:    http://${LAN_IP}:${METRO_PORT}"
echo ""
echo "   Make sure Metro is running:"
echo "   ./dev.sh mobile   (or: podman-compose -f dev.yml up mobile-${APP_SLUG})"

} # end cmd_run

# ════════════════════════════════════════════════════════════════════════════════
# DISPATCH
# ════════════════════════════════════════════════════════════════════════════════
SUBCMD="${1:-}"
shift || true

case "$SUBCMD" in
  gen-app-json) cmd_gen_app_json ;;
  start)        cmd_start ;;
  eas-build)    cmd_eas_build ;;
  run)          cmd_run "$@" ;;
  *)
    echo "Usage: $(basename "$0") <subcommand> [args...]"
    echo ""
    echo "Subcommands:"
    echo "  gen-app-json          Auto-generate app.json for every app folder"
    echo "  start                 Container entrypoint: sync app.json then start Expo"
    echo "  run [list|<app>] ...  Launch app on device/simulator via EAS or local build"
    echo "  eas-build             Run EAS cloud builds (used by dev.yml eas-build service)"
    echo ""
    echo "Run 'mobile.sh run' with no args for run-specific usage."
    exit 1
    ;;
esac
