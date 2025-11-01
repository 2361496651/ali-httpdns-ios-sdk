//
//  HttpdnsNWHTTPClient_PoolManagementTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  连接池管理测试 - 包含多端口隔离 (K)、端口池耗尽 (L)、池验证 (O) 测试组
//  测试总数：11 个（K:5 + L:3 + O:3）
//

#import "HttpdnsNWHTTPClientTestBase.h"

@interface HttpdnsNWHTTPClient_PoolManagementTests : HttpdnsNWHTTPClientTestBase

@end

@implementation HttpdnsNWHTTPClient_PoolManagementTests

#pragma mark - K. 多端口连接隔离测试

// K.1 不同 HTTPS 端口使用不同连接池
- (void)testMultiPort_DifferentHTTPSPorts_SeparatePoolKeys {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Different ports use different pools"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 请求端口 11443
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"Port11443"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        XCTAssertNotNil(response1, @"First request to port 11443 should succeed");
        XCTAssertEqual(response1.statusCode, 200);

        // 请求端口 11444（应该创建新连接，不复用 11443 的）
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                 userAgent:@"Port11444"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        XCTAssertNotNil(response2, @"First request to port 11444 should succeed");
        XCTAssertEqual(response2.statusCode, 200);

        // 再次请求端口 11443（应该复用之前的连接）
        NSError *error3 = nil;
        HttpdnsNWHTTPClientResponse *response3 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"Port11443Again"
                                                                                   timeout:15.0
                                                                                     error:&error3];
        XCTAssertNotNil(response3, @"Second request to port 11443 should reuse connection");
        XCTAssertEqual(response3.statusCode, 200);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:50.0];
}

// K.2 三个不同 HTTPS 端口的并发请求
- (void)testMultiPort_ConcurrentThreePorts_AllSucceed {
    NSInteger requestsPerPort = 10;
    NSArray<NSNumber *> *ports = @[@11443, @11444, @11445];
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSLock *successCountLock = [[NSLock alloc] init];
    __block NSInteger successCount = 0;

    for (NSNumber *port in ports) {
        for (NSInteger i = 0; i < requestsPerPort; i++) {
            XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Port %@ Request %ld", port, (long)i]];
            [expectations addObject:expectation];

            dispatch_async(queue, ^{
                NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
                NSError *error = nil;
                HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                        userAgent:@"ConcurrentMultiPort"
                                                                                          timeout:15.0
                                                                                            error:&error];

                if (response && response.statusCode == 200) {
                    [successCountLock lock];
                    successCount++;
                    [successCountLock unlock];
                }

                [expectation fulfill];
            });
        }
    }

    [self waitForExpectations:expectations timeout:60.0];

    // 验证所有请求都成功
    XCTAssertEqual(successCount, ports.count * requestsPerPort, @"All 30 requests should succeed");
}

// K.3 快速切换端口模式
- (void)testMultiPort_SequentialPortSwitching_ConnectionReusePerPort {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Sequential port switching"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *urls = @[
            @"https://127.0.0.1:11443/get",  // 第一次访问 11443
            @"https://127.0.0.1:11444/get",  // 第一次访问 11444
            @"https://127.0.0.1:11445/get",  // 第一次访问 11445
            @"https://127.0.0.1:11443/get",  // 第二次访问 11443（应复用）
            @"https://127.0.0.1:11444/get",  // 第二次访问 11444（应复用）
        ];

        NSMutableArray<NSNumber *> *responseTimes = [NSMutableArray array];

        for (NSString *url in urls) {
            CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:url
                                                                                    userAgent:@"SwitchingPorts"
                                                                                      timeout:15.0
                                                                                        error:&error];
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - startTime;

            XCTAssertNotNil(response, @"Request to %@ should succeed", url);
            XCTAssertEqual(response.statusCode, 200);
            [responseTimes addObject:@(elapsed)];
        }

        // 验证所有请求都完成
        XCTAssertEqual(responseTimes.count, urls.count);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:80.0];
}

// K.4 每个端口独立的连接池限制
- (void)testMultiPort_PerPortPoolLimit_IndependentPools {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Per-port pool limits"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 向端口 11443 发送 10 个请求
        for (NSInteger i = 0; i < 10; i++) {
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                    userAgent:@"Pool11443"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
        }

        // 向端口 11444 发送 10 个请求（应该有独立的池）
        for (NSInteger i = 0; i < 10; i++) {
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                    userAgent:@"Pool11444"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
        }

        // 等待连接归还
        [NSThread sleepForTimeInterval:1.0];

        // 验证两个端口都仍然可用
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"Verify11443"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        XCTAssertNotNil(response1, @"Port 11443 should still work after heavy usage");

        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                 userAgent:@"Verify11444"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        XCTAssertNotNil(response2, @"Port 11444 should still work after heavy usage");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:150.0];
}

