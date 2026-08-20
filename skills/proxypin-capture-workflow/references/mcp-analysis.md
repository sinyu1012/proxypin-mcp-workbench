# MCP 请求分析

## 传输方式

定制版 ProxyPin 在本机回环地址提供 JSON-RPC。通过 MCP 方法 `tools/call` 调用工具：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "search_requests",
    "arguments": {"urlKeyword": "example.com", "limit": 20}
  }
}
```

优先使用仓库内置的脱敏辅助脚本：

```bash
python3 scripts/proxypin_mcp.py health
python3 scripts/proxypin_mcp.py call search_requests '{"urlKeyword":"example.com","limit":20}'
python3 scripts/proxypin_mcp.py call get_request_detail '{"requestId":"REQUEST_ID","includeBody":true,"maxBodySize":200000}'
```

MCP 监听器应只绑定回环地址。手机连接 HTTP 代理，本地 AI 客户端连接 MCP；不要为了手机抓包把 MCP 暴露到局域网。

## 发现流程

1. 只有用户授权时才清空或重置抓包；否则在现有列表中进行有界搜索。
2. 在目标 App 中只触发一个明确动作。
3. 使用 `get_request_stats` 或 `get_domain_summary` 找出活跃域名。
4. 使用 `search_requests` 按 URL、正文或请求头关键字搜索，并限制返回数量。
5. 对最强候选使用 `get_request_detail`，只有确实需要时才读取正文。
6. 对比同一时间附近的请求，区分页面初始化、统计、上传和真正的数据 API。
7. 记录方法、路径、分页参数、响应结构、结果码和时区行为。

可用工具通常包括 `get_request_list`、`search_requests`、`get_request_detail`、`get_request_body`、`compare_requests`、`get_domain_summary`、`extract_api_endpoints`、`list_rewrite_rules` 和 `generate_code`。定制构建可能变化，应先查询 `tools/list`。

## 证据等级

- DNS、历史 APK 或深链中的主机名只能作为线索。
- 当前客户端会话里的抓包请求能把路径与真实动作关联起来。
- 对用户自己数据的一次成功只读重放，证明该请求在当前授权下仍然有效。
- 单次成功响应不能证明分页完整、写操作安全或接口属于公开 API。

不要猜测性调用未记录的私有接口。用户自己数据的捕获 GET 可能在范围内；POST、PUT、PATCH、DELETE 必须获得明确授权并理解实际影响。

## 敏感输出

MCP 详情可能包含查询凭据、Cookie、Bearer Token、账号资料、儿童数据和设备 ID。原始内容只保留在本地。对外展示时只报告字段名、类型、数量、时间和已经脱敏的 URL 结构；转换完成后删除精确请求详情临时文件。
