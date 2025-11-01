//
//  HttpdnsNWHTTPClientTestBase.h
//  AlicloudHttpDNSTests
//
//  @author Created by Claude Code on 2025-11-01
//  Copyright © 2025 alibaba-inc.com. All rights reserved.
//
//  测试基类 - 为所有 HttpdnsNWHTTPClient 测试提供共享的 setup/teardown
//

#import <XCTest/XCTest.h>
#import "HttpdnsNWHTTPClient.h"
#import "HttpdnsNWHTTPClient_Internal.h"
#import "HttpdnsNWReusableConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface HttpdnsNWHTTPClientTestBase : XCTestCase

@property (nonatomic, strong) HttpdnsNWHTTPClient *client;

@end

NS_ASSUME_NONNULL_END
