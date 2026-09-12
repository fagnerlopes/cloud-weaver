#!/bin/sh
# CloudWeaver entrypoint for the hermes-agent recipe.
#
# Brings up the ttyd web terminal behind an nginx basic-auth gate, then hands
# off to the upstream Hermes entrypoint, which stays the container's main
# process (so `docker stop` and the gateway's own supervision keep working).
#
#   nginx :7681        -> basic auth; /cw-health exempt   (kamal-proxy target)
#   ttyd  :7682        -> Hermes CLI, bound to loopback only
#   hermes gateway run -> exec'd last, as PID 1's payload

set -e

TTYD_USER="${TTYD_USER:-admin}"

if [ -z "${TTYD_PASSWORD}" ]; then
    echo "FATAL: TTYD_PASSWORD is not set — refusing to expose an unauthenticated terminal." >&2
    exit 1
fi

# Credentials file for nginx (apr1, the same scheme the VPS recipe feeds Traefik).
printf '%s:%s\n' "$TTYD_USER" "$(openssl passwd -apr1 "$TTYD_PASSWORD")" \
    > /etc/nginx/cw.htpasswd
chmod 600 /etc/nginx/cw.htpasswd

# ttyd, kept alive by a restart loop — the upstream image's s6 tree supervises
# the gateway only, and we deliberately do not graft services into it.
(
    while true; do
        /usr/local/bin/ttyd \
            --port 7682 \
            --interface 127.0.0.1 \
            --writable \
            /opt/hermes/.venv/bin/hermes
        echo "[cloudweaver] ttyd exited — restarting in 2s" >&2
        sleep 2
    done
) &

nginx -g 'daemon off;' &

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
