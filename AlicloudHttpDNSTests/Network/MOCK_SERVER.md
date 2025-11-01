# HTTP Mock Server for Integration Tests

本目录包含用于 `HttpdnsNWHTTPClient` 集成测试的 HTTP/HTTPS mock server，用于替代 httpbin.org。

---

## 为什么需要 Mock Server？

1. **可靠性**: httpbin.org 在高并发测试下表现不稳定，经常返回非预期的 HTTP 状态码（如 429 Too Many Requests）
2. **速度**: 本地服务器响应更快，缩短测试执行时间
3. **离线测试**: 无需网络连接即可运行集成测试
4. **可控性**: 完全掌控测试环境，便于调试和复现问题

---

## 快速开始

### 1. 启动 Mock Server

```bash
# 进入测试目录
cd AlicloudHttpDNSTests/Network

# 启动服务器（无需 sudo 权限，使用非特权端口）
python3 mock_server.py
```

**注意**:
- **无需 root 权限**（使用非特权端口 11080/11443-11446）
- 首次运行会自动生成自签名证书 (`server.pem`)
- 按 `Ctrl+C` 停止服务器

### 2. 运行集成测试

在另一个终端窗口:

```bash
cd ~/Project/iOS/alicloud-ios-sdk-httpdns

# 运行所有集成测试
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientIntegrationTests

# 运行单个测试
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientIntegrationTests/testConcurrency_ParallelRequestsSameHost_AllSucceed
```

---

## 支持的 Endpoints

Mock server 实现了以下 httpbin.org 兼容的 endpoints:

| Endpoint | 功能 | 示例 |
|----------|------|------|
| `GET /get` | 返回请求信息（headers, args, origin） | `http://127.0.0.1:11080/get` |
| `GET /status/{code}` | 返回指定状态码（100-599） | `http://127.0.0.1:11080/status/404` |
| `GET /stream-bytes/{n}` | 返回 chunked 编码的 N 字节数据 | `http://127.0.0.1:11080/stream-bytes/1024` |
| `GET /delay/{seconds}` | 延迟指定秒数后返回（最多10秒） | `http://127.0.0.1:11080/delay/5` |
| `GET /headers` | 返回所有请求头部 | `http://127.0.0.1:11080/headers` |
| `GET /uuid` | 返回随机 UUID | `http://127.0.0.1:11080/uuid` |
| `GET /user-agent` | 返回 User-Agent 头部 | `http://127.0.0.1:11080/user-agent` |

**端口配置**:
- **HTTP**: `127.0.0.1:11080`
- **HTTPS**: `127.0.0.1:11443`, `11444`, `11445`, `11446`（4个端口用于测试连接池隔离）

所有 endpoints 在 HTTP 和 HTTPS 端口上均可访问。

---

## 实现细节

### 架构

- **HTTP 服务器**: 监听 `127.0.0.1:11080`
- **HTTPS 服务器**: 监听 `127.0.0.1:11443`, `11444`, `11445`, `11446`（4个端口，使用自签名证书）
- **多端口目的**: 测试连接池的端口隔离机制，确保不同端口使用独立的连接池
- **并发模型**: 多线程（`ThreadingMixIn`），支持高并发请求

### TLS 证书

- 自动生成自签名证书（RSA 2048位，有效期 365 天）
- CN (Common Name): `localhost`
- 证书文件: `server.pem`（同时包含密钥和证书）

**重要**: 集成测试通过环境变量 `HTTPDNS_SKIP_TLS_VERIFY=1` 跳过 TLS 验证，这是安全的，因为：
1. 仅在测试环境生效
2. 不影响生产代码
3. 连接限制为本地 loopback (127.0.0.1)

### 响应格式

所有 JSON 响应遵循 httpbin.org 格式，例如:

```json
{
  "args": {},
  "headers": {
    "Host": "127.0.0.1",
    "User-Agent": "HttpdnsNWHTTPClient/1.0"
  },
  "origin": "127.0.0.1",
  "url": "GET /get"
}
```

Chunked 编码响应示例 (`/stream-bytes/10`):
```
HTTP/1.1 200 OK
Transfer-Encoding: chunked

a
XXXXXXXXXX
0

```

---

## 故障排除

### 端口已被占用

**错误信息**:
```
✗ 端口 80 已被占用，请关闭占用端口的进程或使用其他端口
```

**解决方法**:

1. 查找占用进程:
```bash
sudo lsof -i :80
sudo lsof -i :443
```

2. 终止占用进程:
```bash
sudo kill -9 <PID>
```

3. 或修改 mock_server.py 使用其他端口:
```python
# 修改端口号（同时需要更新测试代码中的 URL）
run_http_server(port=8080)
run_https_server(port=8443)
```

### 缺少 OpenSSL

**错误信息**:
```
✗ 未找到 openssl 命令，请安装 OpenSSL
```

**解决方法**:

```bash
# macOS (通常已预装)
brew install openssl

# Ubuntu/Debian
sudo apt-get install openssl

# CentOS/RHEL
sudo yum install openssl
```

### 权限被拒绝

**错误信息**:
```
✗ 错误: 需要 root 权限以绑定 80/443 端口
```

**解决方法**:

必须使用 `sudo` 运行:
```bash
sudo python3 mock_server.py
```

---

## 切换回 httpbin.org

如需使用真实的 httpbin.org 进行测试（例如验证兼容性）:

1. 编辑 `HttpdnsNWHTTPClientIntegrationTests.m`
2. 将所有 `127.0.0.1` 替换回 `httpbin.org`
3. 注释掉 setUp/tearDown 中的环境变量设置

---

## 开发与扩展

### 添加新 Endpoint

在 `mock_server.py` 的 `MockHTTPHandler.do_GET()` 方法中添加:

```python
def do_GET(self):
    path = urlparse(self.path).path

    if path == '/your-new-endpoint':
        self._handle_your_endpoint()
    # ... 其他 endpoints

def _handle_your_endpoint(self):
    """处理自定义 endpoint"""
    data = {'custom': 'data'}
    self._send_json(200, data)
```

### 调试模式

取消注释 `log_message` 方法以启用详细日志:

```python
def log_message(self, format, *args):
    print(f"[{self.address_string()}] {format % args}")
```

---

## 技术栈

- **Python 3.7+** (标准库，无需额外依赖)
- **http.server**: HTTP 服务器实现
- **ssl**: TLS/SSL 支持
- **socketserver.ThreadingMixIn**: 多线程并发

---

## 安全注意事项

1. **仅用于测试**: 此服务器设计用于本地测试，不适合生产环境
2. **自签名证书**: HTTPS 使用不受信任的自签名证书
3. **无身份验证**: 不实现任何身份验证机制
4. **本地绑定**: 服务器仅绑定到 `127.0.0.1`，不接受外部连接

---

**最后更新**: 2025-11-01
**维护者**: Claude Code
