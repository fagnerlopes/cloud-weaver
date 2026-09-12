# CloudWeaver WAHA recipe image.
#
# Thin wrapper over the official WAHA image that adds a health check
# and documents the expected port (3000).
# WAHA connects to Postgres at host "pg" (Kamal accessory internal hostname).

FROM devlikeapro/waha:latest

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -fsS http://localhost:3000/api/health > /dev/null || exit 1
