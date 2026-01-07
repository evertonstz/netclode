FROM golang:1.25-alpine AS builder

WORKDIR /app

# Download dependencies first for caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o control-plane ./cmd/control-plane

# Runtime image
FROM alpine:3.21

RUN apk --no-cache add ca-certificates

COPY --from=builder /app/control-plane /control-plane

# Run as non-root user
USER 65534:65534

EXPOSE 3000

ENTRYPOINT ["/control-plane"]
