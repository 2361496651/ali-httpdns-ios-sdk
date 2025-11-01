# 超时对连接复用的影响分析

## 问题描述

当前测试套件没有充分验证**超时与连接池交互**的"无形结果"（intangible outcomes），可能存在以下风险：
- 超时后的连接泄漏
- 连接池被超时连接污染
- 连接池无法从超时中恢复
- 并发场景下部分超时影响整体池健康

---

## 代码行为分析

### 超时处理流程

**HttpdnsNWHTTPClient.m:144-145**
```objc
if (!rawResponse) {
    [self returnConnection:connection forKey:poolKey shouldClose:YES];
    // 返回 nil，error 设置
}
```

**returnConnection:forKey:shouldClose: (line 279-281)**
```objc
if (shouldClose || connection.isInvalidated) {
    [connection invalidate];    // 取消底层 nw_connection
    [pool removeObject:connection];  // 从池中移除
}
```

**结论**：代码逻辑正确，超时连接**会被移除**而非留在池中。

---

## 当前测试覆盖情况

### 已有测试：`testIntegration_RequestTimeout_ReturnsError`

**验证内容：**
- ✅ 超时返回 `nil` response
- ✅ 超时设置 `error`

**未验证内容（缺失）：**
- ❌ 连接是否从池中移除
- ❌ 池计数是否正确
- ❌ 后续请求是否正常工作
- ❌ 是否存在连接泄漏
- ❌ 并发场景下部分超时的影响

---

## 需要验证的"无形结果"

### 1. 单次超时后的池清理

**场景**：
1. 请求 A 超时（timeout=1s, endpoint=/delay/10）
2. 验证池状态

**应验证：**
- Pool count = 0（连接已移除）
- Total connection count 没有异常增长
- 无连接泄漏

**测试方法**：
```objc
[client resetPoolStatistics];

// 发起超时请求
NSError *error = nil;
HttpdnsNWHTTPClientResponse *response = [client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                   userAgent:@"TimeoutTest"
                                                                     timeout:1.0
                                                                       error:&error];

XCTAssertNil(response);
XCTAssertNotNil(error);

// 验证池状态
NSString *poolKey = @"127.0.0.1:11080:tcp";
XCTAssertEqual([client connectionPoolCountForKey:poolKey], 0, @"Timed-out connection should be removed");
XCTAssertEqual([client totalConnectionCount], 0, @"No connections should remain");
XCTAssertEqual(client.connectionCreationCount, 1, @"Should have created 1 connection");
XCTAssertEqual(client.connectionReuseCount, 0, @"No reuse for timed-out connection");
```

---

### 2. 超时后的池恢复能力

**场景**：
1. 请求 A 超时
2. 请求 B 正常（验证池恢复）
3. 请求 C 复用 B 的连接

**应验证：**
- 请求 B 成功（池已恢复）
- 请求 C 复用连接（connectionReuseCount = 1）
- Pool count = 1（只有 B/C 的连接）

---

### 3. 并发场景：部分超时不影响成功请求

**场景**：
1. 并发发起 10 个请求
2. 5 个正常（timeout=15s）
3. 5 个超时（timeout=0.5s, endpoint=/delay/10）

**应验证：**
- 5 个正常请求成功
- 5 个超时请求失败
- Pool count ≤ 5（只保留成功的连接）
- Total connection count ≤ 5（无泄漏）
- connectionCreationCount ≤ 10（合理范围）
- 成功的请求可以复用连接

---

### 4. 连续超时不导致资源泄漏

**场景**：
1. 连续 20 次超时请求
2. 验证连接池没有累积"僵尸连接"

**应验证：**
- Pool count = 0
- Total connection count = 0
- connectionCreationCount = 20（每次都创建新连接，因为超时的被移除）
- connectionReuseCount = 0（超时连接不可复用）
- 无内存泄漏（虽然代码层面无法直接测试）

---

### 5. 超时不阻塞连接池

**场景**：
1. 请求 A 超时（endpoint=/delay/10, timeout=1s）
2. 同时请求 B 正常（endpoint=/get, timeout=15s）

**应验证：**
- 请求 A 和 B 并发执行（不互相阻塞）
- 请求 B 成功（不受 A 超时影响）
- 请求 A 的超时连接被正确移除
- Pool 中只有请求 B 的连接

---

### 6. 多端口场景下的超时隔离

**场景**：
1. 端口 11443 请求超时
2. 端口 11444 请求正常
3. 验证端口间隔离

**应验证：**
- 端口 11443 pool count = 0
- 端口 11444 pool count = 1
- 两个端口的连接池互不影响

---

## 测试实现建议

### P 组：超时与连接池交互测试

**P.1 单次超时清理验证**
- `testTimeout_SingleRequest_ConnectionRemovedFromPool`

**P.2 超时后池恢复**
- `testTimeout_PoolRecovery_SubsequentRequestSucceeds`

**P.3 并发部分超时**
- `testTimeout_ConcurrentPartialTimeout_SuccessfulRequestsReuse`

**P.4 连续超时无泄漏**
- `testTimeout_ConsecutiveTimeouts_NoConnectionLeak`

**P.5 超时不阻塞池**
- `testTimeout_NonBlocking_ConcurrentNormalRequestSucceeds`

**P.6 多端口超时隔离**
- `testTimeout_MultiPort_IsolatedPoolCleaning`

---

## Mock Server 支持

需要添加可配置延迟的 endpoint：
- `/delay/10` - 延迟 10 秒（已有）
- 测试时设置短 timeout（如 0.5s-2s）触发超时

---

## 预期测试结果

| 验证项 | 当前状态 | 目标状态 |
|--------|---------|---------|
| 超时连接移除 | 未验证 | ✅ 验证池计数=0 |
| 池恢复能力 | 未验证 | ✅ 后续请求成功 |
| 并发超时隔离 | 未验证 | ✅ 成功请求不受影响 |
| 无连接泄漏 | 未验证 | ✅ 总连接数稳定 |
| 超时不阻塞 | 未验证 | ✅ 并发执行不阻塞 |
| 多端口隔离 | 未验证 | ✅ 端口间独立清理 |

---

## 风险评估

**如果不测试这些场景的风险：**
1. **连接泄漏**：超时连接可能未正确清理，导致内存泄漏
2. **池污染**：超时连接留在池中，被后续请求复用导致失败
3. **级联故障**：部分超时影响整体连接池健康
4. **资源耗尽**：连续超时累积连接，最终耗尽系统资源

**当前代码逻辑正确性：** ✅ 高（代码分析显示正确处理）
**测试验证覆盖率：** ❌ 低（缺少池交互验证）

**建议：** 添加 P 组测试以提供**可观测的证据**证明超时处理正确。

---

**创建时间**: 2025-11-01
**维护者**: Claude Code
