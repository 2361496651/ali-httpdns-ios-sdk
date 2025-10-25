#import "HttpdnsNWHTTPClient.h"

#import <Network/Network.h>
#import <Security/SecCertificate.h>
#import <Security/SecPolicy.h>
#import <Security/SecTrust.h>

#import "HttpdnsInternalConstant.h"
#import "HttpdnsLog_Internal.h"
#import "HttpdnsPublicConstant.h"
#import "HttpdnsUtil.h"

@interface HttpdnsNWHTTPClientResponse ()
@end

@implementation HttpdnsNWHTTPClientResponse
@end

static const NSUInteger kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey = 4;
static const NSTimeInterval kHttpdnsNWHTTPClientIdleConnectionTimeout = 30.0;
static const NSTimeInterval kHttpdnsNWHTTPClientDefaultTimeout = 10.0;

typedef NS_ENUM(NSInteger, HttpdnsHTTPHeaderParseResult) {
    HttpdnsHTTPHeaderParseResultIncomplete = 0,
    HttpdnsHTTPHeaderParseResultSuccess,
    HttpdnsHTTPHeaderParseResultError,
};

typedef NS_ENUM(NSInteger, HttpdnsHTTPChunkParseResult) {
    HttpdnsHTTPChunkParseResultIncomplete = 0,
    HttpdnsHTTPChunkParseResultSuccess,
    HttpdnsHTTPChunkParseResultError,
};

@class HttpdnsNWHTTPClient;
@class HttpdnsNWReusableConnection;

@interface HttpdnsNWHTTPClient (HttpdnsNWReusableConnectionAccess)
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;
- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error;
- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error;
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;
@end

@interface HttpdnsNWHTTPExchange : NSObject

@property (nonatomic, strong, readonly) NSMutableData *buffer;
@property (nonatomic, strong, readonly) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL remoteClosed;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) NSUInteger headerEndIndex;
@property (nonatomic, assign) BOOL headerParsed;
@property (nonatomic, assign) BOOL chunked;
@property (nonatomic, assign) long long contentLength;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) dispatch_block_t timeoutBlock;

- (instancetype)init;

@end

@implementation HttpdnsNWHTTPExchange

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
        _semaphore = dispatch_semaphore_create(0);
        _headerEndIndex = NSNotFound;
        _contentLength = -1;
    }
    return self;
}

@end

@interface HttpdnsNWReusableConnection : NSObject

@property (nonatomic, weak, readonly) HttpdnsNWHTTPClient *client;
@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, copy, readonly) NSString *port;
@property (nonatomic, assign, readonly) BOOL useTLS;
@property (nonatomic, strong, readonly) dispatch_queue_t queue;
@property (nonatomic, strong) NSDate *lastUsedDate;
@property (nonatomic, assign) BOOL inUse;
@property (nonatomic, assign, getter=isInvalidated) BOOL invalidated;

- (instancetype)initWithClient:(HttpdnsNWHTTPClient *)client
                          host:(NSString *)host
                          port:(NSString *)port
                        useTLS:(BOOL)useTLS;

- (BOOL)openWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
- (nullable NSData *)sendRequestData:(NSData *)requestData
                             timeout:(NSTimeInterval)timeout
              remoteConnectionClosed:(BOOL *)remoteConnectionClosed
                               error:(NSError **)error;
- (BOOL)isViable;
- (void)invalidate;

@end

@interface HttpdnsNWReusableConnection ()

#if OS_OBJECT_USE_OBJC
@property (nonatomic, strong) nw_connection_t connectionHandle;
#else
@property (nonatomic, assign) nw_connection_t connectionHandle;
#endif
@property (nonatomic, strong) dispatch_semaphore_t stateSemaphore;
@property (nonatomic, assign) nw_connection_state_t state;
@property (nonatomic, strong) NSError *stateError;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong) HttpdnsNWHTTPExchange *currentExchange;

@end

@implementation HttpdnsNWReusableConnection

- (void)dealloc {
    if (_connectionHandle) {
        nw_connection_set_state_changed_handler(_connectionHandle, NULL);
        nw_connection_cancel(_connectionHandle);
#if !OS_OBJECT_USE_OBJC
        nw_release(_connectionHandle);
#endif
        _connectionHandle = NULL;
    }
}

