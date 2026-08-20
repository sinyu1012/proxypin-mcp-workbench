"""预清理：在调试脚本运行前关闭代理，确保初始状态干净"""
import json
import requests

BASE = "http://127.0.0.1:9101"


def call(name, args=None, sid="pre-clean-session"):
    p = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": name, "arguments": args or {}},
    }
    r = requests.post(f"{BASE}/message?sessionId={sid}", json=p, timeout=10)
    r.raise_for_status()
    body = r.json()
    if "error" in body and body["error"]:
        return body
    result = body.get("result", {})
    content = result.get("content", [])
    if content and isinstance(content, list):
        text = content[0].get("text", "")
        try:
            return json.loads(text)
        except Exception:
            return {"raw": text}
    return result


if __name__ == "__main__":
    print("=== Pre-clean: 调用 stop_capture ===")
    result = call("stop_capture")
    print(json.dumps(result, ensure_ascii=False, indent=2))
