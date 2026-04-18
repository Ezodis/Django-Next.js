# frontend/mobile/Dockerfile
#
# Fully dynamic — no app names are hardcoded.
# Any app folder in frontend/mobile/ (with a package.json) is included automatically.
# APP_TYPE env var at runtime selects which app to launch.

FROM node:24-alpine AS base

WORKDIR /app

RUN apk add --no-cache \
    curl \
    wget \
    git \
    python3 \
    make \
    g++ \
    bash \
    && rm -rf /var/cache/apk/*

RUN npm install -g npm@latest
RUN npm install -g @expo/cli@latest

RUN npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm config set fetch-timeout 300000

# ── Dependency install stage ───────────────────────────────────────────────────
# Copy only package.json files first so this layer is cached independently of
# source code changes. We use a helper script to find and copy them dynamically.
FROM base AS deps

WORKDIR /app

# Copy the workspace root package.json
COPY frontend/mobile/package.json ./package.json

# Copy all app-level package.json files.
# We copy the whole mobile dir here but only use package.json files for the
# install step — source code is excluded via .dockerignore patterns.
COPY frontend/mobile/ ./

# Copy shared frontend packages (referenced by metro.config.js as frontendRoot/packages)
COPY frontend/packages/ ./packages/

# Ensure shared dir exists (metro.config.js watches it)
RUN mkdir -p ./shared

RUN npm install --legacy-peer-deps

# ── Final image ────────────────────────────────────────────────────────────────
FROM base

WORKDIR /app

# Bring in node_modules, source, and packages from the deps stage
COPY --from=deps /app ./

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD curl -f http://localhost:8081 || exit 1

# APP_TYPE is the exact folder name set per-container by docker-compose.
# e.g. APP_TYPE="My App" → runs /app/My App
COPY frontend/mobile/scripts/mobile.sh /mobile.sh
RUN chmod +x /mobile.sh

CMD ["/mobile.sh", "start"]
