# CloudWeaver hermes-agent recipe image.
#
# Bundles ttyd (web terminal on port 7681) as the main HTTP service managed
# by kamal-proxy. The Hermes Agent (Telegram bot + LLM) runs alongside ttyd
# using the entrypoint script below.
#
# Health check: ttyd responds with HTTP 200 at GET / when healthy.
# Port: 7681 (kamal proxy.app_port must match).
#
# NOTE: Replace the CMD below with the actual multi-process setup once the
# hermes-agent upstream image is confirmed. Current placeholder gives a
# working terminal accessible via the browser.

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        tini wget ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd (web terminal)
RUN TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64" && \
    wget -qO /usr/local/bin/ttyd "$TTYD_URL" && \
    chmod +x /usr/local/bin/ttyd

EXPOSE 7681

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -fsS http://localhost:7681/ > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["ttyd", "--port", "7681", "--writable", "bash"]