- (instancetype)initWithClient:(HttpdnsNWHTTPClient *)client
                          host:(NSString *)host
                          port:(NSString *)port
                        useTLS:(BOOL)useTLS {
    NSParameterAssert(client);
    NSParameterAssert(host);
    NSParameterAssert(port);

    self = [super init];
    if (!self) {
        return nil;
    }

    _client = client;
    _host = [host copy];
    _port = [port copy];
    _useTLS = useTLS;
    _queue = dispatch_queue_create("com.alibaba.sdk.httpdns.network.connection.reuse", DISPATCH_QUEUE_SERIAL);
    _stateSemaphore = dispatch_semaphore_create(0);
    _state = nw_connection_state_invalid;
    _lastUsedDate = [NSDate date];

    nw_endpoint_t endpoint = nw_endpoint_create_host(_host.UTF8String, _port.UTF8String);
    if (!endpoint) {
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    nw_parameters_t parameters = NULL;
    if (useTLS) {
        parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tlsOptions) {
            if (!tlsOptions) {
                return;
            }
            sec_protocol_options_t secOptions = nw_tls_copy_sec_protocol_options(tlsOptions);
            if (!secOptions) {
                return;
            }
            if (![HttpdnsUtil isIPv4Address:host] && ![HttpdnsUtil isIPv6Address:host]) {
                sec_protocol_options_set_tls_server_name(secOptions, host.UTF8String);
            }
#if defined(__IPHONE_13_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_13_0)
            if (@available(iOS 13.0, *)) {
                sec_protocol_options_add_tls_application_protocol(secOptions, "http/1.1");
            }
#endif
            __strong typeof(weakSelf) strongSelf = weakSelf;
            sec_protocol_options_set_verify_block(secOptions, ^(sec_protocol_metadata_t metadata, sec_trust_t secTrust, sec_protocol_verify_complete_t complete) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                BOOL isValid = NO;
                if (secTrust && strongSelf) {
                    SecTrustRef trustRef = sec_trust_copy_ref(secTrust);
                    if (trustRef) {
                        NSString *validIP = ALICLOUD_HTTPDNS_VALID_SERVER_CERTIFICATE_IP;
                        isValid = [strongSelf.client evaluateServerTrust:trustRef forDomain:validIP];
                        if (!isValid && [HttpdnsUtil isNotEmptyString:strongSelf.host]) {
                            isValid = [strongSelf.client evaluateServerTrust:trustRef forDomain:strongSelf.host];
                        }
                        if (!isValid && !strongSelf.stateError) {
                            strongSelf.stateError = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                                        code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"TLS trust validation failed"}];
                        }
                        CFRelease(trustRef);
                    }
                }
                complete(isValid);
            }, strongSelf.queue);
        }, ^(nw_protocol_options_t tcpOptions) {
            nw_tcp_options_set_no_delay(tcpOptions, true);
        });
    } else {
        parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcpOptions) {
            nw_tcp_options_set_no_delay(tcpOptions, true);
        });
    }

    if (!parameters) {
#if !OS_OBJECT_USE_OBJC
        nw_release(endpoint);
#endif
        return nil;
    }

    nw_connection_t connection = nw_connection_create(endpoint, parameters);

#if !OS_OBJECT_USE_OBJC
    nw_release(endpoint);
    nw_release(parameters);
#endif

    if (!connection) {
        return nil;
    }

    _connectionHandle = connection;

    nw_connection_set_queue(_connectionHandle, _queue);
    nw_connection_set_state_changed_handler(_connectionHandle, ^(nw_connection_state_t state, nw_error_t stateError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf handleStateChange:state error:stateError];
    });

    return self;
}

- (void)handleStateChange:(nw_connection_state_t)state error:(nw_error_t)error {
    _state = state;
    if (error) {
        _stateError = [HttpdnsNWHTTPClient errorFromNWError:error description:@"Connection state error"];
    }
    if (state == nw_connection_state_ready) {
        dispatch_semaphore_signal(_stateSemaphore);
        return;
    }
    if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
        self.invalidated = YES;
        if (!_stateError && error) {
            _stateError = [HttpdnsNWHTTPClient errorFromNWError:error description:@"Connection failed"];
        }
        dispatch_semaphore_signal(_stateSemaphore);
        HttpdnsNWHTTPExchange *exchange = self.currentExchange;
        if (exchange && !exchange.finished) {
            if (!exchange.error) {
                exchange.error = _stateError ?: [HttpdnsNWHTTPClient errorFromNWError:error description:@"Connection failed"];
            }
            exchange.finished = YES;
            dispatch_semaphore_signal(exchange.semaphore);
        }
    }
}

- (BOOL)openWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (self.invalidated) {
        if (error) {
            *error = _stateError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                       code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Connection invalid"}];
        }
        return NO;
    }

    if (!_started) {
        _started = YES;
        nw_connection_start(_connectionHandle);
    }

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    long waitResult = dispatch_semaphore_wait(_stateSemaphore, deadline);
    if (waitResult != 0) {
        self.invalidated = YES;
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Connection setup timed out"}];
        }
        nw_connection_cancel(_connectionHandle);
        return NO;
    }

    if (_state == nw_connection_state_ready) {
        return YES;
    }

    if (error) {
        *error = _stateError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                   code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                               userInfo:@{NSLocalizedDescriptionKey: @"Connection failed to become ready"}];
    }
    return NO;
}

- (BOOL)isViable {
    return !self.invalidated && _state == nw_connection_state_ready;
}

- (void)invalidate {
    if (self.invalidated) {
        return;
    }
    self.invalidated = YES;
    if (_connectionHandle) {
        nw_connection_cancel(_connectionHandle);
    }
}

