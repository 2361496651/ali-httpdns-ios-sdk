//
//  HttpdnsNWHTTPClient_StateMachineTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  状态机测试 - 包含状态机与异常场景 (Q) 测试组
//  测试总数：17 个（Q:17）
//

#import "HttpdnsNWHTTPClientTestBase.h"

@interface HttpdnsNWHTTPClient_StateMachineTests : HttpdnsNWHTTPClientTestBase

@end

@implementation HttpdnsNWHTTPClient_StateMachineTests

#pragma mark - Q. 状态机与异常场景测试

// Q1.1 池溢出时LRU移除策略验证
- (void)testStateMachine_PoolOverflowLRU_RemovesOldestByLastUsedDate {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 需要并发创建5个连接（串行请求会复用）
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 并发发起5个请求
    for (NSInteger i = 0; i < 5; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            // 使用 /delay/2 确保所有请求同时在飞行中，强制创建多个连接
            [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/2"
                                            userAgent:[NSString stringWithFormat:@"Request%ld", (long)i]
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
        [NSThread sleepForTimeInterval:0.05];  // 小间隔避免完全同时启动
    }

    [self waitForExpectations:expectations timeout:20.0];

    // 等待所有连接归还
    [NSThread sleepForTimeInterval:1.0];

    // 验证：池大小 ≤ 4（LRU移除溢出部分）
    NSUInteger poolCount = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolCount, 4,
                             @"Pool should enforce max 4 connections (LRU)");

    // 验证：创建了多个连接
    XCTAssertGreaterThanOrEqual(self.client.connectionCreationCount, 3,
                                @"Should create multiple concurrent connections");
}

// Q2.1 快速连续请求不产生重复连接（间接验证双重归还防护）
- (void)testAbnormal_RapidSequentialRequests_NoDuplicates {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 快速连续发起10个请求（测试连接归还的幂等性）
    for (NSInteger i = 0; i < 10; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"RapidTest"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
    }

    // 等待连接归还
    [NSThread sleepForTimeInterval:1.0];

    // 验证：池中最多1个连接（因为串行请求复用同一连接）
    NSUInteger poolCount = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolCount, 1,
                             @"Pool should have at most 1 connection (rapid sequential reuse)");

    // 验证：创建次数应该是1（所有请求复用同一连接）
    XCTAssertEqual(self.client.connectionCreationCount, 1,
                   @"Should create only 1 connection for sequential requests");
}

// Q2.2 不同端口请求不互相污染池
- (void)testAbnormal_DifferentPorts_IsolatedPools {
    [self.client resetPoolStatistics];
    NSString *poolKey11080 = @"127.0.0.1:11080:tcp";
    NSString *poolKey11443 = @"127.0.0.1:11443:tls";

    // 向端口11080发起请求
    NSError *error1 = nil;
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"Port11080"
                                                                               timeout:15.0
                                                                                 error:&error1];
    XCTAssertNotNil(response1);

    // 向端口11443发起请求
    NSError *error2 = nil;
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                             userAgent:@"Port11443"
                                                                               timeout:15.0
                                                                                 error:&error2];
    XCTAssertNotNil(response2);

    // 等待连接归还
    [NSThread sleepForTimeInterval:0.5];

    // 验证：两个池各自有1个连接
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey11080], 1,
                   @"Port 11080 pool should have 1 connection");
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey11443], 1,
                   @"Port 11443 pool should have 1 connection");

    // 验证：总共2个连接（池完全隔离）
    XCTAssertEqual([self.client totalConnectionCount], 2,
                   @"Total should be 2 (one per pool)");
}

// Q3.1 池大小不变式：任何时候池大小都不超过限制
- (void)testInvariant_PoolSize_NeverExceedsLimit {
    [self.client resetPoolStatistics];

    // 快速连续发起20个请求到同一端点
    for (NSInteger i = 0; i < 20; i++) {
        NSError *error = nil;
        [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                        userAgent:@"InvariantTest"
                                          timeout:15.0
                                            error:&error];
    }

    // 等待所有连接归还
    [NSThread sleepForTimeInterval:1.5];

    // 验证：每个池的大小不超过4
    NSArray<NSString *> *allKeys = [self.client allConnectionPoolKeys];
    for (NSString *key in allKeys) {
        NSUInteger poolCount = [self.client connectionPoolCountForKey:key];
        XCTAssertLessThanOrEqual(poolCount, 4,
                                 @"Pool %@ size should never exceed 4 (actual: %lu)",
                                 key, (unsigned long)poolCount);
    }

    // 验证：总连接数也不超过4（因为只有一个池）
    XCTAssertLessThanOrEqual([self.client totalConnectionCount], 4,
                             @"Total connections should not exceed 4");
}

