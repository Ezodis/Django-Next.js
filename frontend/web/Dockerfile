# frontend/web/Dockerfile
FROM node:20-alpine

# Install curl for health checks and debugging
RUN apk add --no-cache curl

WORKDIR /app

# Copy all package files first for better layer caching
# Root workspace + all sub-workspace package.json files needed for npm workspaces
COPY frontend/package*.json ./
COPY frontend/web/package*.json ./web/
COPY frontend/packages/ ./packages/

# Configure npm for better network handling
RUN npm config set registry https://registry.npmjs.org/ && \
    npm config set fetch-retry-mintimeout 20000 && \
    npm config set fetch-retry-maxtimeout 120000 && \
    npm config set fetch-retries 5 && \
    npm config set fetch-timeout 300000

# Install all workspace dependencies (root + web + packages/*)
RUN npm install --legacy-peer-deps --verbose

# Copy app source
COPY frontend/ ./

# Environment variables
ENV NODE_ENV=development \
    HOST=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    NEXT_PUBLIC_API_URL=http://localhost/api \
    PRIVATE_ASSETS_PATH=/private_assets \
    WATCHPACK_POLLING=true \
    CHOKIDAR_USEPOLLING=true \
    TURBOPACK_WATCH_POLL=500

EXPOSE 3000
# Install deps at startup in case node_modules volume is empty (first run),
# then start the dev server
CMD ["sh", "-c", "npm install --legacy-peer-deps --prefix /app/web 2>/dev/null; npm run dev"]