- (nullable NSData *)sendRequestData:(NSData *)requestData
                             timeout:(NSTimeInterval)timeout
              remoteConnectionClosed:(BOOL *)remoteConnectionClosed
                               error:(NSError **)error {
    if (!requestData || requestData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty HTTP request"}];
        }
        return nil;
    }

    if (![self isViable] || self.currentExchange) {
        if (error) {
            *error = _stateError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                       code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Connection not ready"}];
        }
        return nil;
    }

    HttpdnsNWHTTPExchange *exchange = [HttpdnsNWHTTPExchange new];
    __weak typeof(self) weakSelf = self;

    dispatch_sync(_queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            exchange.error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                 code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                             userInfo:@{NSLocalizedDescriptionKey: @"Connection released unexpectedly"}];
            exchange.finished = YES;
            dispatch_semaphore_signal(exchange.semaphore);
            return;
        }
        if (strongSelf.invalidated || strongSelf.currentExchange) {
            exchange.error = strongSelf.stateError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                                          code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                                      userInfo:@{NSLocalizedDescriptionKey: @"Connection is busy"}];
            exchange.finished = YES;
            dispatch_semaphore_signal(exchange.semaphore);
            return;
        }
        strongSelf.currentExchange = exchange;
        dispatch_data_t payload = dispatch_data_create(requestData.bytes, requestData.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        dispatch_block_t timeoutBlock = dispatch_block_create(0, ^{
            if (exchange.finished) {
                return;
            }
            exchange.error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                 code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                             userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];
            exchange.finished = YES;
            dispatch_semaphore_signal(exchange.semaphore);
            nw_connection_cancel(strongSelf.connectionHandle);
        });
        exchange.timeoutBlock = timeoutBlock;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), strongSelf.queue, timeoutBlock);

        nw_connection_send(strongSelf.connectionHandle, payload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
            __strong typeof(strongSelf) innerSelf = strongSelf;
            if (!innerSelf) {
                return;
            }
            if (sendError) {
                dispatch_async(innerSelf.queue, ^{
                    if (!exchange.finished) {
                        exchange.error = [HttpdnsNWHTTPClient errorFromNWError:sendError description:@"Send failed"];
                        exchange.finished = YES;
                        dispatch_semaphore_signal(exchange.semaphore);
                        nw_connection_cancel(innerSelf.connectionHandle);
                    }
                });
                return;
            }
            [innerSelf startReceiveLoopForExchange:exchange];
        });
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    long waitResult = dispatch_semaphore_wait(exchange.semaphore, deadline);

    dispatch_sync(_queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (exchange.timeoutBlock) {
            dispatch_block_cancel(exchange.timeoutBlock);
            exchange.timeoutBlock = nil;
        }
        if (strongSelf && strongSelf.currentExchange == exchange) {
            strongSelf.currentExchange = nil;
        }
    });

    if (waitResult != 0) {
        if (!exchange.error) {
            exchange.error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                            userInfo:@{NSLocalizedDescriptionKey: @"Request wait timed out"}];
        }
        [self invalidate];
        if (error) {
            *error = exchange.error;
        }
        return nil;
    }

    if (exchange.error) {
        [self invalidate];
        if (error) {
            *error = exchange.error;
        }
        return nil;
    }

    if (remoteConnectionClosed) {
        *remoteConnectionClosed = exchange.remoteClosed;
    }

    self.lastUsedDate = [NSDate date];
    return [exchange.buffer copy];
}

- (void)startReceiveLoopForExchange:(HttpdnsNWHTTPExchange *)exchange {
    __weak typeof(self) weakSelf = self;
    __block void (^receiveBlock)(dispatch_data_t, nw_content_context_t, bool, nw_error_t);
    __block __weak void (^weakReceiveBlock)(dispatch_data_t, nw_content_context_t, bool, nw_error_t);

    receiveBlock = ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t receiveError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (exchange.finished) {
            return;
        }
        if (receiveError) {
            exchange.error = [HttpdnsNWHTTPClient errorFromNWError:receiveError description:@"Receive failed"];
            exchange.finished = YES;
            dispatch_semaphore_signal(exchange.semaphore);
            return;
        }
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                if (buffer && size > 0) {
                    [exchange.buffer appendBytes:buffer length:size];
                }
                return true;
            });
        }
        [strongSelf evaluateExchangeCompletion:exchange isRemoteComplete:is_complete];
        if (exchange.finished) {
            dispatch_semaphore_signal(exchange.semaphore);
            return;
        }
        if (is_complete) {
            exchange.remoteClosed = YES;
            if (!exchange.finished) {
                exchange.error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                     code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Connection closed before response completed"}];
                exchange.finished = YES;
                dispatch_semaphore_signal(exchange.semaphore);
            }
            return;
        }
        void (^callback)(dispatch_data_t, nw_content_context_t, bool, nw_error_t) = weakReceiveBlock;
        if (callback && !exchange.finished) {
            nw_connection_receive(strongSelf.connectionHandle, 1, UINT32_MAX, callback);
        }
    };

    weakReceiveBlock = receiveBlock;
    nw_connection_receive(_connectionHandle, 1, UINT32_MAX, receiveBlock);
}

