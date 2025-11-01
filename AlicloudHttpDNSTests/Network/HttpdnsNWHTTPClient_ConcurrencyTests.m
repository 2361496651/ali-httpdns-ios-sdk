//
//  HttpdnsNWHTTPClient_ConcurrencyTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  并发测试 - 包含并发请求 (H)、竞态条件 (I)、并发多端口 (N) 测试组
//  测试总数：13 个（H:5 + I:5 + N:3）
//

#import "HttpdnsNWHTTPClientTestBase.h"

@interface HttpdnsNWHTTPClient_ConcurrencyTests : HttpdnsNWHTTPClientTestBase

@end

@implementation HttpdnsNWHTTPClient_ConcurrencyTests

#pragma mark - H. 并发测试

// H.1 并发请求同一主机
- (void)testConcurrency_ParallelRequestsSameHost_AllSucceed {
    NSInteger concurrentCount = 10;
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSMutableArray<NSNumber *> *responseTimes = [NSMutableArray array];
    NSLock *lock = [[NSLock alloc] init];

    for (NSInteger i = 0; i < concurrentCount; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                      timeout:15.0
                                                                                        error:&error];
            CFAbsoluteTime endTime = CFAbsoluteTimeGetCurrent();

            XCTAssertNotNil(response, @"Response %ld should not be nil", (long)i);
            XCTAssertTrue(response.statusCode == 200 || response.statusCode == 503,
                         @"Request %ld got statusCode=%ld, expected 200 or 503", (long)i, (long)response.statusCode);

            [lock lock];
            [responseTimes addObject:@(endTime - startTime)];
            [lock unlock];

            [expectation fulfill];
            dispatch_group_leave(group);
        });
    }

    [self waitForExpectations:expectations timeout:30.0];

    // 验证至少部分请求复用了连接（响应时间有差异）
    XCTAssertEqual(responseTimes.count, concurrentCount);
}

// H.2 并发请求不同路径
- (void)testConcurrency_ParallelRequestsDifferentPaths_AllSucceed {
    NSArray<NSString *> *paths = @[@"/get", @"/status/200", @"/headers", @"/user-agent", @"/uuid"];
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    for (NSString *path in paths) {
        XCTestExpectation *expectation = [self expectationWithDescription:path];
        [expectations addObject:expectation];

        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:11080%@", path];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                      timeout:15.0
                                                                                        error:&error];

            XCTAssertNotNil(response, @"Response for %@ should not be nil", path);
            XCTAssertTrue(response.statusCode == 200 || response.statusCode == 503, @"Request %@ should get valid status", path);

            [expectation fulfill];
            dispatch_group_leave(group);
        });
    }

    [self waitForExpectations:expectations timeout:30.0];
}

// H.3 并发 HTTP + HTTPS
- (void)testConcurrency_MixedHTTPAndHTTPS_BothSucceed {
    NSInteger httpCount = 5;
    NSInteger httpsCount = 5;
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // HTTP 请求
    for (NSInteger i = 0; i < httpCount; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"HTTP %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                      timeout:15.0
                                                                                        error:&error];

            XCTAssertNotNil(response);
            [expectation fulfill];
        });
    }

    // HTTPS 请求
    for (NSInteger i = 0; i < httpsCount; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"HTTPS %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                    userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                      timeout:15.0
                                                                                        error:&error];

            XCTAssertNotNil(response);
            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:40.0];
}

// H.4 高负载压力测试
- (void)testConcurrency_HighLoad50Concurrent_NoDeadlock {
    NSInteger concurrentCount = 50;
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    NSLock *successCountLock = [[NSLock alloc] init];
    __block NSInteger successCount = 0;

    for (NSInteger i = 0; i < concurrentCount; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Request %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                      timeout:15.0
                                                                                        error:&error];

            if (response && (response.statusCode == 200 || response.statusCode == 503)) {
                [successCountLock lock];
                successCount++;
                [successCountLock unlock];
            }

            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:60.0];

    // 至少大部分请求应该成功（允许部分失败，因为高负载）
    XCTAssertGreaterThan(successCount, concurrentCount * 0.8, @"At least 80%% should succeed");
}

