#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <errno.h>
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
extern "C" void BKSDisplayServicesStart(void);
extern "C" void UIApplicationInitialize(void);
extern "C" void UIApplicationInstantiateSingleton(id applicationClass);

static NSString * const kFFHUDPIDPath = @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud.pid";
static NSString * const kFFHUDDismissNotification = @"com.minhquandev.fftool.hud.dismiss";
static const CGFloat kFFPurple = 0.68;
static const CGFloat kFFBlue = 0.30;

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
    if (result != 0) return result;

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
        [NSThread sleepForTimeInterval:0.45];
        BOOL running = FFHUDIsRunning();
        if (message) *message = running ? @"Đã bật HUD nổi. Chuyển sang Free Fire để xem trạng thái máy." : @"Lệnh đã gửi nhưng HUD chưa khởi động. Kiểm tra TrollStore/jailbreak.";
        return running;
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
@end

@interface FFHUDAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@interface FFToolAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@interface FFHUDPanelView : UIView
@property(nonatomic, assign) BOOL expanded;
- (void)refreshMetrics;
@end

@interface FFHUDWindow : UIWindow
@property(nonatomic, weak) UIView *interactivePanel;
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

    NSArray *titles = @[@"Trang chủ", @"Game", @"Công cụ", @"Thông tin"];
    NSArray *symbols = @[@"house.fill", @"gamecontroller.fill", @"wrench.and.screwdriver.fill", @"info.circle"];
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

    [self.contentStack addArrangedSubview:[self headerView]];

    switch (tab) {
        case 1:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"CHẾ ĐỘ KHI CHƠI" subtitle:@"Trạng thái thiết bị nổi trên màn hình"]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"HUD độc lập" body:@"HUD được vẽ bởi một tiến trình hiển thị hệ thống riêng. Nó không nạp mã vào Free Fire, không đọc bộ nhớ game và không truy cập trạng thái trận đấu."]];
            break;
        case 2:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"CÔNG CỤ" subtitle:@"Điều khiển HUD và làm mới chỉ số"]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Dynamic Island" body:@"Live Activity là tuỳ chọn riêng; HUD nổi là thành phần chính hiển thị khi chuyển sang ứng dụng khác."]];
            UIButton *refresh = [self actionButton:@"Làm mới chỉ số" symbol:@"arrow.clockwise" action:@selector(refreshNow)];
            [self.contentStack addArrangedSubview:refresh];
            break;
        case 3:
            [self.contentStack addArrangedSubview:[self sectionHeading:@"THÔNG TIN" subtitle:@"FF Tool · Device Status Companion"]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Thông tin thiết bị" body:[NSString stringWithFormat:@"Thiết bị: %@\niOS: %@\nPin: %@ · %@\nTrạng thái nhiệt: %@\nRAM trống ước lượng: %lu MB\nThời gian hoạt động: %@",
                 UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion, FFBatteryText(), FFBatteryStateText(), FFThermalText(), (unsigned long)FFFreeRAMMB(), FFUptimeText()]]];
            [self.contentStack addArrangedSubview:[self informationCard:@"Giới hạn đo" body:@"Nhiệt là trạng thái áp lực nhiệt của iOS, không phải nhiệt độ vật lý °C. RAM trống là ước lượng từ số trang bộ nhớ hệ thống. App không ép xung hoặc giải phóng RAM của ứng dụng khác."]];
            break;
        default:
            [self.contentStack addArrangedSubview:[self systemStatusCard]];
            [self.contentStack addArrangedSubview:[self hudControlCard]];
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
    NSString *message = nil;
    BOOL ok = FFHUDSetEnabled(sender.isOn, &message);
    if (!ok) sender.on = NO;
    if (self.hudHintLabel) self.hudHintLabel.text = message;
    [self updateHUDControls];
}

- (void)hudActionPressed {
    BOOL enabled = !FFHUDIsRunning();
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
}

@end

#pragma mark - System-wide HUD process

@implementation FFHUDWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.interactivePanel) return NO;
    return CGRectContainsPoint(self.interactivePanel.frame, point);
}
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

@interface FFHUDViewController : UIViewController
@property(nonatomic, strong) FFHUDPanelView *panel;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation FFHUDViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat width = 168;
    self.panel = [[FFHUDPanelView alloc] initWithFrame:CGRectMake(MAX(4, bounds.size.width - width - 8), 112, width, 38)];
    self.panel.expanded = NO;
    [self.view addSubview:self.panel];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self.panel selector:@selector(refreshMetrics) userInfo:nil repeats:YES];
}
@end

@implementation FFHUDAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[FFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    FFHUDViewController *controller = [[FFHUDViewController alloc] init];
    (void)controller.view;
    self.window.rootViewController = controller;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.opaque = NO;
    self.window.windowLevel = 10000010.0;
    self.window.interactivePanel = controller.panel;
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    Class hostClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (hostClass) {
        id host = [[hostClass alloc] init];
        unsigned int contextID = 0;
        SEL contextSelector = NSSelectorFromString(@"_contextId");
        if ([self.window respondsToSelector:contextSelector]) {
            unsigned int (*contextIMP)(id, SEL) = (unsigned int (*)(id, SEL))[self.window methodForSelector:contextSelector];
            contextID = contextIMP(self.window, contextSelector);
        }
        SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if (contextID && [host respondsToSelector:registerSelector]) {
            void (*registerIMP)(id, SEL, unsigned int, double) = (void (*)(id, SEL, unsigned int, double))[host methodForSelector:registerSelector];
            registerIMP(host, registerSelector, contextID, self.window.windowLevel);
        }
    }

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
    GSInitialize();
    BKSDisplayServicesStart();
    UIApplicationInitialize();
    UIApplicationInstantiateSingleton([FFHUDApplication class]);

    UIApplication *application = UIApplication.sharedApplication;
    FFHUDAppDelegate *delegate = [[FFHUDAppDelegate alloc] init];
    [application setDelegate:delegate];
    [application _accessibilityInit];
    [application __completeAndRunAsPlugin];
    CFRunLoopRun();
    return EXIT_SUCCESS;
}

static int FFStartHUDMode(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:[kFFHUDPIDPath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
        [pid writeToFile:kFFHUDPIDPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        return FFRunHUDProcess();
    }
}

static int FFStopHUDMode(void) {
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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(FFToolAppDelegate.class));
    }
}
