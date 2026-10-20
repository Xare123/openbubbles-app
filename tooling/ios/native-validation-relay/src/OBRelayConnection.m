#import "OBRelayConnection.h"
#import "OBRelayIdentifiers.h"

NSString *const OBRelayDefaultURLString = @"wss://registration-relay.beeper.com/api/v1/provider";

@interface OBRelayConnection () <NSURLSessionWebSocketDelegate>
@property(nonatomic, strong) OBRelayDispatcher *dispatcher;
@property(nonatomic, strong) OBRelayRegistrationStore *store;
@property(nonatomic, copy) NSURL *url;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@property(nonatomic, strong) dispatch_queue_t sendQueue;
// Everything below is touched only on stateQueue.
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property(nonatomic, strong, nullable) dispatch_source_t pingTimer;
@property(nonatomic) NSUInteger epoch;
@property(nonatomic) BOOL intentConnected;
@property(nonatomic) BOOL registered;
@property(nonatomic) NSInteger backoffSeconds;
@end

@implementation OBRelayConnection
- (instancetype)initWithDispatcher:(OBRelayDispatcher *)dispatcher
                             store:(OBRelayRegistrationStore *)store
                               url:(NSURL *)url {
    if ((self = [super init])) {
        _dispatcher = dispatcher;
        _store = store;
        _url = [url copy];
        _stateQueue = dispatch_queue_create("dev.openbubbles.relay.connection-state", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("dev.openbubbles.relay.send", DISPATCH_QUEUE_SERIAL);
        _backoffSeconds = 2;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        _session = [NSURLSession sessionWithConfiguration:configuration
            delegate:self delegateQueue:NSOperationQueue.mainQueue];
    }
    return self;
}

- (void)emitStatus:(NSString *)status {
    void (^handler)(NSString *) = self.statusHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(status); });
}

- (void)emitCode:(NSString *)code {
    void (^handler)(NSString *) = self.codeHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(code); });
}

#pragma mark - Public intent (any queue in, state queue owns the work)

- (void)connect {
    dispatch_async(self.stateQueue, ^{
        self.intentConnected = YES;
        self.backoffSeconds = 2;
        [self openSocketOnStateQueue];
    });
}

- (void)disconnect {
    dispatch_async(self.stateQueue, ^{
        self.intentConnected = NO;
        [self teardownOnStateQueue];
        [self emitStatus:@"disconnected"];
    });
}

#pragma mark - State queue only below, unless a method says otherwise

- (void)teardownOnStateQueue {
    [self.dispatcher invalidatePendingRequest];
    if (self.pingTimer) {
        dispatch_source_cancel(self.pingTimer);
        self.pingTimer = nil;
    }
    NSURLSessionWebSocketTask *old = self.task;
    self.task = nil;
    self.epoch += 1;
    self.registered = NO;
    // Actively close the replaced socket; never leave it to linger in
    // parallel with its replacement.
    [old cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
}

- (void)openSocketOnStateQueue {
    if (!self.intentConnected || self.task) return;
    [self emitStatus:@"connecting"];
    self.epoch += 1;
    NSURLSessionWebSocketTask *task = [self.session webSocketTaskWithURL:self.url];
    self.task = task;
    [task resume];
    [self receiveOnTask:task];
    [self startPingOnStateQueue];
}

- (void)scheduleReconnectOnStateQueue {
    [self teardownOnStateQueue];
    if (!self.intentConnected) return;
    [self emitStatus:@"reconnecting"];
    NSInteger delay = self.backoffSeconds;
    self.backoffSeconds = MIN(self.backoffSeconds * 2, 64);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * (long long)NSEC_PER_SEC),
        self.stateQueue, ^{ [self openSocketOnStateQueue]; });
}

- (void)startPingOnStateQueue {
    if (self.pingTimer) dispatch_source_cancel(self.pingTimer);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * (long long)NSEC_PER_SEC),
        30 * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        NSURLSessionWebSocketTask *task = weakSelf.task;
        if (task) [weakSelf sendText:@"{\"command\":\"ping\"}" onTask:task];
    });
    self.pingTimer = timer;
    dispatch_resume(timer);
}

