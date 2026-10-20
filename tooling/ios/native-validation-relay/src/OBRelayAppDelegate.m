#import "OBRelayAppDelegate.h"
#import "OBRelayViewController.h"

@implementation OBRelayAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [OBRelayViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    [(OBRelayViewController *)self.window.rootViewController relayDidEnterBackground];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [(OBRelayViewController *)self.window.rootViewController relayDidBecomeActive];
}
@end
