# frontend/Dockerfile
FROM node:26-alpine

WORKDIR /app

# Copy package files first for better caching
COPY frontend/web/package*.json ./

# Install JS dependencies
RUN npm ci --no-fund --loglevel=error && sha256sum package.json package-lock.json > node_modules/.dependency-manifest.sha256

# Copy app source (the actual source will be mounted as volume in dev)
COPY frontend/web/ ./

# Environment variables
ENV NODE_ENV=development \
    HOST=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    NEXT_PUBLIC_API_URL=/api \
    PRIVATE_ASSETS_PATH=/private_assets \
    WATCHPACK_POLLING=true

EXPOSE 3000
CMD ["sh", "-c", "if ! sha256sum -c node_modules/.dependency-manifest.sha256 >/dev/null 2>&1; then npm ci --no-fund --loglevel=error && sha256sum package.json package-lock.json > node_modules/.dependency-manifest.sha256 || exit 1; fi; exec npm run dev -- -H 0.0.0.0"]
