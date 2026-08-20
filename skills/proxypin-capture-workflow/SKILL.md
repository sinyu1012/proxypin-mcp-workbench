---
name: proxypin-capture-workflow
description: Operate a local ProxyPin workflow for iPhone or Android capture, MCP request analysis, authorized personal-data export, and Mock rule management. Use when the user mentions ProxyPin, mobile HTTPS capture, ProxyPin MCP, captured API discovery, HAR-like export, or ProxyPin Mock collections.
---

# ProxyPin Capture Workflow

Use the live ProxyPin instance and captured requests as the source of truth. Do not infer an endpoint from an old note when it is cheap to inspect the current capture.

## Locate the live system

- The source checkout may live anywhere; resolve it from the user's workspace instead of assuming a personal absolute path.
- The customized desktop build commonly exposes an HTTP proxy and a loopback MCP server. Verify both from the running process, configuration, or `/health`; do not assume ports are unchanged.
- Preserve a dirty worktree. Before code changes, run `git status --short` and inspect overlapping diffs.
- A running app, an open proxy port, captured CONNECT traffic, decrypted HTTPS, and a successful Mock match are separate verification levels. Report only the levels actually observed.

## Route by task

- For phone connection, CA installation, HTTPS enablement, or “phone has no internet”, read [references/capture-setup.md](references/capture-setup.md).
- For request discovery, MCP JSON-RPC, endpoint analysis, and request-detail inspection, read [references/mcp-analysis.md](references/mcp-analysis.md).
- For complete data export, privacy-safe replay, validation, or Mock collection management, read [references/export-and-mock.md](references/export-and-mock.md).

Use `scripts/proxypin_mcp.py` for health checks and ordinary MCP calls. It redacts common credentials by default. Use `--raw` only when a local transformation genuinely needs exact values, and redirect raw output to a permission-restricted temporary file rather than echoing it into chat.

## Shared boundaries

- Work only on traffic, accounts, devices, and applications the user owns or is authorized to test.
- Installing a local CA is authorized only for the user's device and ProxyPin instance. Never provide certificate-pinning bypass, app repackaging, Frida injection, jailbreak, or root instructions.
- “Analyze”, “inspect”, or “export” is read-only with respect to remote services. It does not authorize Mock rules, replays that mutate server state, account changes, or private endpoint probing.
- Mocking a paid or privileged state is acceptable only for the user's own application or an explicitly authorized test environment. Do not help bypass third-party entitlements.
- Treat cookies, Authorization headers, query tokens, account codes, device identifiers, child/family data, and captured bodies as sensitive. Do not print them in summaries, commits, screenshots, or persistent helper scripts.
- Prefer exact host-scoped HTTPS decryption. Do not enable blanket decryption when the task concerns a small set of domains.

## Completion evidence

For capture tasks, state whether the phone connected, whether HTTP was captured, and whether HTTPS bodies decrypted. For exports, report range, counts, deduplication, cross-checks, and output paths. For Mock tasks, verify persisted groups/rules through MCP or config and, when UI changed, build and inspect the running desktop UI.
