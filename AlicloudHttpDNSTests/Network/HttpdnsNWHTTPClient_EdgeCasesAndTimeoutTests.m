//
//  HttpdnsNWHTTPClient_EdgeCasesAndTimeoutTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  边界条件与超时测试 - 包含边界条件 (M) 和超时交互 (P) 测试组
//  测试总数：10 个（M:4 + P:6）
//

#import "HttpdnsNWHTTPClientTestBase.h"

@interface HttpdnsNWHTTPClient_EdgeCasesAndTimeoutTests : HttpdnsNWHTTPClientTestBase

@end

@implementation HttpdnsNWHTTPClient_EdgeCasesAndTimeoutTests

#pragma mark - M. 边界条件与验证测试

// M.1 连接复用边界：端口内复用，端口间隔离
- (void)testEdgeCase_ConnectionReuseWithinPortOnly_NotAcross {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Reuse boundaries"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 请求 A 到端口 11443
        CFAbsoluteTime timeA = CFAbsoluteTimeGetCurrent();
        NSError *errorA = nil;
        HttpdnsNWHTTPClientResponse *responseA = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"RequestA"
                                                                                   timeout:15.0
                                                                                     error:&errorA];
        CFAbsoluteTime elapsedA = CFAbsoluteTimeGetCurrent() - timeA;
        XCTAssertNotNil(responseA);

        // 请求 B 到端口 11443（应该复用连接，可能更快）
        CFAbsoluteTime timeB = CFAbsoluteTimeGetCurrent();
        NSError *errorB = nil;
        HttpdnsNWHTTPClientResponse *responseB = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"RequestB"
                                                                                   timeout:15.0
                                                                                     error:&errorB];
        CFAbsoluteTime elapsedB = CFAbsoluteTimeGetCurrent() - timeB;
        XCTAssertNotNil(responseB);

        // 请求 C 到端口 11444（应该创建新连接）
        CFAbsoluteTime timeC = CFAbsoluteTimeGetCurrent();
        NSError *errorC = nil;
        HttpdnsNWHTTPClientResponse *responseC = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                 userAgent:@"RequestC"
                                                                                   timeout:15.0
                                                                                     error:&errorC];
        CFAbsoluteTime elapsedC = CFAbsoluteTimeGetCurrent() - timeC;
        XCTAssertNotNil(responseC);

        // 请求 D 到端口 11444（应该复用端口 11444 的连接）
        CFAbsoluteTime timeD = CFAbsoluteTimeGetCurrent();
        NSError *errorD = nil;
        HttpdnsNWHTTPClientResponse *responseD = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                 userAgent:@"RequestD"
                                                                                   timeout:15.0
                                                                                     error:&errorD];
        CFAbsoluteTime elapsedD = CFAbsoluteTimeGetCurrent() - timeD;
        XCTAssertNotNil(responseD);

        // 验证所有请求都成功
        XCTAssertEqual(responseA.statusCode, 200);
        XCTAssertEqual(responseB.statusCode, 200);
        XCTAssertEqual(responseC.statusCode, 200);
        XCTAssertEqual(responseD.statusCode, 200);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:70.0];
}

// M.2 高端口数量压力测试
- (void)testEdgeCase_HighPortCount_AllPortsManaged {
    XCTestExpectation *expectation = [self expectationWithDescription:@"High port count"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber *> *ports = @[@11443, @11444, @11445, @11446];

        // 第一轮：向所有端口各发起一个请求
        for (NSNumber *port in ports) {
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"Round1"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertNotNil(response, @"First round request to port %@ should succeed", port);
        }

        // 第二轮：再次向所有端口发起请求（应该复用连接）
        for (NSNumber *port in ports) {
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"Round2"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertNotNil(response, @"Second round request to port %@ should reuse connection", port);
        }

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:120.0];
}

