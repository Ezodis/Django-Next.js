# frontend/mobile/Dockerfile
#
# Fully dynamic — no app names or ports are hardcoded.
# Any folder in frontend/mobile/ with a package.json is picked up automatically.
# APP_TYPE and METRO_PORT env vars are injected at runtime by dev.sh per app.
#
# This file is a shared template — keep it free of project-specific logic.

# ── Dependency install stage ───────────────────────────────────────────────────
FROM node:22-slim AS deps

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ bash \
    && rm -rf /var/lib/apt/lists/*

RUN npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm config set fetch-timeout 300000 \
 && npm config set maxsockets 5 \
 && npm config set loglevel error

# Copy npm config for better reliability
COPY frontend/mobile/.npmrc /root/.npmrc

# Copy package manifests and shared assets for layer caching.
COPY frontend/mobile/ ./
COPY frontend/web/public/ ./shared/

RUN mkdir -p ./shared

# Install workspace-level deps with timeout protection
RUN timeout 300 npm install --legacy-peer-deps --prefer-offline --no-audit --progress=false || \
    (echo "⚠️  Workspace install timed out or failed, retrying..." && npm install --legacy-peer-deps --prefer-offline --no-audit --progress=false) && \
    npm cache clean --force

# Install per-app deps — fully dynamic, handles any folder name including spaces
# Added timeout, progress suppression, and parallel installation where safe
RUN for dir in */; do \
      name="${dir%/}"; \
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac; \
      [ -f "$dir/package.json" ] || continue; \
      echo "📦 [$(date +%H:%M:%S)] Installing deps for: $name"; \
      cd "/app/$name" && \
      (timeout 300 npm install --legacy-peer-deps --prefer-offline --no-audit --progress=false || \
       (echo "⚠️  [$(date +%H:%M:%S)] Install for $name timed out, retrying..." && \
        npm install --legacy-peer-deps --prefer-offline --no-audit --progress=false)) && \
      npm cache clean --force && \
      echo "✅ [$(date +%H:%M:%S)] Completed: $name" && \
      cd /app; \
    done && \
    echo "✅ [$(date +%H:%M:%S)] All app dependencies installed successfully"

# ── Final image ────────────────────────────────────────────────────────────────
FROM node:22-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl bash git \
    && rm -rf /var/lib/apt/lists/*

RUN timeout 180 npm install -g @expo/cli@latest --prefer-offline --no-audit --progress=false || \
    (echo "⚠️  Expo CLI install timed out, retrying..." && npm install -g @expo/cli@latest --prefer-offline --no-audit) && \
    npm cache clean --force && \
    ln -sf /usr/local/lib/node_modules/@expo/cli/build/bin/cli /usr/local/bin/expo && \
    chmod +x /usr/local/bin/expo

# Copy workspace-level node_modules
COPY --from=deps /app/node_modules ./node_modules

# Copy metro.config.base.js so all apps can use it
COPY --from=deps /app/metro.config.base.js ./metro.config.base.js

# Patch engine.io-client to use browser globals instead of Node.js globals.
# The package.json "browser" field maps globals.node.js → globals.js but Metro
# does not apply file-level browser field substitutions for internal requires.
# This patch makes the substitution explicit so WebSocket/XHR resolve correctly.
RUN --mount=type=bind,from=deps,source=/app,target=/deps \
    for dir in /deps/*/; do \
      name="${dir%/}"; name="${name##*/}"; \
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac; \
      eio="/app/$name/node_modules/engine.io-client/build/cjs"; \
      [ -d "$eio" ] || continue; \
      for f in "$eio/transports/websocket.js" "$eio/transports/polling-xhr.js" "$eio/index.js"; do \
        [ -f "$f" ] || continue; \
        sed -i 's|require("../globals\.node\.js")|require("../globals.js")|g' "$f"; \
        sed -i "s|require('../globals\.node\.js')|require('../globals.js')|g" "$f"; \
        sed -i 's|require("./transports/polling-xhr\.node\.js")|require("./transports/polling-xhr.js")|g' "$f"; \
        sed -i 's|require("./transports/websocket\.node\.js")|require("./transports/websocket.js")|g' "$f"; \
        echo "✅ patched engine.io-client in $name: $f"; \
      done; \
    done

# Dynamically copy each app's node_modules from the deps stage.
# Use a more robust method to preserve folder names with special characters (hyphens, spaces, etc.)
RUN --mount=type=bind,from=deps,source=/app,target=/deps \
    cd /deps && \
    for dir in */; do \
      name="${dir%/}"; \
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac; \
      [ -d "/deps/$name/node_modules" ] || continue; \
      echo "📦 Copying node_modules for: $name"; \
      mkdir -p "/app/$name"; \
      cp -r "/deps/$name/node_modules" "/app/$name/node_modules"; \
    done

# NOTE: App source files are NOT copied here — they are volume-mounted at runtime
# so Metro always reads live files from the host. Only node_modules are baked in.

# Copy the entrypoint script (avoids heredoc syntax which Podman <4.4 doesn't support)
COPY frontend/mobile/mobile.sh /mobile.sh
RUN chmod +x /mobile.sh

# METRO_PORT is injected per-app by dev.sh (8081 for app 1, 8082 for app 2, etc.)
CMD ["bash", "-c", "\
  echo '⏳ Waiting for source files...' && \
  until find /app -mindepth 2 -maxdepth 2 -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null | grep -q .; do sleep 1; done && \
  echo '✅ Source mounted, starting Metro...' && \
  exec /mobile.sh start \
"]
