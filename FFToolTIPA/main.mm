#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

extern "C" char **environ;
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

extern "C" void GSInitialize(void);
extern "C" void GSEventInitialize(int type);
extern "C" void GSEventPushRunLoopMode(CFStringRef mode);
extern "C" void BKSDisplayServicesStart(void);
extern "C" void UIApplicationInitialize(void);
extern "C" void UIApplicationInstantiateSingleton(id applicationClass);
extern "C" CFStringRef SBSCopyFrontmostApplicationDisplayIdentifier(void);

static NSSet<NSString *> *FFGameBundleIDs(void) {
    static NSSet<NSString *> *ids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ids = [NSSet setWithArray:@[
            @"vn.vng.freefireth",
            @"com.dts.freefireth",
            @"com.dts.freefiremax",
            @"com.garena.game.ffi"
        ]];
    });
    return ids;
}

static void FFAppendHUDLog(NSString *category, NSString *message);

static NSString *gFFFrontmostSource = @"unknown";

typedef NSUInteger (*FFBKSStateFunction)(id, SEL, id);
typedef void (*FFBKSInvalidateFunction)(id, SEL);

static NSString *FFCurrentFrontmostBundleID(void) {
    // SpringBoardServices may return NULL from external processes on iOS 15+.
    // Use it on older systems; on newer systems query BackBoard app state.
    if (@available(iOS 15.0, *)) {
        gFFFrontmostSource = @"BackBoard";
    } else {
        CFStringRef identifier = SBSCopyFrontmostApplicationDisplayIdentifier();
        if (identifier) {
            NSString *bundleID = [((__bridge NSString *)identifier) copy];
            CFRelease(identifier);
            gFFFrontmostSource = @"SpringBoardServices";
            return bundleID;
        }
        gFFFrontmostSource = @"SpringBoardServices(NULL)";
        FFAppendHUDLog(@"FRONTMOST", @"SBSCopyFrontmostApplicationDisplayIdentifier returned NULL; trying BackBoard");
    }

    Class monitorClass = NSClassFromString(@"BKSApplicationStateMonitor");
    if (!monitorClass) {
        gFFFrontmostSource = @"BackBoard(class_missing)";
        FFAppendHUDLog(@"BACKBOARD_ERROR", @"BKSApplicationStateMonitor class not found");
        return @"<backboard-class-missing>";
    }

    id monitor = [[monitorClass alloc] init];
    SEL stateSelector = NSSelectorFromString(@"applicationStateForApplication:");
    SEL invalidateSelector = NSSelectorFromString(@"invalidate");
    if (!monitor || ![monitor respondsToSelector:stateSelector]) {
        gFFFrontmostSource = @"BackBoard(selector_missing)";
        FFAppendHUDLog(@"BACKBOARD_ERROR", @"BKSApplicationStateMonitor does not respond to applicationStateForApplication:");
        return @"<backboard-selector-missing>";
    }

    static NSDictionary<NSString *, NSNumber *> *lastStates = nil;
    NSMutableDictionary<NSString *, NSNumber *> *currentStates = [NSMutableDictionary dictionary];
    NSString *matchedBundleID = nil;
    NSArray<NSString *> *candidates = @[
        @"vn.vng.freefireth",
        @"com.dts.freefireth",
        @"com.dts.freefiremax",
        @"com.garena.game.ffi"
    ];

    @try {
        FFBKSStateFunction stateFunction = (FFBKSStateFunction)objc_msgSend;
        for (NSString *candidate in candidates) {
            NSUInteger state = stateFunction(monitor, stateSelector, candidate);
            BOOL foreground = (state & (1UL << 3)) != 0; // BKS foreground-running bit
            currentStates[candidate] = @(state);

            NSNumber *oldState = lastStates[candidate];
            if (!oldState || oldState.unsignedIntegerValue != state) {
                FFAppendHUDLog(@"BACKBOARD_STATE", [NSString stringWithFormat:
                    @"bundle_id=%@ | state=%lu | foreground_running=%@",
                    candidate, (unsigned long)state, foreground ? @"YES" : @"NO"]);
            }
            if (foreground && !matchedBundleID) matchedBundleID = candidate;
        }

        lastStates = [currentStates copy];
        if ([monitor respondsToSelector:invalidateSelector]) {
            ((FFBKSInvalidateFunction)objc_msgSend)(monitor, invalidateSelector);
        }
    } @catch (NSException *exception) {
        gFFFrontmostSource = @"BackBoard(exception)";
        NSString *reason = [NSString stringWithFormat:@"BKS state query exception | %@ | %@",
                            exception.name ?: @"unknown", exception.reason ?: @"(none)"];
        FFAppendHUDLog(@"BACKBOARD_ERROR", reason);
        return @"<backboard-query-exception>";
    }

    if (matchedBundleID) {
        FFAppendHUDLog(@"FRONTMOST", [NSString stringWithFormat:@"bundle_id=%@ | source=BackBoard", matchedBundleID]);
        return matchedBundleID;
    }

    return @"<no-freefire-match>";
}

static NSString * const kFFHUDPIDPath = @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud.pid";
static NSString * const kFFHUDStatusPath = @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud-status.plist";
static NSString * const kFFHUDLogPath = @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud.log";
static NSString * const kFFHUDSettingsPath = @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud-settings.plist";
static const CGFloat kFFPurple = 0.68;

static NSDictionary *FFDefaultHUDSettings(void) {
    return @{
        @"fovEnabled": @NO,
        @"fovDiameter": @240,
        @"fovColor": @0,
        @"fovOpacity": @0.88
    };
}

static NSDictionary *FFLoadHUDSettings(void) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:FFDefaultHUDSettings()];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kFFHUDSettingsPath];
    if ([saved isKindOfClass:NSDictionary.class]) [settings addEntriesFromDictionary:saved];
    return settings;
}

static BOOL FFSaveHUDSettings(NSDictionary *settings) {
    NSString *directory = [kFFHUDSettingsPath stringByDeletingLastPathComponent];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) return NO;
    return [settings writeToFile:kFFHUDSettingsPath atomically:YES];
}

static void FFAppendHUDLog(NSString *category, NSString *message) {
    @autoreleasepool {
        static NSDateFormatter *formatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        });

        NSString *line = [NSString stringWithFormat:@"%@ | pid=%d | %@ | %@\n",
                          [formatter stringFromDate:[NSDate date]],
                          getpid(),
                          category ?: @"LOG",
                          message ?: @""];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *directory = [kFFHUDLogPath stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:kFFHUDLogPath error:nil];
        unsigned long long currentSize = [attributes fileSize];
        if (currentSize > 512 * 1024) {
            NSData *existing = [NSData dataWithContentsOfFile:kFFHUDLogPath];
            NSUInteger keepBytes = MIN((NSUInteger)(384 * 1024), existing.length);
            NSData *tail = [existing subdataWithRange:NSMakeRange(existing.length - keepBytes, keepBytes)];
            [tail writeToFile:kFFHUDLogPath atomically:YES];
        }

        @try {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kFFHUDLogPath];
            if (!handle) {
                [NSFileManager.defaultManager createFileAtPath:kFFHUDLogPath contents:[NSData data] attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:kFFHUDLogPath];
            }
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (NSException *exception) {
            NSLog(@"[FFToolHUD] log write failed: %@", exception);
        }
        NSLog(@"[FFToolHUD] %@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    }
}

static NSString *FFReadHUDLogTail(NSUInteger maxLines) {
    NSString *contents = [NSString stringWithContentsOfFile:kFFHUDLogPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (!contents.length) return @"Chưa có nhật ký. Bật HUD để bắt đầu ghi log.";
    NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *line in lines) if (line.length) [valid addObject:line];
    NSUInteger start = valid.count > maxLines ? valid.count - maxLines : 0;
    return [[valid subarrayWithRange:NSMakeRange(start, valid.count - start)] componentsJoinedByString:@"\n"];
}

static void FFClearHUDLog(void) {
    [@"" writeToFile:kFFHUDLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FFAppendHUDLog(@"DASHBOARD", @"Nhật ký đã được xoá theo yêu cầu");
}

static NSDictionary *FFReadHUDStatus(void);

static void FFWriteHUDStatus(NSString *stage, NSString *detail) {
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:FFReadHUDStatus()];
    status[@"stage"] = stage ?: @"unknown";
    status[@"detail"] = detail ?: @"";
    status[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    status[@"pid"] = @(getpid());
    status[@"ios"] = UIDevice.currentDevice.systemVersion ?: @"unknown";
    BOOL saved = [status writeToFile:kFFHUDStatusPath atomically:YES];
    FFAppendHUDLog(@"STATUS", [NSString stringWithFormat:@"%@ | %@ | status_file=%@",
                               stage ?: @"unknown", detail ?: @"", saved ? @"ok" : @"failed"]);
}

static NSDictionary *FFReadHUDStatus(void) {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:kFFHUDStatusPath];
    return [status isKindOfClass:NSDictionary.class] ? status : @{};
}