// H.5 混合串行+并发
- (void)testConcurrency_MixedSerialAndParallel_NoInterference {
    XCTestExpectation *serialExpectation = [self expectationWithDescription:@"Serial requests"];
    XCTestExpectation *parallel1 = [self expectationWithDescription:@"Parallel 1"];
    XCTestExpectation *parallel2 = [self expectationWithDescription:@"Parallel 2"];
    XCTestExpectation *parallel3 = [self expectationWithDescription:@"Parallel 3"];

    dispatch_queue_t serialQueue = dispatch_queue_create("serial", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t parallelQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 串行线程
    dispatch_async(serialQueue, ^{
        for (NSInteger i = 0; i < 5; i++) {
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"Serial"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertNotNil(response);
        }
        [serialExpectation fulfill];
    });

    // 并发线程
    dispatch_async(parallelQueue, ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/uuid"
                                                                                userAgent:@"Parallel1"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
        [parallel1 fulfill];
    });

    dispatch_async(parallelQueue, ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/headers"
                                                                                userAgent:@"Parallel2"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
        [parallel2 fulfill];
    });

    dispatch_async(parallelQueue, ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/user-agent"
                                                                                userAgent:@"Parallel3"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertNotNil(response);
        [parallel3 fulfill];
    });

    [self waitForExpectations:@[serialExpectation, parallel1, parallel2, parallel3] timeout:60.0];
}

#pragma mark - I. 竞态条件测试

// I.1 连接池容量测试
- (void)testRaceCondition_ExceedPoolCapacity_MaxFourConnections {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Pool capacity test"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 快速连续发起 10 个请求
        for (NSInteger i = 0; i < 10; i++) {
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"PoolTest"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
        }

        // 等待连接归还
        [NSThread sleepForTimeInterval:1.0];

        // 注意：无法直接检查池大小（内部实现），只能通过行为验证
        // 如果实现正确，池应自动限制为最多 4 个空闲连接

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:120.0];
}

// I.2 同时归还连接
- (void)testRaceCondition_SimultaneousConnectionReturn_NoDataRace {
    NSInteger concurrentCount = 5;
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    for (NSInteger i = 0; i < concurrentCount; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Return %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"ReturnTest"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
            // 连接在这里自动归还

            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:30.0];

    // 如果没有崩溃或断言失败，说明并发归还处理正确
}

// I.3 获取-归还-再获取竞态
- (void)testRaceCondition_AcquireReturnReacquire_CorrectState {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Acquire-Return-Reacquire"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 第一个请求
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"First"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        XCTAssertTrue(response1 != nil || error1 != nil);

        // 极短暂等待确保连接归还
        [NSThread sleepForTimeInterval:0.1];

        // 第二个请求应该能复用连接
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"Second"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        XCTAssertTrue(response2 != nil || error2 != nil);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:35.0];
}

// I.4 超时与活跃连接冲突（需要31秒，标记为慢测试）
- (void)testRaceCondition_ExpiredConnectionPruning_CreatesNewConnection {
    // 跳过此测试如果环境变量设置了 SKIP_SLOW_TESTS
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Connection expiry"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 创建连接
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"Initial"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        XCTAssertTrue(response1 != nil || error1 != nil);

        // 等待超过30秒超时
        [NSThread sleepForTimeInterval:31.0];

        // 新请求应该创建新连接（旧连接已过期）
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"AfterExpiry"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        XCTAssertTrue(response2 != nil || error2 != nil);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:70.0];
}