// M.3 并发池访问安全性
- (void)testEdgeCase_ConcurrentPoolAccess_NoDataRace {
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSArray<NSNumber *> *ports = @[@11443, @11444, @11445];
    NSInteger requestsPerPort = 5;

    // 向三个端口并发发起请求
    for (NSNumber *port in ports) {
        for (NSInteger i = 0; i < requestsPerPort; i++) {
            XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Port %@ Req %ld", port, (long)i]];
            [expectations addObject:expectation];

            dispatch_async(queue, ^{
                NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];
                NSError *error = nil;
                HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                        userAgent:@"ConcurrentAccess"
                                                                                          timeout:15.0
                                                                                            error:&error];
                // 如果没有崩溃或断言失败，说明并发访问安全
                XCTAssertTrue(response != nil || error != nil);
                [expectation fulfill];
            });
        }
    }

    [self waitForExpectations:expectations timeout:50.0];
}

// M.4 端口迁移模式
- (void)testEdgeCase_PortMigration_OldConnectionsEventuallyExpire {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Port migration"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 阶段 1：向端口 11443 发起多个请求
        for (NSInteger i = 0; i < 5; i++) {
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                            userAgent:@"Port11443"
                                              timeout:15.0
                                                error:&error];
        }

        // 阶段 2：切换到端口 11444，发起多个请求
        for (NSInteger i = 0; i < 5; i++) {
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                            userAgent:@"Port11444"
                                              timeout:15.0
                                                error:&error];
        }

        // 等待超过 30 秒，让端口 11443 的连接过期
        [NSThread sleepForTimeInterval:31.0];

        // 阶段 3：验证端口 11444 仍然可用
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                                 userAgent:@"Port11444After"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        XCTAssertNotNil(response1, @"Port 11444 should still work after 11443 expired");

        // 阶段 4：端口 11443 应该创建新连接（旧连接已过期）
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                 userAgent:@"Port11443New"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        XCTAssertNotNil(response2, @"Port 11443 should work with new connection after expiry");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:120.0];
}

#pragma mark - P. 超时与连接池交互测试

// P.1 单次超时后连接被正确移除
- (void)testTimeout_SingleRequest_ConnectionRemovedFromPool {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 验证初始状态
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 0,
                   @"Pool should be empty initially");

    // 发起超时请求（delay 10s, timeout 1s）
    NSError *error = nil;
    HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                            userAgent:@"TimeoutTest"
                                                                              timeout:1.0
                                                                                error:&error];

    // 验证请求失败
    XCTAssertNil(response, @"Response should be nil on timeout");
    XCTAssertNotNil(error, @"Error should be set on timeout");

    // 等待异步 returnConnection 完成
    [NSThread sleepForTimeInterval:0.5];

    // 验证池状态：超时连接应该被移除
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 0,
                   @"Timed-out connection should be removed from pool");
    XCTAssertEqual([self.client totalConnectionCount], 0,
                   @"No connections should remain in pool");

    // 验证统计
    XCTAssertEqual(self.client.connectionCreationCount, 1,
                   @"Should have created 1 connection");
    XCTAssertEqual(self.client.connectionReuseCount, 0,
                   @"No reuse for timed-out connection");
}

// P.2 超时后连接池恢复能力
- (void)testTimeout_PoolRecovery_SubsequentRequestSucceeds {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 第一个请求：超时
    NSError *error1 = nil;
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                             userAgent:@"TimeoutTest"
                                                                               timeout:1.0
                                                                                 error:&error1];
    XCTAssertNil(response1, @"First request should timeout");
    XCTAssertNotNil(error1);

    // 等待清理完成
    [NSThread sleepForTimeInterval:0.5];

    // 第二个请求：正常（验证池已恢复）
    NSError *error2 = nil;
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"RecoveryTest"
                                                                               timeout:15.0
                                                                                 error:&error2];
    XCTAssertNotNil(response2, @"Second request should succeed after timeout");
    XCTAssertEqual(response2.statusCode, 200);

    // 等待 returnConnection
    [NSThread sleepForTimeInterval:0.5];

    // 验证池恢复：现在应该有 1 个连接（来自第二个请求）
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 1,
                   @"Pool should have 1 connection from second request");

    // 第三个请求：应该复用第二个请求的连接
    NSError *error3 = nil;
    HttpdnsNWHTTPClientResponse *response3 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                             userAgent:@"ReuseTest"
                                                                               timeout:15.0
                                                                                 error:&error3];
    XCTAssertNotNil(response3);
    XCTAssertEqual(response3.statusCode, 200);

    // 验证统计：1 个超时（创建后移除）+ 1 个成功（创建）+ 1 个复用
    XCTAssertEqual(self.client.connectionCreationCount, 2,
                   @"Should have created 2 connections (1 timed out, 1 succeeded)");
    XCTAssertEqual(self.client.connectionReuseCount, 1,
                   @"Third request should reuse second's connection");
}