- (void)evaluateExchangeCompletion:(HttpdnsNWHTTPExchange *)exchange isRemoteComplete:(bool)isComplete {
    if (exchange.finished) {
        return;
    }

    if (isComplete) {
        // 远端已经发送完并关闭，需要提前标记，避免提前返回时漏记连接状态
        exchange.remoteClosed = YES;
    }

    if (!exchange.headerParsed) {
        NSUInteger headerEnd = NSNotFound;
        NSInteger statusCode = 0;
        NSDictionary<NSString *, NSString *> *headers = nil;
        NSError *headerError = nil;
        HttpdnsHTTPHeaderParseResult headerResult = [self.client tryParseHTTPHeadersInData:exchange.buffer
                                                                           headerEndIndex:&headerEnd
                                                                               statusCode:&statusCode
                                                                                  headers:&headers
                                                                                    error:&headerError];
        if (headerResult == HttpdnsHTTPHeaderParseResultError) {
            exchange.error = headerError;
            exchange.finished = YES;
            return;
        }
        if (headerResult == HttpdnsHTTPHeaderParseResultIncomplete) {
            return;
        }
        exchange.headerParsed = YES;
        exchange.headerEndIndex = headerEnd;
        exchange.statusCode = statusCode;
        NSString *contentLengthValue = headers[@"content-length"];
        if ([HttpdnsUtil isNotEmptyString:contentLengthValue]) {
            exchange.contentLength = [contentLengthValue longLongValue];
        }
        NSString *transferEncodingValue = headers[@"transfer-encoding"];
        if ([HttpdnsUtil isNotEmptyString:transferEncodingValue] && [transferEncodingValue rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            exchange.chunked = YES;
        }
    }

    if (!exchange.headerParsed) {
        return;
    }

    NSUInteger bodyOffset = exchange.headerEndIndex == NSNotFound ? 0 : exchange.headerEndIndex + 4;
    NSUInteger currentBodyLength = exchange.buffer.length > bodyOffset ? exchange.buffer.length - bodyOffset : 0;

    if (exchange.chunked) {
        NSError *chunkError = nil;
        HttpdnsHTTPChunkParseResult chunkResult = [self.client checkChunkedBodyCompletionInData:exchange.buffer
                                                                                headerEndIndex:exchange.headerEndIndex
                                                                                        error:&chunkError];
        if (chunkResult == HttpdnsHTTPChunkParseResultError) {
            exchange.error = chunkError;
            exchange.finished = YES;
            return;
        }
        if (chunkResult == HttpdnsHTTPChunkParseResultSuccess) {
            exchange.finished = YES;
            return;
        }
        return;
    }

    if (exchange.contentLength >= 0) {
        if ((long long)currentBodyLength >= exchange.contentLength) {
            exchange.finished = YES;
        }
        return;
    }

    if (isComplete) {
        exchange.remoteClosed = YES;
        exchange.finished = YES;
    }
}

@end

@interface HttpdnsNWHTTPClient ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<HttpdnsNWReusableConnection *> *> *connectionPool;
@property (nonatomic, strong) dispatch_queue_t poolQueue;

- (NSString *)connectionPoolKeyForHost:(NSString *)host port:(NSString *)port useTLS:(BOOL)useTLS;
- (HttpdnsNWReusableConnection *)dequeueConnectionForHost:(NSString *)host
                                                     port:(NSString *)port
                                                   useTLS:(BOOL)useTLS
                                                  timeout:(NSTimeInterval)timeout
                                                    error:(NSError **)error;
- (void)returnConnection:(HttpdnsNWReusableConnection *)connection
                   forKey:(NSString *)key
              shouldClose:(BOOL)shouldClose;
- (void)pruneConnectionPool:(NSMutableArray<HttpdnsNWReusableConnection *> *)pool
              referenceDate:(NSDate *)referenceDate;
- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                         body:(NSData *__autoreleasing *)body
                        error:(NSError **)error;
- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error;
- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error;
- (NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError **)error;
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain;
+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description;

@end

@implementation HttpdnsNWHTTPClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _poolQueue = dispatch_queue_create("com.alibaba.sdk.httpdns.network.pool", DISPATCH_QUEUE_SERIAL);
        _connectionPool = [NSMutableDictionary dictionary];
    }
    return self;
}

