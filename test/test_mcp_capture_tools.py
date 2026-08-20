"""
ProxyPin MCP 抓包控制工具调试脚本
测试 start_capture / stop_capture / clear_requests 三个工具的返回结构

流程：
  1. 初始化 MCP 会话（建立 SSE 连接，发送 initialize）
  2. 调用 stop_capture    （关闭代理，预期 status.running=False）
  3. 调用 start_capture   （启动代理，预期 status.running=True）
  4. 调用 clear_requests  （清空列表，预期 clearedCount>=0）
  5. 校验每次返回的 status 字段完整性

使用方法：
  1. 启动 ProxyPin 桌面端，确保 MCP Server 处于运行状态（默认端口 9099）
  2. 打开 ProxyPin 的抓包页面（让 ProxyServer.current 初始化）
  3. python test/test_mcp_capture_tools.py
"""
import json
import sys
import time

import requests

MCP_HOST = "127.0.0.1"
MCP_PORT = 9101
BASE_URL = f"http://{MCP_HOST}:{MCP_PORT}"

REQUEST_TIMEOUT = 10


def log(tag, msg):
    print(f"[{time.strftime('%H:%M:%S')}] [{tag}] {msg}", flush=True)


def check_health():
    """健康检查，确认 MCP Server 正在运行"""
    try:
        r = requests.get(f"{BASE_URL}/health", timeout=REQUEST_TIMEOUT)
        r.raise_for_status()
        body = r.json()
        log("HEALTH", f"status={body.get('status')} requestCount={body.get('requestCount')}")
        return True
    except Exception as e:
        log("HEALTH", f"FAIL: {e}")
        return False


def open_session():
    """直接使用任意 sessionId 通过 message 端点调用（无需建立 SSE）"""
    session_id = f"debug-{int(time.time() * 1000)}"
    log("SESSION", f"使用 sessionId={session_id}")
    return session_id


def call_tool(session_id, tool_name, arguments=None, msg_id=None):
    """通过 JSON-RPC 调用 MCP 工具"""
    if msg_id is None:
        msg_id = int(time.time() * 1000)
    payload = {
        "jsonrpc": "2.0",
        "id": msg_id,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": arguments or {},
        },
    }
    url = f"{BASE_URL}/message?sessionId={session_id}"
    r = requests.post(url, json=payload, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    body = r.json()
    if "error" in body and body["error"]:
        log("CALL", f"RPC error: {body['error']}")
        return body
    result = body.get("result", {})
    # MCP 工具的返回在 result.content[0].text 中，是一个 JSON 字符串
    content = result.get("content", [])
    if content and isinstance(content, list) and content[0].get("type") == "text":
        text = content[0].get("text", "")
        try:
            parsed = json.loads(text)
            return parsed
        except json.JSONDecodeError:
            return {"raw": text}
    return result


def assert_status_shape(label, status, require_running=None, require_count=None):
    """校验 status 字段结构"""
    errors = []
    if not isinstance(status, dict):
        return [f"status 不是 dict: {type(status).__name__}"]

    required_keys = ["running", "requestCount", "port", "sslEnabled",
                     "systemProxyEnabled", "socks5Enabled", "http2Enabled",
                     "proxyPassDomains"]
    for k in required_keys:
        if k not in status:
            errors.append(f"缺少字段: {k}")

    if require_running is not None and status.get("running") != require_running:
        errors.append(f"running 期望 {require_running}, 实际 {status.get('running')}")

    if require_count is not None and status.get("requestCount") != require_count:
        errors.append(f"requestCount 期望 {require_count}, 实际 {status.get('requestCount')}")

    if errors:
        log("CHECK", f"❌ {label} 校验失败:")
        for e in errors:
            log("CHECK", f"   - {e}")
        return errors
    log("CHECK", f"✅ {label} 校验通过")
    return []


def pretty(label, obj):
    """美化输出 JSON"""
    log(label, json.dumps(obj, ensure_ascii=False, indent=2))


def main():
    log("BOOT", "=== ProxyPin MCP 抓包控制工具调试脚本 ===")
    log("BOOT", f"目标 MCP Server: {BASE_URL}")

    # 0. 健康检查
    if not check_health():
        log("BOOT", "❌ MCP Server 未运行，请先启动 ProxyPin 并开启 MCP 服务")
        sys.exit(1)

    # 1. 建立会话
    session_id = open_session()

    # 2. 发送 initialize
    init_payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test_mcp_capture_tools", "version": "1.0.0"},
        },
    }
    r = requests.post(f"{BASE_URL}/message?sessionId={session_id}",
                      json=init_payload, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    log("INIT", f"serverInfo={r.json().get('result', {}).get('serverInfo')}")

    all_errors = []

    # 3. 调用 stop_capture (清理状态)
    log("STEP", "▶ 调用 stop_capture (确保代理关闭)")
    r1 = call_tool(session_id, "stop_capture", msg_id=1001)
    pretty("STOP", r1)
    errs = assert_status_shape("stop_capture", r1.get("status"), require_running=False)
    all_errors.extend([f"[stop_capture] {e}" for e in errs])

    time.sleep(1)

    # 4. 调用 start_capture
    log("STEP", "▶ 调用 start_capture (启动代理)")
    r2 = call_tool(session_id, "start_capture", msg_id=1002)
    pretty("START", r2)
    errs = assert_status_shape("start_capture", r2.get("status"), require_running=True)
    all_errors.extend([f"[start_capture] {e}" for e in errs])

    time.sleep(1)

    # 5. 调用 clear_requests
    log("STEP", "▶ 调用 clear_requests (清空列表)")
    r3 = call_tool(session_id, "clear_requests", msg_id=1003)
    pretty("CLEAR", r3)
    if "clearedCount" not in r3:
        all_errors.append("[clear_requests] 缺少 clearedCount 字段")
    errs = assert_status_shape("clear_requests", r3.get("status"))
    all_errors.extend([f"[clear_requests] {e}" for e in errs])

    # 6. 再次调用 start_capture 确认 idempotent
    log("STEP", "▶ 再次调用 start_capture (验证幂等)")
    r4 = call_tool(session_id, "start_capture", msg_id=1004)
    pretty("START2", r4)
    errs = assert_status_shape("start_capture(again)", r4.get("status"), require_running=True)
    all_errors.extend([f"[start_capture#2] {e}" for e in errs])

    # 7. 清理：停止代理
    log("STEP", "▶ 测试结束，停止代理")
    r5 = call_tool(session_id, "stop_capture", msg_id=1005)
    pretty("STOP2", r5)

    # 总结
    print()
    log("DONE", "=" * 50)
    if all_errors:
        log("DONE", f"❌ 共 {len(all_errors)} 处校验失败:")
        for e in all_errors:
            log("DONE", f"   - {e}")
        sys.exit(1)
    else:
        log("DONE", "✅ 全部 3 个工具 + 幂等性测试通过！")
        sys.exit(0)


if __name__ == "__main__":
    main()