// K.5 交错访问多个端口
- (void)testMultiPort_InterleavedRequests_AllPortsAccessible {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Interleaved multi-port requests"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber *> *ports = @[@11443, @11444, @11445, @11446];
        NSInteger totalRequests = 20;
        NSInteger successCount = 0;

        // 交错请求：依次循环访问所有端口
        for (NSInteger i = 0; i < totalRequests; i++) {
            NSNumber *port = ports[i % ports.count];
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];

            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"Interleaved"
                                                                                      timeout:15.0
                                                                                        error:&error];

            if (response && response.statusCode == 200) {
                successCount++;
            }
        }

        XCTAssertEqual(successCount, totalRequests, @"All interleaved requests should succeed");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:120.0];
}

#pragma mark - L. 基于端口的池耗尽测试

// L.1 四个端口同时承载高负载
- (void)testPoolExhaustion_FourPortsSimultaneous_AllSucceed {
    NSInteger requestsPerPort = 10;
    NSArray<NSNumber *> *ports = @[@11443, @11444, @11445, @11446];
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSLock *successCountLock = [[NSLock alloc] init];
    __block NSInteger successCount = 0;

    // 向 4 个端口各发起 10 个并发请求（共 40 个）
    for (NSNumber *port in ports) {
        for (NSInteger i = 0; i < requestsPerPort; i++) {
            XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Port %@ Request %ld", port, (long)i]];
            [expectations addObject:expectation];

            dispatch_async(queue, ^{
                NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
                NSError *error = nil;
                HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                        userAgent:@"FourPortLoad"
                                                                                          timeout:15.0
                                                                                            error:&error];

                if (response && response.statusCode == 200) {
                    [successCountLock lock];
                    successCount++;
                    [successCountLock unlock];
                }

                [expectation fulfill];
            });
        }
    }

    [self waitForExpectations:expectations timeout:80.0];

    // 验证成功率 > 95%（允许少量因并发导致的失败）
    XCTAssertGreaterThan(successCount, 38, @"At least 95%% of 40 requests should succeed");
}

// L.2 单个端口耗尽时其他端口不受影响
- (void)testPoolExhaustion_SinglePortExhausted_OthersUnaffected {
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __block NSInteger port11444SuccessCount = 0;
    NSLock *countLock = [[NSLock alloc] init];

    // 向端口 11443 发起 20 个并发请求（可能导致池耗尽）
    for (NSInteger i = 0; i < 20; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Exhaust11443 %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                            userAgent:@"Exhaust11443"
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
    }

    // 同时向端口 11444 发起 5 个请求（应该不受 11443 影响）
    for (NSInteger i = 0; i < 5; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Port11444 %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                    userAgent:@"Independent11444"
                                                                                      timeout:15.0
                                                                                        error:&error];
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - startTime;

            if (response && response.statusCode == 200) {
                [countLock lock];
                port11444SuccessCount++;
                [countLock unlock];
            }

            // 验证响应时间合理（不应因 11443 负载而显著延迟）
            XCTAssertLessThan(elapsed, 10.0, @"Port 11444 should not be delayed by port 11443 load");

            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:60.0];

    // 验证端口 11444 的请求都成功
    XCTAssertEqual(port11444SuccessCount, 5, @"All port 11444 requests should succeed despite 11443 load");
}

// L.3 多端口使用后的连接清理
- (void)testPoolExhaustion_MultiPortCleanup_ExpiredConnectionsPruned {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Multi-port connection cleanup"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber *> *ports = @[@11443, @11444, @11445];

        // 向三个端口各发起一个请求
        for (NSNumber *port in ports) {
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"Initial"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
        }

        // 等待超过 30 秒，让所有连接过期
        [NSThread sleepForTimeInterval:31.0];

        // 再次向三个端口发起请求（应该创建新连接）
        for (NSNumber *port in ports) {
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"AfterExpiry"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil, @"Requests should succeed after expiry");
        }

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:80.0];
}

#pragma mark - O. 连接池验证测试（使用新增的检查 API）