- (nullable HttpdnsNWHTTPClientResponse *)performRequestWithURLString:(NSString *)urlString
                                                            userAgent:(NSString *)userAgent
                                                              timeout:(NSTimeInterval)timeout
                                                                error:(NSError **)error {
    HttpdnsLogDebug("Send Network.framework request URL: %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid resolve URL"}];
        }
        return nil;
    }

    NSTimeInterval requestTimeout = timeout > 0 ? timeout : kHttpdnsNWHTTPClientDefaultTimeout;

    NSString *host = url.host;
    if (![HttpdnsUtil isNotEmptyString:host]) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing host in resolve URL"}];
        }
        return nil;
    }

    BOOL useTLS = [[url.scheme lowercaseString] isEqualToString:@"https"];
    NSString *portString = url.port ? url.port.stringValue : (useTLS ? @"443" : @"80");

    NSString *requestString = [self buildHTTPRequestStringWithURL:url userAgent:userAgent];
    NSData *requestData = [requestString dataUsingEncoding:NSUTF8StringEncoding];
    if (!requestData) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to encode HTTP request"}];
        }
        return nil;
    }

    NSError *connectionError = nil;
    HttpdnsNWReusableConnection *connection = [self dequeueConnectionForHost:host
                                                                         port:portString
                                                                       useTLS:useTLS
                                                                      timeout:requestTimeout
                                                                        error:&connectionError];
    if (!connection) {
        if (error) {
            *error = connectionError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                            code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unable to obtain network connection"}];
        }
        return nil;
    }

    NSString *poolKey = [self connectionPoolKeyForHost:host port:portString useTLS:useTLS];
    BOOL remoteClosed = NO;
    NSError *exchangeError = nil;
    NSData *rawResponse = [connection sendRequestData:requestData
                                              timeout:requestTimeout
                               remoteConnectionClosed:&remoteClosed
                                                error:&exchangeError];

    if (!rawResponse) {
        [self returnConnection:connection forKey:poolKey shouldClose:YES];
        if (error) {
            *error = exchangeError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Network request failed"}];
        }
        return nil;
    }

    NSInteger statusCode = 0;
    NSDictionary<NSString *, NSString *> *headers = nil;
    NSData *bodyData = nil;
    NSError *parseError = nil;
    if (![self parseHTTPResponseData:rawResponse statusCode:&statusCode headers:&headers body:&bodyData error:&parseError]) {
        [self returnConnection:connection forKey:poolKey shouldClose:YES];
        if (error) {
            *error = parseError ?: [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                                       code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse HTTP response"}];
        }
        return nil;
    }

    BOOL shouldClose = remoteClosed;
    NSString *connectionHeader = headers[@"connection"];
    if ([HttpdnsUtil isNotEmptyString:connectionHeader] && [connectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        shouldClose = YES;
    }
    NSString *proxyConnectionHeader = headers[@"proxy-connection"];
    if (!shouldClose && [HttpdnsUtil isNotEmptyString:proxyConnectionHeader] && [proxyConnectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        shouldClose = YES;
    }

    [self returnConnection:connection forKey:poolKey shouldClose:shouldClose];

    HttpdnsNWHTTPClientResponse *response = [HttpdnsNWHTTPClientResponse new];
    response.statusCode = statusCode;
    response.headers = headers ?: @{};
    response.body = bodyData ?: [NSData data];
    return response;
}

- (NSString *)connectionPoolKeyForHost:(NSString *)host port:(NSString *)port useTLS:(BOOL)useTLS {
    NSString *safeHost = host ?: @"";
    NSString *safePort = port ?: @"";
    return [NSString stringWithFormat:@"%@:%@:%@", safeHost, safePort, useTLS ? @"tls" : @"tcp"];
}

- (HttpdnsNWReusableConnection *)dequeueConnectionForHost:(NSString *)host
                                                     port:(NSString *)port
                                                   useTLS:(BOOL)useTLS
                                                  timeout:(NSTimeInterval)timeout
                                                    error:(NSError **)error {
    NSString *key = [self connectionPoolKeyForHost:host port:port useTLS:useTLS];
    NSDate *now = [NSDate date];
    __block HttpdnsNWReusableConnection *connection = nil;

    dispatch_sync(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }
        [self pruneConnectionPool:pool referenceDate:now];
        for (HttpdnsNWReusableConnection *candidate in pool) {
            if (!candidate.inUse && [candidate isViable]) {
                candidate.inUse = YES;
                candidate.lastUsedDate = now;
                connection = candidate;
                break;
            }
        }
    });

    if (connection) {
        return connection;
    }

    HttpdnsNWReusableConnection *newConnection = [[HttpdnsNWReusableConnection alloc] initWithClient:self
                                                                                                 host:host
                                                                                                 port:port
                                                                                               useTLS:useTLS];
    if (!newConnection) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create network connection"}];
        }
        return nil;
    }

    if (![newConnection openWithTimeout:timeout error:error]) {
        [newConnection invalidate];
        return nil;
    }

    newConnection.inUse = YES;
    newConnection.lastUsedDate = now;

    dispatch_sync(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }
        [pool addObject:newConnection];
        [self pruneConnectionPool:pool referenceDate:[NSDate date]];
    });

    return newConnection;
}