static void FFClearHUDRuntimeState(void) {
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:FFReadHUDStatus()];
    [status removeObjectForKey:@"frontmostBundleID"];
    [status removeObjectForKey:@"foregroundMatch"];
    [status removeObjectForKey:@"foregroundUpdated"];
    [status writeToFile:kFFHUDStatusPath atomically:YES];
}

static void FFWriteHUDRuntimeState(NSString *bundleID, BOOL foregroundMatch) {
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:FFReadHUDStatus()];
    status[@"frontmostBundleID"] = bundleID ?: @"<unavailable>";
    status[@"foregroundMatch"] = @(foregroundMatch);
    status[@"foregroundSource"] = gFFFrontmostSource ?: @"unknown";
    status[@"foregroundUpdated"] = @([[NSDate date] timeIntervalSince1970]);
    [status writeToFile:kFFHUDStatusPath atomically:YES];
}

static UIColor *FFColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static UIColor *FFAccent(void) { return FFColor(kFFPurple, 0.20, 1.0, 1.0); }
static UIColor *FFCanvas(void) { return FFColor(0.025, 0.016, 0.075, 1.0); }
static UIColor *FFPanel(void) { return FFColor(0.085, 0.047, 0.17, 0.96); }

static UILabel *FFLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    return label;
}

static void FFStyleCard(UIView *view, CGFloat radius) {
    view.backgroundColor = FFPanel();
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = FFColor(0.47, 0.24, 0.86, 0.45).CGColor;
    view.layer.masksToBounds = YES;
}

static NSString *FFBatteryText(void) {
    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    float level = device.batteryLevel;
    if (level < 0.0f) return @"N/A";
    return [NSString stringWithFormat:@"%.0f%%", level * 100.0f];
}

static NSString *FFBatteryStateText(void) {
    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging: return @"Đang sạc";
        case UIDeviceBatteryStateFull: return @"Đã đầy";
        case UIDeviceBatteryStateUnplugged: return @"Không sạc";
        default: return @"Không xác định";
    }
}

static NSString *FFThermalText(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return @"Bình thường";
        case NSProcessInfoThermalStateFair: return @"Ấm";
        case NSProcessInfoThermalStateSerious: return @"Nóng";
        case NSProcessInfoThermalStateCritical: return @"Rất nóng";
        default: return @"Không xác định";
    }
}

static BOOL FFThermalWarning(void) {
    NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
    return state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical;
}

static NSUInteger FFFreeRAMMB(void) {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    host_page_size(host, &pageSize);
    vm_statistics64_data_t stats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || pageSize == 0) return 0;
    uint64_t bytes = (uint64_t)stats.free_count * (uint64_t)pageSize;
    return (NSUInteger)(bytes / (1024ULL * 1024ULL));
}

static NSString *FFUptimeText(void) {
    NSUInteger total = (NSUInteger)MAX(0, NSProcessInfo.processInfo.systemUptime);
    NSUInteger days = total / 86400;
    NSUInteger hours = (total % 86400) / 3600;
    NSUInteger minutes = (total % 3600) / 60;
    if (days) return [NSString stringWithFormat:@"%lud %luh", (unsigned long)days, (unsigned long)hours];
    if (hours) return [NSString stringWithFormat:@"%luh %lum", (unsigned long)hours, (unsigned long)minutes];
    return [NSString stringWithFormat:@"%lum", (unsigned long)minutes];
}

static NSString *FFExecutablePath(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (!size) return nil;
    char *buffer = (char *)calloc(1, size + 1);
    if (!buffer) return nil;
    if (_NSGetExecutablePath(buffer, &size) != 0) {
        free(buffer);
        return nil;
    }
    NSString *result = [NSString stringWithUTF8String:buffer];
    free(buffer);
    return result;
}

static int FFSpawnRootCommand(const char *command, BOOL detach) {
    FFAppendHUDLog(@"SPAWN", [NSString stringWithFormat:@"command=%s | detach=%@", command ?: "(null)", detach ? @"YES" : @"NO"]);
    NSString *path = FFExecutablePath();
    if (!path.length) return ENOENT;

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_set_persona_np(&attributes, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attributes, 0);
    posix_spawnattr_set_persona_gid_np(&attributes, 0);

    if (detach) {
        posix_spawnattr_setpgroup(&attributes, 0);
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    }

    pid_t child = 0;
    const char *arguments[] = { path.UTF8String, command, NULL };
    int result = posix_spawn(&child, path.UTF8String, NULL, &attributes, (char * const *)arguments, environ);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) {
        FFAppendHUDLog(@"SPAWN", [NSString stringWithFormat:@"posix_spawn failed | errno=%d | %s", result, strerror(result)]);
        return result;
    }
    FFAppendHUDLog(@"SPAWN", [NSString stringWithFormat:@"posix_spawn success | child_pid=%d", child]);

    if (!detach) {
        int status = 0;
        while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        return ECHILD;
    }
    return 0;
}

static BOOL FFHUDIsRunning(void) {
    NSString *pidString = [NSString stringWithContentsOfFile:kFFHUDPIDPath encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = (pid_t)pidString.intValue;
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0 || errno == EPERM) return YES;
    [NSFileManager.defaultManager removeItemAtPath:kFFHUDPIDPath error:nil];
    return NO;
}

static BOOL FFHUDSetEnabled(BOOL enabled, NSString **message) {
    if (enabled) {
        if (FFHUDIsRunning()) {
            if (message) *message = @"HUD đang hiển thị trên màn hình.";
            return YES;
        }
        int result = FFSpawnRootCommand("-hud", YES);
        if (result != 0) {
            if (message) *message = [NSString stringWithFormat:@"Không khởi chạy được HUD (lỗi %d). Kiểm tra TrollStore và trạng thái jailbreak.", result];
            return NO;
        }
        FFAppendHUDLog(@"HUD_CONTROL", @"Enable HUD requested; waiting for hosted-window status");
        [NSThread sleepForTimeInterval:2.00];
        BOOL running = FFHUDIsRunning();
        NSDictionary *status = FFReadHUDStatus();
        NSString *stage = status[@"stage"] ?: @"no_status";
        NSString *detail = status[@"detail"] ?: @"HUD process has not reported its window state";
        BOOL hosted = [stage isEqualToString:@"window_hosted"] || [stage isEqualToString:@"plugin_running"];

        if (running && !hosted) {
            // Do not leave a headless root HUD process running when system-window
            // registration failed. Preserve the diagnostic file for the UI.
            FFSpawnRootCommand("-exit", NO);
            running = FFHUDIsRunning();
        }

        FFAppendHUDLog(@"HUD_CONTROL", [NSString stringWithFormat:@"enable result | running=%@ | hosted=%@ | stage=%@ | detail=%@", running ? @"YES" : @"NO", hosted ? @"YES" : @"NO", stage, detail]);
        if (message) {
            if (!running && !hosted) *message = [NSString stringWithFormat:@"HUD chưa đăng ký được cửa sổ (%@): %@", stage, detail];
            else if (!hosted) *message = @"HUD process đã thoát trước khi đăng ký cửa sổ. Mở lại app và kiểm tra log hệ thống.";
            else *message = @"Cửa sổ HUD đã được đăng ký. Chuyển sang Free Fire; ngoài Free Fire HUD sẽ tự ẩn.";
        }
        return running && hosted;
    }

    if (!FFHUDIsRunning()) {
        if (message) *message = @"HUD đã tắt.";
        return YES;
    }
    int result = FFSpawnRootCommand("-exit", NO);
    BOOL stopped = !FFHUDIsRunning();
    if (message) *message = stopped ? @"Đã tắt HUD nổi." : [NSString stringWithFormat:@"Không dừng được HUD (lỗi %d).", result];
    return stopped;
}

@interface FFToolDashboardController : UIViewController
@end

@interface FFHUDApplication : UIApplication
@end

@interface UIApplication (FFToolPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)terminateWithSuccess;
@end

@interface UIWindow (FFToolPrivate)
- (unsigned int)_contextId;
@end

@interface FFHUDAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@interface FFToolAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation FFHUDApplication
@end

@interface FFHUDPanelView : UIView
@property(nonatomic, assign) BOOL expanded;
- (void)refreshMetrics;
@end

@interface FFHUDRingView : UIView
- (void)applySettings:(NSDictionary *)settings;
@end

@interface FFHUDWindow : UIWindow
@end

@interface FFHUDMenuWindow : UIWindow
@end