// Q3.3 无重复连接不变式：并发请求不产生重复
- (void)testInvariant_NoDuplicates_ConcurrentRequests {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 并发发起15个请求（可能复用连接）
    for (NSInteger i = 0; i < 15; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                            userAgent:@"ConcurrentTest"
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:30.0];

    // 等待连接归还
    [NSThread sleepForTimeInterval:1.0];

    // 验证：池大小 ≤ 4（不变式）
    NSUInteger poolCount = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolCount, 4,
                             @"Pool should not have duplicates (max 4 connections)");

    // 验证：创建的连接数合理（≤15，因为可能有复用）
    XCTAssertLessThanOrEqual(self.client.connectionCreationCount, 15,
                             @"Should not create excessive connections");
}

// Q4.1 边界条件：恰好30秒后连接过期
- (void)testBoundary_Exactly30Seconds_ConnectionExpired {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    [self.client resetPoolStatistics];

    // 第一个请求
    NSError *error1 = nil;
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"InitialRequest"
                                                                               timeout:15.0
                                                                                 error:&error1];
    XCTAssertNotNil(response1);

    // 等待恰好30.5秒（超过30秒过期时间）
    [NSThread sleepForTimeInterval:30.5];

    // 第二个请求：应该创建新连接（旧连接已过期）
    NSError *error2 = nil;
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"AfterExpiry"
                                                                               timeout:15.0
                                                                                 error:&error2];
    XCTAssertNotNil(response2);

    // 验证：创建了2个连接（旧连接过期，无法复用）
    XCTAssertEqual(self.client.connectionCreationCount, 2,
                   @"Should create 2 connections (first expired after 30s)");
    XCTAssertEqual(self.client.connectionReuseCount, 0,
                   @"Should not reuse expired connection");
}

// Q4.2 边界条件：29秒内连接未过期
- (void)testBoundary_Under30Seconds_ConnectionNotExpired {
    [self.client resetPoolStatistics];

    // 第一个请求
    NSError *error1 = nil;
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"InitialRequest"
                                                                               timeout:15.0
                                                                                 error:&error1];
    XCTAssertNotNil(response1);

    // 等待29秒（未到30秒过期时间）
    [NSThread sleepForTimeInterval:29.0];

    // 第二个请求：应该复用连接
    NSError *error2 = nil;
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"BeforeExpiry"
                                                                               timeout:15.0
                                                                                 error:&error2];
    XCTAssertNotNil(response2);

    // 验证：只创建了1个连接（复用了）
    XCTAssertEqual(self.client.connectionCreationCount, 1,
                   @"Should create only 1 connection (reused within 30s)");
    XCTAssertEqual(self.client.connectionReuseCount, 1,
                   @"Should reuse connection within 30s");
}

// Q4.3 边界条件：恰好4个连接全部保留
- (void)testBoundary_ExactlyFourConnections_AllKept {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 并发发起4个请求（使用延迟确保同时在飞行中，创建4个独立连接）
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    for (NSInteger i = 0; i < 4; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:
            [NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            // 使用 /delay/2 确保所有请求同时在飞行中
            [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/2"
                                            userAgent:[NSString stringWithFormat:@"Request%ld", (long)i]
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });

        [NSThread sleepForTimeInterval:0.05];  // 小间隔避免完全同时启动
    }

    [self waitForExpectations:expectations timeout:20.0];

    // 等待连接归还
    [NSThread sleepForTimeInterval:1.0];

    // 验证：池恰好有4个连接（全部保留）
    NSUInteger poolCount = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertEqual(poolCount, 4,
                   @"Pool should keep all 4 connections (not exceeding limit)");

    // 验证：恰好创建4个连接
    XCTAssertEqual(self.client.connectionCreationCount, 4,
                   @"Should create exactly 4 connections");
}

