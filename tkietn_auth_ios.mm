/**
 * ============================================================================
 * 🍏 TKIETN-AUTH VIP iOS NATIVE SDK & LUXURY OVERLAY GATEWAY
 * ============================================================================
 * Version: 3.0 - LUXURY DARK MARBLE WEBOVERLAY + ZKV AUTH EDITION
 * - Server: http://zkvauth.site/verify.php (Dashboard tkietn)
 * - Tích hợp Luxury Overlay UI (WKWebView + Pass-through UIWindow)
 * - Tự động nạp Crackbydipper.dylib khi đăng nhập thành công
 * - Anti-debug: ptrace + Frida detection + watchdog
 * ============================================================================
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>
#import <WebKit/WebKit.h>
#import <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
typedef int (*ptrace_ptr_t)(int _request, pid_t _pid, void *_addr, int _data);

// ==========================================
// STRING OBFUSCATION
// ==========================================
// http://zkvauth.site/verify.php -> XOR 0x55
#define TKIETN_SERVER_RAW  \
    { 0x3D, 0x21, 0x21, 0x25, 0x6F, 0x7A, 0x7A, 0x2F, 0x3E, 0x23, 0x34, 0x20, 0x21, 0x3D, 0x7B, 0x26, 0x3C, 0x21, 0x30, 0x7A, 0x23, 0x30, 0x27, 0x3C, 0x33, 0x2C, 0x7B, 0x25, 0x3D, 0x25 }
// tkietn -> XOR 0x55
#define TKIETN_OWNER_RAW   \
    { 0x21, 0x3E, 0x3C, 0x30, 0x21, 0x3B }
// tkietn -> XOR 0x55
#define TKIETN_API_RAW     \
    { 0x21, 0x3E, 0x3C, 0x30, 0x21, 0x3B }

static inline NSString* tkietn_deobf(const uint8_t *enc, int len) {
    char *buf = (char *)malloc(len + 1);
    for (int i = 0; i < len; i++) buf[i] = enc[i] ^ 0x55;
    buf[len] = 0;
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

@interface TkietnAuthResult : NSObject
@property (nonatomic, assign) BOOL success;
@property (nonatomic, strong) NSString *message;
@property (nonatomic, strong) NSString *expiryDate;
@property (nonatomic, assign) NSInteger remainingDays;
@end

@implementation TkietnAuthResult
@end

@interface TkietnAuthSessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation TkietnAuthSessionDelegate
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [[NSURLCredential alloc] initWithTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end

// ==========================================
// PASS-THROUGH UIWINDOW (TOUCH CHO GAME)
// ==========================================
@interface TkietnPassThroughWindow : UIWindow
@property (nonatomic, assign) BOOL isMenuVisible;
@property (nonatomic, weak) UIView *webViewRef;
@end

@implementation TkietnPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!self.isMenuVisible) {
        // Khi menu đang đóng, chỉ cho chạm vào nút trigger nổi, còn lại truyền hết xuống Free Fire
        if (hitView == self.webViewRef) {
            return nil;
        }
    }
    return hitView;
}
@end

@interface TkietnAuthIOS : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) TkietnPassThroughWindow *overlayWindow;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL isMenuVisible;

+ (instancetype)sharedInstance;
+ (NSString *)getDeviceHWID;
+ (void)verifyLicense:(NSString *)licenseKey completion:(void(^)(TkietnAuthResult *result))completion;
+ (void)startWatchdog;
+ (void)unlockAndLoadModMenus;
+ (void)showLuxuryOverlay;
@end

@implementation TkietnAuthIOS

+ (instancetype)sharedInstance {
    static TkietnAuthIOS *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TkietnAuthIOS alloc] init];
    });
    return instance;
}

// 1. MỞ KHÓA VÀ NẠP MOD DYLIB VÀO PROCESS
+ (void)unlockAndLoadModMenus {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[+] TKIETN: Unlocking and activating mod menus...");
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

        // Nạp tất cả mod dylibs có trong game: Crackbydipper, VanNam, EreenModz
        const char *mods[] = { "Crackbydipper.dylib", "VanNam.dylib", "EreenModz.dylib" };
        for (int i = 0; i < 3; i++) {
            NSString *dylibPath = [bundlePath stringByAppendingPathComponent:[NSString stringWithUTF8String:mods[i]]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
                void *handle = dlopen([dylibPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
                if (handle) {
                    NSLog(@"[+] TKIETN: Activated %s successfully!", mods[i]);
                } else {
                    NSLog(@"[-] TKIETN: dlopen error for %s: %s", mods[i], dlerror());
                }
            } else {
                NSLog(@"[-] TKIETN: File not found in bundle: %@", dylibPath);
            }
        }
    });
}

// 2. LẤY MÃ PHẦN CỨNG THIẾT BỊ (HWID)
+ (NSString *)getDeviceHWID {
    NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (idfv && idfv.length > 5) { return idfv; }

    NSString *keychainKey = @"com.tkietn.auth.hwid";
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: keychainKey,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef dataTypeRef = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef) == errSecSuccess) {
        NSData *data = (__bridge_transfer NSData *)dataTypeRef;
        NSString *savedUUID = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (savedUUID && savedUUID.length > 5) return savedUUID;
    }

    NSString *newUUID = [[NSUUID UUID] UUIDString];
    NSData *uuidData = [newUUID dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: keychainKey,
        (__bridge id)kSecValueData: uuidData
    };
    SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    return newUUID;
}

// 3. CHỐNG DEBUGGER + WATCHDOG
+ (void)startWatchdog {
    void *h = dlopen(NULL, RTLD_GLOBAL | RTLD_NOW);
    if (h) {
        ptrace_ptr_t ptrace_func = (ptrace_ptr_t)dlsym(h, "ptrace");
        if (ptrace_func) ptrace_func(PT_DENY_ATTACH, 0, 0, 0);
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        while (1) {
            int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
            struct kinfo_proc info;
            size_t info_size = sizeof(info);
            info.kp_proc.p_flag = 0;
            sysctl(name, 4, &info, &info_size, NULL, 0);
            if ((info.kp_proc.p_flag & P_TRACED) != 0) {
                exit(0);
            }

            int sock = socket(AF_INET, SOCK_STREAM, 0);
            if (sock >= 0) {
                struct sockaddr_in addr;
                memset(&addr, 0, sizeof(addr));
                addr.sin_family = AF_INET;
                addr.sin_port = htons(27042);
                addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                int connected = connect(sock, (struct sockaddr*)&addr, sizeof(addr));
                close(sock);
                if (connected == 0) {
                    NSLog(@"[!] TKIETN: Frida detected! Terminating...");
                    exit(0);
                }
            }
            [NSThread sleepForTimeInterval:4.0];
        }
    });
}

// 4. XÁC THỰC LICENSE KEY VỚI ZKV AUTH SERVER
+ (void)verifyLicense:(NSString *)licenseKey completion:(void(^)(TkietnAuthResult *result))completion {
    NSString *cleanKey = [licenseKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *hwid = [self getDeviceHWID];

    // Master Key check cho Owner @tkietn
    NSArray *masters = @[@"tkietn", @"@tkietn", @"admin", @"MASTER", @"TKIE-TN", @"tkietnn", @"TKIETN-VIP-2026"];
    if ([masters containsObject:cleanKey] || [cleanKey.uppercaseString isEqualToString:@"TKIETN"]) {
        TkietnAuthResult *res = [[TkietnAuthResult alloc] init];
        res.success = YES;
        res.message = @"Xác thực Master Key thành công! Chào mừng Đại ca tkietn.";
        res.expiryDate = @"Vĩnh viễn (Master Lifetime)";
        res.remainingDays = 9999;
        completion(res);
        return;
    }

    const uint8_t serverEnc[] = TKIETN_SERVER_RAW;
    const uint8_t ownerEnc[]  = TKIETN_OWNER_RAW;
    const uint8_t apiEnc[]    = TKIETN_API_RAW;
    NSString *serverURL = tkietn_deobf(serverEnc, sizeof(serverEnc));
    NSString *ownerName = tkietn_deobf(ownerEnc, sizeof(ownerEnc));
    NSString *apiName   = tkietn_deobf(apiEnc, sizeof(apiEnc));

    NSURLComponents *components = [NSURLComponents componentsWithString:serverURL];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"owner" value:ownerName],
        [NSURLQueryItem queryItemWithName:@"api"   value:apiName],
        [NSURLQueryItem queryItemWithName:@"key"   value:cleanKey],
        [NSURLQueryItem queryItemWithName:@"hwid"  value:hwid]
    ];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setHTTPMethod:@"GET"];
    [request setTimeoutInterval:8.0];
    [request setValue:@"ZkvAuth-iOS/2.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    TkietnAuthSessionDelegate *del = [[TkietnAuthSessionDelegate alloc] init];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:del delegateQueue:nil];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        TkietnAuthResult *res = [[TkietnAuthResult alloc] init];
        if (error || !data) {
            res.success = NO;
            res.message = [NSString stringWithFormat:@"Không thể kết nối Server (%@)", error.localizedDescription ?: @"Timeout"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(res); });
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || !json) {
            res.success = NO;
            res.message = @"Server phản hồi dữ liệu lỗi!";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(res); });
            return;
        }

        res.success = [json[@"valid"] boolValue] || [json[@"success"] boolValue];
        res.message = json[@"message"] ?: (res.success ? @"Kích hoạt thành công!" : @"Key không hợp lệ!");
        
        id expObj = json[@"expiry"];
        if ([expObj isKindOfClass:[NSNumber class]]) {
            long long expTs = [expObj longLongValue];
            if (expTs == 0) {
                res.expiryDate = @"Vĩnh Viễn (Lifetime)";
            } else {
                NSDate *d = [NSDate dateWithTimeIntervalSince1970:expTs];
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                [df setDateFormat:@"dd/MM/yyyy"];
                res.expiryDate = [df stringFromDate:d];
            }
        } else {
            res.expiryDate = json[@"expiry"] ?: @"Vĩnh Viễn";
        }
        res.remainingDays = [json[@"days_left"] integerValue];

        dispatch_async(dispatch_get_main_queue(), ^{ completion(res); });
    }] resume];
}

// 5. HIỂN THỊ GIAO DIỆN LUXURY OVERLAY TRONG GAME
+ (void)showLuxuryOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        TkietnAuthIOS *selfInstance = [TkietnAuthIOS sharedInstance];
        if (selfInstance.overlayWindow) return; // Đã khởi tạo

        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;

        selfInstance.overlayWindow = [[TkietnPassThroughWindow alloc] initWithFrame:bounds];
        selfInstance.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
        selfInstance.overlayWindow.backgroundColor = [UIColor clearColor];
        selfInstance.overlayWindow.hidden = NO;
        selfInstance.isMenuVisible = YES;
        selfInstance.overlayWindow.isMenuVisible = YES;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        selfInstance.overlayWindow.rootViewController = rootVC;

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        WKUserContentController *contentController = [[WKUserContentController alloc] init];
        [contentController addScriptMessageHandler:selfInstance name:@"tkietnHandler"];
        config.userContentController = contentController;
        [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];

        selfInstance.webView = [[WKWebView alloc] initWithFrame:bounds configuration:config];
        selfInstance.webView.navigationDelegate = selfInstance;
        selfInstance.webView.opaque = NO;
        selfInstance.webView.backgroundColor = [UIColor clearColor];
        selfInstance.webView.scrollView.backgroundColor = [UIColor clearColor];
        selfInstance.webView.scrollView.bounces = NO;
        selfInstance.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        selfInstance.overlayWindow.webViewRef = selfInstance.webView;

        [rootVC.view addSubview:selfInstance.webView];

        // Đường dẫn file menu HTML đóng gói sẵn trong IPA
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString *htmlPath = [bundlePath stringByAppendingPathComponent:@"tkietn_menu/index.html"];

        if ([[NSFileManager defaultManager] fileExistsAtPath:htmlPath]) {
            NSURL *htmlURL = [NSURL fileURLWithPath:htmlPath];
            NSURL *baseURL = [htmlURL URLByDeletingLastPathComponent];
            [selfInstance.webView loadFileURL:htmlURL allowingReadAccessToURL:baseURL];
            NSLog(@"[+] TKIETN: Loaded luxury menu from bundle: %@", htmlPath);
        } else {
            NSLog(@"[-] TKIETN: WARNING: tkietn_menu/index.html not found in bundle!");
        }
    });
}

// Handler nhận tin nhắn từ JavaScript Menu
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"tkietnHandler"]) {
        NSDictionary *dict = (NSDictionary *)message.body;
        NSString *action = dict[@"action"];
        id data = dict[@"data"];

        NSLog(@"[TkietnBridge IN]: %@ -> %@", action, data);

        if ([action isEqualToString:@"AUTH_VALIDATE"]) {
            NSString *key = data[@"key"] ?: @"";
            [TkietnAuthIOS verifyLicense:key completion:^(TkietnAuthResult *result) {
                if (result.success) {
                    [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"TKIETN_AUTH_SAVED_KEY"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    [TkietnAuthIOS unlockAndLoadModMenus];
                }

                NSDictionary *res = @{
                    @"success": @(result.success),
                    @"message": result.message ?: @"",
                    @"info": @{
                        @"username": @"Admin",
                        @"expiry": result.expiryDate ?: @"Vĩnh Viễn",
                        @"rank": @"VIP Owner"
                    }
                };
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:res options:0 error:nil];
                NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                NSString *jsCode = [NSString stringWithFormat:@"window.tkietnAuth.onNativeAuthResult(%@);", jsonStr];
                [self.webView evaluateJavaScript:jsCode completionHandler:nil];
            }];
        } else if ([action isEqualToString:@"MENU_VISIBILITY"]) {
            self.isMenuVisible = [data[@"visible"] boolValue];
            self.overlayWindow.isMenuVisible = self.isMenuVisible;
        }
    }
}

@end

// ==========================================
// TỰ ĐỘNG CHẠY KHI DYLIB ĐƯỢC LOAD VÀO GAME
// ==========================================
__attribute__((constructor)) static void TkietnAuthAutoInit() {
    NSLog(@"[+] TkietnAuth v3.0 loaded into game process. Starting security & overlay...");
    [TkietnAuthIOS startWatchdog];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Hiển thị Luxury Web Overlay
        [TkietnAuthIOS showLuxuryOverlay];

        // Tự động kiểm tra Key cũ đã lưu
        NSString *savedKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"TKIETN_AUTH_SAVED_KEY"];
        if (savedKey && savedKey.length > 3) {
            [TkietnAuthIOS verifyLicense:savedKey completion:^(TkietnAuthResult *result) {
                if (result.success) {
                    NSLog(@"[+] Auto-login success for key: %@", savedKey);
                    [TkietnAuthIOS unlockAndLoadModMenus];
                }
            }];
        }
    });
}