@implementation FFToolAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = FFCanvas();
    self.window.rootViewController = [[FFToolDashboardController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@interface FFToolDashboardController ()
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *contentStack;
@property(nonatomic, strong) UIView *bottomBar;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *metricLabels;
@property(nonatomic, strong) UILabel *systemStateLabel;
@property(nonatomic, strong) UILabel *hudStateLabel;
@property(nonatomic, strong) UILabel *hudHintLabel;
@property(nonatomic, strong) UIButton *hudActionButton;
@property(nonatomic, strong) UISwitch *hudSwitch;
@property(nonatomic, strong) UISwitch *fovSwitch;
@property(nonatomic, strong) UISegmentedControl *fovSizeControl;
@property(nonatomic, strong) UISegmentedControl *fovColorControl;
@property(nonatomic, strong) UISlider *fovOpacitySlider;
@property(nonatomic, strong) UILabel *fovHintLabel;
@property(nonatomic, strong) UILabel *fovOpacityLabel;
@property(nonatomic, strong) UITextView *diagnosticLogView;
@property(nonatomic, strong) UILabel *diagnosticLogStatusLabel;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, assign) NSInteger selectedTab;
@end

@implementation FFToolDashboardController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.metricLabels = [NSMutableDictionary dictionary];
    self.view.backgroundColor = FFCanvas();

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (id)FFColor(0.08, 0.025, 0.20, 1).CGColor,
        (id)FFCanvas().CGColor,
        (id)FFColor(0.02, 0.01, 0.06, 1).CGColor
    ];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    gradient.frame = self.view.bounds;
    gradient.name = @"fftool.gradient";
    [self.view.layer insertSublayer:gradient atIndex:0];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 15;
    [self.scrollView addSubview:self.contentStack];

    self.bottomBar = [self buildBottomBar];
    self.bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bottomBar];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.bottomBar.topAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:13],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:17],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-17],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [self.bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.bottomBar.heightAnchor constraintEqualToConstant:65]
    ]];

    [self showTab:0];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refreshMetrics) userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in self.view.layer.sublayers) {
        if ([layer.name isEqualToString:@"fftool.gradient"]) layer.frame = self.view.bounds;
    }
}

- (UIView *)buildBottomBar {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.backgroundColor = FFColor(0.01, 0.008, 0.03, 0.92);
    bar.layer.borderColor = FFColor(1, 1, 1, 0.08).CGColor;
    bar.layer.borderWidth = 0.5;

    UIStackView *items = [[UIStackView alloc] initWithFrame:CGRectZero];
    items.translatesAutoresizingMaskIntoConstraints = NO;
    items.axis = UILayoutConstraintAxisHorizontal;
    items.distribution = UIStackViewDistributionFillEqually;
    [bar addSubview:items];

    NSArray *titles = @[@"Trang chủ", @"Game", @"Công cụ", @"Thông tin", @"Nhật ký"];
    NSArray *symbols = @[@"house.fill", @"gamecontroller.fill", @"wrench.and.screwdriver.fill", @"info.circle", @"doc.text.magnifyingglass"];
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = i;
        [button addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
        UIImage *image = [UIImage systemImageNamed:symbols[i]];
        [button setImage:image forState:UIControlStateNormal];
        [button setTitle:[@"  " stringByAppendingString:titles[i]] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        button.tintColor = i == 0 ? FFAccent() : FFColor(0.70, 0.65, 0.84, 0.70);
        [items addArrangedSubview:button];
    }
    [NSLayoutConstraint activateConstraints:@[
        [items.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:4],
        [items.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-4],
        [items.topAnchor constraintEqualToAnchor:bar.topAnchor constant:5],
        [items.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-5]
    ]];
    return bar;
}

- (void)tabPressed:(UIButton *)sender {
    [self showTab:sender.tag];
}

- (void)showTab:(NSInteger)tab {
    self.selectedTab = tab;
    for (UIView *view in self.contentStack.arrangedSubviews) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.metricLabels removeAllObjects];
    self.hudStateLabel = nil;
    self.hudHintLabel = nil;
    self.hudActionButton = nil;
    self.hudSwitch = nil;
    self.fovSwitch = nil;
    self.fovSizeControl = nil;
    self.fovColorControl = nil;
    self.fovOpacitySlider = nil;
    self.fovHintLabel = nil;
    self.fovOpacityLabel = nil;
    self.diagnosticLogView = nil;
    self.diagnosticLogStatusLabel = nil;

    [self.contentStack addArrangedSubview:[self headerView]];

    switch (tab) {
        case 1:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"CHẾ ĐỘ KHI CHƠI" subtitle:@"Trạng thái thiết bị nổi trên màn hình"]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
            [self.contentStack addArrangedSubview:[self fovControlCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Chỉ hiện trong Free Fire" body:@"HUD và vòng FOV tự bật khi Free Fire ở foreground, tự ẩn khi thoát hoặc chuyển sang app khác. Vòng FOV là hình tròn tĩnh, không aim, tracking hoặc ESP."]];
            break;
        case 2: {
            [self.contentStack addArrangedSubview:[self sectionHeading:@"CÔNG CỤ" subtitle:@"Điều khiển HUD, vòng FOV và chỉ số"]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
            [self.contentStack addArrangedSubview:[self fovControlCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Dynamic Island" body:@"Live Activity là tuỳ chọn riêng; HUD nổi và vòng trang trí là lớp hiển thị độc lập."]];
            UIButton *refresh = [self actionButton:@"Làm mới chỉ số" symbol:@"arrow.clockwise" action:@selector(refreshNow)];
            [self.contentStack addArrangedSubview:refresh];
            break;
        }
        case 3:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"THÔNG TIN" subtitle:@"FF Tool · Device Status Companion"]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Thông tin thiết bị" body:[NSString stringWithFormat:@"Thiết bị: %@\niOS: %@\nPin: %@ · %@\nTrạng thái nhiệt: %@\nRAM trống ước lượng: %lu MB\nThời gian hoạt động: %@",
                 UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion, FFBatteryText(), FFBatteryStateText(), FFThermalText(), (unsigned long)FFFreeRAMMB(), FFUptimeText()]]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Giới hạn đo" body:@"Nhiệt là trạng thái áp lực nhiệt của iOS, không phải nhiệt độ vật lý °C. RAM trống là ước lượng từ số trang bộ nhớ hệ thống. App không ép xung hoặc giải phóng RAM của ứng dụng khác."]];
            break;
        case 4:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"CHẨN ĐOÁN HUD" subtitle:@"Nhật ký chạy trực tiếp"]];
            [self.contentStack addArrangedSubview:[self diagnosticLogCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Cách lấy log" body:@"Bật HUD, mở Free Fire, chờ vài giây rồi vào Nhật ký và bấm Sao chép. Gửi toàn bộ nội dung cho nhà phát triển để xác định lỗi bundle ID, system window hoặc vòng lặp hiển thị."]];
            break;
        default:
            [self.contentStack addArrangedSubview:[self systemStatusCard]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
            [self.contentStack addArrangedSubview:[self fovControlCard]];
            [self.contentStack addArrangedSubview:[self metricsCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Trạng thái trực tiếp" body:@"FF Tool chỉ hiển thị thông số thiết bị. Không có ESP, không đọc hoặc sửa bộ nhớ Free Fire, không thay đổi dữ liệu trận đấu."]];
            break;
    }
    [self updateHUDControls];
    [self refreshMetrics];
    [self updateBottomBarSelection];
}

- (void)updateBottomBarSelection {
    UIStackView *items = (UIStackView *)self.bottomBar.subviews.firstObject;
    if (![items isKindOfClass:UIStackView.class]) return;
    for (NSInteger i = 0; i < items.arrangedSubviews.count; i++) {
        UIButton *button = (UIButton *)items.arrangedSubviews[i];
        button.tintColor = i == self.selectedTab ? FFAccent() : FFColor(0.70, 0.65, 0.84, 0.70);
        [button setTitleColor:i == self.selectedTab ? FFAccent() : FFColor(0.70, 0.65, 0.84, 0.70) forState:UIControlStateNormal];
    }
}

- (UIView *)headerView {
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header.heightAnchor constraintEqualToConstant:60].active = YES;

    UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(0, 3, 54, 54)];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.layer.cornerRadius = 14;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)FFColor(0.70, 0.12, 1.0, 1).CGColor, (id)FFColor(0.24, 0.14, 0.94, 1).CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    g.frame = CGRectMake(0, 0, 54, 54);
    [icon.layer addSublayer:g];
    UIImageView *bolt = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.shield.fill"]];
    bolt.tintColor = UIColor.whiteColor;
    bolt.contentMode = UIViewContentModeScaleAspectFit;
    bolt.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:bolt];

    UILabel *name = FFLabel(@"FF Tool", 22, UIFontWeightHeavy, UIColor.whiteColor);
    UILabel *subtitle = FFLabel(@"Free Fire Helper", 12, UIFontWeightMedium, FFColor(0.73, 0.65, 1, 1));
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[name, subtitle]];
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;

    UIButton *settings = [UIButton buttonWithType:UIButtonTypeSystem];
    settings.translatesAutoresizingMaskIntoConstraints = NO;
    [settings setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    settings.tintColor = FFAccent();
    [settings addTarget:self action:@selector(openInfoTab) forControlEvents:UIControlEventTouchUpInside];

    [header addSubview:icon];
    [header addSubview:texts];
    [header addSubview:settings];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:54],
        [icon.heightAnchor constraintEqualToConstant:54],
        [bolt.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [bolt.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [bolt.widthAnchor constraintEqualToConstant:28],
        [bolt.heightAnchor constraintEqualToConstant:28],
        [texts.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:13],
        [texts.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [settings.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:42],
        [settings.heightAnchor constraintEqualToConstant:42]
    ]];
    return header;
}