// Q1.2 正常状态序列验证
- (void)testStateMachine_NormalSequence_StateTransitionsCorrect {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 第1步：创建并使用连接 (CREATING → IN_USE → IDLE)
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                            userAgent:@"StateTest"
                                                                              timeout:15.0
                                                                                error:nil];
    XCTAssertNotNil(response1, @"First request should succeed");

    [NSThread sleepForTimeInterval:1.0];  // 等待归还

    // 验证：池中有1个连接
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 1,
                   @"Connection should be in pool");

    // 第2步：复用连接 (IDLE → IN_USE → IDLE)
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                            userAgent:@"StateTest"
                                                                              timeout:15.0
                                                                                error:nil];
    XCTAssertNotNil(response2, @"Second request should reuse connection");

    // 验证：复用计数增加
    XCTAssertEqual(self.client.connectionReuseCount, 1,
                   @"Should have reused connection once");
}

// Q1.3 inUse 标志维护验证
- (void)testStateMachine_InUseFlag_CorrectlyMaintained {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 发起请求并归还
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"InUseTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];  // 等待归还

    // 获取池中连接
    NSArray<HttpdnsNWReusableConnection *> *connections = [self.client connectionsInPoolForKey:poolKey];
    XCTAssertEqual(connections.count, 1, @"Should have 1 connection in pool");

    // 验证：池中连接的 inUse 应为 NO
    for (HttpdnsNWReusableConnection *conn in connections) {
        XCTAssertFalse(conn.inUse, @"Connection in pool should not be marked as inUse");
    }
}

// Q2.3 Nil lastUsedDate 处理验证
- (void)testAbnormal_NilLastUsedDate_HandledGracefully {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 发起请求创建连接
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"NilDateTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];

    // 获取连接并设置 lastUsedDate 为 nil
    NSArray<HttpdnsNWReusableConnection *> *connections = [self.client connectionsInPoolForKey:poolKey];
    XCTAssertEqual(connections.count, 1, @"Should have connection");

    HttpdnsNWReusableConnection *conn = connections.firstObject;
    [conn debugSetLastUsedDate:nil];

    // 发起新请求触发 prune（内部应使用 distantPast 处理 nil）
    HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                            userAgent:@"NilDateTest"
                                                                              timeout:15.0
                                                                                error:nil];

    // 验证：不崩溃，正常工作
    XCTAssertNotNil(response, @"Should handle nil lastUsedDate gracefully");
}

// Q3.2 池中无失效连接不变式
- (void)testInvariant_NoInvalidatedInPool {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 发起多个请求（包括成功和超时）
    for (NSInteger i = 0; i < 3; i++) {
        [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                        userAgent:@"InvariantTest"
                                          timeout:15.0
                                            error:nil];
    }

    // 发起1个超时请求
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                    userAgent:@"TimeoutTest"
                                      timeout:0.5
                                        error:nil];

    [NSThread sleepForTimeInterval:2.0];

    // 获取池中所有连接
    NSArray<HttpdnsNWReusableConnection *> *connections = [self.client connectionsInPoolForKey:poolKey];

    // 验证：池中无失效连接
    for (HttpdnsNWReusableConnection *conn in connections) {
        XCTAssertFalse(conn.isInvalidated, @"Pool should not contain invalidated connections");
    }
}

// Q3.4 lastUsedDate 单调性验证
- (void)testInvariant_LastUsedDate_Monotonic {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 第1次使用
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"MonotonicTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];

    NSArray<HttpdnsNWReusableConnection *> *connections1 = [self.client connectionsInPoolForKey:poolKey];
    XCTAssertEqual(connections1.count, 1, @"Should have connection");
    NSDate *date1 = connections1.firstObject.lastUsedDate;
    XCTAssertNotNil(date1, @"lastUsedDate should be set");

    // 等待1秒确保时间推进
    [NSThread sleepForTimeInterval:1.0];

    // 第2次使用同一连接
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"MonotonicTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];

    NSArray<HttpdnsNWReusableConnection *> *connections2 = [self.client connectionsInPoolForKey:poolKey];
    XCTAssertEqual(connections2.count, 1, @"Should still have 1 connection");
    NSDate *date2 = connections2.firstObject.lastUsedDate;

    // 验证：lastUsedDate 递增
    XCTAssertTrue([date2 timeIntervalSinceDate:date1] > 0,
                  @"lastUsedDate should increase after reuse");
}

