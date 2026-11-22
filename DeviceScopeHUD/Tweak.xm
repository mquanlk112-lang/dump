#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

static UIWindow *DSWindow = nil;
static UIViewController *DSController = nil;
static NSTimer *DSRefreshTimer = nil;
static BOOL DSIsVisible = NO;

static NSString *DSThermalText(void) {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal: return @"MÁT";
        case NSProcessInfoThermalStateFair: return @"ỔN";
        case NSProcessInfoThermalStateSerious: return @"NÓNG";
        case NSProcessInfoThermalStateCritical: return @"RẤT NÓNG";
        default: return @"N/A";
    }
}

static NSString *DSBatteryText(void) {
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    float level = device.batteryLevel;
    NSString *percent = level >= 0.0f ? [NSString stringWithFormat:@"%.0f%%", level * 100.0f] : @"--";
    NSString *state = @"";
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging: state = @" · ĐANG SẠC"; break;
        case UIDeviceBatteryStateFull: state = @" · ĐẦY"; break;
        case UIDeviceBatteryStateUnplugged: state = @" · PIN"; break;
        default: state = @""; break;
    }
    return [percent stringByAppendingString:state];
}

static NSUInteger DSFreeMemoryMB(void) {
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

static NSString *DSUptimeText(void) {
    NSTimeInterval seconds = [NSProcessInfo processInfo].systemUptime;
    NSUInteger total = (NSUInteger)MAX(0, seconds);
    NSUInteger days = total / 86400;
    NSUInteger hours = (total % 86400) / 3600;
    NSUInteger minutes = (total % 3600) / 60;
    if (days > 0) return [NSString stringWithFormat:@"%lud %luh", (unsigned long)days, (unsigned long)hours];
    if (hours > 0) return [NSString stringWithFormat:@"%luh %lum", (unsigned long)hours, (unsigned long)minutes];
    return [NSString stringWithFormat:@"%lum", (unsigned long)minutes];
}

@interface DSHUDPanel : UIView
@property(nonatomic, assign) BOOL expanded;
- (void)refreshMetrics;
@end

@implementation DSHUDPanel {
    UIView *_card;
    UILabel *_titleLabel;
    UILabel *_batteryLabel;
    UILabel *_detailLabel;
    UILabel *_uptimeLabel;
    CGPoint _touchStart;
    CGRect _windowStartFrame;
    BOOL _didDrag;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _card = [[UIView alloc] initWithFrame:self.bounds];
        _card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _card.backgroundColor = [UIColor colorWithRed:0.035 green:0.045 blue:0.105 alpha:0.94];
        _card.layer.cornerRadius = 15.0;
        _card.layer.borderWidth = 1.0;
        _card.layer.borderColor = [UIColor colorWithRed:0.42 green:0.30 blue:1.0 alpha:0.9].CGColor;
        _card.layer.shadowColor = [UIColor colorWithRed:0.30 green:0.18 blue:1.0 alpha:1.0].CGColor;
        _card.layer.shadowOpacity = 0.22;
        _card.layer.shadowRadius = 10.0;
        [self addSubview:_card];

        _titleLabel = [self makeLabelWithSize:11 weight:UIFontWeightBold color:UIColor.whiteColor];
        _batteryLabel = [self makeLabelWithSize:10 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.45 green:0.95 blue:1.0 alpha:1.0]];
        _detailLabel = [self makeLabelWithSize:10 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1.0 alpha:0.86]];
        _uptimeLabel = [self makeLabelWithSize:9 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1.0 alpha:0.56]];

        [_card addSubview:_titleLabel];
        [_card addSubview:_batteryLabel];
        [_card addSubview:_detailLabel];
        [_card addSubview:_uptimeLabel];

        [self refreshMetrics];
    }
    return self;
}

- (UILabel *)makeLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _card.frame = self.bounds;
    CGFloat width = CGRectGetWidth(self.bounds);
    if (self.expanded) {
        _titleLabel.frame = CGRectMake(12, 8, width - 24, 18);
        _batteryLabel.frame = CGRectMake(12, 31, width - 24, 17);
        _detailLabel.frame = CGRectMake(12, 53, width - 24, 17);
        _uptimeLabel.frame = CGRectMake(12, 76, width - 24, 16);
        _batteryLabel.hidden = NO;
        _detailLabel.hidden = NO;
        _uptimeLabel.hidden = NO;
    } else {
        _titleLabel.frame = CGRectMake(10, 0, width - 20, CGRectGetHeight(self.bounds));
        _batteryLabel.hidden = YES;
        _detailLabel.hidden = YES;
        _uptimeLabel.hidden = YES;
    }
}