- (void)openInfoTab { [self showTab:3]; }

- (UIView *)sectionHeading:(NSString *)title subtitle:(NSString *)subtitle {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        FFLabel(title, 10, UIFontWeightHeavy, FFAccent()),
        FFLabel(subtitle, 19, UIFontWeightBold, UIColor.whiteColor)
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    return stack;
}

- (UIView *)systemStatusCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 20);
    card.backgroundColor = FFColor(0.025, 0.12, 0.095, 0.88);
    card.layer.borderColor = FFColor(0.05, 0.78, 0.42, 0.48).CGColor;

    UIStackView *left = [[UIStackView alloc] initWithFrame:CGRectZero];
    left.translatesAutoresizingMaskIntoConstraints = NO;
    left.axis = UILayoutConstraintAxisVertical;
    left.spacing = 7;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, 9, 9)],
        FFLabel(@"Trạng thái hệ thống", 12, UIFontWeightMedium, FFColor(0.86, 0.84, 1, 1))
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    UIView *dot = row.arrangedSubviews.firstObject;
    dot.backgroundColor = FFThermalWarning() ? UIColor.orangeColor : UIColor.greenColor;
    dot.layer.cornerRadius = 4.5;
    [dot.widthAnchor constraintEqualToConstant:9].active = YES;
    [dot.heightAnchor constraintEqualToConstant:9].active = YES;

    UILabel *state = FFLabel(FFThermalWarning() ? @"Đang nóng" : @"Hoạt động tốt", 21, UIFontWeightHeavy, FFThermalWarning() ? UIColor.orangeColor : FFColor(0.0, 0.94, 0.46, 1));
    self.systemStateLabel = state;
    UILabel *detail = FFLabel(FFThermalWarning() ? @"iOS đang ghi nhận áp lực nhiệt cao." : @"Máy đang hoạt động ổn định.", 10, UIFontWeightMedium, FFColor(0.78, 0.77, 0.91, 1));
    [left addArrangedSubview:row];
    [left addArrangedSubview:state];
    [left addArrangedSubview:detail];

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:FFThermalWarning() ? @"thermometer.high" : @"checkmark.circle"]];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.tintColor = FFThermalWarning() ? UIColor.orangeColor : UIColor.greenColor;
    check.contentMode = UIViewContentModeScaleAspectFit;

    [card addSubview:left];
    [card addSubview:check];
    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:112],
        [left.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [left.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [left.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-12],
        [check.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [check.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:52],
        [check.heightAnchor constraintEqualToConstant:52]
    ]];
    return card;
}

- (UIView *)hudControlCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 20);

    UIView *icon = [[UIView alloc] initWithFrame:CGRectZero];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.backgroundColor = FFColor(0.42, 0.12, 0.65, 0.30);
    icon.layer.cornerRadius = 15;
    UIImageView *symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"scope"]];
    symbol.translatesAutoresizingMaskIntoConstraints = NO;
    symbol.tintColor = FFColor(0.80, 0.35, 1, 1);
    symbol.contentMode = UIViewContentModeScaleAspectFit;
    [icon addSubview:symbol];

    UILabel *title = FFLabel(@"HUD trạng thái thiết bị", 15, UIFontWeightBold, UIColor.whiteColor);
    UILabel *sub = FFLabel(@"Hiển thị khi chuyển sang game", 10, UIFontWeightMedium, FFColor(0.76, 0.70, 0.88, 1));
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, sub]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 4;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.onTintColor = FFAccent();
    [toggle addTarget:self action:@selector(hudSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    self.hudSwitch = toggle;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, toggle]];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 12;

    UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
    action.translatesAutoresizingMaskIntoConstraints = NO;
    action.layer.cornerRadius = 15;
    action.layer.borderWidth = 1;
    action.layer.borderColor = FFColor(0.72, 0.22, 1, 0.75).CGColor;
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.name = @"fftool.hud.button.gradient";
    gradient.colors = @[(id)FFColor(0.70, 0.12, 1, 1).CGColor, (id)FFColor(0.28, 0.13, 0.95, 1).CGColor];
    gradient.startPoint = CGPointMake(0, 0.5);
    gradient.endPoint = CGPointMake(1, 0.5);
    gradient.frame = CGRectMake(0, 0, 300, 54);
    [action.layer insertSublayer:gradient atIndex:0];
    action.clipsToBounds = YES;
    [action setTitle:@"  Bật HUD trên màn hình" forState:UIControlStateNormal];
    [action setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    action.tintColor = UIColor.whiteColor;
    action.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [action addTarget:self action:@selector(hudActionPressed) forControlEvents:UIControlEventTouchUpInside];
    self.hudActionButton = action;

    UILabel *hint = FFLabel(@"Sau khi bật, chuyển sang Free Fire. Chạm HUD để mở rộng/thu gọn và kéo để di chuyển.", 10, UIFontWeightMedium, FFColor(0.78, 0.71, 0.98, 1));
    hint.numberOfLines = 0;
    self.hudHintLabel = hint;

    UIImageView *infoIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"info.circle.fill"]];
    infoIcon.translatesAutoresizingMaskIntoConstraints = NO;
    infoIcon.tintColor = FFAccent();
    infoIcon.contentMode = UIViewContentModeScaleAspectFit;
    [infoIcon.widthAnchor constraintEqualToConstant:18].active = YES;
    [infoIcon.heightAnchor constraintEqualToConstant:18].active = YES;
    UIStackView *hintRow = [[UIStackView alloc] initWithArrangedSubviews:@[infoIcon, hint]];
    hintRow.axis = UILayoutConstraintAxisHorizontal;
    hintRow.alignment = UIStackViewAlignmentTop;
    hintRow.spacing = 8;
    hintRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *body = [[UIStackView alloc] initWithArrangedSubviews:@[top, action, hintRow]];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = 14;

    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:210],
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:15],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-15],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-15],
        [icon.widthAnchor constraintEqualToConstant:58],
        [icon.heightAnchor constraintEqualToConstant:58],
        [symbol.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [symbol.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:28],
        [symbol.heightAnchor constraintEqualToConstant:28],
        [toggle.widthAnchor constraintEqualToConstant:48],
        [action.heightAnchor constraintEqualToConstant:54]
    ]];
    return card;
}

