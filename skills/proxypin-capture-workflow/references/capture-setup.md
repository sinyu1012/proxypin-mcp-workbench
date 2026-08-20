# 手机抓包配置与诊断

## 从可验证的桌面状态开始

1. 找到正在运行的 ProxyPin 进程，确认它来自哪个构建目录。
2. 验证 HTTP 代理监听在局域网地址，MCP 服务仅在回环地址响应。
3. 让电脑与手机处于同一个 Wi-Fi；手机代理必须使用电脑的真实局域网 IP，不能使用 `127.0.0.1`。
4. 在手机 Wi-Fi 详情中把 HTTP 代理设为“手动”，填写电脑局域网 IP 和 ProxyPin HTTP 端口。
5. 先通过普通 HTTP 页面或 ProxyPin 中出现的请求验证转发，再排查 CA。

常用只读检查：

```bash
ps ax -o pid=,command= | rg 'ProxyPin.app/Contents/MacOS/ProxyPin'
lsof -nP -iTCP -sTCP:LISTEN | rg 'ProxyPin|9099|9101'
curl -sS http://127.0.0.1:9101/health
```

端口只是示例，必须以当前运行配置为准。

## 安装并信任 CA

使用 ProxyPin 针对目标平台提供的证书安装入口。CA 必须由当前可信构建在本地生成；不要接受聊天、邮件或公共下载链接中的陌生 CA。

iPhone：

1. 手机流量已通过 ProxyPin 后，使用“安装根证书 iOS”流程。
2. 在系统设置中安装下载的描述文件。
3. 打开“设置 → 通用 → 关于本机 → 证书信任设置”，为该 ProxyPin CA 开启完全信任。
4. 如果界面提供名称或指纹，与电脑端显示值进行核对。
5. 开启 HTTPS 抓包，并仅对目标域名启用解密。

“描述文件已安装”和“根证书已完全信任”是两个不同步骤。Mac 上显示证书已安装，也不能证明 iPhone 已信任。

## 手机像断网时的排查顺序

1. 确认 ProxyPin 正在抓包，手机填写的是 HTTP 代理端口，不是 MCP、SOCKS 或远程控制端口。
2. 确认电脑局域网 IP 没有变化，两台设备所在网络没有客户端隔离。
3. 暂停手机和电脑上的冲突 VPN/代理，包括 Surge、Private Relay 和按 App 路由的 VPN。
4. 检查 macOS 防火墙是否允许当前实际运行的 ProxyPin 构建接收入站连接。
5. 关闭 HTTPS 解密，先验证普通 HTTP 转发。
6. HTTP 正常而 HTTPS 失败时，检查 CA 安装、完全信任、HTTPS 开关和域名范围。
7. Safari 可以解密但某个 App 不行时，分别考虑 QUIC/HTTP3、代理绕过和证书固定；不要直接尝试绕过证书固定。
8. 请求出现但响应失败时，检查状态码、TLS 错误、超时，以及是否启用了重写或断点。

## 清理

- 将手机 Wi-Fi 代理改回“关闭”。
- 不再使用时关闭 ProxyPin HTTPS 抓包。
- 移除不再需要的 ProxyPin 描述文件和根 CA。
- 删除包含凭据的 HAR、会话和截图。
- 验证手机恢复正常网络。
