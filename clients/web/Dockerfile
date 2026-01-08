# Web App Dockerfile
FROM node:24-alpine AS builder

WORKDIR /app

# Copy workspace files (skip lock file due to npm optional deps bug)
COPY package.json ./
COPY clients/web/package.json clients/web/
COPY packages/protocol/package.json packages/protocol/

# Install dependencies fresh to get correct platform-specific optional deps
RUN --mount=type=cache,target=/root/.npm \
    npm install

# Copy source code
COPY clients/web clients/web
COPY packages/protocol packages/protocol

# Build
WORKDIR /app/clients/web
RUN npm run build

# Production image with nginx
FROM nginx:alpine

# Copy built static files
COPY --from=builder /app/clients/web/dist /usr/share/nginx/html

# Copy nginx configuration
COPY clients/web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
