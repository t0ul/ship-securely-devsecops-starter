# --- build stage ---
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/server ./main.go

# --- runtime stage ---
FROM alpine:3.20

# Create group and user with fixed IDs
RUN addgroup -g 10001 app && adduser -D -H -u 10001 -G app appuser

WORKDIR /home/appuser
COPY --from=build /out/server /usr/local/bin/server

# Ensure ownership (optional if you don’t write to $HOME)
RUN chown -R 10001:10001 /home/appuser

# Set USER **numerically** so kubelet can verify non-root
USER 10001:10001

EXPOSE 3000
ENV PORT=3000
ENTRYPOINT ["/usr/local/bin/server"]