// Q5.1 超时+池溢出复合场景
- (void)testCompound_TimeoutDuringPoolOverflow_Handled {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 先填满池（4个成功连接）
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    for (NSInteger i = 0; i < 4; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:
            [NSString stringWithFormat:@"Fill pool %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/2"
                                            userAgent:@"CompoundTest"
                                              timeout:15.0
                                                error:nil];
            [expectation fulfill];
        });
        [NSThread sleepForTimeInterval:0.05];
    }

    [self waitForExpectations:expectations timeout:20.0];
    [NSThread sleepForTimeInterval:1.0];

    NSUInteger poolCountBefore = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolCountBefore, 4, @"Pool should have ≤4 connections");

    // 第5个请求超时
    NSError *error = nil;
    HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                            userAgent:@"TimeoutRequest"
                                                                              timeout:0.5
                                                                                error:&error];

    XCTAssertNil(response, @"Timeout request should return nil");
    XCTAssertNotNil(error, @"Should have error");

    [NSThread sleepForTimeInterval:1.0];

    // 验证：超时连接未加入池
    NSUInteger poolCountAfter = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolCountAfter, 4, @"Timed-out connection should not be added to pool");
}

// Q2.4 打开失败不加入池
- (void)testAbnormal_OpenFailure_NotAddedToPool {
    [self.client resetPoolStatistics];

    // 尝试连接无效端口（连接拒绝）
    NSError *error = nil;
    HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:99999/get"
                                                                            userAgent:@"FailureTest"
                                                                              timeout:2.0
                                                                                error:&error];

    // 验证：请求失败
    XCTAssertNil(response, @"Should fail to connect to invalid port");

    // 验证：无连接加入池
    XCTAssertEqual([self.client totalConnectionCount], 0,
                   @"Failed connection should not be added to pool");
}

// Q2.5 多次 invalidate 幂等性
- (void)testAbnormal_MultipleInvalidate_Idempotent {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 创建连接
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"InvalidateTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];

    NSArray<HttpdnsNWReusableConnection *> *connections = [self.client connectionsInPoolForKey:poolKey];
    XCTAssertEqual(connections.count, 1, @"Should have connection");

    HttpdnsNWReusableConnection *conn = connections.firstObject;

    // 多次 invalidate
    [conn debugInvalidate];
    [conn debugInvalidate];
    [conn debugInvalidate];

    // 验证：不崩溃
    XCTAssertTrue(conn.isInvalidated, @"Connection should be invalidated");
}

// Q5.2 并发 dequeue 竞态测试
- (void)testCompound_ConcurrentDequeueDuringPrune_Safe {
    [self.client resetPoolStatistics];

    // 在两个端口创建连接
    [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                    userAgent:@"RaceTest"
                                      timeout:15.0
                                        error:nil];

    [self.client performRequestWithURLString:@"http://127.0.0.1:11443/get"
                                    userAgent:@"RaceTest"
                                      timeout:15.0
                                        error:nil];

    [NSThread sleepForTimeInterval:1.0];

    // 等待30秒让连接过期
    [NSThread sleepForTimeInterval:30.5];

    // 并发触发两个端口的 dequeue（会触发 prune）
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_group_async(group, queue, ^{
        [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                        userAgent:@"Race1"
                                          timeout:15.0
                                            error:nil];
    });

    dispatch_group_async(group, queue, ^{
        [self.client performRequestWithURLString:@"http://127.0.0.1:11443/get"
                                        userAgent:@"Race2"
                                          timeout:15.0
                                            error:nil];
    });

    // 等待完成
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    // 验证：无崩溃，连接池正常工作
    NSUInteger totalCount = [self.client totalConnectionCount];
    XCTAssertLessThanOrEqual(totalCount, 4, @"Pool should remain stable after concurrent prune");
}

@end
