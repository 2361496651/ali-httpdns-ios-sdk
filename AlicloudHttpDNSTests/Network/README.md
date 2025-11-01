# HttpdnsNWHTTPClient 测试套件

本目录包含 `HttpdnsNWHTTPClient` 和 `HttpdnsNWReusableConnection` 的完整测试套件。

## 测试文件结构

```
AlicloudHttpDNSTests/Network/
├── HttpdnsNWHTTPClientTests.m              # 主单元测试（44个）
├── HttpdnsNWHTTPClientIntegrationTests.m   # 集成测试（7个）
├── HttpdnsNWHTTPClientTestHelper.h/m       # 测试辅助工具类
└── README.md                               # 本文件
```

## 测试覆盖范围

### 单元测试 (HttpdnsNWHTTPClientTests.m)

#### A. HTTP 解析逻辑测试 (25个)
- **A1. Header 解析 (9个)**
  - 正常响应解析
  - 多个头部字段
  - 不完整数据处理
  - 无效状态行
  - 空格处理与 trim
  - 空值头部
  - 非数字状态码
  - 状态码为零
  - 无效头部行

- **A2. Chunked 编码检查 (8个)**
  - 单个 chunk
  - 多个 chunks
  - 不完整 chunk
  - Chunk extension 支持
  - 无效十六进制 size
  - Chunk size 溢出
  - 缺少 CRLF 终止符
  - 带 trailers 的 chunked

- **A3. Chunked 解码 (2个)**
  - 多个 chunks 正确解码
  - 无效格式返回 nil

- **A4. 完整响应解析 (6个)**
  - Content-Length 响应
  - Chunked 编码响应
  - 空 body
  - Content-Length 不匹配
  - 空数据错误
  - 只有 headers 无 body

#### C. 请求构建测试 (7个)
- 基本 GET 请求格式
- 查询参数处理
- User-Agent 头部
- HTTP 默认端口处理
- HTTPS 默认端口处理
- 非默认端口显示
- 固定头部验证

#### E. TLS 验证测试 (4个占位符)
- 有效证书返回 YES
- Proceed 结果返回 YES
- 无效证书返回 NO
- 指定域名使用 SSL Policy

*注：TLS 测试需要真实的 SecTrustRef 或复杂 mock，当前为占位符*

#### F. 边缘情况测试 (8个)
- 超长 URL 处理
- 空 User-Agent
- 超大响应体（5MB）
- Chunked 解码失败回退
- 连接池 key - 不同 hosts
- 连接池 key - 不同 ports
- 连接池 key - HTTP vs HTTPS

### 集成测试 (HttpdnsNWHTTPClientIntegrationTests.m)

使用 httpbin.org 进行真实网络测试 (22个)：

**G. 基础集成测试 (7个)**
- HTTP GET 请求
- HTTPS GET 请求
- HTTP 404 响应
- 连接复用（两次请求）
- Chunked 响应处理
- 请求超时测试
- 自定义头部验证

**H. 并发测试 (5个)**
- 并发请求同一主机（10个线程）
- 并发请求不同路径（5个不同endpoint）
- 混合 HTTP + HTTPS 并发（各5个线程）
- 高负载压力测试（50个并发请求）
- 混合串行+并发模式

**I. 竞态条件测试 (5个)**
- 连接池容量测试（超过4个连接上限）
- 同时归还连接（5个并发）
- 获取-归还-再获取竞态
- 超时与活跃连接冲突（需31秒，可跳过）
- 错误恢复后连接池健康状态

**J. 高级连接复用测试 (5个)**
- 连接过期与清理（31秒，可跳过）
- 连接池容量限制验证（10个连续请求）
- 不同路径复用连接（4个不同路径）
- HTTP vs HTTPS 使用不同连接池key
- 长连接保持测试（20个请求间隔1秒，可跳过）

## 运行测试

### 运行所有单元测试
```bash
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientTests
```

### 运行集成测试（需要网络）
```bash
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientIntegrationTests
```

### 运行单个测试
```bash
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientTests/testParseHTTPHeaders_ValidResponse_Success
```

## 测试辅助工具

### HttpdnsNWHTTPClientTestHelper

提供以下工具方法：

#### HTTP 响应构造
```objc
// 构造标准 HTTP 响应
+ (NSData *)createHTTPResponseWithStatus:(NSInteger)statusCode
                              statusText:(NSString *)statusText
                                 headers:(NSDictionary *)headers
                                    body:(NSData *)body;

// 构造 chunked 响应
+ (NSData *)createChunkedHTTPResponseWithStatus:(NSInteger)statusCode
                                        headers:(NSDictionary *)headers
                                         chunks:(NSArray<NSData *> *)chunks;
```

#### Chunked 编码工具
```objc
+ (NSData *)encodeChunk:(NSData *)data;
+ (NSData *)encodeLastChunk;
```

#### 数据生成
```objc
+ (NSData *)randomDataWithSize:(NSUInteger)size;
+ (NSData *)jsonBodyWithDictionary:(NSDictionary *)dictionary;
```

