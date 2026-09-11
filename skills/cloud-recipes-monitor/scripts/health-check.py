#!/usr/bin/env python3
"""Health check poller for Cloud Recipes deployments.

Polls a URL until it returns HTTP 200, with exponential backoff, a total
timeout and an initial grace delay (let cloud-init / docker compose boot).
Pure Python 3 standard library, matching the vm-provision.py / deploy-hermes.py
style. All HTTP goes through a proxy-free opener so the check always hits the
VM directly.

The polling core (`poll`) is injectable for offline tests: pass custom
requester / sleep / now functions. Exit code: 0 when healthy, 1 on timeout.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

DEFAULT_TIMEOUT_S = 600
DEFAULT_INITIAL_DELAY_S = 30
DEFAULT_REQUEST_TIMEOUT_S = 10
MAX_BACKOFF_S = 60


def open_url(url, request_timeout):
    """Return the HTTP status code; 0 on connection/network errors.

    A dedicated opener with an empty ProxyHandler disables any environment
    proxy, so the poll always goes straight to the target address.
    """
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=request_timeout) as resp:
            return resp.getcode()
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:
        return 0


def backoff_delay(attempt):
    """Exponential backoff: 5s, 10s, 20s, 40s, capped at 60s."""
    return min(MAX_BACKOFF_S, 5 * (2 ** max(attempt, 0)))


def poll(url, timeout_s=DEFAULT_TIMEOUT_S, initial_delay_s=DEFAULT_INITIAL_DELAY_S,
         requester=open_url, sleep=time.sleep, now=time.monotonic, request_timeout=DEFAULT_REQUEST_TIMEOUT_S):
    """Poll `url` until HTTP 200 or timeout. Returns (ok, attempts)."""
    started = now()
    if initial_delay_s:
        sleep(initial_delay_s)
    attempts = []
    while now() - started < timeout_s:
        status = requester(url, request_timeout)
        attempts.append(status)
        if status == 200:
            return True, attempts
        delay = backoff_delay(len(attempts) - 1)
        if now() - started + delay >= timeout_s:
            break
        sleep(delay)
    return False, attempts


def parse_args(argv):
    p = argparse.ArgumentParser(description="Poll an HTTP health endpoint until 200.")
    p.add_argument("--url", required=True, help="Health URL (e.g. http://<ip>:3000/api/health)")
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S,
                   help="Total polling budget in seconds (default %(default)s)")
    p.add_argument("--initial-delay", type=float, default=DEFAULT_INITIAL_DELAY_S,
                   help="Grace period before the first probe (default %(default)s)")
    p.add_argument("--output", default=None, help="Write the report JSON to this path")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    ok, attempts = poll(args.url, timeout_s=args.timeout, initial_delay_s=args.initial_delay)
    final_status = attempts[-1] if attempts else None
    report = {
        "url": args.url,
        "ok": ok,
        "attempts": attempts,
        "attempt_count": len(attempts),
        "final_status": final_status,
    }
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, sort_keys=True)
            f.write("\n")
    if ok:
        print("Healthy: HTTP {} after {} attempt(s)".format(final_status, len(attempts)))
        return 0
    print("Unhealthy: no HTTP 200 after {} attempt(s) — last status {} "
          .format(len(attempts), final_status), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())