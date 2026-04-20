# frontend/Dockerfile
FROM node:24-alpine

# Install dependencies for native modules
RUN apk add --no-cache python3 make g++ curl bash

RUN npm install -g npm@latest

WORKDIR /app

# Copy root package.json and lock file for workspace setup
COPY frontend/package.json ./package.json
COPY frontend/package-lock.json ./package-lock.json
COPY frontend/tsconfig.json ./tsconfig.json

# Copy all package.json files for workspace resolution
COPY frontend/packages ./packages
COPY frontend/web/package.json ./web/package.json

# Install all workspace dependencies from root
RUN npm ci --legacy-peer-deps

# Build shared packages
RUN npm run build:packages || true

# Copy web source code
COPY frontend/web ./web

# Set working directory to web
WORKDIR /app/web

# Environment variables
ENV NODE_ENV=development \
    HOST=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    PRIVATE_ASSETS_PATH=/private_assets \
    WATCHPACK_POLLING=true

# API URL will be set via docker-compose environment or .env.local
# Default to /api for development (proxied through Next.js)
ENV NEXT_PUBLIC_API_URL=/api

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# Run dev server
CMD ["npm", "run", "dev"]