## 测试统计

| 测试类别 | 测试数量 | 覆盖范围 |
|---------|---------|---------|
| HTTP 解析 | 25 | HTTP 头部、Chunked 编码、完整响应 |
| 请求构建 | 7 | URL 处理、头部生成 |
| TLS 验证 | 4 (占位符) | 证书验证 |
| 边缘情况 | 8 | 异常输入、连接池 key |
| **单元测试合计** | **43** | - |
| 基础集成测试 (G) | 7 | 真实网络请求、基本场景 |
| 并发测试 (H) | 5 | 多线程并发、高负载 |
| 竞态条件测试 (I) | 5 | 连接池竞态、错误恢复 |
| 连接复用测试 (J) | 5 | 连接过期、长连接、协议隔离 |
| 多端口连接隔离 (K) | 5 | 不同端口独立连接池 |
| 端口池耗尽测试 (L) | 3 | 多端口高负载、池隔离 |
| 边界条件验证 (M) | 4 | 端口迁移、高端口数量 |
| 并发多端口场景 (N) | 3 | 并行 keep-alive、轮询分配 |
| **集成测试合计** | **37** | - |
| **总计** | **80** | - |

## 待实现测试（可选）

以下测试组涉及复杂的 Mock 场景，可根据需要添加：

### B. 连接池管理测试 (18个)
需要 Mock `HttpdnsNWReusableConnection` 的完整生命周期

### D. 完整流程测试 (13个)
需要 Mock 连接池和网络层的集成场景

## Mock Server 使用

集成测试使用本地 mock server (127.0.0.1) 替代 httpbin.org，提供稳定可靠的测试环境。

### 启动 Mock Server

```bash
cd AlicloudHttpDNSTests/Network
python3 mock_server.py
```

**注意**：使用非特权端口（11080/11443-11446），无需 `sudo` 权限。

### 运行集成测试

在另一个终端窗口：

```bash
xcodebuild test \
  -workspace AlicloudHttpDNS.xcworkspace \
  -scheme AlicloudHttpDNSTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AlicloudHttpDNSTests/HttpdnsNWHTTPClientIntegrationTests
```

### Mock Server 特性

- **HTTP**: 监听 `127.0.0.1:11080`
- **HTTPS**: 监听 `127.0.0.1:11443`, `11444`, `11445`, `11446` (自签名证书)
- **多端口目的**: 测试连接池的端口隔离机制
- **并发支持**: 多线程处理，适合并发测试
- **零延迟**: 本地响应，测试速度快

详见 [MOCK_SERVER.md](./MOCK_SERVER.md)

## 注意事项

1. **集成测试依赖 Mock Server**：`HttpdnsNWHTTPClientIntegrationTests` 使用本地 mock server (127.0.0.1)。测试前需先启动 `mock_server.py`。

2. **慢测试跳过**：部分测试需要等待31秒（测试连接过期），可设置环境变量 `SKIP_SLOW_TESTS=1` 跳过这些测试：
   - `testRaceCondition_ExpiredConnectionPruning_CreatesNewConnection`
   - `testConnectionReuse_Expiry31Seconds_NewConnectionCreated`
   - `testConnectionReuse_TwentyRequestsOneSecondApart_ConnectionKeptAlive`

3. **并发测试容错**：并发和压力测试允许部分失败（例如 H.4 要求80%成功率），因为高负载下仍可能出现网络波动。

4. **TLS 测试占位符**：E 组 TLS 测试需要真实的 `SecTrustRef` 或高级 mock 框架，当前仅为占位符。

5. **新文件添加到 Xcode**：创建的测试文件需要手动添加到 `AlicloudHttpDNSTests` target。

6. **测试数据**：使用 `HttpdnsNWHTTPClientTestHelper` 生成测试数据，确保测试的可重复性。

## 文件依赖

测试文件依赖以下源文件：
- `HttpdnsNWHTTPClient.h/m` - 主要被测试类
- `HttpdnsNWHTTPClient_Internal.h` - 内部方法暴露（测试专用）
- `HttpdnsNWReusableConnection.h/m` - 连接管理
- `HttpdnsNWHTTPClientResponse` - 响应模型

## 贡献指南

添加新测试时，请遵循：
1. 命名规范：`test<Component>_<Scenario>_<ExpectedResult>`
2. 使用 `#pragma mark` 组织测试分组
3. 添加清晰的注释说明测试目的
4. 验证测试覆盖率并更新本文档

---

**最后更新**: 2025-11-01
**测试框架**: XCTest + OCMock
**维护者**: Claude Code

**更新日志**:
- 2025-11-01: 新增 15 个多端口连接复用测试（K、L、M、N组），测试总数增至 37 个
- 2025-11-01: Mock server 新增 3 个 HTTPS 端口（11444-11446）用于测试连接池隔离
- 2025-11-01: 新增本地 mock server，替代 httpbin.org，提供稳定测试环境
- 2025-11-01: 新增 15 个并发、竞态和连接复用集成测试（H、I、J组）
