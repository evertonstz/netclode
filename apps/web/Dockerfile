# Web App Dockerfile
FROM node:24-alpine AS builder

WORKDIR /app

# Copy workspace files (skip lock file due to npm optional deps bug)
COPY package.json ./
COPY apps/web/package.json apps/web/
COPY packages/protocol/package.json packages/protocol/

# Install dependencies fresh to get correct platform-specific optional deps
RUN npm install

# Copy source code
COPY apps/web apps/web
COPY packages/protocol packages/protocol

# Build
WORKDIR /app/apps/web
RUN npm run build

# Production image with nginx
FROM nginx:alpine

# Copy built static files
COPY --from=builder /app/apps/web/dist /usr/share/nginx/html

# Copy nginx configuration
COPY apps/web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
