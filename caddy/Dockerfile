# Custom Caddy with the Cloudflare DNS plugin compiled in.
# Needed for DNS-01 challenge — lets us issue real LetsEncrypt certs
# without exposing port 80 to the public internet.

FROM caddy:2-builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