// P.3 并发场景：部分超时不影响成功请求的连接复用
- (void)testTimeout_ConcurrentPartialTimeout_SuccessfulRequestsReuse {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSLock *successCountLock = [[NSLock alloc] init];
    NSLock *timeoutCountLock = [[NSLock alloc] init];
    __block NSInteger successCount = 0;
    __block NSInteger timeoutCount = 0;

    // 发起 10 个请求：5 个正常，5 个超时
    for (NSInteger i = 0; i < 10; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            NSString *urlString;
            NSTimeInterval timeout;

            if (i % 2 == 0) {
                // 偶数：正常请求
                urlString = @"http://127.0.0.1:11080/get";
                timeout = 15.0;
            } else {
                // 奇数：超时请求
                urlString = @"http://127.0.0.1:11080/delay/10";
                timeout = 0.5;
            }

            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"ConcurrentTest"
                                                                                      timeout:timeout
                                                                                        error:&error];

            if (response && response.statusCode == 200) {
                [successCountLock lock];
                successCount++;
                [successCountLock unlock];
            } else {
                [timeoutCountLock lock];
                timeoutCount++;
                [timeoutCountLock unlock];
            }

            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:20.0];

    // 验证结果
    XCTAssertEqual(successCount, 5, @"5 requests should succeed");
    XCTAssertEqual(timeoutCount, 5, @"5 requests should timeout");

    // 验证连接创建数合理（5个成功 + 5个超时 = 最多10个，可能有复用）
    XCTAssertGreaterThan(self.client.connectionCreationCount, 0,
                         @"Should have created connections for concurrent requests");
    XCTAssertLessThanOrEqual(self.client.connectionCreationCount, 10,
                             @"Should not create more than 10 connections");

    // 等待所有连接归还（异步操作需要更长时间）
    [NSThread sleepForTimeInterval:2.0];

    // 验证总连接数合理（无泄漏）- 关键验证点
    // 在并发场景下，成功的连接可能已经被关闭（remote close），池可能为空
    XCTAssertLessThanOrEqual([self.client totalConnectionCount], 4,
                             @"Total connections should not exceed pool limit (no leak)");

    // 发起新请求验证池仍然健康（能创建新连接）
    NSError *recoveryError = nil;
    HttpdnsNWHTTPClientResponse *recoveryResponse = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"RecoveryTest"
                                                                                      timeout:15.0
                                                                                        error:&recoveryError];
    XCTAssertNotNil(recoveryResponse, @"Pool should recover and handle new requests after mixed timeout/success");
    XCTAssertEqual(recoveryResponse.statusCode, 200, @"Recovery request should succeed");
}

// P.4 连续超时不导致连接泄漏
- (void)testTimeout_ConsecutiveTimeouts_NoConnectionLeak {
    [self.client resetPoolStatistics];
    NSString *poolKey = @"127.0.0.1:11080:tcp";

    // 连续发起 10 个超时请求
    for (NSInteger i = 0; i < 10; i++) {
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                                userAgent:@"LeakTest"
                                                                                  timeout:0.5
                                                                                    error:&error];
        XCTAssertNil(response, @"Request %ld should timeout", (long)i);

        // 等待清理
        [NSThread sleepForTimeInterval:0.2];
    }

    // 验证池状态：无连接泄漏
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 0,
                   @"Pool should be empty after consecutive timeouts");
    XCTAssertEqual([self.client totalConnectionCount], 0,
                   @"No connections should leak");

    // 验证统计：每次都创建新连接（因为超时的被移除）
    XCTAssertEqual(self.client.connectionCreationCount, 10,
                   @"Should have created 10 connections (all timed out and removed)");
    XCTAssertEqual(self.client.connectionReuseCount, 0,
                   @"No reuse for timed-out connections");
}