- (UIView *)fovControlCard {
    NSDictionary *settings = FFLoadHUDSettings();
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 20);

    UILabel *title = FFLabel(@"Vòng FOV trang trí", 15, UIFontWeightBold, UIColor.whiteColor);
    UILabel *subtitle = FFLabel(@"Vòng tròn cố định ở giữa màn hình", 10, UIFontWeightMedium, FFColor(0.76, 0.70, 0.88, 1));

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.onTintColor = FFAccent();
    toggle.on = [settings[@"fovEnabled"] boolValue];
    [toggle addTarget:self action:@selector(fovSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    self.fovSwitch = toggle;

    UIStackView *headingTexts = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    headingTexts.axis = UILayoutConstraintAxisVertical;
    headingTexts.spacing = 4;

    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[headingTexts, toggle]];
    heading.axis = UILayoutConstraintAxisHorizontal;
    heading.alignment = UIStackViewAlignmentCenter;
    heading.spacing = 10;

    UILabel *sizeTitle = FFLabel(@"Kích thước vòng", 10, UIFontWeightSemibold, FFColor(0.80, 0.75, 0.92, 1));
    UISegmentedControl *size = [[UISegmentedControl alloc] initWithItems:@[@"Nhỏ", @"Vừa", @"Lớn"]];
    size.translatesAutoresizingMaskIntoConstraints = NO;
    size.selectedSegmentIndex = 1;
    NSInteger diameter = [settings[@"fovDiameter"] integerValue];
    if (diameter <= 190) size.selectedSegmentIndex = 0;
    else if (diameter >= 290) size.selectedSegmentIndex = 2;
    size.selectedSegmentTintColor = FFAccent();
    [size setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                   NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]}
                        forState:UIControlStateSelected];
    [size addTarget:self action:@selector(fovSizeChanged:) forControlEvents:UIControlEventValueChanged];
    self.fovSizeControl = size;

    UILabel *colorTitle = FFLabel(@"Màu vòng", 10, UIFontWeightSemibold, FFColor(0.80, 0.75, 0.92, 1));
    UISegmentedControl *color = [[UISegmentedControl alloc] initWithItems:@[@"Tím", @"Cyan", @"Xanh"]];
    color.translatesAutoresizingMaskIntoConstraints = NO;
    color.selectedSegmentIndex = MIN(2, MAX(0, [settings[@"fovColor"] integerValue]));
    color.selectedSegmentTintColor = FFAccent();
    [color setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                    NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]}
                         forState:UIControlStateSelected];
    [color addTarget:self action:@selector(fovColorChanged:) forControlEvents:UIControlEventValueChanged];
    self.fovColorControl = color;

    UILabel *opacityTitle = FFLabel(@"Độ mờ", 10, UIFontWeightSemibold, FFColor(0.80, 0.75, 0.92, 1));
    UILabel *opacityValue = FFLabel([NSString stringWithFormat:@"%.0f%%", [settings[@"fovOpacity"] doubleValue] * 100.0], 10, UIFontWeightBold, FFAccent());
    self.fovOpacityLabel = opacityValue;

    UISlider *opacity = [[UISlider alloc] initWithFrame:CGRectZero];
    opacity.translatesAutoresizingMaskIntoConstraints = NO;
    opacity.minimumValue = 0.25;
    opacity.maximumValue = 1.0;
    opacity.value = MIN(1.0, MAX(0.25, [settings[@"fovOpacity"] floatValue]));
    opacity.minimumTrackTintColor = FFAccent();
    opacity.maximumTrackTintColor = FFColor(0.48, 0.40, 0.62, 0.50);
    [opacity addTarget:self action:@selector(fovOpacityChanged:) forControlEvents:UIControlEventValueChanged];
    self.fovOpacitySlider = opacity;

    UIStackView *opacityHeading = [[UIStackView alloc] initWithArrangedSubviews:@[opacityTitle, [UIView new], opacityValue]];
    opacityHeading.axis = UILayoutConstraintAxisHorizontal;

    UILabel *hint = FFLabel(@"Chỉ hiện trong Free Fire. Đây là nét vẽ cố định, không tự bám theo người chơi và không tác động điều khiển ngắm.", 10, UIFontWeightMedium, FFColor(0.78, 0.71, 0.98, 1));
    hint.numberOfLines = 0;
    self.fovHintLabel = hint;

    UIStackView *body = [[UIStackView alloc] initWithArrangedSubviews:@[
        heading,
        sizeTitle,
        size,
        colorTitle,
        color,
        opacityHeading,
        opacity,
        hint
    ]];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = 9;

    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:15],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:15],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-15],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-15],
        [size.heightAnchor constraintEqualToConstant:32],
        [color.heightAnchor constraintEqualToConstant:32],
        [opacity.heightAnchor constraintEqualToConstant:26],
        [toggle.widthAnchor constraintEqualToConstant:48]
    ]];
    return card;
}

- (void)saveFOVSettings {
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:FFLoadHUDSettings()];
    if (self.fovSwitch) settings[@"fovEnabled"] = @(self.fovSwitch.isOn);
    if (self.fovSizeControl) {
        NSArray *diameters = @[@180, @240, @320];
        NSInteger index = MIN(2, MAX(0, self.fovSizeControl.selectedSegmentIndex));
        settings[@"fovDiameter"] = diameters[index];
    }
    if (self.fovColorControl) settings[@"fovColor"] = @(MAX(0, self.fovColorControl.selectedSegmentIndex));
    if (self.fovOpacitySlider) settings[@"fovOpacity"] = @(self.fovOpacitySlider.value);

    BOOL saved = FFSaveHUDSettings(settings);
    self.fovHintLabel.text = saved
        ? (FFHUDIsRunning() ? @"Đã lưu. Vòng FOV sẽ cập nhật trên HUD." : @"Đã lưu cài đặt. Bật HUD nổi để hiển thị vòng FOV.")
        : @"Không lưu được cài đặt vòng FOV. Kiểm tra quyền ghi của TrollStore.";
}

- (void)fovSwitchChanged:(UISwitch *)sender {
    [self saveFOVSettings];
}

- (void)fovSizeChanged:(UISegmentedControl *)sender {
    [self saveFOVSettings];
}

- (void)fovColorChanged:(UISegmentedControl *)sender {
    [self saveFOVSettings];
}

- (void)fovOpacityChanged:(UISlider *)sender {
    self.fovOpacityLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100.0];
    [self saveFOVSettings];
}

- (UIView *)metricsCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 20);

    UILabel *heading = FFLabel(@"Trạng Thái Máy", 15, UIFontWeightBold, UIColor.whiteColor);
    UIStackView *headingRow = [[UIStackView alloc] initWithArrangedSubviews:@[heading, [UIView new]]];
    headingRow.axis = UILayoutConstraintAxisHorizontal;

    UIStackView *grid = [[UIStackView alloc] initWithFrame:CGRectZero];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 9;

    NSArray *rows = @[
        @[
            @{@"key":@"battery", @"title":@"Pin", @"value":FFBatteryText(), @"detail":FFBatteryStateText(), @"symbol":@"battery.100percent", @"tint":UIColor.greenColor},
            @{@"key":@"thermal", @"title":@"Nhiệt hệ thống", @"value":FFThermalText(), @"detail":@"Mức iOS báo cáo", @"symbol":@"thermometer.medium", @"tint":FFColor(0.23, 0.64, 1, 1)}
        ],
        @[
            @{@"key":@"memory", @"title":@"RAM trống", @"value":[NSString stringWithFormat:@"%lu MB",(unsigned long)FFFreeRAMMB()], @"detail":@"Ước lượng theo VM pages", @"symbol":@"memorychip", @"tint":FFColor(0.0, 0.88, 0.68, 1)},
            @{@"key":@"uptime", @"title":@"Thời gian hoạt động", @"value":FFUptimeText(), @"detail":@"Từ lần khởi động", @"symbol":@"clock", @"tint":FFColor(0.23, 0.64, 1, 1)}
        ]
    ];

    for (NSArray *rowData in rows) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 9;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSDictionary *data in rowData) {
            UIView *tile = [[UIView alloc] initWithFrame:CGRectZero];
            tile.translatesAutoresizingMaskIntoConstraints = NO;
            tile.backgroundColor = FFColor(0.13, 0.075, 0.23, 1);
            tile.layer.cornerRadius = 14;
            tile.layer.borderWidth = 0.5;
            tile.layer.borderColor = FFColor(1, 1, 1, 0.05).CGColor;

            UIImageView *symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:data[@"symbol"]]];
            symbol.translatesAutoresizingMaskIntoConstraints = NO;
            symbol.tintColor = data[@"tint"];
            symbol.contentMode = UIViewContentModeScaleAspectFit;
            UILabel *title = FFLabel(data[@"title"], 9, UIFontWeightMedium, FFColor(0.76, 0.71, 0.89, 1));
            UILabel *value = FFLabel(data[@"value"], 14, UIFontWeightBold, UIColor.whiteColor);
            value.numberOfLines = 1;
            UILabel *detail = FFLabel(data[@"detail"], 8, UIFontWeightRegular, FFColor(0.58, 0.55, 0.68, 1));
            detail.numberOfLines = 1;
            UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[title, value, detail]];
            labels.translatesAutoresizingMaskIntoConstraints = NO;
            labels.axis = UILayoutConstraintAxisVertical;
            labels.spacing = 3;
            [tile addSubview:symbol];
            [tile addSubview:labels];
            [NSLayoutConstraint activateConstraints:@[
                [tile.heightAnchor constraintEqualToConstant:80],
                [symbol.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:10],
                [symbol.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
                [symbol.widthAnchor constraintEqualToConstant:27],
                [symbol.heightAnchor constraintEqualToConstant:27],
                [labels.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:9],
                [labels.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-5],
                [labels.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor]
            ]];
            self.metricLabels[data[@"key"]] = value;
            [row addArrangedSubview:tile];
        }
        [grid addArrangedSubview:row];
    }

    [card addSubview:headingRow];
    [card addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [headingRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:15],
        [headingRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:15],
        [headingRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-15],
        [grid.topAnchor constraintEqualToAnchor:headingRow.bottomAnchor constant:12],
        [grid.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [grid.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [grid.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
    ]];
    return card;
}

- (UIView *)diagnosticLogCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 18);

    UILabel *status = FFLabel(@"Trạng thái: đang đọc...", 10, UIFontWeightSemibold, FFColor(0.26, 0.91, 0.68, 1));
    self.diagnosticLogStatusLabel = status;

    UITextView *logView = [[UITextView alloc] initWithFrame:CGRectZero];
    logView.translatesAutoresizingMaskIntoConstraints = NO;
    logView.editable = NO;
    logView.selectable = YES;
    logView.scrollEnabled = YES;
    logView.backgroundColor = FFColor(0.012, 0.008, 0.035, 0.96);
    logView.textColor = FFColor(0.78, 0.91, 1.0, 1);
    logView.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    logView.layer.cornerRadius = 11;
    logView.layer.borderWidth = 0.7;
    logView.layer.borderColor = FFColor(0.49, 0.28, 0.78, 0.55).CGColor;
    logView.text = FFReadHUDLogTail(80);
    self.diagnosticLogView = logView;

    UIButton *refresh = [self actionButton:@"Làm mới" symbol:@"arrow.clockwise" action:@selector(refreshDiagnosticLog)];
    UIButton *copy = [self actionButton:@"Sao chép" symbol:@"doc.on.doc" action:@selector(copyDiagnosticLog)];
    UIButton *clear = [self actionButton:@"Xoá log" symbol:@"trash" action:@selector(confirmClearDiagnosticLog)];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[refresh, copy, clear]];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 6;

    UIStackView *body = [[UIStackView alloc] initWithArrangedSubviews:@[status, logView, actions]];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = 10;
    [card addSubview:body];

    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:13],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-13],
        [logView.heightAnchor constraintEqualToConstant:250],
        [actions.heightAnchor constraintEqualToConstant:44]
    ]];
    [self refreshDiagnosticLog];
    return card;
}

