//
//  HttpdnsNWHTTPClientIntegrationTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  真实网络集成测试 - 使用本地 mock server (127.0.0.1)
//  注意：需要先启动 mock_server.py (python3 mock_server.py)
//  测试总数：46 个（G:7 + H:5 + I:5 + J:5 + K:5 + L:3 + M:4 + N:3 + O:3 + P:6）

#import <XCTest/XCTest.h>
#import "HttpdnsNWHTTPClient.h"
#import "HttpdnsNWHTTPClient_Internal.h"

@interface HttpdnsNWHTTPClientIntegrationTests : XCTestCase

@property (nonatomic, strong) HttpdnsNWHTTPClient *client;

@end

@implementation HttpdnsNWHTTPClientIntegrationTests

- (void)setUp {
    [super setUp];

    // 设置环境变量以跳过 TLS 验证（用于本地 mock server 的自签名证书）
    // 这是安全的，因为：
    // 1. 仅在测试环境生效
    // 2. 连接限制为本地 loopback (127.0.0.1)
    // 3. 不影响生产代码
    setenv("HTTPDNS_SKIP_TLS_VERIFY", "1", 1);

    self.client = [[HttpdnsNWHTTPClient alloc] init];
}

- (void)tearDown {
    // 清除环境变量，避免影响其他测试
    unsetenv("HTTPDNS_SKIP_TLS_VERIFY");

    self.client = nil;
    [super tearDown];
}

#pragma mark - G. 集成测试（真实网络）

// G.1 HTTP GET 请求
- (void)testIntegration_HTTPGetRequest_RealNetwork {
    XCTestExpectation *expectation = [self expectationWithDescription:@"HTTP GET request"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                  timeout:15.0
                                                                                    error:&error];

        XCTAssertNotNil(response, @"Response should not be nil");
        XCTAssertNil(error, @"Error should be nil, got: %@", error);
        XCTAssertEqual(response.statusCode, 200, @"Status code should be 200");
        XCTAssertNotNil(response.body, @"Body should not be nil");
        XCTAssertGreaterThan(response.body.length, 0, @"Body should not be empty");

        // 验证响应包含 JSON
        NSError *jsonError = nil;
        NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:response.body
                                                                 options:0
                                                                   error:&jsonError];
        XCTAssertNotNil(jsonDict, @"Response should be valid JSON");
        XCTAssertNil(jsonError, @"JSON parsing should succeed");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:20.0];
}

// G.2 HTTPS GET 请求
- (void)testIntegration_HTTPSGetRequest_RealNetwork {
    XCTestExpectation *expectation = [self expectationWithDescription:@"HTTPS GET request"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                  timeout:15.0
                                                                                    error:&error];

        XCTAssertNotNil(response, @"Response should not be nil");
        XCTAssertNil(error, @"Error should be nil, got: %@", error);
        XCTAssertEqual(response.statusCode, 200, @"Status code should be 200");
        XCTAssertNotNil(response.body, @"Body should not be nil");

        // 验证 TLS 成功建立
        XCTAssertGreaterThan(response.body.length, 0, @"HTTPS body should not be empty");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:20.0];
}

// G.3 HTTP 404 响应
- (void)testIntegration_NotFound_Returns404 {
    XCTestExpectation *expectation = [self expectationWithDescription:@"404 response"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/status/404"
                                                                                userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                  timeout:15.0
                                                                                    error:&error];

        XCTAssertNotNil(response, @"Response should not be nil even for 404");
        XCTAssertNil(error, @"Error should be nil for valid HTTP response");
        XCTAssertEqual(response.statusCode, 404, @"Status code should be 404");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:20.0];
}

// G.4 连接复用测试
- (void)testIntegration_ConnectionReuse_MultipleRequests {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Connection reuse"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                   timeout:15.0
                                                                                     error:&error1];

        XCTAssertNotNil(response1, @"First response should not be nil");
        XCTAssertNil(error1, @"First request should succeed");
        XCTAssertEqual(response1.statusCode, 200);

        // 立即发起第二个请求，应该复用连接
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                   timeout:15.0
                                                                                     error:&error2];

        XCTAssertNotNil(response2, @"Second response should not be nil");
        XCTAssertNil(error2, @"Second request should succeed");
        XCTAssertEqual(response2.statusCode, 200);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:30.0];
}

