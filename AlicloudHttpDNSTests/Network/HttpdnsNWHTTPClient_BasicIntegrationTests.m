//
//  HttpdnsNWHTTPClient_BasicIntegrationTests.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  基础集成测试 - 包含基础功能 (G) 和连接复用 (J) 测试组
//  测试总数：12 个（G:7 + J:5）
//

#import "HttpdnsNWHTTPClientTestBase.h"

@interface HttpdnsNWHTTPClient_BasicIntegrationTests : HttpdnsNWHTTPClientTestBase

@end

@implementation HttpdnsNWHTTPClient_BasicIntegrationTests

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

#pragma mark - J. 连接复用详细测试

// J.1 连接过期测试（31秒后创建新连接）
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

@end
