// Minimal operator surface: connection status and the registration code.
// There are no account fields and proofs are never displayed.
#import "OBRelayViewController.h"
#import "OBNACValidator.h"
#import "OBNativeNACValidator.h"
#import "OBRelayConnection.h"
#import "OBRelayDispatcher.h"
#import "OBRelayGenerators.h"
#import "OBRelayRegistrationStore.h"

@interface OBRelayViewController ()
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *codeLabel;
@property(nonatomic, strong) UIButton *toggleButton;
@property(nonatomic, strong) OBRelayConnection *connection;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL resumeWhenActive;
@end

@implementation OBRelayViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.text = @"OB Native Relay (private test)";
    title.font = [UIFont boldSystemFontOfSize:20];
    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"disconnected";
    self.codeLabel = [UILabel new];
    self.codeLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
    self.codeLabel.numberOfLines = 0;
    self.codeLabel.text = @"No registration code yet";
    UILabel *note = [UILabel new];
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:13];
    note.text = @"Keep this app in the foreground. A relay connection alone "
        @"does not confirm Apple sign-in. This private test supplies separate "
        @"device validation and native account authentication. No Apple Account "
        @"password is entered or stored here.";
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.toggleButton setTitle:@"Connect" forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(toggleConnection)
        forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, self.statusLabel, self.codeLabel, self.toggleButton, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
    ]];

    NSURL *url = [NSURL URLWithString:OBRelayDefaultURLString];
    OBRelayDispatcher *dispatcher = [[OBRelayDispatcher alloc]
        initWithHeaderGenerator:[OBRelayHeaderGenerator new]
            qualifierGenerator:[OBRelayEmptyQualifierGenerator new]
                       validator:[OBNativeNACValidator new]];
    dispatcher.nativePushEnabled=YES;
    OBRelayRegistrationStore *store = [[OBRelayRegistrationStore alloc] initWithRelayURL:url];
    if (store.hasSavedRegistration) self.codeLabel.text = store.code;
    self.connection = [[OBRelayConnection alloc] initWithDispatcher:dispatcher store:store url:url];
    __weak typeof(self) weakSelf = self;
    self.connection.statusHandler = ^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.text = status;
            weakSelf.connected = [status isEqualToString:@"registered"]
                || [status isEqualToString:@"connecting"]
                || [status isEqualToString:@"reconnecting"];
            UIApplication.sharedApplication.idleTimerDisabled = weakSelf.connected;
            [weakSelf.toggleButton setTitle:weakSelf.connected ? @"Disconnect" : @"Connect"
                forState:UIControlStateNormal];
        });
    };
    self.connection.codeHandler = ^(NSString *code) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.codeLabel.text = code; });
    };
    [self.connection connect];
    self.connected = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
}

- (void)toggleConnection {
    if (self.connected) {
        [self.connection disconnect];
        self.connected = NO;
    } else {
        [self.connection connect];
        self.connected = YES;
    }
}

- (void)relayDidEnterBackground {
    self.resumeWhenActive = self.connected;
    [self.connection disconnect];
    self.connected = NO;
    UIApplication.sharedApplication.idleTimerDisabled = NO;
}

- (void)relayDidBecomeActive {
    if (self.resumeWhenActive) {
        self.resumeWhenActive = NO;
        [self.connection connect];
    }
}
@end
