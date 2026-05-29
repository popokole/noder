#!/usr/bin/env python3
"""
05_reality.py — генерация Reality keypair + валидация dest-маски.

Использование:
    reality.py keygen
        → JSON {"private_key": "...", "public_key": "..."} (X25519)

    reality.py validate <host[:port]>
        → JSON отчёт по dest-кандидату:
          {
            "host": "...", "port": 443, "ok": true/false,
            "resolved": ["1.2.3.4"], "tls13": true, "h2": true,
            "blacklisted": false, "reasons": ["..."]
          }
        Проверки:
          • DNS-резолв
          • TLS 1.3 handshake (через openssl s_client)
          • ALPN h2 (HTTP/2)
          • Не в списке forbidden_substrings (российские/блокируемые)
          • (опционально) проверка в реестре РКН — пока offline-only

    reality.py masks
        → выводит data/reality_masks.json как есть

X25519 keypair генерируется через docker-образ remnawave/node (xray x25519).
Если docker недоступен, fallback: используем cryptography (pip-зависимость не
требуем, поэтому fallback включается только если модуль есть).

by popokole
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

NODER_HOME = Path(os.environ.get("NODER_HOME", "/opt/noder"))
MASKS_FILE = NODER_HOME / "data" / "reality_masks.json"
DOCKER_IMAGE = "remnawave/node:latest"


# ---------------------------------------------------------------------------
# X25519 keypair
# ---------------------------------------------------------------------------

def _xray_keygen_docker() -> dict | None:
    if shutil.which("docker") is None:
        return None
    try:
        out = subprocess.run(
            ["docker", "run", "--rm", DOCKER_IMAGE, "xray", "x25519"],
            check=True, capture_output=True, text=True, timeout=60,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return _parse_xray_x25519_output(out)


def _xray_keygen_local() -> dict | None:
    # If xray is installed natively (rare), use it.
    if shutil.which("xray") is None:
        return None
    try:
        out = subprocess.run(
            ["xray", "x25519"], check=True, capture_output=True, text=True, timeout=15,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return _parse_xray_x25519_output(out)


def _xray_keygen_python() -> dict | None:
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import (
            Encoding, PrivateFormat, PublicFormat, NoEncryption,
        )
        import base64
    except ImportError:
        return None
    priv = X25519PrivateKey.generate()
    priv_raw = priv.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    # Xray uses urlsafe-b64 (no padding) for Reality keys.
    return {
        "private_key": base64.urlsafe_b64encode(priv_raw).rstrip(b"=").decode(),
        "public_key": base64.urlsafe_b64encode(pub_raw).rstrip(b"=").decode(),
    }


def _parse_xray_x25519_output(text: str) -> dict | None:
    priv = pub = None
    for line in text.splitlines():
        line = line.strip()
        # Xray prints either "Private key: ..." or "PrivateKey: ..." depending on version.
        if line.lower().startswith(("private key", "privatekey")):
            priv = line.split(":", 1)[1].strip()
        elif line.lower().startswith(("public key", "publickey", "password")):
            # Newer xray uses "Password" for the public side of Reality.
            pub = line.split(":", 1)[1].strip()
    if priv and pub:
        return {"private_key": priv, "public_key": pub}
    return None


def keygen() -> dict:
    for fn in (_xray_keygen_local, _xray_keygen_docker, _xray_keygen_python):
        result = fn()
        if result and result.get("private_key") and result.get("public_key"):
            return result
    raise SystemExit(
        "Не удалось сгенерировать X25519 keypair. Установите docker (для образа "
        f"{DOCKER_IMAGE}) или python3-cryptography."
    )


# ---------------------------------------------------------------------------
# Dest validation
# ---------------------------------------------------------------------------

def _load_masks() -> dict:
    if not MASKS_FILE.exists():
        return {"masks": [], "forbidden_substrings": []}
    return json.loads(MASKS_FILE.read_text(encoding="utf-8"))


def _split_host_port(target: str) -> tuple[str, int]:
    if ":" in target and not target.startswith("["):
        host, _, port = target.rpartition(":")
        return host, int(port)
    return target, 443


def _is_forbidden(host: str, forbidden: list[str]) -> bool:
    h = host.lower()
    return any(sub in h for sub in forbidden)


def _resolve(host: str) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return []
    seen = set()
    out: list[str] = []
    for info in infos:
        addr = info[4][0]
        if addr not in seen:
            seen.add(addr)
            out.append(addr)
    return out


def _tls_probe(host: str, port: int, timeout: int = 8) -> dict:
    """Negotiate TLS via Python's ssl module and report version + ALPN."""
    import ssl
    ctx = ssl.create_default_context()
    # Require TLS 1.3 floor when the runtime supports it. LibreSSL builds
    # (notably macOS Python 3.9) raise ValueError here — fall back to
    # plain negotiation and inspect the resulting version afterwards.
    try:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    except (AttributeError, ValueError):
        pass
    ctx.set_alpn_protocols(["h2", "http/1.1"])

    try:
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as tls:
                version = tls.version()           # e.g. "TLSv1.3"
                alpn = tls.selected_alpn_protocol()  # e.g. "h2"
    except ssl.SSLError as e:
        return {"tls_version": None, "alpn": None, "error": f"tls: {e}"}
    except socket.timeout:
        return {"tls_version": None, "alpn": None, "error": "timeout"}
    except OSError as e:
        return {"tls_version": None, "alpn": None, "error": str(e)}

    norm = {"TLSv1.3": "1.3", "TLSv1.2": "1.2", "TLSv1.1": "1.1", "TLSv1": "1.0"}
    return {
        "tls_version": norm.get(version or "", version),
        "alpn": alpn,
        "error": None,
    }