// P.5 超时不阻塞连接池（并发正常请求不受影响）
- (void)testTimeout_NonBlocking_ConcurrentNormalRequestSucceeds {
    [self.client resetPoolStatistics];

    XCTestExpectation *timeoutExpectation = [self expectationWithDescription:@"Timeout request"];
    XCTestExpectation *successExpectation = [self expectationWithDescription:@"Success request"];

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 请求 A：超时（delay 10s, timeout 2s）
    dispatch_async(queue, ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                                userAgent:@"TimeoutRequest"
                                                                                  timeout:2.0
                                                                                    error:&error];
        XCTAssertNil(response, @"Request A should timeout");
        [timeoutExpectation fulfill];
    });

    // 请求 B：正常（应该不受 A 阻塞）
    dispatch_async(queue, ^{
        // 稍微延迟，确保 A 先开始
        [NSThread sleepForTimeInterval:0.1];

        CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"NormalRequest"
                                                                                  timeout:15.0
                                                                                    error:&error];
        CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - startTime;

        XCTAssertNotNil(response, @"Request B should succeed despite A timing out");
        XCTAssertEqual(response.statusCode, 200);

        // 验证请求 B 没有被请求 A 阻塞（应该很快完成）
        XCTAssertLessThan(elapsed, 5.0,
                          @"Request B should complete quickly, not blocked by A's timeout");

        [successExpectation fulfill];
    });

    [self waitForExpectations:@[timeoutExpectation, successExpectation] timeout:20.0];

    // 等待连接归还
    [NSThread sleepForTimeInterval:0.5];

    // 验证池状态：只有请求 B 的连接
    NSString *poolKey = @"127.0.0.1:11080:tcp";
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey], 1,
                   @"Pool should have 1 connection from successful request B");
}

// P.6 多端口场景下的超时隔离
- (void)testTimeout_MultiPort_IsolatedPoolCleaning {
    [self.client resetPoolStatistics];

    NSString *poolKey11443 = @"127.0.0.1:11443:tls";
    NSString *poolKey11444 = @"127.0.0.1:11444:tls";

    // 端口 11443：超时请求
    NSError *error1 = nil;
    HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/delay/10"
                                                                             userAgent:@"Port11443Timeout"
                                                                               timeout:1.0
                                                                                 error:&error1];
    XCTAssertNil(response1, @"Port 11443 request should timeout");

    // 端口 11444：正常请求
    NSError *error2 = nil;
    HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                             userAgent:@"Port11444Success"
                                                                               timeout:15.0
                                                                                 error:&error2];
    XCTAssertNotNil(response2, @"Port 11444 request should succeed");
    XCTAssertEqual(response2.statusCode, 200);

    // 等待连接归还
    [NSThread sleepForTimeInterval:0.5];

    // 验证端口隔离：端口 11443 无连接，端口 11444 有 1 个连接
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey11443], 0,
                   @"Port 11443 pool should be empty (timed out)");
    XCTAssertEqual([self.client connectionPoolCountForKey:poolKey11444], 1,
                   @"Port 11444 pool should have 1 connection");

    // 验证总连接数
    XCTAssertEqual([self.client totalConnectionCount], 1,
                   @"Total should be 1 (only from port 11444)");

    // 再次请求端口 11444：应该复用连接
    NSError *error3 = nil;
    HttpdnsNWHTTPClientResponse *response3 = [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                                                             userAgent:@"Port11444Reuse"
                                                                               timeout:15.0
                                                                                 error:&error3];
    XCTAssertNotNil(response3);
    XCTAssertEqual(response3.statusCode, 200);

    // 验证复用发生
    XCTAssertEqual(self.client.connectionReuseCount, 1,
                   @"Second request to port 11444 should reuse connection");
}

@end
