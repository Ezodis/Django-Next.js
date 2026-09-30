# frontend/Dockerfile
FROM node:20-alpine

WORKDIR /app

# Copy package files first for better caching
COPY frontend/web/package*.json ./

# Install JS dependencies
RUN npm install --no-fund --loglevel=error

# Copy app source (the actual source will be mounted as volume in dev)
COPY frontend/web/ ./

# Environment variables
ENV NODE_ENV=development \
    HOST=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    NEXT_PUBLIC_API_URL=http://localhost/api \
    PRIVATE_ASSETS_PATH=/private_assets \
    WATCHPACK_POLLING=true

EXPOSE 3000
CMD ["sh", "-c", "npm install --no-fund --loglevel=error && npm run dev -- -H 0.0.0.0"]
