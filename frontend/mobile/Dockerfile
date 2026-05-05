# frontend/mobile/Dockerfile
#
# Fully dynamic — no app names or ports are hardcoded.
# Any folder in frontend/mobile/ with a package.json is picked up automatically.
# APP_TYPE and METRO_PORT env vars are injected at runtime by dev.sh per app.

# ── Dependency install stage ───────────────────────────────────────────────────
FROM node:24-slim AS deps

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ bash \
    && rm -rf /var/lib/apt/lists/*

RUN npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm config set fetch-timeout 300000

# Copy only package manifests first for better layer caching.
# We copy the full mobile dir (with .dockerignore filtering out node_modules etc.)
COPY frontend/mobile/ ./
COPY frontend/packages/ ./packages/

RUN mkdir -p ./shared

# Install workspace-level deps
RUN npm install --legacy-peer-deps && npm cache clean --force

# Install per-app deps — fully dynamic, handles any folder name including spaces
RUN for dir in */; do \
      name="${dir%/}"; \
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac; \
      [ -f "$dir/package.json" ] || continue; \
      echo "📦 Installing deps for: $name"; \
      cd "/app/$name" && npm install --legacy-peer-deps && npm cache clean --force && cd /app; \
    done

# ── Final image ────────────────────────────────────────────────────────────────
FROM node:24-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl bash git \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @expo/cli@latest && npm cache clean --force \
 && ln -sf /usr/local/lib/node_modules/@expo/cli/build/bin/cli /usr/local/bin/expo \
 && chmod +x /usr/local/bin/expo

# Copy workspace-level node_modules
COPY --from=deps /app/node_modules ./node_modules

# Dynamically copy each app's node_modules from the deps stage using a shell script.
# This avoids hardcoding app names while also avoiding copying the entire /app/ tree.
# We use a RUN --mount to access the deps stage filesystem directly.
RUN --mount=type=bind,from=deps,source=/app,target=/deps \
    for dir in /deps/*/; do \
      name="$(basename "$dir")"; \
      case "$name" in node_modules|shared|scripts|packages|builds) continue ;; esac; \
      [ -d "/deps/$name/node_modules" ] || continue; \
      echo "📦 Copying node_modules for: $name"; \
      mkdir -p "/app/$name"; \
      cp -r "/deps/$name/node_modules" "/app/$name/node_modules"; \
    done

# NOTE: App source files are NOT copied here — they are mounted via volume at
# runtime so Metro always reads live files from the host, never a stale image layer.
# Only node_modules (from the deps stage) are baked in.

COPY frontend/mobile/scripts/mobile.sh /mobile.sh
RUN chmod +x /mobile.sh

# METRO_PORT is injected per-app by dev.sh (8081 for app 1, 8082 for app 2, etc.)
# Wait for the volume-mounted source to appear before starting Metro.
CMD ["bash", "-c", "\
  echo '⏳ Waiting for source files...' && \
  until find /app -mindepth 2 -maxdepth 2 -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null | grep -q .; do sleep 1; done && \
  echo '✅ Source mounted, starting Metro...' && \
  exec /mobile.sh start \
"]
