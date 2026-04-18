/**
 * Shared Metro configuration helpers for mobile apps.
 *
 * Centralised here so that all mobile apps stay in sync without duplicating logic.
 */

const fs = require('fs');

/**
 * Returns true when Metro is running inside a Docker container.
 *
 * Docker creates `/.dockerenv` in every container, so checking for its
 * existence is a reliable, zero-dependency way to detect the environment.
 *
 * Why it matters:
 *   On macOS, Docker uses virtiofs to share the host filesystem. virtiofs
 *   does not propagate inotify/kqueue events into the guest, so Watchman
 *   (which relies on those events) never fires and Hot Reload silently
 *   stops working. Disabling Watchman and switching to polling fixes this,
 *   but **only inside Docker** — on a real macOS machine Watchman is the
 *   fastest and most reliable watcher and must stay enabled.
 */
function isDocker() {
  return fs.existsSync('/.dockerenv');
}

/**
 * Apply Docker-safe watcher options to a Metro config object.
 * When running outside Docker this is a no-op, so Watchman (and therefore
 * Fast Refresh) works normally on the developer's Mac.
 *
 * @param {import('metro-config').MetroConfig} config
 * @returns {import('metro-config').MetroConfig}
 */
function applyDockerWatcherOptions(config) {
  if (isDocker()) {
    config.watcherOptions = {
      ...config.watcherOptions,
      // Watchman is unavailable inside Docker — use polling instead.
      useWatchman: false,
      // Poll every 300 ms — fast enough for a good dev experience.
      poll: 300,
    };
  }
  return config;
}

module.exports = { isDocker, applyDockerWatcherOptions };
