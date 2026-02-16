FROM golang:1.25-alpine AS builder

WORKDIR /build

# Disable go.work so only go.mod replace directives are used
ENV GOWORK=off

# Copy control-plane (needed for generated proto stubs via replace directive)
COPY services/control-plane/go.mod services/control-plane/go.sum ./services/control-plane/
COPY services/control-plane/gen/ ./services/control-plane/gen/

# Copy github-bot
COPY services/github-bot/go.mod services/github-bot/go.sum ./services/github-bot/

# Download deps
RUN --mount=type=cache,target=/go/pkg/mod \
    cd services/github-bot && go mod download

# Copy full github-bot source
COPY services/github-bot/ ./services/github-bot/

# Build
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd services/github-bot && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /github-bot ./cmd/github-bot

# Runtime image
FROM alpine:3.21

RUN apk --no-cache add ca-certificates

COPY --from=builder /github-bot /github-bot

# Run as non-root user
USER 65534:65534

EXPOSE 8080

ENTRYPOINT ["/github-bot"]