- (void)returnConnection:(HttpdnsNWReusableConnection *)connection
                   forKey:(NSString *)key
              shouldClose:(BOOL)shouldClose {
    if (!connection || !key) {
        return;
    }

    NSDate *now = [NSDate date];
    dispatch_async(self.poolQueue, ^{
        NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
        if (!pool) {
            pool = [NSMutableArray array];
            self.connectionPool[key] = pool;
        }

        if (shouldClose || connection.isInvalidated) {
            [connection invalidate];
            [pool removeObject:connection];
        } else {
            connection.inUse = NO;
            connection.lastUsedDate = now;
            if (![pool containsObject:connection]) {
                [pool addObject:connection];
            }
            [self pruneConnectionPool:pool referenceDate:now];
        }

        if (pool.count == 0) {
            [self.connectionPool removeObjectForKey:key];
        }
    });
}

- (void)pruneConnectionPool:(NSMutableArray<HttpdnsNWReusableConnection *> *)pool referenceDate:(NSDate *)referenceDate {
    if (!pool || pool.count == 0) {
        return;
    }

    NSTimeInterval idleLimit = kHttpdnsNWHTTPClientIdleConnectionTimeout;
    for (NSInteger idx = (NSInteger)pool.count - 1; idx >= 0; idx--) {
        HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)idx];
        if (!candidate) {
            [pool removeObjectAtIndex:(NSUInteger)idx];
            continue;
        }
        NSDate *lastUsed = candidate.lastUsedDate ?: [NSDate distantPast];
        BOOL expired = !candidate.inUse && referenceDate && [referenceDate timeIntervalSinceDate:lastUsed] > idleLimit;
        if (candidate.isInvalidated || expired) {
            [candidate invalidate];
            [pool removeObjectAtIndex:(NSUInteger)idx];
        }
    }

    if (pool.count <= kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey) {
        return;
    }

    while (pool.count > kHttpdnsNWHTTPClientMaxIdleConnectionsPerKey) {
        NSInteger removeIndex = NSNotFound;
        NSDate *oldestDate = nil;
        for (NSInteger idx = 0; idx < (NSInteger)pool.count; idx++) {
            HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)idx];
            if (candidate.inUse) {
                continue;
            }
            NSDate *candidateDate = candidate.lastUsedDate ?: [NSDate distantPast];
            if (!oldestDate || [candidateDate compare:oldestDate] == NSOrderedAscending) {
                oldestDate = candidateDate;
                removeIndex = idx;
            }
        }
        if (removeIndex == NSNotFound) {
            break;
        }
        HttpdnsNWReusableConnection *candidate = pool[(NSUInteger)removeIndex];
        [candidate invalidate];
        [pool removeObjectAtIndex:(NSUInteger)removeIndex];
    }
}

- (NSString *)buildHTTPRequestStringWithURL:(NSURL *)url userAgent:(NSString *)userAgent {
    NSString *pathComponent = url.path.length > 0 ? url.path : @"/";
    NSMutableString *path = [NSMutableString stringWithString:pathComponent];
    if (url.query.length > 0) {
        [path appendFormat:@"?%@", url.query];
    }

    BOOL isTLS = [[url.scheme lowercaseString] isEqualToString:@"https"];
    NSInteger portValue = url.port ? url.port.integerValue : (isTLS ? 443 : 80);
    BOOL isDefaultPort = (!url.port) || (isTLS && portValue == 443) || (!isTLS && portValue == 80);

    NSMutableString *hostHeader = [NSMutableString stringWithString:url.host ?: @""];
    if (!isDefaultPort && url.port) {
        [hostHeader appendFormat:@":%@", url.port];
    }

    NSMutableString *request = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\n", path];
    [request appendFormat:@"Host: %@\r\n", hostHeader];
    if ([HttpdnsUtil isNotEmptyString:userAgent]) {
        [request appendFormat:@"User-Agent: %@\r\n", userAgent];
    }
    [request appendString:@"Accept: application/json\r\n"];
    [request appendString:@"Accept-Encoding: identity\r\n"];
    [request appendString:@"Connection: keep-alive\r\n\r\n"];
    return request;
}

