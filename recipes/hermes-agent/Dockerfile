# CloudWeaver hermes-agent recipe image.
#
# Thin wrapper over the official Nous Research Hermes Agent image that adds a
# ttyd web terminal for first-run setup and day-to-day management.
#
# Architecture — mirrors the VPS cloud-init recipe, adapted to Kamal:
#
#   VPS recipe                      This image
#   ----------------------------    --------------------------------------
#   Traefik (TLS + basicauth)       kamal-proxy (TLS) + nginx (basicauth)
#   ttyd container :7681            ttyd on 127.0.0.1:7682, fronted by nginx
#   hermes-agent container          container main process (upstream entrypoint)
#
# nginx owns the published port so that basic auth can be enforced while
# leaving an unauthenticated liveness path for kamal-proxy — ttyd's own
# --credential would answer 401 on every path, including the health probe.
#
# All mutable state lives in /opt/data (HERMES_HOME), backed by the VM's
# /data disk through the Kamal volume mount.

FROM nousresearch/hermes-agent:latest

# Recipe images are published for linux/amd64 only (see build-recipes.yml).
ARG TTYD_VERSION=1.7.7

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx openssl curl ca-certificates \
    && curl -fsSL -o /usr/local/bin/ttyd \
         "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && chmod +x /usr/local/bin/ttyd \
    && rm -f /etc/nginx/sites-enabled/default \
    && rm -rf /var/lib/apt/lists/*

COPY nginx-ttyd.conf  /etc/nginx/conf.d/cw-ttyd.conf
COPY cw-entrypoint.sh /usr/local/bin/cw-entrypoint.sh
RUN chmod +x /usr/local/bin/cw-entrypoint.sh

EXPOSE 7681

HEALTHCHECK --interval=10s --timeout=5s --start-period=40s --retries=6 \
    CMD curl -fsS -o /dev/null http://localhost:7681/cw-health || exit 1

ENTRYPOINT ["/usr/local/bin/cw-entrypoint.sh"]
CMD ["hermes", "gateway", "run"]
