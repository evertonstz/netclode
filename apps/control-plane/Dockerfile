FROM oven/bun:1.1-alpine AS builder

WORKDIR /app

# Copy workspace files
COPY package.json bun.lock ./
COPY packages/protocol ./packages/protocol
COPY apps/control-plane ./apps/control-plane

# Install dependencies
RUN bun install --frozen-lockfile

# Build
WORKDIR /app/apps/control-plane
RUN bun run build

# Production image
FROM oven/bun:1.1-alpine

WORKDIR /app

COPY --from=builder /app/apps/control-plane/dist ./dist
COPY --from=builder /app/apps/control-plane/package.json ./

# Install production dependencies only
RUN bun install --production

EXPOSE 3001

CMD ["bun", "run", "dist/index.js"]