- (HttpdnsHTTPHeaderParseResult)tryParseHTTPHeadersInData:(NSData *)data
                                          headerEndIndex:(NSUInteger *)headerEndIndex
                                              statusCode:(NSInteger *)statusCode
                                                 headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                                                   error:(NSError **)error {
    if (!data || data.length == 0) {
        return HttpdnsHTTPHeaderParseResultIncomplete;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger headerEnd = NSNotFound;
    for (NSUInteger idx = 0; idx + 3 < length; idx++) {
        if (bytes[idx] == '\r' && bytes[idx + 1] == '\n' && bytes[idx + 2] == '\r' && bytes[idx + 3] == '\n') {
            headerEnd = idx;
            break;
        }
    }

    if (headerEnd == NSNotFound) {
        return HttpdnsHTTPHeaderParseResultIncomplete;
    }

    if (headerEndIndex) {
        *headerEndIndex = headerEnd;
    }

    NSData *headerData = [data subdataWithRange:NSMakeRange(0, headerEnd)];
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (![HttpdnsUtil isNotEmptyString:headerString]) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode HTTP headers"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP status line"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSString *statusLine = lines.firstObject;
    NSArray<NSString *> *statusParts = [statusLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *filteredParts = [NSMutableArray array];
    for (NSString *component in statusParts) {
        if (component.length > 0) {
            [filteredParts addObject:component];
        }
    }

    if (filteredParts.count < 2) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP status line"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSInteger localStatus = [filteredParts[1] integerValue];
    if (localStatus <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP status code"}];
        }
        return HttpdnsHTTPHeaderParseResultError;
    }

    NSMutableDictionary<NSString *, NSString *> *headerDict = [NSMutableDictionary dictionary];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger idx = 1; idx < lines.count; idx++) {
        NSString *line = lines[idx];
        if (line.length == 0) {
            continue;
        }
        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:trimSet];
        NSString *value = [[line substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:trimSet];
        if (key.length > 0) {
            headerDict[[key lowercaseString]] = value ?: @"";
        }
    }

    if (statusCode) {
        *statusCode = localStatus;
    }
    if (headers) {
        *headers = [headerDict copy];
    }
    return HttpdnsHTTPHeaderParseResultSuccess;
}

- (HttpdnsHTTPChunkParseResult)checkChunkedBodyCompletionInData:(NSData *)data
                                                 headerEndIndex:(NSUInteger)headerEndIndex
                                                         error:(NSError **)error {
    if (!data || headerEndIndex == NSNotFound) {
        return HttpdnsHTTPChunkParseResultIncomplete;
    }

    NSUInteger length = data.length;
    NSUInteger cursor = headerEndIndex + 4;
    if (cursor > length) {
        return HttpdnsHTTPChunkParseResultIncomplete;
    }

    const uint8_t *bytes = data.bytes;
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    while (cursor < length) {
        NSUInteger lineEnd = cursor;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }

        NSData *sizeData = [data subdataWithRange:NSMakeRange(cursor, lineEnd - cursor)];
        NSString *sizeString = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
        if (![HttpdnsUtil isNotEmptyString:sizeString]) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        NSString *trimmed = [[sizeString componentsSeparatedByString:@";"] firstObject];
        trimmed = [trimmed stringByTrimmingCharactersInSet:trimSet];
        char *endPtr = NULL;
        unsigned long long chunkSize = strtoull(trimmed.UTF8String, &endPtr, 16);
        if (endPtr == NULL || endPtr == trimmed.UTF8String) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        if (chunkSize > NSUIntegerMax - cursor) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Chunk size overflow"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }

        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            NSUInteger trailerCursor = cursor;
            while (YES) {
                if (trailerCursor + 1 >= length) {
                    return HttpdnsHTTPChunkParseResultIncomplete;
                }
                NSUInteger trailerLineEnd = trailerCursor;
                while (trailerLineEnd + 1 < length && !(bytes[trailerLineEnd] == '\r' && bytes[trailerLineEnd + 1] == '\n')) {
                    trailerLineEnd++;
                }
                if (trailerLineEnd + 1 >= length) {
                    return HttpdnsHTTPChunkParseResultIncomplete;
                }
                if (trailerLineEnd == trailerCursor) {
                    return HttpdnsHTTPChunkParseResultSuccess;
                }
                trailerCursor = trailerLineEnd + 2;
            }
        }

        if (cursor + (NSUInteger)chunkSize > length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }
        cursor += (NSUInteger)chunkSize;
        if (cursor + 1 >= length) {
            return HttpdnsHTTPChunkParseResultIncomplete;
        }
        if (bytes[cursor] != '\r' || bytes[cursor + 1] != '\n') {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk terminator"}];
            }
            return HttpdnsHTTPChunkParseResultError;
        }
        cursor += 2;
    }

    return HttpdnsHTTPChunkParseResultIncomplete;
}