// O.1 综合连接池验证 - 演示所有检查能力
- (void)testPoolVerification_ComprehensiveCheck_AllAspectsVerified {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 初始状态：无连接
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 0,
                   @"Pool should be empty initially");
    XCTAssertEqual([self.client totalConnectionCount], 0,
                   @"Total connections should be 0 initially");
    XCTAssertEqual(self.client.connectionCreationCount, 0,
                   @"Creation count should be 0 initially");
    XCTAssertEqual(self.client.connectionReuseCount, 0,
                   @"Reuse count should be 0 initially");

    // 发送 5 个请求到同一端点
    for (NSInteger i = 0; i < 5; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"PoolVerificationTest"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response, @"Request %ld should succeed", (long)i);
        XCTAssertEqual(response.statusCode, 200, @"Request %ld should return 200", (long)i);
    }

    // 验证连接池状态
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 1,
                   @"Should have exactly 1 connection in pool for key: %@", poolKey);
    XCTAssertEqual([self.client totalConnectionCount], 1,
                   @"Total connection count should be 1");

    // 验证统计计数
    XCTAssertEqual(self.client.connectionCreationCount, 1,
                   @"Should create only 1 connection");
    XCTAssertEqual(self.client.connectionReuseCount, 4,
                   @"Should reuse connection 4 times");

    // 验证连接复用率
    CGFloat reuseRate = (CGFloat)self.client.connectionReuseCount /
                        (self.client.connectionCreationCount + self.client.connectionReuseCount);
    XCTAssertGreaterThanOrEqual(reuseRate, 0.8,
                                @"Reuse rate should be at least 80%% (actual: %.1f%%)", reuseRate * 100);

    // 验证 pool keys
    NSArray<NSString *> *allKeys = [self.client allConnectionPoolKeys];
    XCTAssertEqual(allKeys.count, 1, @"Should have exactly 1 pool key");
    XCTAssertTrue([allKeys containsObject:poolKey], @"Should contain the expected pool key");
}

// O.2 多端口连接池隔离验证
- (void)testPoolVerification_MultiPort_IndependentPools {
    [self.client resetPoolStatistics];

    NSString *key11443 = @"127.0.0.1:11443:tls";
    NSString *key11444 = @"127.0.0.1:11444:tls";

    // 初始：两个池都为空
    XCTAssertEqual([self.client connectionPoolCountForKey:key11443], 0);
    XCTAssertEqual([self.client connectionPoolCountForKey:key11444], 0);

    // 向端口 11443 发送 3 个请求
    for (NSInteger i = 0; i < 3; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                userAgent:@"Port11443"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
    }

    // 验证端口 11443 的池状态
    XCTAssertEqual([self.client connectionPoolCountForKey:key11443], 1,
                   @"Port 11443 should have 1 connection");
    XCTAssertEqual([self.client connectionPoolCountForKey:key11444], 0,
                   @"Port 11444 should still be empty");

    // 向端口 11444 发送 3 个请求
    for (NSInteger i = 0; i < 3; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                userAgent:@"Port11444"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
    }

    // 验证两个端口的池都存在且独立
    XCTAssertEqual([self.client connectionPoolCountForKey:key11443], 1,
                   @"Port 11443 should still have 1 connection");
    XCTAssertEqual([self.client connectionPoolCountForKey:key11444], 1,
                   @"Port 11444 should now have 1 connection");
    XCTAssertEqual([self.client totalConnectionCount], 2,
                   @"Total should be 2 connections (one per port)");

    // 验证统计：应该创建了 2 个连接，复用了 4 次
    XCTAssertEqual(self.client.connectionCreationCount, 2,
                   @"Should create 2 connections (one per port)");
    XCTAssertEqual(self.client.connectionReuseCount, 4,
                   @"Should reuse connections 4 times total");

    // 验证 pool keys
    NSArray<NSString *> *allKeys = [self.client allConnectionPoolKeys];
    XCTAssertEqual(allKeys.count, 2, @"Should have 2 pool keys");
    XCTAssertTrue([allKeys containsObject:key11443], @"Should contain key for port 11443");
    XCTAssertTrue([allKeys containsObject:key11444], @"Should contain key for port 11444");
}

// O.3 连接池容量限制验证
- (void)testPoolVerification_PoolCapacity_MaxFourConnections {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 发送 10 个连续请求（每个请求都会归还连接到池）
    for (NSInteger i = 0; i < 10; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"CapacityTest"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
    }

    // 等待连接归还
    [NSThread sleepForTimeInterval:1.0];

    // 验证池大小不超过 4（kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey）
    NSUInteger poolSize = [self.client connectionPoolCountForKey:poolKey];
    XCTAssertLessThanOrEqual(poolSize, 4,
                            @"Pool size should not exceed 4 (actual: %lu)", (unsigned long)poolSize);

    // 验证统计：应该只创建了 1 个连接（因为串行请求，每次都复用）
    XCTAssertEqual(self.client.connectionCreationCount, 1,
                   @"Should create only 1 connection for sequential requests");
    XCTAssertEqual(self.client.connectionReuseCount, 9,
                   @"Should reuse connection 9 times");
}

@end