- (void)refreshMetrics {
    NSString *battery = DSBatteryText();
    NSString *thermal = DSThermalText();
    _titleLabel.text = [NSString stringWithFormat:@"DS  ·  PIN %@  ·  %@", battery, thermal];
    _batteryLabel.text = [NSString stringWithFormat:@"PIN: %@", battery];
    _detailLabel.text = [NSString stringWithFormat:@"NHIỆT: %@   ·   RAM FREE: %lu MB",
                         thermal, (unsigned long)DSFreeMemoryMB()];
    _uptimeLabel.text = [NSString stringWithFormat:@"UPTIME: %@   ·   KÉO ĐỂ DI CHUYỂN", DSUptimeText()];
    [self setNeedsLayout];
}

- (void)toggleExpanded {
    self.expanded = !self.expanded;
    CGRect frame = DSWindow.frame;
    frame.size = self.expanded ? CGSizeMake(214, 104) : CGSizeMake(158, 42);
    CGRect screen = [UIScreen mainScreen].bounds;
    frame.origin.x = MIN(MAX(4.0, frame.origin.x), MAX(4.0, screen.size.width - frame.size.width - 4.0));
    frame.origin.y = MIN(MAX(52.0, frame.origin.y), MAX(52.0, screen.size.height - frame.size.height - 8.0));
    DSWindow.frame = frame;
    [self setNeedsLayout];
    [self refreshMetrics];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    _touchStart = [touch locationInView:nil];
    _windowStartFrame = DSWindow.frame;
    _didDrag = NO;
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint current = [touch locationInView:nil];
    CGFloat dx = current.x - _touchStart.x;
    CGFloat dy = current.y - _touchStart.y;
    if (!_didDrag && (fabs(dx) > 6.0 || fabs(dy) > 6.0)) _didDrag = YES;
    if (_didDrag) {
        CGRect frame = _windowStartFrame;
        frame.origin.x += dx;
        frame.origin.y += dy;
        CGRect screen = [UIScreen mainScreen].bounds;
        frame.origin.x = MIN(MAX(0.0, frame.origin.x), MAX(0.0, screen.size.width - frame.size.width));
        frame.origin.y = MIN(MAX(48.0, frame.origin.y), MAX(48.0, screen.size.height - frame.size.height));
        DSWindow.frame = frame;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_didDrag) [self toggleExpanded];
    [super touchesEnded:touches withEvent:event];
}

@end

static void DSCreateWindowIfNeeded(void) {
    if (DSWindow) return;
    CGRect screen = [UIScreen mainScreen].bounds;
    CGRect frame = CGRectMake(MAX(4.0, screen.size.width - 164.0), 96.0, 158.0, 42.0);
    DSWindow = [[UIWindow alloc] initWithFrame:frame];
    DSWindow.backgroundColor = UIColor.clearColor;
    DSWindow.opaque = NO;
    DSWindow.windowLevel = UIWindowLevelAlert + 50.0;
    DSWindow.userInteractionEnabled = YES;

    DSController = [[UIViewController alloc] init];
    DSHUDPanel *panel = [[DSHUDPanel alloc] initWithFrame:DSWindow.bounds];
    DSController.view = panel;
    DSWindow.rootViewController = DSController;
    DSWindow.hidden = YES;
}

static void DSStartRefreshTimer(void) {
    if (DSRefreshTimer) return;
    DSRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                      repeats:YES
                                                        block:^(__unused NSTimer *timer) {
        if (DSIsVisible) {
            [(DSHUDPanel *)DSController.view refreshMetrics];
        }
    }];
}

static void DSStopRefreshTimer(void) {
    [DSRefreshTimer invalidate];
    DSRefreshTimer = nil;
}

static void DSShowHUD(void) {
    DSCreateWindowIfNeeded();
    DSIsVisible = YES;
    DSWindow.hidden = NO;
    DSWindow.windowLevel = UIWindowLevelAlert + 50.0;
    [(DSHUDPanel *)DSController.view refreshMetrics];
    DSStartRefreshTimer();
}

static void DSHideHUD(void) {
    DSIsVisible = NO;
    DSWindow.hidden = YES;
    DSStopRefreshTimer();
}

static void DSToggleHUD(void) {
    if (DSIsVisible) DSHideHUD(); else DSShowHUD();
}

static void DSHandleNotification(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    NSString *command = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([command isEqualToString:@"com.minhquandev.devicescope.hud.show"]) {
            DSShowHUD();
        } else if ([command isEqualToString:@"com.minhquandev.devicescope.hud.hide"]) {
            DSHideHUD();
        } else if ([command isEqualToString:@"com.minhquandev.devicescope.hud.toggle"]) {
            DSToggleHUD();
        }
    });
}

%ctor {
    @autoreleasepool {
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, DSHandleNotification,
            CFSTR("com.minhquandev.devicescope.hud.show"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, DSHandleNotification,
            CFSTR("com.minhquandev.devicescope.hud.hide"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, DSHandleNotification,
            CFSTR("com.minhquandev.devicescope.hud.toggle"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
