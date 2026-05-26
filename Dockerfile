# Use an official Node runtime as the base image
FROM node:24-slim AS base
WORKDIR /usr/src/app

# Build stage - install ALL dependencies and build
FROM base AS build
ENV HUSKY=0
# Copy package files first for better caching
COPY package*.json ./
RUN --mount=type=cache,id=s/f28c2318-fc2b-4487-ad2d-05e9c09ff888-/root/.npm,target=/root/.npm \
    npm ci

# Copy only what's needed for build
COPY tsconfig.json ./
COPY vite.config.ts ./
COPY eslint.config.js ./
COPY index.html ./
COPY resources ./resources
COPY proprietary ./proprietary
COPY src ./src

# Provide dummy build credentials so the template engine doesn't crash compiling the UI
ENV TURNSTILE_SITE_KEY="1x00000000000000000000AA"
ENV TURNSTILE_SECRET_KEY="1x0000000000000000000000000000000AA"

ARG GIT_COMMIT=unknown
ENV GIT_COMMIT="$GIT_COMMIT"
RUN npm run build-prod

# Production dependencies stage - separate from build
FROM base AS prod-deps
ENV HUSKY=0
ENV NPM_CONFIG_IGNORE_SCRIPTS=1
COPY package*.json ./
RUN --mount=type=cache,id=s/f28c2318-fc2b-4487-ad2d-05e9c09ff888-/root/.npm,target=/root/.npm \
    npm ci --omit=dev

# Final production image
FROM base

# Copy production node_modules from prod-deps stage (cached separately from build)
COPY --from=prod-deps /usr/src/app/node_modules ./node_modules
COPY package*.json ./

# Copy built artifacts from build stage
COPY --from=build /usr/src/app/static ./static

COPY resources ./resources

# Remove maps because they are not used by the server.
RUN rm -rf ./resources/maps
COPY tsconfig.json ./
COPY src ./src

ARG GIT_COMMIT=unknown
RUN echo "$GIT_COMMIT" > static/commit.txt
ENV GIT_COMMIT="$GIT_COMMIT"

# PURGE LOCAL ENV CONFIGS EVERYWHERE TO PREVENT RE-INJECTION OVERRIDES
RUN rm -rf .env .env.* src/server/.env src/server/.env.*

# EXPOSE the required Hugging Face Port
EXPOSE 7860

# Inject a clean, unified runtime startup script
RUN <<'EOF' tee /usr/local/bin/start.sh
#!/bin/sh

# Write an intermediate launcher that injects environment maps directly inside the JS execution layer.
# This forces the internal cluster framework to safely evaluate loopbacks on port 7860 without throwing URL syntax crashes.
cat << 'NODE_SCRIPT' > launch.js
process.env.NODE_ENV = 'production';
process.env.GAME_ENV = 'prod';
process.env.NUM_WORKERS = '1';
process.env.PORT = '7860';
process.env.BACKEND_PORT = '7860';
process.env.DOMAIN = '127.0.0.1:7860';
process.env.BACKEND_URL = 'http://127.0.0.1:7860';
process.env.LOBBY_SERVER_URL = 'http://127.0.0.1:7860';
process.env.API_URL = 'http://127.0.0.1:7860';
process.env.TURNSTILE_SITE_KEY = '1x00000000000000000000AA';
process.env.TURNSTILE_SECRET_KEY = '1x0000000000000000000000000000000AA';

// Intercept all system variable polls to guarantee deep configuration values match exactly
const originalEnv = process.env;
process.env = new Proxy({}, {
  get: (target, prop) => {
    if (prop === 'DOMAIN') return '127.0.0.1:7860';
    if (prop === 'BACKEND_URL' || prop === 'LOBBY_SERVER_URL' || prop === 'API_URL') return 'http://127.0.0.1:7860';
    if (prop === 'PORT' || prop === 'BACKEND_PORT') return '7860';
    if (prop === 'TURNSTILE_SITE_KEY') return '1x00000000000000000000AA';
    if (prop === 'TURNSTILE_SECRET_KEY') return '1x0000000000000000000000000000000AA';
    return originalEnv[prop];
  }
});

// Run tsx CLI to safely execute the app engine
require('tsx/cli');
NODE_SCRIPT

echo "Launching OpenFront Process Mesh on port 7860..."
exec npx tsx launch.js src/server/Server.ts --port 7860 --host 0.0.0.0
EOF

RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