- (void)refreshDiagnosticLog {
    if (!self.diagnosticLogView && !self.diagnosticLogStatusLabel) return;

    NSDictionary *status = FFReadHUDStatus();
    NSString *stage = status[@"stage"] ?: @"chưa có trạng thái";
    NSString *bundleID = status[@"frontmostBundleID"] ?: @"chưa có dữ liệu";
    NSString *matchText = [status[@"foregroundMatch"] boolValue] ? @"ĐÚNG Free Fire" : @"không khớp / chưa xác định";
    NSString *source = status[@"foregroundSource"] ?: @"nguồn chưa xác định";
    self.diagnosticLogStatusLabel.text = [NSString stringWithFormat:@"HUD: %@  ·  %@  ·  %@  ·  %@", stage, matchText, bundleID, source];
    self.diagnosticLogView.text = FFReadHUDLogTail(80);
    if (self.diagnosticLogView.text.length) {
        [self.diagnosticLogView scrollRangeToVisible:NSMakeRange(self.diagnosticLogView.text.length - 1, 1)];
    }
}

- (void)copyDiagnosticLog {
    NSString *log = FFReadHUDLogTail(1000);
    NSDictionary *status = FFReadHUDStatus();
    NSString *bundleID = status[@"frontmostBundleID"] ?: @"(no HUD foreground sample yet)";
    NSString *matchText = [status[@"foregroundMatch"] boolValue] ? @"YES" : @"NO / unknown";
    NSString *source = status[@"foregroundSource"] ?: @"unknown";
    NSString *payload = [NSString stringWithFormat:@"FF TOOL DIAGNOSTICS\nHUD stage: %@\nHUD detail: %@\nLast HUD foreground probe: %@\nMatched Free Fire: %@\nDetection source: %@\n\n%@",
                         status[@"stage"] ?: @"unknown",
                         status[@"detail"] ?: @"",
                         bundleID,
                         matchText,
                         source,
                         log];
    UIPasteboard.generalPasteboard.string = payload;
    FFAppendHUDLog(@"DASHBOARD", @"User copied diagnostic log to clipboard");
    if (self.diagnosticLogStatusLabel) self.diagnosticLogStatusLabel.text = @"Đã sao chép log vào clipboard.";
    [self refreshDiagnosticLog];
}

- (void)confirmClearDiagnosticLog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoá nhật ký?"
                                                                   message:@"Log hiện tại sẽ bị xoá. Lần bật HUD tiếp theo sẽ tạo log mới."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        FFClearHUDLog();
        [self refreshDiagnosticLog];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIView *)informationCard:(NSString *)title body:(NSString *)bodyText {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    FFStyleCard(card, 17);
    UILabel *heading = FFLabel(title, 13, UIFontWeightBold, UIColor.whiteColor);
    UILabel *body = FFLabel(bodyText, 10, UIFontWeightRegular, FFColor(0.76, 0.73, 0.85, 1));
    body.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, body]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]
    ]];
    return card;
}

- (UIButton *)actionButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 14;
    button.clipsToBounds = YES;
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)FFColor(0.70, 0.12, 1, 1).CGColor, (id)FFColor(0.28, 0.13, 0.95, 1).CGColor];
    gradient.startPoint = CGPointMake(0, 0.5);
    gradient.endPoint = CGPointMake(1, 0.5);
    gradient.frame = CGRectMake(0, 0, 300, 50);
    [button.layer insertSublayer:gradient atIndex:0];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:50].active = YES;
    return button;
}

- (void)hudSwitchChanged:(UISwitch *)sender {
    FFAppendHUDLog(@"HUD_CONTROL", [NSString stringWithFormat:@"HUD switch changed | enabled=%@", sender.isOn ? @"YES" : @"NO"]);
    NSString *message = nil;
    BOOL ok = FFHUDSetEnabled(sender.isOn, &message);
    if (!ok) sender.on = NO;
    if (self.hudHintLabel) self.hudHintLabel.text = message;
    [self updateHUDControls];
}

- (void)hudActionPressed {
    BOOL enabled = !FFHUDIsRunning();
    FFAppendHUDLog(@"HUD_CONTROL", [NSString stringWithFormat:@"HUD action button | enable=%@", enabled ? @"YES" : @"NO"]);
    NSString *message = nil;
    BOOL ok = FFHUDSetEnabled(enabled, &message);
    if (self.hudHintLabel) self.hudHintLabel.text = message;
    if (!ok && enabled) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Không bật được HUD" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self updateHUDControls];
}

- (void)updateHUDControls {
    BOOL active = FFHUDIsRunning();
    self.hudSwitch.on = active;
    [self.hudActionButton setTitle:active ? @"  Tắt HUD nổi" : @"  Bật HUD trên màn hình" forState:UIControlStateNormal];
    [self.hudActionButton setImage:[UIImage systemImageNamed:active ? @"stop.fill" : @"play.fill"] forState:UIControlStateNormal];
    self.hudStateLabel.text = active ? @"HUD đang hiển thị" : @"HUD đang tắt";
}

- (void)refreshNow { [self refreshMetrics]; }

- (void)refreshMetrics {
    if (self.systemStateLabel) {
        BOOL warning = FFThermalWarning();
        self.systemStateLabel.text = warning ? @"Đang nóng" : @"Hoạt động tốt";
        self.systemStateLabel.textColor = warning ? UIColor.orangeColor : FFColor(0.0, 0.94, 0.46, 1);
    }
    if (self.metricLabels[@"battery"]) self.metricLabels[@"battery"].text = FFBatteryText();
    if (self.metricLabels[@"thermal"]) self.metricLabels[@"thermal"].text = FFThermalText();
    if (self.metricLabels[@"memory"]) self.metricLabels[@"memory"].text = [NSString stringWithFormat:@"%lu MB",(unsigned long)FFFreeRAMMB()];
    if (self.metricLabels[@"uptime"]) self.metricLabels[@"uptime"].text = FFUptimeText();
    [self updateHUDControls];
    if (self.selectedTab == 4) [self refreshDiagnosticLog];
}

@end

#pragma mark - System-wide HUD process

// Mirrors Mail Temp's non-interactive HUDMainWindow: render-only, never consumes touches.
@implementation FFHUDWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

// Mirrors Mail Temp's separate HUDMenuWindow, hosted independently from the render window.
@implementation FFHUDMenuWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
@end

@interface FFHUDPanelView ()
@property(nonatomic, strong) UIStackView *labelStack;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *footerLabel;
@property(nonatomic, assign) CGPoint dragStartPoint;
@property(nonatomic, assign) CGRect dragStartFrame;
@end

@implementation FFHUDPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = FFColor(0.025, 0.02, 0.08, 0.95);
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = FFColor(0.70, 0.25, 1.0, 0.95).CGColor;
        self.layer.shadowColor = FFColor(0.45, 0.18, 1.0, 1).CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 10;

        self.titleLabel = FFLabel(@"FF TOOL  ·  PIN --", 10, UIFontWeightBold, UIColor.whiteColor);
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.numberOfLines = 1;

        self.detailLabel = FFLabel(@"NHIỆT: N/A  ·  RAM: N/A", 10, UIFontWeightSemibold, FFColor(0.54, 0.91, 1.0, 1));
        self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.detailLabel.numberOfLines = 2;

        self.footerLabel = FFLabel(@"UPTIME: --  ·  CHẠM ĐỂ THU GỌN", 8, UIFontWeightMedium, FFColor(0.73, 0.68, 0.85, 1));
        self.footerLabel.translatesAutoresizingMaskIntoConstraints = NO;

        self.labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.detailLabel, self.footerLabel]];
        self.labelStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.labelStack.axis = UILayoutConstraintAxisVertical;
        self.labelStack.alignment = UIStackViewAlignmentFill;
        self.labelStack.distribution = UIStackViewDistributionFill;
        self.labelStack.spacing = 4;
        [self addSubview:self.labelStack];

        [NSLayoutConstraint activateConstraints:@[
            [self.labelStack.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [self.labelStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [self.labelStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [self.labelStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-7]
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleExpanded)];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:tap];
        [self addGestureRecognizer:pan];
        [self refreshMetrics];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.hidden = NO;
    self.detailLabel.hidden = !self.expanded;
    self.footerLabel.hidden = !self.expanded;
}

- (void)toggleExpanded {
    self.expanded = !self.expanded;
    CGRect frame = self.frame;
    frame.size = self.expanded ? CGSizeMake(222, 92) : CGSizeMake(168, 38);
    self.frame = frame;
    [self.superview setNeedsLayout];
    [self setNeedsLayout];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint delta = [gesture translationInView:self.superview];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStartFrame = self.frame;
    }
    CGRect frame = self.dragStartFrame;
    frame.origin.x += delta.x;
    frame.origin.y += delta.y;
    CGRect bounds = self.superview.bounds;
    frame.origin.x = MIN(MAX(0, frame.origin.x), MAX(0, bounds.size.width - frame.size.width));
    frame.origin.y = MIN(MAX(50, frame.origin.y), MAX(50, bounds.size.height - frame.size.height));
    if (gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded) self.frame = frame;
}

