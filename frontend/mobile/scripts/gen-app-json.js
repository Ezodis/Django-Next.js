#!/usr/bin/env node
/**
 * gen-app-json.js
 * Auto-generates app.json for every app folder under frontend/mobile/.
 * Called by dev.sh on startup: node "$MOBILE_DIR/scripts/gen-app-json.js"
 */

const fs   = require('fs');
const path = require('path');

const MOBILE_DIR   = process.argv[2] || path.resolve(__dirname, '..');
const PACKAGES_DIR = path.resolve(MOBILE_DIR, '..', 'packages', 'assets');
const SKIP = new Set(['node_modules', 'shared', 'scripts', 'packages']);

const toSlug = (name) => name.toLowerCase().replace(/\s+/g, '-');
const toId   = (name) => name.toLowerCase().replace(/\s+/g, '');
const dig    = (obj, ...keys) => keys.reduce((o, k) => (o && o[k] !== undefined ? o[k] : null), obj);

// Read package/bundleIdentifier from app.config.js if it exists
const readAppConfigJs = (appDir) => {
  const configPath = path.join(appDir, 'app.config.js');
  if (!fs.existsSync(configPath)) return {};
  try {
    const mod = { exports: {} };
    const src = fs.readFileSync(configPath, 'utf8');
    const fn = new Function('module', 'exports', 'require', 'process', src);
    fn(mod, mod.exports, require, process);
    const cfg = (mod.exports && mod.exports.expo) ? mod.exports.expo : mod.exports;
    return {
      androidPackage: (cfg.android && cfg.android.package) || null,
      iosBundleId:    (cfg.ios && cfg.ios.bundleIdentifier) || null,
    };
  } catch (_) { return {}; }
};

let folders;
try {
  folders = fs.readdirSync(MOBILE_DIR).filter((name) => {
    if (SKIP.has(name)) return false;
    const dir = path.join(MOBILE_DIR, name);
    try {
      return fs.statSync(dir).isDirectory() && fs.existsSync(path.join(dir, 'package.json'));
    } catch (_) {
      return false;
    }
  });
} catch (err) {
  console.error('⚠️  Could not read mobile dir:', err.message);
  process.exit(0);
}

if (folders.length === 0) {
  console.log('⚠️  No app folders found in', MOBILE_DIR);
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
    // Bare workflow: preserve all existing fields, only fill in missing ones
    config = {
      expo: {
        name,
        slug,
        version:        dig(existing, 'expo', 'version')        || '1.0.0',
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ...(dig(existing, 'expo', 'icon')   ? { icon:   dig(existing, 'expo', 'icon')   } : {}),
        ...(dig(existing, 'expo', 'splash') ? { splash: dig(existing, 'expo', 'splash') } : {}),
        extra: { eas: projectId ? { projectId } : {} },
        ...(owner ? { owner } : {}),
        developmentClient: { silentLaunch: true },
        ...(dig(existing, 'expo', 'android') ? { android: dig(existing, 'expo', 'android') } : {}),
        ...(dig(existing, 'expo', 'ios')     ? { ios:     dig(existing, 'expo', 'ios')     } : {}),
      },
    };
  } else {
    // Resolve icon from shared packages/assets (source of truth)
    const sharedIconAbs = path.join(PACKAGES_DIR, `${slug}-icon.png`);
    const iconPath = path.relative(appDir, sharedIconAbs).replace(/\\/g, '/');

    const splashImage = iconPath;

    config = {
      expo: {
        name,
        slug,
        scheme: slug,
        version:           dig(existing, 'expo', 'version') || '1.0.0',
        orientation:       'portrait',
        icon:              iconPath,
        userInterfaceStyle: 'light',
        splash: {
          image:           splashImage,
          resizeMode:      'contain',
          backgroundColor: dig(existing, 'expo', 'splash', 'backgroundColor') || '#000000',
        },
        runtimeVersion: dig(existing, 'expo', 'runtimeVersion') || '1.0.0',
        ios: {
          supportsTablet:   true,
          bundleIdentifier: bundleId,
          infoPlist: {
            NSLocationWhenInUseUsageDescription:            `${name} needs your location.`,
            NSLocationAlwaysAndWhenInUseUsageDescription:   `${name} needs your location in the background.`,
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
            ? { permissions: dig(existing, 'expo', 'android', 'permissions') }
            : {}),
        },
        web: { favicon: './assets/favicon.png' },
        plugins: dig(existing, 'expo', 'plugins') || [
          ['expo-location', {
            locationAlwaysAndWhenInUsePermission: `Allow ${name} to use your location.`,
            locationWhenInUsePermission:          `Allow ${name} to use your location.`,
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
