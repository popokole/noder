#!/usr/bin/env python3
"""
04_random.py — криптографически безопасная генерация параметров для noder.

Использует только secrets / os.urandom; никогда не использует random.*.

Использование:
    random.py short-id                           hex(8)
    random.py port [--exclude PORT[,PORT...]]    случайный порт 10000-65000
    random.py mask [--region REGION] [--avoid HOST[,HOST...]]
                                                  случайная маска из data/reality_masks.json
    random.py secret [--len N]                   hex(N), по умолчанию 32
    random.py node-suffix                        короткий суффикс для имени (например AB12)

by popokole
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import sys
from pathlib import Path

NODER_HOME = Path(os.environ.get("NODER_HOME", "/opt/noder"))
MASKS_FILE = NODER_HOME / "data" / "reality_masks.json"

# Reserved / commonly-occupied ports we never pick automatically.
RESERVED_PORTS = {
    22, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995,
    2222, 2375, 2376, 3000, 3306, 3389, 5432, 5900, 5984,
    6379, 8000, 8008, 8080, 8443, 8888, 9000, 9090, 9100,
    11211, 27017,
}


def hex_random(n_bytes: int) -> str:
    return secrets.token_hex(n_bytes)


def short_id() -> str:
    return hex_random(4)  # 8 hex chars


def free_port(exclude: set[int]) -> int:
    """
    Pick a port in [10000, 65000] that is:
      - not reserved,
      - not in caller-supplied exclude,
      - not currently bound on this host (best effort).
    """
    for _ in range(200):
        # secrets.randbelow gives uniform distribution.
        candidate = 10000 + secrets.randbelow(65000 - 10000 + 1)
        if candidate in RESERVED_PORTS or candidate in exclude:
            continue
        if _port_in_use(candidate):
            continue
        return candidate
    raise SystemExit("could not find a free port after 200 attempts")


def _port_in_use(port: int) -> bool:
    for family, proto in ((socket.AF_INET, socket.SOCK_STREAM),
                          (socket.AF_INET6, socket.SOCK_STREAM)):
        try:
            s = socket.socket(family, proto)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1" if family == socket.AF_INET else "::1", port))
            s.close()
        except OSError:
            return True
    return False


def load_masks() -> list[dict]:
    if not MASKS_FILE.exists():
        raise SystemExit(f"masks file not found: {MASKS_FILE}")
    data = json.loads(MASKS_FILE.read_text(encoding="utf-8"))
    return data.get("masks", [])


def pick_mask(region: str | None, avoid: set[str]) -> dict:
    masks = load_masks()
    pool = [m for m in masks if m["domain"] not in avoid]
    if region:
        regional = [m for m in pool if m.get("region") in (region, "global")]
        if regional:
            pool = regional
    if not pool:
        raise SystemExit("no masks available after filtering")
    return pool[secrets.randbelow(len(pool))]


def cmd_short_id(_args) -> int:
    print(short_id())
    return 0


def cmd_port(args) -> int:
    exclude: set[int] = set()
    if args.exclude:
        for p in args.exclude.split(","):
            p = p.strip()
            if p:
                exclude.add(int(p))
    print(free_port(exclude))
    return 0


def cmd_mask(args) -> int:
    avoid = set(x.strip() for x in args.avoid.split(",") if x.strip()) if args.avoid else set()
    mask = pick_mask(args.region, avoid)
    print(json.dumps(mask, ensure_ascii=False))
    return 0


def cmd_secret(args) -> int:
    print(hex_random(args.len))
    return 0


def cmd_node_suffix(_args) -> int:
    # 4 uppercase alphanumeric, easy to type/distinguish (no 0/O/1/I).
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    suffix = "".join(alphabet[secrets.randbelow(len(alphabet))] for _ in range(4))
    print(suffix)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="random.py", description="noder random parameter generator")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("short-id").set_defaults(func=cmd_short_id)

    p_port = sub.add_parser("port")
    p_port.add_argument("--exclude", default="")
    p_port.set_defaults(func=cmd_port)

    p_mask = sub.add_parser("mask")
    p_mask.add_argument("--region", default=None)
    p_mask.add_argument("--avoid", default="")
    p_mask.set_defaults(func=cmd_mask)

    p_secret = sub.add_parser("secret")
    p_secret.add_argument("--len", type=int, default=32)
    p_secret.set_defaults(func=cmd_secret)

    sub.add_parser("node-suffix").set_defaults(func=cmd_node_suffix)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