- (void)refreshMetrics {
    self.titleLabel.text = [NSString stringWithFormat:@"FF TOOL  ·  PIN %@", FFBatteryText()];
    self.detailLabel.text = [NSString stringWithFormat:@"NHIỆT: %@\nRAM FREE: %lu MB", FFThermalText(), (unsigned long)FFFreeRAMMB()];
    self.footerLabel.text = [NSString stringWithFormat:@"UPTIME: %@  ·  CHẠM ĐỂ THU GỌN", FFUptimeText()];
    self.layer.borderColor = (FFThermalWarning() ? UIColor.orangeColor : FFAccent()).CGColor;
}
@end

// The menu window only accepts hit-tests inside the draggable HUD panel.
@interface FFHUDMenuPassThroughView : UIView
@property(nonatomic, weak) FFHUDPanelView *panel;
@end

@implementation FFHUDMenuPassThroughView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.panel || self.panel.hidden) return NO;
    return CGRectContainsPoint(self.panel.frame, point);
}
@end

@interface FFHUDMenuViewController : UIViewController
@property(nonatomic, strong) FFHUDPanelView *panel;
- (instancetype)initWithPanel:(FFHUDPanelView *)panel;
@end

@implementation FFHUDMenuViewController
- (instancetype)initWithPanel:(FFHUDPanelView *)panel {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _panel = panel;
    return self;
}
- (void)loadView {
    FFHUDMenuPassThroughView *root = [[FFHUDMenuPassThroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    root.opaque = NO;
    root.panel = self.panel;
    self.view = root;
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root addSubview:self.panel];
}
@end

@interface FFHUDRingView ()
@property(nonatomic, strong) CAShapeLayer *glowLayer;
@property(nonatomic, strong) CAShapeLayer *ringLayer;
@property(nonatomic, assign) CGFloat diameter;
@property(nonatomic, strong) UIColor *ringColor;
@end

@implementation FFHUDRingView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;

        self.glowLayer = [CAShapeLayer layer];
        self.glowLayer.fillColor = UIColor.clearColor.CGColor;
        self.glowLayer.lineWidth = 8.0;
        self.glowLayer.lineCap = kCALineCapRound;
        self.glowLayer.shadowRadius = 10.0;
        self.glowLayer.shadowOffset = CGSizeZero;
        self.glowLayer.shadowOpacity = 0.45;
        [self.layer addSublayer:self.glowLayer];

        self.ringLayer = [CAShapeLayer layer];
        self.ringLayer.fillColor = UIColor.clearColor.CGColor;
        self.ringLayer.lineWidth = 2.1;
        self.ringLayer.lineDashPattern = @[@10, @6];
        self.ringLayer.lineCap = kCALineCapRound;
        [self.layer addSublayer:self.ringLayer];

        self.diameter = 240.0;
        self.ringColor = FFAccent();
    }
    return self;
}

- (void)applySettings:(NSDictionary *)settings {
    BOOL enabled = [settings[@"fovEnabled"] boolValue];
    self.hidden = !enabled;

    CGFloat requested = [settings[@"fovDiameter"] doubleValue];
    if (requested < 140.0) requested = 240.0;
    self.diameter = MIN(360.0, MAX(160.0, requested));

    NSInteger colorIndex = [settings[@"fovColor"] integerValue];
    UIColor *baseColor = FFAccent();
    if (colorIndex == 1) baseColor = FFColor(0.12, 0.83, 1.0, 1.0);
    else if (colorIndex == 2) baseColor = FFColor(0.08, 0.96, 0.48, 1.0);

    CGFloat opacity = [settings[@"fovOpacity"] doubleValue];
    opacity = MIN(1.0, MAX(0.25, opacity));
    self.ringColor = [baseColor colorWithAlphaComponent:opacity];
    self.ringLayer.strokeColor = self.ringColor.CGColor;
    self.glowLayer.strokeColor = [baseColor colorWithAlphaComponent:opacity * 0.32].CGColor;
    self.glowLayer.shadowColor = baseColor.CGColor;
    self.glowLayer.shadowOpacity = (float)(opacity * 0.48);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat limit = MAX(120.0, MIN(self.bounds.size.width, self.bounds.size.height) - 28.0);
    CGFloat diameter = MIN(self.diameter, limit);
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGRect circle = CGRectMake(center.x - diameter / 2.0,
                               center.y - diameter / 2.0,
                               diameter,
                               diameter);
    CGPathRef path = [UIBezierPath bezierPathWithOvalInRect:circle].CGPath;
    self.glowLayer.frame = self.bounds;
    self.ringLayer.frame = self.bounds;
    self.glowLayer.path = path;
    self.ringLayer.path = path;
}
@end

@interface FFHUDViewController : UIViewController
@property(nonatomic, strong) FFHUDPanelView *panel;
@property(nonatomic, strong) FFHUDRingView *ring;
@property(nonatomic, strong) NSTimer *refreshTimer;
- (void)refreshHUD;
@end

@implementation FFHUDViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    FFAppendHUDLog(@"HUD_VIEW", [NSString stringWithFormat:@"viewDidLoad | screen_bounds=%@", NSStringFromCGRect(UIScreen.mainScreen.bounds)]);
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    CGRect bounds = UIScreen.mainScreen.bounds;

    self.ring = [[FFHUDRingView alloc] initWithFrame:bounds];
    self.ring.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.ring applySettings:FFLoadHUDSettings()];
    [self.view addSubview:self.ring];

    CGFloat width = 168;
    self.panel = [[FFHUDPanelView alloc] initWithFrame:CGRectMake(MAX(4, bounds.size.width - width - 8), 112, width, 38)];
    self.panel.expanded = NO;
    // The panel is attached to the separate HUDMenuWindow by FFHUDAppDelegate.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(refreshHUD)
                                                       userInfo:nil
                                                        repeats:YES];
    [self refreshHUD];
}

- (void)refreshHUD {
    NSString *bundleID = FFCurrentFrontmostBundleID();
    BOOL inFreeFire = [FFGameBundleIDs() containsObject:bundleID];
    static BOOL hasLoggedForeground = NO;
    static BOOL lastForeground = NO;
    static NSString *lastObservedBundleID = nil;
    BOOL bundleChanged = !lastObservedBundleID || ![lastObservedBundleID isEqualToString:bundleID];
    if (!hasLoggedForeground || lastForeground != inFreeFire || bundleChanged) {
        FFAppendHUDLog(@"VISIBILITY", [NSString stringWithFormat:@"source=%@ | foreground_match=%@ | bundle_id=%@ | panel_hidden=%@ | ring_hidden=%@",
                                       gFFFrontmostSource ?: @"unknown",
                                       inFreeFire ? @"YES" : @"NO",
                                       bundleID,
                                       inFreeFire ? @"NO" : @"YES",
                                       inFreeFire ? @"NO" : @"YES"]);
        hasLoggedForeground = YES;
        lastForeground = inFreeFire;
        lastObservedBundleID = [bundleID copy];
        FFWriteHUDRuntimeState(bundleID, inFreeFire);
    }

    NSDictionary *settings = FFLoadHUDSettings();
    BOOL fovEnabled = [settings[@"fovEnabled"] boolValue];
    static BOOL hasLoggedFOV = NO;
    static BOOL lastFOVEnabled = NO;
    if (!hasLoggedFOV || lastFOVEnabled != fovEnabled) {
        FFAppendHUDLog(@"FOV", [NSString stringWithFormat:@"enabled=%@ | diameter=%@ | color_index=%@ | opacity=%@",
                                fovEnabled ? @"YES" : @"NO",
                                settings[@"fovDiameter"] ?: @"?",
                                settings[@"fovColor"] ?: @"?",
                                settings[@"fovOpacity"] ?: @"?"]);
        hasLoggedFOV = YES;
        lastFOVEnabled = fovEnabled;
    }

    self.panel.hidden = !inFreeFire;
    self.ring.hidden = !inFreeFire || !fovEnabled;
    if (!inFreeFire) return;

    [self.panel refreshMetrics];
    [self.ring applySettings:settings];
    static BOOL hasLoggedVisibleOnce = NO;
    if (!hasLoggedVisibleOnce) {
        FFAppendHUDLog(@"RENDER", [NSString stringWithFormat:@"HUD content visible | view_bounds=%@ | panel_frame=%@ | ring_bounds=%@",
                                   NSStringFromCGRect(self.view.bounds),
                                   NSStringFromCGRect(self.panel.frame),
                                   NSStringFromCGRect(self.ring.bounds)]);
        hasLoggedVisibleOnce = YES;
    }
}
@end