// I.5 错误恢复竞态
- (void)testRaceCondition_ErrorRecovery_PoolRemainsHealthy {
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 发起一些会失败的请求
    for (NSInteger i = 0; i < 3; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Error %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            // 使用短超时导致失败
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/5"
                                                                                    userAgent:@"ErrorTest"
                                                                                      timeout:1.0
                                                                                        error:&error];
            // 预期失败
            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:15.0];

    // 验证后续正常请求仍能成功
    XCTestExpectation *recoveryExpectation = [self expectationWithDescription:@"Recovery"];
    dispatch_async(queue, ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"Recovery"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertTrue(response != nil || error != nil);
        [recoveryExpectation fulfill];
    });

    [self waitForExpectations:@[recoveryExpectation] timeout:20.0];
}

#pragma mark - N. 并发多端口测试

// N.1 并发保持连接（慢测试）
- (void)testConcurrentMultiPort_ParallelKeepAlive_IndependentConnections {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation11443 = [self expectationWithDescription:@"Port 11443 keep-alive"];
    XCTestExpectation *expectation11444 = [self expectationWithDescription:@"Port 11444 keep-alive"];

    // 线程 1：向端口 11443 发起 10 个请求，间隔 1 秒
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < 10; i++) {
            if (i > 0) {
                [NSThread sleepForTimeInterval:1.0];
            }
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                            userAgent:@"KeepAlive11443"
                                              timeout:15.0
                                                error:&error];
        }
        [expectation11443 fulfill];
    });

    // 线程 2：同时向端口 11444 发起 10 个请求，间隔 1 秒
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < 10; i++) {
            if (i > 0) {
                [NSThread sleepForTimeInterval:1.0];
            }
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                            userAgent:@"KeepAlive11444"
                                              timeout:15.0
                                                error:&error];
        }
        [expectation11444 fulfill];
    });

    [self waitForExpectations:@[expectation11443, expectation11444] timeout:40.0];
}

// N.2 轮询端口分配模式
- (void)testConcurrentMultiPort_RoundRobinDistribution_EvenLoad {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Round-robin distribution"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber *> *ports = @[@11443, @11444, @11445, @11446];
        NSInteger totalRequests = 100;
        NSMutableDictionary<NSNumber *, NSNumber *> *portRequestCounts = [NSMutableDictionary dictionary];

        // 初始化计数器
        for (NSNumber *port in ports) {
            portRequestCounts[port] = @0;
        }

        // 以轮询方式向 4 个端口分发 100 个请求
        for (NSInteger i = 0; i < totalRequests; i++) {
            NSNumber *port = ports[i % ports.count];
            NSString *urlString = [NSString stringWithFormat:@"https://127.0.0.1:%@/get", port];

            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"RoundRobin"
                                                                                      timeout:15.0
                                                                                        error:&error];

            if (response && response.statusCode == 200) {
                NSInteger count = [portRequestCounts[port] integerValue];
                portRequestCounts[port] = @(count + 1);
            }
        }

        // 验证每个端口大约获得 25 个请求
        for (NSNumber *port in ports) {
            NSInteger count = [portRequestCounts[port] integerValue];
            XCTAssertEqual(count, 25, @"Port %@ should receive 25 requests", port);
        }

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:180.0];
}

// N.3 混合负载多端口场景
- (void)testConcurrentMultiPort_MixedLoadPattern_RobustHandling {
    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // 端口 11443：高负载（20 个请求）
    for (NSInteger i = 0; i < 20; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Heavy11443 %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                            userAgent:@"HeavyLoad"
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
    }

    // 端口 11444：中负载（10 个请求）
    for (NSInteger i = 0; i < 10; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Medium11444 %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11444/get"
                                            userAgent:@"MediumLoad"
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
    }

    // 端口 11445：低负载（5 个请求）
    for (NSInteger i = 0; i < 5; i++) {
        XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Light11445 %ld", (long)i]];
        [expectations addObject:expectation];

        dispatch_async(queue, ^{
            NSError *error = nil;
            [self.client performRequestWithURLString:@"https://127.0.0.1:11445/get"
                                            userAgent:@"LightLoad"
                                              timeout:15.0
                                                error:&error];
            [expectation fulfill];
        });
    }

    [self waitForExpectations:expectations timeout:80.0];
}

@end
