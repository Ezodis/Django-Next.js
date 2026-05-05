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

// Read package/bundleIdentifier from app.config.js if it exists
const readAppConfigJs = (appDir) => {
  const configPath = path.join(appDir, 'app.config.js');
  if (!fs.existsSync(configPath)) return {};
  try {
    // Temporarily set module.exports capture
    const mod = { exports: {} };
    const src = fs.readFileSync(configPath, 'utf8');
    // Use Function constructor to evaluate in isolated scope
    const fn = new Function('module', 'exports', 'require', 'process', src);
    fn(mod, mod.exports, require, process);
    const cfg = mod.exports.expo || mod.exports;
    return {
      androidPackage: dig(cfg, 'android', 'package') || null,
      iosBundleId:    dig(cfg, 'ios', 'bundleIdentifier') || null,
    };
  } catch (_) { return {}; }
};

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
  const appConfig = readAppConfigJs(appDir);
  const bundleId = appConfig.androidPackage || appConfig.iosBundleId || `com.${toId(name)}`;

  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(appJson, 'utf8')); } catch (_) {}

  const projectId = dig(existing, 'expo', 'extra', 'eas', 'projectId') || null;
  const owner     = dig(existing, 'expo', 'owner') || null;

  const isBare = fs.existsSync(path.join(appDir, 'android')) ||
                 fs.existsSync(path.join(appDir, 'ios'));

  let config;
  if (isBare) {
    // For bare workflow apps, preserve all existing fields and only fill in missing ones
    config = {
      expo: {
        name,
        slug,
        version: dig(existing, 'expo', 'version') || '1.0.0',
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ...(dig(existing, 'expo', 'icon') ? { icon: dig(existing, 'expo', 'icon') } : {}),
        ...(dig(existing, 'expo', 'splash') ? { splash: dig(existing, 'expo', 'splash') } : {}),
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
        ...(dig(existing, 'expo', 'android') ? { android: dig(existing, 'expo', 'android') } : {}),
        ...(dig(existing, 'expo', 'ios') ? { ios: dig(existing, 'expo', 'ios') } : {}),
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
# HELPER: _ensure_maps_key
# Writes GOOGLE_MAPS_API_KEY into gradle.properties and AndroidManifest.xml for
# every bare-workflow app that has an android/ folder.
# Called before every Gradle build and on container start so the key is always
# present even if gradle.properties or the manifest was deleted / regenerated.
# ════════════════════════════════════════════════════════════════════════════════
_ensure_maps_key() {
  local app_dir="${1:-}"   # optional: target a single app dir
  local key="${GOOGLE_MAPS_API_KEY:-}"

  # Also check EXPO_PUBLIC_GOOGLE_MAPS_API_KEY (the name used in .env)
  if [ -z "$key" ]; then
    key="${EXPO_PUBLIC_GOOGLE_MAPS_API_KEY:-}"
  fi

  # Load from .env if not already in the environment
  if [ -z "$key" ] && [ -f "$ROOT_DIR/.env" ]; then
    key=$(grep -E '^EXPO_PUBLIC_GOOGLE_MAPS_API_KEY=' "$ROOT_DIR/.env" | head -1 | cut -d'=' -f2- | tr -d '"'"'" | tr -d '[:space:]')
  fi
  if [ -z "$key" ] && [ -f "$ROOT_DIR/.env" ]; then
    key=$(grep -E '^GOOGLE_MAPS_API_KEY=' "$ROOT_DIR/.env" | head -1 | cut -d'=' -f2- | tr -d '"'"'" | tr -d '[:space:]')
  fi

  if [ -z "$key" ]; then
    echo "⚠️  GOOGLE_MAPS_API_KEY not found in environment or .env — skipping Maps key injection"
    return 0
  fi

  # Determine which app dirs to patch
  local dirs=()
  if [ -n "$app_dir" ] && [ -d "$app_dir/android" ]; then
    dirs=("$app_dir")
  else
    # Scan all app folders
    local scan_root="${app_dir:-$MOBILE_DIR}"
    while IFS= read -r -d '' dir; do
      local name; name="$(basename "$dir")"
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac
      [ -f "$dir/package.json" ] || continue
      [ -d "$dir/android" ] || continue
      dirs+=("$dir")
    done < <(find "$scan_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi

  for dir in "${dirs[@]}"; do
    local gradle_props="$dir/android/gradle.properties"
    local manifest="$dir/android/app/src/main/AndroidManifest.xml"

    # ── gradle.properties ────────────────────────────────────────────────────
    if [ -f "$gradle_props" ]; then
      if grep -q '^GOOGLE_MAPS_API_KEY=' "$gradle_props"; then
        # Update existing entry
        sed -i.bak "s|^GOOGLE_MAPS_API_KEY=.*|GOOGLE_MAPS_API_KEY=${key}|" "$gradle_props" && rm -f "${gradle_props}.bak"
      else
        printf '\n# Google Maps API key (auto-injected by mobile.sh)\nGOOGLE_MAPS_API_KEY=%s\n' "$key" >> "$gradle_props"
      fi
      echo "✅ Maps key written to $(basename "$dir")/android/gradle.properties"
    fi

    # ── AndroidManifest.xml ──────────────────────────────────────────────────
    if [ -f "$manifest" ]; then
      if grep -q 'com.google.android.geo.API_KEY' "$manifest"; then
        # Update existing entry with the actual key value (not a placeholder)
        sed -i.bak "s|android:name=\"com.google.android.geo.API_KEY\"[^/]*/> *|android:name=\"com.google.android.geo.API_KEY\" android:value=\"${key}\"/>|g" "$manifest" && rm -f "${manifest}.bak"
      else
        # Inject after the opening <application tag
        sed -i.bak "s|<application \([^>]*\)>|<application \1>\n    <meta-data android:name=\"com.google.android.geo.API_KEY\" android:value=\"${key}\"/>|" "$manifest" && rm -f "${manifest}.bak"
      fi
      echo "✅ Maps key meta-data ensured in $(basename "$dir")/AndroidManifest.xml"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: start
# Container entrypoint — syncs app.json then launches Expo dev client.
# Used as Docker CMD.
# ════════════════════════════════════════════════════════════════════════════════
cmd_start() {
  echo "🚀 Starting mobile app..."

  # ── Ensure @assets symlinks exist in every app's node_modules ──────────────
  # This makes require('@assets/Logo.png') work in Metro without any custom resolver.
  # The packages/ dir is at /app/packages/ in Docker (copied by Dockerfile).
  echo "🔗 Setting up @assets symlinks..."
  PACKAGES_ASSETS="/app/packages/assets"
  if [ -d "$PACKAGES_ASSETS" ]; then
    for app_dir in /app/*/; do
      app_name="$(basename "$app_dir")"
      case "$app_name" in node_modules|shared|scripts|packages|builds) continue ;; esac
      [ -f "$app_dir/package.json" ] || continue
      assets_mod="$app_dir/node_modules/@assets"
      mkdir -p "$assets_mod"
      # Create package.json so Metro treats it as a proper module
      if [ ! -f "$assets_mod/package.json" ]; then
        echo '{"name":"@assets","version":"1.0.0","main":"index.js"}' > "$assets_mod/package.json"
        echo 'module.exports = {};' > "$assets_mod/index.js"
      fi
      # Symlink every file from packages/assets into @assets
      for asset_file in "$PACKAGES_ASSETS"/*; do
        fname="$(basename "$asset_file")"
        if [ ! -e "$assets_mod/$fname" ]; then
          ln -sf "$asset_file" "$assets_mod/$fname"
        fi
      done
      echo "  ✅ @assets linked for $app_name"
    done
  else
    echo "  ⚠️  $PACKAGES_ASSETS not found — skipping @assets setup"
  fi

  echo "🔄 Syncing app.json files..."
  # Explicitly pass /app so gen-app-json scans the right directory in Docker
  node - /app << 'NODEEOF'
const fs   = require('fs');
const path = require('path');

const MOBILE_DIR = process.argv[2] || '/app';
const SKIP = new Set(['node_modules', 'shared', 'scripts', 'packages']);

const toSlug = (name) => name.toLowerCase().replace(/\s+/g, '-');
const toId   = (name) => name.toLowerCase().replace(/\s+/g, '');
const dig = (obj, ...keys) => keys.reduce((o, k) => (o && o[k] !== undefined ? o[k] : null), obj);

// Read package/bundleIdentifier from app.config.js if it exists
const readAppConfigJs = (appDir) => {
  const configPath = path.join(appDir, 'app.config.js');
  if (!fs.existsSync(configPath)) return {};
  try {
    const mod = { exports: {} };
    const src = fs.readFileSync(configPath, 'utf8');
    const fn = new Function('module', 'exports', 'require', 'process', src);
    fn(mod, mod.exports, require, process);
    const cfg = mod.exports.expo || mod.exports;
    return {
      androidPackage: (cfg.android && cfg.android.package) || null,
      iosBundleId:    (cfg.ios && cfg.ios.bundleIdentifier) || null,
    };
  } catch (_) { return {}; }
};

const folders = fs.readdirSync(MOBILE_DIR).filter((name) => {
  if (SKIP.has(name)) return false;
  const dir = path.join(MOBILE_DIR, name);
  try { return fs.statSync(dir).isDirectory() && fs.existsSync(path.join(dir, 'package.json')); }
  catch (_) { return false; }
});

if (folders.length === 0) { console.log('⚠️  No app folders found in ' + MOBILE_DIR); process.exit(0); }

for (const name of folders) {
  const appDir   = path.join(MOBILE_DIR, name);
  const appJson  = path.join(appDir, 'app.json');
  const slug     = toSlug(name);
  const appConfig = readAppConfigJs(appDir);
  const bundleId = appConfig.androidPackage || appConfig.iosBundleId || `com.${toId(name)}`;

  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(appJson, 'utf8')); } catch (_) {}

  const projectId = dig(existing, 'expo', 'extra', 'eas', 'projectId') || null;
  const owner     = dig(existing, 'expo', 'owner') || null;
  const isBare    = fs.existsSync(path.join(appDir, 'android')) || fs.existsSync(path.join(appDir, 'ios'));

  let config;
  if (isBare) {
    // Preserve all existing fields, only fill in missing ones.
    // Fix icon/splash paths: in Docker, packages are at /app/packages (one level up from app dir),
    // so ../../packages/... (two levels up) is wrong — normalize to ../packages/...
    const fixPath = (p) => {
      if (!p) return p;
      return p.replace(/^\.\.\/\.\.\/packages\//, '../packages/');
    };
    const existingIcon = fixPath(dig(existing, 'expo', 'icon'));
    const existingSplash = dig(existing, 'expo', 'splash');
    if (existingSplash && existingSplash.image) {
      existingSplash.image = fixPath(existingSplash.image);
    }
    const existingAndroid = dig(existing, 'expo', 'android');
    if (existingAndroid && existingAndroid.adaptiveIcon && existingAndroid.adaptiveIcon.foregroundImage) {
      existingAndroid.adaptiveIcon.foregroundImage = fixPath(existingAndroid.adaptiveIcon.foregroundImage);
    }
    config = {
      expo: {
        name,
        slug,
        version: dig(existing, 'expo', 'version') || '1.0.0',
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ...(existingIcon   ? { icon:   existingIcon   } : {}),
        ...(existingSplash ? { splash: existingSplash } : {}),
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
        ...(existingAndroid ? { android: existingAndroid } : {}),
        ...(dig(existing, 'expo', 'ios')     ? { ios:     dig(existing, 'expo', 'ios')     } : {}),
      },
    };
  } else {
    // For managed workflow apps, use shared packages/assets
    const sharedIcon = fs.existsSync(path.join(MOBILE_DIR, 'packages', 'assets', `${slug}-icon.png`))
      ? `../packages/assets/${slug}-icon.png`
      : (fs.existsSync(path.join(appDir, 'assets', 'icon.png')) ? './assets/icon.png' : `../packages/assets/${slug}-icon.png`);
    const splashImage = sharedIcon;
    const existingPlugins = dig(existing, 'expo', 'plugins');
    config = {
      expo: {
        name, slug, scheme: slug,
        version: dig(existing, 'expo', 'version') || '1.0.0',
        orientation: 'portrait', icon: sharedIcon, userInterfaceStyle: 'light',
        splash: { image: splashImage, resizeMode: 'contain',
          backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000' },
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ios: {
          supportsTablet: true,
          bundleIdentifier: `com.${toId(name)}`,
          infoPlist: {
            NSLocationWhenInUseUsageDescription: `${name} needs your location.`,
            NSLocationAlwaysAndWhenInUseUsageDescription: `${name} needs your location in the background.`,
            ITSAppUsesNonExemptEncryption: false,
          },
        },
        android: {
          adaptiveIcon: { foregroundImage: sharedIcon, backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000' },
          package: `com.${toId(name)}`,
        },
        plugins: existingPlugins || [['expo-location', {
          locationAlwaysAndWhenInUsePermission: `Allow ${name} to use your location.`,
          locationWhenInUsePermission: `Allow ${name} to use your location.`,
        }]],
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

  # APP_TYPE may be lowercase (e.g. "elitecar") but the actual folder may be
  # mixed-case (e.g. "EliteCar"). Do a case-insensitive lookup.
  APP_DIR=""
  for dir in /app/*/; do
    folder="$(basename "$dir")"
    # Skip non-app folders
    case "$folder" in node_modules|shared|scripts|packages) continue ;; esac
    [ -f "$dir/package.json" ] || continue
    folder_lower="$(echo "$folder" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    apptype_lower="$(echo "${APP_TYPE}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    if [ "$folder_lower" = "$apptype_lower" ]; then
      APP_DIR="$dir"
      break
    fi
  done

  if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
    echo "❌ No directory found for APP_TYPE='${APP_TYPE}'"
    echo "   Available apps:"
    ls /app | grep -v node_modules
    exit 1
  fi

  echo "========================================"
  echo "📱 ${APP_TYPE}"
  echo "========================================"

  cd "$APP_DIR"

  # Ensure the Google Maps API key is always present in native Android files
  _ensure_maps_key "$APP_DIR"

  # ── Patch metro-file-map FallbackWatcher for virtiofs hot reload ────────────
  # Problem: virtiofs (used by Podman/Docker on macOS) does NOT propagate
  # inotify/kqueue events into the container. Metro's FallbackWatcher uses
  # fs.watch() which relies on those events — so it never fires.
  # Fix: replace FallbackWatcher with a stat()-polling implementation that
  # works regardless of the filesystem event layer.
  _patch_fallback_watcher() {
    local watcher_path="$1/node_modules/metro-file-map/src/watchers/FallbackWatcher.js"
    [ -f "$watcher_path" ] || return 0
    # Only patch if not already patched
    grep -q 'POLLING_PATCH' "$watcher_path" 2>/dev/null && return 0
    echo "🔧 Patching FallbackWatcher for virtiofs polling ($1)..."
    cat > "$watcher_path" << 'WATCHER_EOF'
// POLLING_PATCH — replaced by mobile.sh for virtiofs/Podman/Docker compatibility.
// Original FallbackWatcher uses fs.watch() (inotify) which doesn't work in virtiofs.
// This version uses stat()-based polling so Fast Refresh works in containers.
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = void 0;
var _AbstractWatcher = require("./AbstractWatcher");
var common = _interopRequireWildcard(require("./common"));
var _fs = _interopRequireDefault(require("fs"));
var _path = _interopRequireDefault(require("path"));
var _walker = _interopRequireDefault(require("walker"));
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
function _interopRequireWildcard(e) {
  if (e && e.__esModule) return e;
  var f = { __proto__: null, default: e };
  if (e != null) for (var k in e) if (k !== 'default' && Object.prototype.hasOwnProperty.call(e, k)) f[k] = e[k];
  return f;
}
const POLL_INTERVAL_MS = 150;
const DEBOUNCE_MS = 100;
const TOUCH_EVENT = common.TOUCH_EVENT;
const DELETE_EVENT = common.DELETE_EVENT;

class FallbackWatcher extends _AbstractWatcher.AbstractWatcher {
  #changeTimers = new Map();
  #knownFiles = new Map(); // filepath -> mtime (ms)
  #pollTimer = null;

  async startWatching() {
    // Initial crawl to build the known-files map
    await new Promise((resolve) => {
      recReaddir(
        this.root,
        (_dir) => {},
        (filename, stats) => { this.#knownFiles.set(filename, stats.mtime.getTime()); },
        (symlink, stats) => { this.#knownFiles.set(symlink, stats.mtime.getTime()); },
        resolve,
        (err) => { if (!isIgnorableFileError(err)) this.emitError(err); },
        this.ignored,
      );
    });
    // Start polling
    this.#pollTimer = setInterval(() => this.#poll(), POLL_INTERVAL_MS);
  }

  async #poll() {
    const seen = new Set();
    // Check all known files for changes/deletions
    for (const [filepath, oldMtime] of this.#knownFiles) {
      seen.add(filepath);
      try {
        const stat = _fs.default.statSync(filepath);
        const newMtime = stat.mtime.getTime();
        if (newMtime !== oldMtime) {
          this.#knownFiles.set(filepath, newMtime);
          const relativePath = _path.default.relative(this.root, filepath);
          const type = common.typeFromStat(stat);
          if (type != null) {
            this.#emitEvent({ event: TOUCH_EVENT, relativePath, metadata: { modifiedTime: newMtime, size: stat.size, type } });
          }
        }
      } catch (err) {
        if (isIgnorableFileError(err)) {
          this.#knownFiles.delete(filepath);
          const relativePath = _path.default.relative(this.root, filepath);
          this.#emitEvent({ event: DELETE_EVENT, relativePath });
        }
      }
    }
    // Scan for new files by re-reading directories
    try {
      await this.#scanForNew(this.root, seen);
    } catch (_) {}
  }

  async #scanForNew(dir, seen) {
    let entries;
    try { entries = _fs.default.readdirSync(dir, { withFileTypes: true }); }
    catch (_) { return; }
    for (const entry of entries) {
      const fullPath = _path.default.join(dir, entry.name);
      if (this.doIgnore(_path.default.relative(this.root, fullPath))) continue;
      if (entry.isDirectory()) {
        if (!entry.name.startsWith('.') && entry.name !== 'node_modules') {
          await this.#scanForNew(fullPath, seen);
        }
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        if (!this.#knownFiles.has(fullPath)) {
          try {
            const stat = _fs.default.statSync(fullPath);
            this.#knownFiles.set(fullPath, stat.mtime.getTime());
            const relativePath = _path.default.relative(this.root, fullPath);
            const type = common.typeFromStat(stat);
            if (type != null) {
              this.#emitEvent({ event: TOUCH_EVENT, relativePath, metadata: { modifiedTime: stat.mtime.getTime(), size: stat.size, type } });
            }
          } catch (_) {}
        }
      }
    }
  }

  async stopWatching() {
    await super.stopWatching();
    if (this.#pollTimer) { clearInterval(this.#pollTimer); this.#pollTimer = null; }
  }

  #emitEvent(change) {
    const key = change.event + '-' + change.relativePath;
    const existing = this.#changeTimers.get(key);
    if (existing) clearTimeout(existing);
    this.#changeTimers.set(key, setTimeout(() => {
      this.#changeTimers.delete(key);
      this.emitFileEvent(change);
    }, DEBOUNCE_MS));
  }

  getPauseReason() { return null; }
}

exports.default = FallbackWatcher;

function isIgnorableFileError(error) {
  return error.code === 'ENOENT' || error.code === 'EPERM';
}

function recReaddir(dir, dirCallback, fileCallback, symlinkCallback, endCallback, errorCallback, ignored) {
  const walk = (0, _walker.default)(dir);
  if (ignored) walk.filterDir((d) => !common.posixPathMatchesPattern(ignored, d));
  walk
    .on('dir', (p, s) => dirCallback(_path.default.normalize(p), s))
    .on('file', (p, s) => fileCallback(_path.default.normalize(p), s))
    .on('symlink', (p, s) => symlinkCallback(_path.default.normalize(p), s))
    .on('error', errorCallback)
    .on('end', endCallback);
}
WATCHER_EOF
    echo "✅ FallbackWatcher patched for polling"
  }

  # Patch in the app's own node_modules and the workspace node_modules
  _patch_fallback_watcher "$APP_DIR"
  _patch_fallback_watcher "/app"

  # Use the local expo binary from node_modules to avoid npx prompting to
  # download/install expo interactively (which hangs in a container).
  # @expo/cli is installed globally as `expo-internal` (not `expo`).
  # We also check per-app and workspace node_modules as fallbacks.
  EXPO_BIN=""
  if [ -x "./node_modules/.bin/expo" ]; then
    EXPO_BIN="./node_modules/.bin/expo"
  elif [ -x "/app/node_modules/.bin/expo" ]; then
    EXPO_BIN="/app/node_modules/.bin/expo"
  elif command -v expo-internal >/dev/null 2>&1; then
    # @expo/cli installs its binary as `expo-internal` globally
    EXPO_BIN="expo-internal"
  elif [ -x "/usr/local/lib/node_modules/@expo/cli/build/bin/cli" ]; then
    EXPO_BIN="node /usr/local/lib/node_modules/@expo/cli/build/bin/cli"
  else
    # Last resort: npx with --yes to auto-confirm install prompt
    EXPO_BIN="npx --yes expo"
  fi

  # Use 'localhost' as the packager hostname so Metro advertises
  # http://localhost:<port> in the dev-client URL.  Combined with
  # `adb reverse tcp:<port> tcp:<port>` (set up by dev.sh) this lets
  # both emulators (via the adb reverse tunnel) and physical USB devices
  # connect reliably.  Falls back to the env-var value if explicitly set
  # (e.g. REACT_NATIVE_PACKAGER_HOSTNAME=10.0.2.2 for emulator-only mode).
  #
  # NOTE: CI=1 is intentionally NOT set here — it disables Fast Refresh in
  # Expo/Metro. EXPO_USE_FAST_REFRESH=true ensures Hot Reload is always on.
  exec env \
    REACT_NATIVE_PACKAGER_HOSTNAME="${REACT_NATIVE_PACKAGER_HOSTNAME:-localhost}" \
    EXPO_USE_FAST_REFRESH=true \
    EXPO_NO_TELEMETRY=1 \
    $EXPO_BIN start --dev-client --port "${METRO_PORT:-8081}" --clear
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
_app_keys() { printf '%s' "$APP_RECORDS" | awk -F'|' 'NF>=3{print $1}' | sort -f; }

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
    # Ensure Maps API key is present before every Gradle build
    _ensure_maps_key "$APP_DIR"
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
    # Re-inject Maps key — prebuild regenerates AndroidManifest.xml
    _ensure_maps_key "$APP_DIR"
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
