/**
 * Shared Metro configuration helpers for EliteCar mobile apps.
 *
 * Centralised here so that all mobile apps (Elite Car, Elite Car Driver, etc.)
 * stay in sync without duplicating logic.
 */

const fs = require('fs');

/**
 * Returns true when Metro is running inside a Docker or Podman container.
 *
 * Docker creates `/.dockerenv`; Podman creates `/run/.containerenv`.
 * Checking both covers all container runtimes.
 *
 * Why it matters:
 *   On macOS, Docker/Podman uses virtiofs to share the host filesystem.
 *   virtiofs does not propagate inotify/kqueue events into the guest, so
 *   Watchman (which relies on those events) never fires and Hot Reload
 *   silently stops working. Disabling Watchman and switching to polling
 *   fixes this, but **only inside a container** — on a real macOS machine
 *   Watchman is the fastest and most reliable watcher and must stay enabled.
 */
function isDocker() {
  return fs.existsSync('/.dockerenv') || fs.existsSync('/run/.containerenv');
}

/**
 * Apply Docker-safe watcher options to a Metro config object.
 * When running outside Docker this is a no-op, so Watchman (and therefore
 * Fast Refresh) works normally on the developer's Mac.
 *
 * Metro 0.83+ (Expo SDK 55+): useWatchman moved to config.resolver.useWatchman.
 * The old config.watcherOptions.poll is silently ignored in 0.83+.
 * We set both for backwards compatibility.
 *
 * @param {import('metro-config').MetroConfig} config
 * @returns {import('metro-config').MetroConfig}
 */
function applyDockerWatcherOptions(config) {
  if (isDocker()) {
    // Metro 0.83+: the correct field is config.resolver.useWatchman
    config.resolver = {
      ...config.resolver,
      useWatchman: false,
    };
    // Legacy fallback for older Metro versions
    config.watcherOptions = {
      ...config.watcherOptions,
      useWatchman: false,
      poll: 150,
    };
  }
  return config;
}

module.exports = { isDocker, applyDockerWatcherOptions };
