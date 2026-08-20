#!/usr/bin/env python3
"""Small, redacting client for ProxyPin's local MCP endpoint."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen


DEFAULT_BASE_URL = "http://127.0.0.1:9101"
SENSITIVE_KEYS = {
    "authorization",
    "cookie",
    "set-cookie",
    "token",
    "access_token",
    "refresh_token",
    "apikey",
    "api_key",
    "secret",
    "password",
    "usercode",
    "trackinfo",
}
BEARER_RE = re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+")


def redact_url(value: str) -> str:
    try:
        parts = urlsplit(value)
    except ValueError:
        return value
    if not parts.scheme or not parts.netloc or not parts.query:
        return value
    query = []
    for key, item in parse_qsl(parts.query, keep_blank_values=True):
        query.append((key, "[REDACTED]" if key.lower() in SENSITIVE_KEYS else item))
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def redact(value: Any, key: str | None = None) -> Any:
    if key and key.lower() in SENSITIVE_KEYS:
        return "[REDACTED]"
    if isinstance(value, dict):
        return {item_key: redact(item_value, str(item_key)) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, str):
        text = redact_url(value)
        return BEARER_RE.sub("Bearer [REDACTED]", text)
    return value


def request_json(url: str, payload: dict[str, Any] | None = None) -> Any:
    if payload is None:
        request = Request(url)
    else:
        body = json.dumps(payload).encode("utf-8")
        request = Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    with urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def unpack_text_content(response: Any) -> Any:
    try:
        content = response["result"]["content"]
    except (KeyError, TypeError):
        return response
    if len(content) != 1 or content[0].get("type") != "text":
        return response
    try:
        return json.loads(content[0]["text"])
    except (json.JSONDecodeError, KeyError):
        return response


def main() -> int:
    parser = argparse.ArgumentParser(description="Call ProxyPin MCP with credential redaction by default")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--raw", action="store_true", help="print exact response; keep it local")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("health")
    subparsers.add_parser("tools")
    call_parser = subparsers.add_parser("call")
    call_parser.add_argument("tool")
    call_parser.add_argument("arguments", nargs="?", default="{}", help="JSON object")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    if args.command == "health":
        result = request_json(f"{base_url}/health")
    elif args.command == "tools":
        result = request_json(
            f"{base_url}/message",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
        )
    else:
        try:
            arguments = json.loads(args.arguments)
        except json.JSONDecodeError as error:
            parser.error(f"arguments must be valid JSON: {error}")
        if not isinstance(arguments, dict):
            parser.error("arguments must decode to a JSON object")
        result = request_json(
            f"{base_url}/message",
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": args.tool, "arguments": arguments},
            },
        )
        result = unpack_text_content(result)

    print(json.dumps(result if args.raw else redact(result), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ProxyPin MCP request failed: {error}", file=sys.stderr)
        raise SystemExit(1)
