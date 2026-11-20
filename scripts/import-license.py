#!/usr/bin/env python3
"""Thin compatibility wrapper: postboot-check.sh calls this with import flags.

Real logic lives in idrac7-wsman.py (same package).

TLS: idrac7-wsman.py verifies certificates by default, and the factory
iDRAC7 cert is self-signed/expired. This wrapper pins the BMC's public key
when config/pins/<host>.pin exists (created once with --trust-cert), and
falls back to --insecure otherwise so the postboot job never dies on the
cert. The pin, not a silent -k, is the trust anchor on boxes we manage.
"""
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PIN_DIR = os.path.join(HERE, "..", "config", "pins")


def host_arg(argv):
    for i, a in enumerate(argv):
        if a == "--host" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--host="):
            return a.split("=", 1)[1]
    return None


def tls_args(argv):
    host = host_arg(argv)
    if host:
        pin = os.path.normpath(os.path.join(PIN_DIR, f"{host}.pin"))
        if os.path.exists(pin):
            return ["--pin-file", pin]
    return ["--insecure"]


def main():
    args = [sys.executable, os.path.join(HERE, "idrac7-wsman.py")]
    if "--check-only" in sys.argv:
        args.append("check")
    else:
        args.append("import")
    args += [a for a in sys.argv[1:] if a != "--check-only"]
    args += tls_args(sys.argv[1:])
    return subprocess.call(args)


if __name__ == "__main__":
    sys.exit(main())
