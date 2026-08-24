# 更新日志

## v1.3.0 - 2026-08-24

本版本将手机/局域网设备抓包与 macOS 本机抓包分开管理，并补齐面向 MCP 自动分析的工作台能力。

### 主要更新

- 新增「本机抓包」独立页面，避免本机流量与手机、平板等设备流量混在一起。
- 支持按来源设备、macOS 应用及域名筛选请求，并展示来源应用图标。
- 新增兼容 Surge 的安全第一跳模式：ProxyPin 接管 macOS 系统 HTTP/HTTPS 代理后，将原代理作为唯一上游；不会修改 Surge 配置，并在退出时原子恢复系统代理。
- 请求与响应采用双列详情布局，默认直接展示响应内容。
- 新增自动化工作台、抓包项目、API 资产、数据导出与采集方案归档。
- 新增 Mock 场景合集，可用一个开关统一启停多条 Mock 规则。
- 扩展 MCP 工具，让 AI 可以分析当前抓包会话、API 结构与归档数据。

### 下载说明

- `proxypin-mcp-workbench-macos-1.3.0.zip`：macOS Universal（Apple Silicon + Intel）。当前为 ad-hoc 临时签名、未经过 Apple 公证；首次打开可在 Finder 中右键应用并选择「打开」。
- `proxypin-mcp-workbench-windows-1.3.0-setup.exe`：Windows 安装程序。
- `proxypin-mcp-workbench-windows-1.3.0.zip`：Windows 免安装压缩包。

### 证书安全

- 发布包不包含用户 CA 私钥、`.p12/.pfx`、抓包记录、Token、Cookie、Mock 私有配置或调试日志。
- 包内 `assets/certs/ca.crt` 仅作为公开证书结构模板，不包含私钥。
- 每台设备首次运行时会在本机 Application Support 目录独立生成 CA 与私钥；macOS/Linux 私钥文件权限设置为 `0600`。
- HTTPS 解密仅应用于你主动安装并信任该 CA 的设备。停止调试后，建议在系统证书设置中移除不再使用的 ProxyPin CA。

### SHA-256

```text
ad147c9b954f748c4d10ed29a28c6781102212e831d720400e12e62eb5f9eed1  proxypin-mcp-workbench-macos-1.3.0.zip
57fa86aa8a2f81ba403685c46cb9e88b343b43dd25ab5e9367c7e00de908e422  proxypin-mcp-workbench-windows-1.3.0-setup.exe
cbc153baba9e2f6c524233971a1621519e48e129aafe682db5feff58b84f895a  proxypin-mcp-workbench-windows-1.3.0.zip
```

完整提交记录：[v1.3.0](https://github.com/sinyu1012/proxypin-mcp-workbench/commits/v1.3.0)
