#!/usr/bin/env python3
"""Thin compatibility wrapper: postboot-check.sh calls this with import flags.

Real logic lives in idrac7-wsman.py (same package).
"""
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))

def main():
    args = [sys.executable, os.path.join(HERE, "idrac7-wsman.py")]
    if "--check-only" in sys.argv:
        args.append("check")
    else:
        args.append("import")
    args += [a for a in sys.argv[1:] if a != "--check-only"]
    return subprocess.call(args)

if __name__ == "__main__":
    sys.exit(main())
