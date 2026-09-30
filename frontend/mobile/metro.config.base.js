/**
 * Shared Metro configuration factory for mobile apps.
 *
 * Usage from each app's metro.config.js:
 *
 *   const createMetroConfig = require('../metro.config.base');
 *   module.exports = createMetroConfig(__dirname, { /* overrides *\/ });
 *
 * Features:
 *  - @shared/* → frontend/mobile/shared/ alias (shared components between mobile apps)
 *  - Assets served from frontend/web/public/ (single source of truth for web + mobile)
 *  - Stat-based polling watcher for virtiofs (Docker on macOS)
 *  - FileStore caching
 *  - EAS / production optimisations
 */

'use strict';

const path = require('path');
const fs   = require('fs');

// ── Path helpers ──────────────────────────────────────────────────────────────

/**
 * Resolve the shared components directory (mobile/shared/).
 * Handles multiple environments:
 *   1. Host (dev): <repo>/frontend/mobile/<app>/  → <repo>/frontend/mobile/shared/
 *   2. Docker/Podman: /app/<app>/                 → /app/shared/
 */
function resolveSharedRoot(appDir) {
  const candidates = [
    // Standard monorepo layout: frontend/mobile/<app>/ → frontend/mobile/shared/
    path.resolve(appDir, '../shared'),
    // Docker mount: /app/<app>/ → /app/shared/
    path.resolve(appDir, '../shared'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return candidates[0];
}

/**
 * Resolve the web/public directory (assets source of truth).
 */
function resolveAssetsRoot(appDir) {
  const candidates = [
    path.resolve(appDir, '../shared/assets'),
    path.resolve(appDir, '../../../web/public'),
    path.resolve(appDir, '../../web/public'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return candidates[0];
}

// ── Virtiofs detection ────────────────────────────────────────────────────────

function isDocker() {
  return fs.existsSync('/.dockerenv') || fs.existsSync('/run/.containerenv');
}

// ── Metro config factory ──────────────────────────────────────────────────────

/**
 * @param {string} appDir   - Absolute path to the app directory (__dirname from metro.config.js)
 * @param {object} overrides - Optional Metro config overrides merged on top
 * @returns {import('metro-config').MetroConfig}
 */
function createMetroConfig(appDir, overrides = {}) {
  // Resolve metro config modules from the app's own node_modules first,
  // then fall back to the workspace root. This is critical when metro.config.base.js
  // is volume-mounted at /app/ but the actual metro packages live inside
  // /app/<AppName>/node_modules/ (installed per-app, not at workspace level).
  const { getDefaultConfig } = (() => {
    const resolve = (id) => require(require.resolve(id, { paths: [appDir] }));
    try { return resolve('expo/metro-config'); } catch (_) {}
    try { return resolve('@expo/metro-config'); } catch (_) {}
    try { return resolve('metro-config'); } catch (_) {}
    // Last resort: workspace-level require (may fail in container)
    try { return require('expo/metro-config'); } catch (_) {}
    try { return require('@expo/metro-config'); } catch (_) {}
    return require('metro-config');
  })();

  const config      = getDefaultConfig(appDir);
  const sharedRoot  = resolveSharedRoot(appDir);   // frontend/mobile/shared/
  const assetsRoot  = resolveAssetsRoot(appDir);   // frontend/web/public/
  const mobileRoot  = path.dirname(appDir);        // frontend/mobile/

  // ── Watch folders ────────────────────────────────────────────────────────
  config.watchFolders = [
    ...(config.watchFolders || []),
    sharedRoot,
    mobileRoot,
    assetsRoot,
  ].filter((v, i, a) => a.indexOf(v) === i);

  // ── Resolver aliases ─────────────────────────────────────────────────────
  config.resolver = config.resolver || {};
  // Don't use extraNodeModules - we handle everything in resolveRequest below
  config.resolver.extraNodeModules = {
    ...(config.resolver.extraNodeModules || {}),
  };

  // Intercept @shared/* requires and redirect to mobile/shared/
  const _origResolveRequest = config.resolver.resolveRequest;
  config.resolver.resolveRequest = (context, moduleName, platform) => {
    // Handle @shared/* - look for components in mobile/shared/
    if (moduleName.startsWith('@shared/') || moduleName === '@shared') {
      const subpath = moduleName === '@shared' ? '' : moduleName.slice('@shared/'.length);
      const resolved = path.join(sharedRoot, subpath);
      if (fs.existsSync(resolved) || fs.existsSync(resolved + '.ts') || fs.existsSync(resolved + '.tsx') || fs.existsSync(resolved + '.js')) {
        return context.resolveRequest(context, resolved, platform);
      }
    }
    
    if (_origResolveRequest) {
      return _origResolveRequest(context, moduleName, platform);
    }
    return context.resolveRequest(context, moduleName, platform);
  };

  // ── Transformer ──────────────────────────────────────────────────────────
  config.transformer = config.transformer || {};
  config.transformer.getTransformOptions = async () => ({
    transform: {
      experimentalImportSupport: false,
      inlineRequires: true,
    },
  });

  // ── Cache ────────────────────────────────────────────────────────────────
  try {
    const { FileStore } = require(require.resolve('metro-cache', { paths: [appDir] }));
    config.cacheStores = [
      new FileStore({ root: path.join(appDir, '.metro-cache') }),
    ];
  } catch (_) { /* metro-cache may not be installed as a direct dep */ }

  // ── Docker / virtiofs polling watcher ────────────────────────────────────
  if (isDocker()) {
    config.resolver.useWatchman = false;
    config.watcherOptions = {
      ...(config.watcherOptions || {}),
      useWatchman: false,
      poll: 150,
    };
  }

  // ── Merge caller overrides (shallow) ─────────────────────────────────────
  return deepMerge(config, overrides);
}

// ── Utility ───────────────────────────────────────────────────────────────────

function deepMerge(base, override) {
  const out = { ...base };
  for (const [k, v] of Object.entries(override)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && base[k] && typeof base[k] === 'object') {
      out[k] = deepMerge(base[k], v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

module.exports = createMetroConfig;
