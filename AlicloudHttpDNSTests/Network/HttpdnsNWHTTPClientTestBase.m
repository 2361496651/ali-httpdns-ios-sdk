//
//  HttpdnsNWHTTPClientTestBase.m
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  测试基类实现 - 共享的环境配置与清理逻辑
//
//  注意：所有测试需要先启动本地 mock server
//  启动命令：cd AlicloudHttpDNSTests/Network && python3 mock_server.py
//  服务端口：
//    - HTTP:  11080
//    - HTTPS: 11443, 11444, 11445, 11446
//

#import "HttpdnsNWHTTPClientTestBase.h"

@implementation HttpdnsNWHTTPClientTestBase

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

@end
