# frontend/web/Dockerfile
FROM node:20-alpine

RUN apk add --no-cache curl

WORKDIR /app

RUN npm config set registry https://registry.npmjs.org/ && \
    npm config set fetch-retry-mintimeout 20000 && \
    npm config set fetch-retry-maxtimeout 120000 && \
    npm config set fetch-retries 5 && \
    npm config set fetch-timeout 300000

# Copy package manifests first — maximises layer cache reuse.
# Source files changing won't invalidate the npm install layer.
COPY frontend/package*.json ./
COPY frontend/web/package*.json ./web/
COPY frontend/packages/api-client/package.json ./packages/api-client/
COPY frontend/packages/constants/package.json ./packages/constants/
COPY frontend/packages/hooks/package.json ./packages/hooks/
COPY frontend/packages/storage/package.json ./packages/storage/
COPY frontend/packages/theme/package.json ./packages/theme/
COPY frontend/packages/types/package.json ./packages/types/
COPY frontend/packages/utils/package.json ./packages/utils/

# Rewrite root package.json to exclude the mobile workspace so npm doesn't
# try to resolve mobile-only packages (Expo, React Native, etc.)
RUN node -e " \
  const fs = require('fs'); \
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8')); \
  pkg.workspaces = pkg.workspaces.filter(w => !w.includes('mobile')); \
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2)); \
"

# Install web + packages/* dependencies only (no mobile workspace)
RUN npm install --legacy-peer-deps && npm cache clean --force

# NOTE: Source files are NOT copied here — they are mounted via volume at runtime.
# This ensures next dev always reads live files from the host, never a stale image layer.

ENV NODE_ENV=development \
    HOST=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    NEXT_PUBLIC_API_URL=http://localhost/api \
    PRIVATE_ASSETS_PATH=/private_assets \
    WATCHPACK_POLLING=true \
    CHOKIDAR_USEPOLLING=true \
    CHOKIDAR_INTERVAL=500 \
    WATCHPACK_POLLING_INTERVAL=500

EXPOSE 3000

# Wait for the volume-mounted source to appear, then start next dev.
# This guards against Podman's VM mount being slightly delayed at startup.
CMD ["sh", "-c", "\
  echo '⏳ Waiting for source files...' && \
  until [ -f /app/web/package.json ]; do sleep 1; done && \
  echo '✅ Source mounted, starting Next.js dev server...' && \
  cd /app/web && exec npm run dev \
"]