@implementation FFHUDAppDelegate {
    id _windowHostingController;
    id _menuHostingController;
    UIWindow *_menuWindow;
}

- (id)registerWindow:(UIWindow *)window role:(NSString *)role {
    Class hostClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!hostClass) {
        FFAppendHUDLog(@"HOST", [NSString stringWithFormat:@"%@ host class lookup returned nil", role]);
        FFWriteHUDStatus(@"host_class_missing", [NSString stringWithFormat:@"%@ SBSAccessibilityWindowHostingController was not found", role]);
        return nil;
    }

    id host = [[hostClass alloc] init];
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!host || ![host respondsToSelector:registerSelector]) {
        FFAppendHUDLog(@"HOST", [NSString stringWithFormat:@"%@ registration selector missing", role]);
        FFWriteHUDStatus(@"register_selector_missing", [NSString stringWithFormat:@"%@ host registration selector is unavailable", role]);
        return nil;
    }

    unsigned int contextID = [window _contextId];
    double windowLevel = window.windowLevel;
    FFAppendHUDLog(@"HOST", [NSString stringWithFormat:@"role=%@ | class=%@ | context_id=%u | level=%.2f | host=%@",
                               role, NSStringFromClass(window.class), contextID, windowLevel, host]);
    if (contextID == 0) {
        FFWriteHUDStatus(@"window_context_missing", [NSString stringWithFormat:@"%@ UIWindow returned an empty context ID", role]);
        return nil;
    }

    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    if (!signature) {
        FFWriteHUDStatus(@"registration_signature_missing", [NSString stringWithFormat:@"%@ could not create host method signature", role]);
        return nil;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:host];
    [invocation setSelector:registerSelector];
    [invocation setArgument:&contextID atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        NSString *reason = [NSString stringWithFormat:@"%@ registration exception | name=%@ | reason=%@",
                            role, exception.name ?: @"unknown", exception.reason ?: @"(none)"];
        FFAppendHUDLog(@"HOST_EXCEPTION", reason);
        FFWriteHUDStatus(@"registration_exception", reason);
        return nil;
    }

    FFAppendHUDLog(@"HOST", [NSString stringWithFormat:@"%@ registration call returned without Objective-C exception", role]);
    return host;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    FFWriteHUDStatus(@"delegate_started", @"HUD app delegate started");
    FFAppendHUDLog(@"APP_DELEGATE", [NSString stringWithFormat:@"delegate=%@ | principal_class=%@", NSStringFromClass(self.class), NSStringFromClass(UIApplication.sharedApplication.class)]);

    // Render-only system window: the ring never participates in touch hit-testing.
    self.window = [[FFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    FFHUDViewController *controller = [[FFHUDViewController alloc] init];
    (void)controller.view;
    self.window.rootViewController = controller;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.opaque = NO;
    self.window.windowLevel = 10000010.0;
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];
    FFWriteHUDStatus(@"main_window_created", @"Non-interactive HUDMainWindow created");
    FFAppendHUDLog(@"WINDOW", [NSString stringWithFormat:@"role=main | class=%@ | frame=%@ | level=%.2f | hidden=%@",
                               NSStringFromClass(self.window.class), NSStringFromCGRect(self.window.frame),
                               self.window.windowLevel, self.window.hidden ? @"YES" : @"NO"]);

    _windowHostingController = [self registerWindow:self.window role:@"main"];
    if (!_windowHostingController) return YES;
    FFWriteHUDStatus(@"main_window_hosted", @"HUDMainWindow registration call returned");

    // Separate pass-through menu window, matching Mail Temp's HUDMenuWindow architecture.
    _menuWindow = [[FFHUDMenuWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    FFHUDMenuViewController *menuController = [[FFHUDMenuViewController alloc] initWithPanel:controller.panel];
    _menuWindow.rootViewController = menuController;
    _menuWindow.backgroundColor = UIColor.clearColor;
    _menuWindow.opaque = NO;
    _menuWindow.windowLevel = self.window.windowLevel + 1.0;
    [_menuWindow setHidden:NO];
    [_menuWindow makeKeyAndVisible];
    FFWriteHUDStatus(@"menu_window_created", @"Interactive HUDMenuWindow created separately");
    FFAppendHUDLog(@"WINDOW", [NSString stringWithFormat:@"role=menu | class=%@ | frame=%@ | level=%.2f | hidden=%@",
                               NSStringFromClass(_menuWindow.class), NSStringFromCGRect(_menuWindow.frame),
                               _menuWindow.windowLevel, _menuWindow.hidden ? @"YES" : @"NO"]);

    _menuHostingController = [self registerWindow:_menuWindow role:@"menu"];
    if (!_menuHostingController) {
        [_menuWindow setHidden:YES];
        return YES;
    }

    FFWriteHUDStatus(@"window_hosted", @"Main render window and separate menu window registration calls returned");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [NSTimer scheduledTimerWithTimeInterval:20.0 repeats:YES block:^(__unused NSTimer *timer) {
            NSString *bundlePath = NSBundle.mainBundle.bundlePath;
            if (![NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
                [UIApplication.sharedApplication terminateWithSuccess];
            }
        }];
    });
    return YES;
}
@end

static int FFRunHUDProcess(void) {
    FFWriteHUDStatus(@"initializing", @"Starting system HUD application");
    FFAppendHUDLog(@"BOOT", [NSString stringWithFormat:@"iOS=%@ | executable=%@ | uid=%d | euid=%d", UIDevice.currentDevice.systemVersion, FFExecutablePath() ?: @"unknown", getuid(), geteuid()]);
    [UIScreen initialize];
    CFRunLoopGetCurrent();

    GSInitialize();
    BKSDisplayServicesStart();
    UIApplicationInitialize();
    UIApplicationInstantiateSingleton([FFHUDApplication class]);

    UIApplication *application = UIApplication.sharedApplication;
    static FFHUDAppDelegate *gFFHUDAppDelegate = nil;
    gFFHUDAppDelegate = [[FFHUDAppDelegate alloc] init];
    [application setDelegate:gFFHUDAppDelegate];
    [application _accessibilityInit];

    [NSRunLoop currentRunLoop];
    if (@available(iOS 15.0, *)) {
        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
    }

    [application __completeAndRunAsPlugin];
    NSDictionary *hostStatus = FFReadHUDStatus();
    NSString *hostStage = hostStatus[@"stage"] ?: @"unknown";
    if ([hostStage isEqualToString:@"window_hosted"]) {
        FFWriteHUDStatus(@"plugin_running", @"HUD plugin run loop started; main and menu windows registered");
    } else {
        FFAppendHUDLog(@"BOOT", [NSString stringWithFormat:@"Plugin loop entered with window-hosting incomplete | stage=%@", hostStage]);
    }
    CFRunLoopRun();
    return EXIT_SUCCESS;
}

static int FFStartHUDMode(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:[kFFHUDPIDPath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
        [pid writeToFile:kFFHUDPIDPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        FFClearHUDRuntimeState();
        FFWriteHUDStatus(@"process_started", @"HUD child process started");
        FFAppendHUDLog(@"BOOT", [NSString stringWithFormat:@"HUD child process started | pid=%d", getpid()]);
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        return FFRunHUDProcess();
    }
}

static int FFStopHUDMode(void) {
    FFAppendHUDLog(@"STOP", @"HUD stop requested");
    NSString *pidString = [NSString stringWithContentsOfFile:kFFHUDPIDPath encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = (pid_t)pidString.intValue;
    if (pid > 0 && pid != getpid()) kill(pid, SIGTERM);
    [NSFileManager.defaultManager removeItemAtPath:kFFHUDPIDPath error:nil];
    return EXIT_SUCCESS;
}

static int FFCheckHUDMode(void) {
    NSString *pidString = [NSString stringWithContentsOfFile:kFFHUDPIDPath encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = (pid_t)pidString.intValue;
    if (pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)) return EXIT_FAILURE;
    [NSFileManager.defaultManager removeItemAtPath:kFFHUDPIDPath error:nil];
    return EXIT_SUCCESS;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) return FFStartHUDMode();
        if (argc > 1 && strcmp(argv[1], "-exit") == 0) return FFStopHUDMode();
        if (argc > 1 && strcmp(argv[1], "-check") == 0) return FFCheckHUDMode();
        return UIApplicationMain(argc, argv, NSStringFromClass(UIApplication.class), NSStringFromClass(FFToolAppDelegate.class));
    }
}