- (BOOL)parseHTTPResponseData:(NSData *)data
                   statusCode:(NSInteger *)statusCode
                      headers:(NSDictionary<NSString *, NSString *> *__autoreleasing *)headers
                         body:(NSData *__autoreleasing *)body
                        error:(NSError **)error {
    if (!data || data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                         code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty HTTP response"}];
        }
        return NO;
    }

    NSUInteger headerEnd = NSNotFound;
    NSInteger localStatus = 0;
    NSDictionary<NSString *, NSString *> *headerDict = nil;
    NSError *headerError = nil;
    HttpdnsHTTPHeaderParseResult headerResult = [self tryParseHTTPHeadersInData:data
                                                                headerEndIndex:&headerEnd
                                                                    statusCode:&localStatus
                                                                       headers:&headerDict
                                                                         error:&headerError];
    if (headerResult != HttpdnsHTTPHeaderParseResultSuccess) {
        if (error) {
            if (headerResult == HttpdnsHTTPHeaderParseResultIncomplete) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing HTTP header terminator"}];
            } else {
                *error = headerError;
            }
        }
        return NO;
    }

    NSUInteger bodyStart = headerEnd + 4;
    NSData *bodyData = bodyStart <= data.length ? [data subdataWithRange:NSMakeRange(bodyStart, data.length - bodyStart)] : [NSData data];

    NSString *transferEncoding = headerDict[@"transfer-encoding"];
    if ([HttpdnsUtil isNotEmptyString:transferEncoding] && [transferEncoding rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSError *chunkError = nil;
        NSData *decoded = [self decodeChunkedBody:bodyData error:&chunkError];
        if (!decoded) {
            HttpdnsLogDebug("Chunked decode failed, fallback to raw body, error: %@", chunkError);
            decoded = bodyData;
        }
        bodyData = decoded;
    } else {
        NSString *contentLengthValue = headerDict[@"content-length"];
        if ([HttpdnsUtil isNotEmptyString:contentLengthValue]) {
            long long expected = [contentLengthValue longLongValue];
            if (expected >= 0 && (NSUInteger)expected != bodyData.length) {
                HttpdnsLogDebug("Content-Length mismatch, expected: %lld, actual: %lu", expected, (unsigned long)bodyData.length);
            }
        }
    }

    if (statusCode) {
        *statusCode = localStatus;
    }
    if (headers) {
        *headers = headerDict ?: @{};
    }
    if (body) {
        *body = bodyData;
    }
    return YES;
}

- (NSData *)decodeChunkedBody:(NSData *)bodyData error:(NSError **)error {
    if (!bodyData) {
        return [NSData data];
    }

    const uint8_t *bytes = bodyData.bytes;
    NSUInteger length = bodyData.length;
    NSUInteger cursor = 0;
    NSMutableData *decoded = [NSMutableData data];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    while (cursor < length) {
        NSUInteger lineEnd = cursor;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunked encoding"}];
            }
            return nil;
        }

        NSData *sizeData = [bodyData subdataWithRange:NSMakeRange(cursor, lineEnd - cursor)];
        NSString *sizeString = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
        if (![HttpdnsUtil isNotEmptyString:sizeString]) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk size"}];
            }
            return nil;
        }
        NSString *trimmed = [[sizeString componentsSeparatedByString:@";"] firstObject];
        trimmed = [trimmed stringByTrimmingCharactersInSet:trimSet];
        unsigned long chunkSize = strtoul(trimmed.UTF8String, NULL, 16);
        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            if (cursor + 1 < length) {
                cursor += 2;
            }
            break;
        }
        if (cursor + chunkSize > length) {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Chunk size exceeds buffer"}];
            }
            return nil;
        }
        [decoded appendBytes:bytes + cursor length:chunkSize];
        cursor += chunkSize;
        if (cursor + 1 >= length || bytes[cursor] != '\r' || bytes[cursor + 1] != '\n') {
            if (error) {
                *error = [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                                             code:ALICLOUD_HTTP_PARSE_JSON_FAILED
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid chunk terminator"}];
            }
            return nil;
        }
        cursor += 2;
    }

    return decoded;
}

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forDomain:(NSString *)domain {
    NSMutableArray *policies = [NSMutableArray array];
    if (domain) {
        [policies addObject:(__bridge_transfer id) SecPolicyCreateSSL(true, (__bridge CFStringRef) domain)];
    } else {
        [policies addObject:(__bridge_transfer id) SecPolicyCreateBasicX509()];
    }
    SecTrustSetPolicies(serverTrust, (__bridge CFArrayRef) policies);
    SecTrustResultType result;
    SecTrustEvaluate(serverTrust, &result);
    if (result == kSecTrustResultRecoverableTrustFailure) {
        CFDataRef errDataRef = SecTrustCopyExceptions(serverTrust);
        SecTrustSetExceptions(serverTrust, errDataRef);
        SecTrustEvaluate(serverTrust, &result);
    }
    return (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
}

+ (NSError *)errorFromNWError:(nw_error_t)nwError description:(NSString *)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if ([HttpdnsUtil isNotEmptyString:description]) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (nwError) {
        CFErrorRef cfError = nw_error_copy_cf_error(nwError);
        if (cfError) {
            NSError *underlyingError = CFBridgingRelease(cfError);
            if (underlyingError) {
                userInfo[NSUnderlyingErrorKey] = underlyingError;
                if (!userInfo[NSLocalizedDescriptionKey] && underlyingError.localizedDescription) {
                    userInfo[NSLocalizedDescriptionKey] = underlyingError.localizedDescription;
                }
            }
        }
    }
    if (!userInfo[NSLocalizedDescriptionKey]) {
        userInfo[NSLocalizedDescriptionKey] = @"Network operation failed";
    }
    return [NSError errorWithDomain:ALICLOUD_HTTPDNS_ERROR_DOMAIN
                               code:ALICLOUD_HTTPDNS_HTTPS_COMMON_ERROR_CODE
                           userInfo:userInfo];
}

@end