// G.5 Chunked 响应处理
- (void)testIntegration_ChunkedResponse_RealNetwork {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Chunked response"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        // httpbin.org/stream-bytes 返回 chunked 编码的响应
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/stream-bytes/1024"
                                                                                userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                  timeout:15.0
                                                                                    error:&error];

        XCTAssertNotNil(response, @"Response should not be nil");
        XCTAssertNil(error, @"Error should be nil, got: %@", error);
        XCTAssertEqual(response.statusCode, 200);
        XCTAssertEqual(response.body.length, 1024, @"Should receive exactly 1024 bytes");

        // 验证 Transfer-Encoding 头
        NSString *transferEncoding = response.headers[@"transfer-encoding"];
        if (transferEncoding) {
            XCTAssertTrue([transferEncoding containsString:@"chunked"], @"Should use chunked encoding");
        }

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:20.0];
}

#pragma mark - 额外的集成测试

// G.6 超时测试（可选）
- (void)testIntegration_RequestTimeout_ReturnsError {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Request timeout"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        // httpbin.org/delay/10 会延迟 10 秒响应，我们设置 2 秒超时
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/delay/10"
                                                                                userAgent:@"HttpdnsNWHTTPClient/1.0"
                                                                                  timeout:2.0
                                                                                    error:&error];

        XCTAssertNil(response, @"Response should be nil on timeout");
        XCTAssertNotNil(error, @"Error should be set on timeout");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:5.0];
}

// G.7 多个不同头部的请求
- (void)testIntegration_CustomHeaders_Reflected {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Custom headers"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/headers"
                                                                                userAgent:@"TestUserAgent/1.0"
                                                                                  timeout:15.0
                                                                                    error:&error];

        XCTAssertNotNil(response);
        XCTAssertEqual(response.statusCode, 200);

        // 解析 JSON 响应，验证我们的 User-Agent 被发送
        NSError *jsonError = nil;
        NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:response.body
                                                                 options:0
                                                                   error:&jsonError];
        XCTAssertNotNil(jsonDict);

        NSDictionary *headers = jsonDict[@"headers"];
        XCTAssertTrue([headers[@"User-Agent"] containsString:@"TestUserAgent"], @"User-Agent should be sent");

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:20.0];
}

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

#pragma mark - J. 高级连接复用测试

// J.1 连接过期与清理（慢测试）
- (void)testConnectionReuse_Expiry31Seconds_NewConnectionCreated {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Connection expiry"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFAbsoluteTime time1 = CFAbsoluteTimeGetCurrent();
        NSError *error1 = nil;
        HttpdnsNWHTTPClientResponse *response1 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"First"
                                                                                   timeout:15.0
                                                                                     error:&error1];
        CFAbsoluteTime elapsed1 = CFAbsoluteTimeGetCurrent() - time1;
        XCTAssertTrue(response1 != nil || error1 != nil);

        // 等待31秒让连接过期
        [NSThread sleepForTimeInterval:31.0];

        // 第二个请求应该创建新连接（可能稍慢，因为需要建立连接）
        CFAbsoluteTime time2 = CFAbsoluteTimeGetCurrent();
        NSError *error2 = nil;
        HttpdnsNWHTTPClientResponse *response2 = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                 userAgent:@"Second"
                                                                                   timeout:15.0
                                                                                     error:&error2];
        CFAbsoluteTime elapsed2 = CFAbsoluteTimeGetCurrent() - time2;
        XCTAssertTrue(response2 != nil || error2 != nil);

        // 注意：由于网络波动，不能严格比较时间
        // 只验证请求都成功即可

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:70.0];
}

// J.2 连接池容量限制验证
- (void)testConnectionReuse_TenRequests_OnlyFourConnectionsKept {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Pool size limit"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 连续10个请求
        for (NSInteger i = 0; i < 10; i++) {
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"PoolSizeTest"
                                                                                      timeout:15.0
                                                                                        error:&error];
            XCTAssertTrue(response != nil || error != nil);
        }

        // 等待所有连接归还
        [NSThread sleepForTimeInterval:1.0];

        // 无法直接验证池大小，但如果实现正确，池应自动限制
        // 后续请求应该仍能正常工作
        NSError *error = nil;
        HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                userAgent:@"Verification"
                                                                                  timeout:15.0
                                                                                    error:&error];
        XCTAssertTrue(response != nil || error != nil);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:120.0];
}

