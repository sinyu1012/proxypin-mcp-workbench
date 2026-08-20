# ProxyPin MCP

[中文](README.md) | English

> **This repo is an MCP-enhanced fork of [ProxyPin](https://github.com/wanghongenpin/proxypin).**  
> It ships a built-in **MCP Server (Model Context Protocol)** on top of the full original feature set, letting AI clients (Claude, Cursor, Windsurf, etc.) connect directly to the running proxy, read capture data, and actively control interception and modification—no extra service or Python script needed.

---

## MCP Features

> **TL;DR**: Open ProxyPin, and AI can see every request you capture, help you analyze it, modify it, and release it—like Fiddler breakpoints, but controlled by AI.

### Connection

The MCP Server listens on port **9101** by default (SSE transport, no extra dependencies required).

Configure in Claude Desktop / Cursor / Windsurf:

```json
{
  "mcpServers": {
    "proxypin": {
      "url": "http://127.0.0.1:9101/sse"
    }
  }
}
```

### Quick Debug: Raw JSON-RPC via `/message`

For quick testing or scripts, send raw JSON-RPC directly to the `/message` endpoint. No MCP client needed — just `curl`:

```bash
# 1. Connect SSE to get a sessionId (separate terminal or background)
curl -N http://127.0.0.1:9101/sse
# → prints: event: endpoint\ndata: http://127.0.0.1:9101/message?sessionId=xxxxx

# 2. Call any tool via POST /message?sessionId=xxxxx
curl -X POST "http://127.0.0.1:9101/message?sessionId=xxxxx" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"get_request_list","params":{}}'

# 3. One-liner for stateless debugging (omit sessionId for fire-and-forget)
curl -X POST http://127.0.0.1:9101/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"list_breakpoints","params":{}}'
```

**Tip**: The `/message` endpoint returns the JSON-RPC response directly in the HTTP body, so you can quickly inspect results without maintaining a persistent SSE connection. The `sessionId` is only needed if you want bi-directional SSE events (e.g. intercept notifications); for read-only tools (query, search, analysis), omitting it works fine.

---

### Available MCP Tools (27 total)

#### 1. Basic Capture Query (9 tools)

| Tool | Description |
|------|-------------|
| `get_request_list` | List captured requests with filters: domain, method, status code, keyword, pagination |
| `get_request_detail` | Full details of a single request: headers, body, response, timing |
| `get_request_body` | Fetch large request/response body content directly |
| `get_request_stats` | Summary stats: domain distribution, status codes, methods, avg latency |
| `search_requests` | Advanced search: URL/Body/Header keyword + time range |
| `get_domain_summary` | Group by domain: unique paths, method distribution, avg latency |
| `get_cookie_info` | Extract Cookie/Set-Cookie headers and analyze attributes |
| `compare_requests` | Diff two requests: URL, Headers, Query params, Body, Status code |
| `analyze_encrypted_content` | Detect Base64/Hex/URL-encoded/JWT content, compute entropy, hint at algorithm |

#### 2. Replay & Code Generation (2 tools)

| Tool | Description |
|------|-------------|
| `replay_request` | Replay a captured request with optional header/body overrides; returns the live response |
| `generate_code` | Convert a captured request to runnable code: Python / JavaScript / cURL / Go |

#### 3. Breakpoint Interception · Modify & Release (5 tools, highlight)

> Fiddler-style breakpoints, but controlled by AI conversation.

| Tool | Description |
|------|-------------|
| `add_breakpoint` | Add a breakpoint rule (URL regex + HTTP method + request/response phase) |
| `list_breakpoints` | List all rules and their enabled state |
| `remove_breakpoint` | Remove a rule by index |
| `get_pending_intercepts` | View all currently paused requests/responses with full data |
| `release_intercept` | Release an intercept with optional modifications: Headers, Body, StatusCode, or abort |

**Typical workflow:**
```
AI → add_breakpoint url=".*api/login.*"
   Trigger login in the App
AI → get_pending_intercepts        ← reads the full intercepted request
AI → release_intercept requestId=xxx body='{"user":"admin","pass":"test"}'
   The modified request is forwarded to the server
```

#### 4. Rewrite Rule Management (3 tools)

| Tool | Description |
|------|-------------|
| `list_rewrite_rules` | List all persistent rewrite rules |
| `add_rewrite_rule` | Add a rule: replace body/headers, update params, redirect (5 types) |
| `remove_rewrite_rule` | Remove a rule by index |

#### 5. JS Script Management (3 tools)

| Tool | Description |
|------|-------------|
| `list_scripts` | List all JS intercept scripts |
| `get_script_content` | Read script source code |
| `create_or_update_script` | AI writes/updates a JS script with `onRequest`/`onResponse`; takes effect immediately |

#### 6. Security Analysis (3 tools)

| Tool | Description |
|------|-------------|
| `find_sensitive_data` | Scan for phone numbers, ID cards, emails, JWT, Bearer tokens, API keys, passwords, private IPs |
| `analyze_auth` | Extract Auth headers, API key headers, Cookie session tokens; auto-decode JWT payloads |
| `extract_api_endpoints` | Group and normalize API paths (replace IDs/UUIDs with placeholders), count calls and status codes |

## Known Issues

### UI tearing when using Rewrite / Decrypt

When request rewrite rules or request decryption are active, the UI may occasionally flicker or tear. This is caused by the large number of simultaneous state updates — the UI thread is shared with the capture engine. It does not affect capture data or rewrite correctness.

### Occasional capture lag

Under heavy traffic, the request list may briefly stutter when new requests arrive. This is most noticeable when thousands of requests are in the list. Workaround: use `clear_requests` (or the MCP `clear_requests` tool) periodically to keep the list manageable.

---

## Capturing Claude Desktop traffic

Claude Desktop (and other Electron-based apps) use Node.js which has its own certificate store. There are two approaches to intercept their HTTPS traffic with ProxyPin:

### 1. Certificate trust (NODE_EXTRA_CA_CERTS)

1. Export the ProxyPin CA certificate (the app menu → HTTPS → Export Root Certificate → PEM)
2. Set the `NODE_EXTRA_CA_CERTS` environment variable before launching Claude:

```cmd
set NODE_EXTRA_CA_CERTS=C:\Users\1\Desktop\ProxyPinCA.pem
claude-desktop
```

Or set it system-wide (persistent):

```cmd
setx NODE_EXTRA_CA_CERTS C:\Users\1\Desktop\ProxyPinCA.pem
```

Then restart Claude Desktop. All HTTPS requests from Claude will now be captured by ProxyPin.

### 2. ProxyRule + ProxyBridge

For more control (selective routing, no certificate store modification), use ProxyRule + ProxyBridge together:

- **ProxyRule** — defines which requests to intercept (by domain, process, or URL pattern)
- **ProxyBridge** — a companion tool that bridges Claude's traffic through ProxyPin's proxy without needing Node.js certificate changes

Configure ProxyBridge to forward traffic through `127.0.0.1:9099` (ProxyPin's default proxy port), and set up a ProxyRule targeting `api.anthropic.com` (or `*` for all traffic). See the ProxyBridge documentation for setup details.

> **Note**: Claude's MCP client connections are not routed through the OS proxy by default — configure the MCP server URL in Claude's `claude_desktop_config.json` instead (see [Connection](#connection) above).

---

## Automated Build & Release

GitHub Actions handles multi-platform builds with no local Flutter environment needed.

### Workflows

| File | Trigger | Output |
|------|---------|--------|
| `windows-build.yml` | Push to `mcp-main` / manual | Windows zip (CI validation) |
| `release.yml` | `v*` tag push / manual | Windows zip + Setup.exe + Android APK → GitHub Release |

### Release a new version

```bash
git tag v1.2.8
git push origin v1.2.8
# GitHub Actions builds and creates the Release automatically (~15-25 min)
```

### Release Artifacts

- `proxypin-mcp-windows-{ver}.zip` — extract and run
- `proxypin-mcp-windows-{ver}-setup.exe` — Inno Setup installer (EN/ZH)
- `proxypin-mcp-android-{ver}.apk` — Android APK (release-signed if secrets configured, otherwise debug-signed)

### Android Signing (optional)

Set these Secrets in GitHub → Settings → Secrets → Actions to enable release signing:

| Secret | Description |
|--------|-------------|
| `ANDROID_KEYSTORE_BASE64` | Output of `base64 -w 0 your.keystore` |
| `ANDROID_STORE_PASSWORD` | storePassword |
| `ANDROID_KEY_ALIAS` | keyAlias |
| `ANDROID_KEY_PASSWORD` | keyPassword |

Without these secrets, the build automatically falls back to debug signing (sideloadable, not Play Store ready).

---

## Original ProxyPin Features (fully preserved)

- **All platforms**: Windows, Mac, Android, iOS, Linux
- **QR code device pairing**: connect phones without manual Wi-Fi proxy config
- **Domain filtering**: intercept only the traffic you need
- **Request search**: keyword, content-type, multi-condition search
- **JavaScript scripts**: dynamic request/response manipulation
- **Request rewrite**: redirect, replace body, modify headers/params
- **Request mapping**: respond with local files/scripts instead of remote server
- **Request decryption**: AES key auto-decrypts message bodies
- **Request blocking**: block requests by URL pattern
- **History**: auto-save capture data; HAR import/export

---

## Staying in sync with upstream

```bash
git fetch upstream
git merge upstream/main
git push origin mcp-main
```

---

## Upstream

Original ProxyPin: [https://github.com/wanghongenpin/proxypin](https://github.com/wanghongenpin/proxypin)  
Thanks to [@wanghongenpin](https://github.com/wanghongenpin) for the excellent original work.

## MCP Project Origin

The MCP Server implementation in this repository is based on [SuxyEE/proxypin-mcp](https://github.com/SuxyEE/proxypin-mcp), integrating the MCP Server directly into the ProxyPin process while preserving full capture capabilities.

Thanks to [@SuxyEE](https://github.com/SuxyEE) for the pioneering work.

---

## License

Apache License 2.0, same as the upstream project.