def validate(target: str) -> dict:
    masks = _load_masks()
    forbidden = masks.get("forbidden_substrings", [])
    host, port = _split_host_port(target)

    report: dict = {
        "host": host,
        "port": port,
        "ok": False,
        "blacklisted": False,
        "resolved": [],
        "tls13": False,
        "h2": False,
        "reasons": [],
    }

    if _is_forbidden(host, forbidden):
        report["blacklisted"] = True
        report["reasons"].append(
            "запрещено: маска совпадает с российским или блокируемым ресурсом"
        )
        return report

    resolved = _resolve(host)
    report["resolved"] = resolved
    if not resolved:
        report["reasons"].append("DNS не резолвится")
        return report

    tls = _tls_probe(host, port)
    if tls.get("error"):
        report["reasons"].append(f"TLS handshake: {tls['error']}")
        return report
    report["tls13"] = tls.get("tls_version") == "1.3"
    report["h2"] = tls.get("alpn") == "h2"

    if not report["tls13"]:
        report["reasons"].append(
            f"требуется TLS 1.3, сервер согласовал {tls.get('tls_version')}"
        )
    if not report["h2"]:
        report["reasons"].append(
            f"требуется ALPN h2, сервер согласовал {tls.get('alpn')}"
        )

    report["ok"] = report["tls13"] and report["h2"]
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_keygen(_args) -> int:
    print(json.dumps(keygen()))
    return 0


def cmd_validate(args) -> int:
    rep = validate(args.target)
    print(json.dumps(rep, ensure_ascii=False))
    return 0 if rep["ok"] else 1


def cmd_masks(_args) -> int:
    print(MASKS_FILE.read_text(encoding="utf-8"))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="reality.py", description="noder Reality helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("keygen").set_defaults(func=cmd_keygen)

    p_val = sub.add_parser("validate")
    p_val.add_argument("target", help="host or host:port")
    p_val.set_defaults(func=cmd_validate)

    sub.add_parser("masks").set_defaults(func=cmd_masks)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