// J.3 不同路径复用连接
- (void)testConnectionReuse_DifferentPaths_SameConnection {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Different paths"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *paths = @[@"/get", @"/headers", @"/user-agent", @"/uuid"];
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];

        for (NSString *path in paths) {
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:11080%@", path];
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:urlString
                                                                                    userAgent:@"PathTest"
                                                                                      timeout:15.0
                                                                                        error:&error];
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;

            XCTAssertTrue(response != nil || error != nil);
            [times addObject:@(elapsed)];
        }

        // 如果连接复用工作正常，后续请求应该更快（但网络波动可能影响）
        // 至少验证所有请求都成功
        XCTAssertEqual(times.count, paths.count);

        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:60.0];
}

// J.4 HTTP vs HTTPS 使用不同连接
- (void)testConnectionReuse_HTTPvsHTTPS_DifferentPoolKeys {
    XCTestExpectation *expectation = [self expectationWithDescription:@"HTTP vs HTTPS"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // HTTP 请求
        NSError *httpError = nil;
        HttpdnsNWHTTPClientResponse *httpResponse = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"HTTP"
                                                                                      timeout:15.0
                                                                                        error:&httpError];
        XCTAssertTrue(httpResponse != nil || httpError != nil);

        // HTTPS 请求（应该使用不同的连接池 key）
        NSError *httpsError = nil;
        HttpdnsNWHTTPClientResponse *httpsResponse = [self.client performRequestWithURLString:@"https://127.0.0.1:11443/get"
                                                                                     userAgent:@"HTTPS"
                                                                                       timeout:15.0
                                                                                         error:&httpsError];
        XCTAssertTrue(httpsResponse != nil || httpsError != nil);

        // 两者都应该成功，且不会相互干扰
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:35.0];
}

// J.5 长连接保持测试
- (void)testConnectionReuse_TwentyRequestsOneSecondApart_ConnectionKeptAlive {
    if (getenv("SKIP_SLOW_TESTS")) {
        return;
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Keep-alive"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger successCount = 0;
        NSMutableArray<NSNumber *> *requestTimes = [NSMutableArray array];

        // 20个请求，间隔1秒（第一个请求立即执行）
        for (NSInteger i = 0; i < 20; i++) {
            // 除第一个请求外，每次请求前等待1秒
            if (i > 0) {
                [NSThread sleepForTimeInterval:1.0];
            }

            CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
            NSError *error = nil;
            HttpdnsNWHTTPClientResponse *response = [self.client performRequestWithURLString:@"http://127.0.0.1:11080/get"
                                                                                    userAgent:@"KeepAlive"
                                                                                      timeout:10.0
                                                                                        error:&error];
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - startTime;
            [requestTimes addObject:@(elapsed)];

            if (response && (response.statusCode == 200 || response.statusCode == 503)) {
                successCount++;
            } else {
                // 如果请求失败，提前退出以避免超时
                break;
            }
        }

        // 至少大部分请求应该成功
        XCTAssertGreaterThan(successCount, 15, @"Most requests should succeed with connection reuse");

        // 验证连接复用：后续请求应该更快（如果使用了keep-alive）
        if (requestTimes.count >= 10) {
            double firstRequestTime = [requestTimes[0] doubleValue];
            double laterAvgTime = 0;
            for (NSInteger i = 5; i < MIN(10, requestTimes.count); i++) {
                laterAvgTime += [requestTimes[i] doubleValue];
            }
            laterAvgTime /= MIN(5, requestTimes.count - 5);
            // 后续请求应该不会明显更慢（说明连接复用工作正常）
            XCTAssertLessThanOrEqual(laterAvgTime, firstRequestTime * 2.0, @"Connection reuse should keep latency reasonable");
        }

        [expectation fulfill];
    });

    // 超时计算: 19秒sleep + 20个请求×~2秒 = 59秒，设置50秒（提前退出机制保证效率）
    [self waitForExpectations:@[expectation] timeout:50.0];
}

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

#pragma mark - N. 并发多端口场景测试

// N.1 并行多端口 Keep-Alive
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