// Sends are serialized and always target the captured task, never whatever
// task happens to be current when an asynchronous caller resumes.
- (void)sendText:(NSString *)text onTask:(NSURLSessionWebSocketTask *)task {
    if (!task || !text.length) return;
    dispatch_async(self.sendQueue, ^{
        [task sendMessage:[NSURLSessionWebSocketMessage.alloc initWithString:text]
            completionHandler:^(NSError *error) {
                if (!error) return;
                dispatch_async(self.stateQueue, ^{
                    if (self.task == task) [self scheduleReconnectOnStateQueue];
                });
            }];
    });
}

- (void)sendRegistrationOnStateQueue {
    NSDictionary *message = @{@"command": @"register",
        @"data": [self.store registerDataWithHardwareModel:OBRelayIdentifiers.hardwareModel]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:message
        options:NSJSONWritingSortedKeys error:NULL];
    if (!json.length) return;
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (text) [self sendText:text onTask:self.task];
}

- (void)receiveOnTask:(NSURLSessionWebSocketTask *)task {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            dispatch_async(strongSelf.stateQueue, ^{
                if (strongSelf.task == task) [strongSelf scheduleReconnectOnStateQueue];
            });
            return;
        }
        // This completion runs on the session delegate queue (main), which
        // is where device identifiers are read before the state hop.
        if (message.type == NSURLSessionWebSocketMessageTypeString)
            [strongSelf handleText:message.string fromTask:task];
        [strongSelf receiveOnTask:task];
    }];
}

- (void)handleText:(NSString *)text fromTask:(NSURLSessionWebSocketTask *)task {
    id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
        options:0 error:NULL];
    if (![parsed isKindOfClass:NSDictionary.class]) return;
    NSDictionary *envelope = parsed;
    id command = envelope[@"command"];
    NSDictionary *identifiers = [command isEqual:@"get-version-info"]
        ? [OBRelayIdentifiers versionIdentifiers] : @{};
    dispatch_async(self.stateQueue, ^{
        if (self.task != task) return;
        if (!self.registered) {
            [self handleRegistrationEnvelope:envelope];
            return;
        }
        if (![command isKindOfClass:NSString.class]) return;
        if ([command isEqualToString:@"pong"]) return;
        NSUInteger epoch = self.epoch;
        NSURLSessionWebSocketTask *boundTask = self.task;
        __weak typeof(self) weakSelf = self;
        // The reply is bound to this exact task and epoch. The connection
        // revalidates both on the state queue at send time, so a late
        // completion from a replaced socket can only be dropped.
        OBRelayReply reply = ^(NSString *responseText) {
            typeof(self) owner = weakSelf;
            if (!owner) return;
            dispatch_async(owner.stateQueue, ^{
                if (owner.registered && owner.epoch == epoch && owner.task == boundTask)
                    [owner sendText:responseText onTask:boundTask];
            });
        };
        [self.dispatcher handleCommand:command requestID:envelope[@"id"]
            identifiers:identifiers reply:reply];
    });
}

- (void)handleRegistrationEnvelope:(NSDictionary *)envelope {
    id data = envelope[@"data"];
    if ([data isKindOfClass:NSDictionary.class] && [data[@"error"] isKindOfClass:NSString.class]) {
        self.intentConnected = NO;
        [self teardownOnStateQueue];
        [self emitStatus:@"registration-rejected"];
        return;
    }
    NSString *code = [self.store acceptRegistrationData:data];
    if (!code) return;
    self.registered = YES;
    self.backoffSeconds = 2;
    [self emitStatus:@"registered"];
    [self emitCode:code];
}

#pragma mark - NSURLSessionWebSocketDelegate (main queue, hops to state queue)

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didOpenWithProtocol:(NSString *)protocol {
    (void)session; (void)protocol;
    dispatch_async(self.stateQueue, ^{
        if (self.task == task) [self sendRegistrationOnStateQueue];
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    (void)session; (void)closeCode; (void)reason;
    dispatch_async(self.stateQueue, ^{
        if (self.task == task) [self scheduleReconnectOnStateQueue];
    });
}
@end
