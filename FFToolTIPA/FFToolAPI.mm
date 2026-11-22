#import "FFToolAPI.h"

#import <mach/mach.h>
#import <mach/mach_host.h>
#import <sys/types.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

NSString * const FFToolAPIErrorDomain = @"com.minhquandev.fftool.api";
NSString * const FFToolAPIEventDidPublishNotification = @"com.minhquandev.fftool.api.event";

static NSString * const kFFToolAPILogPath =
    @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud.log";
static NSString * const kFFToolAPISettingsPath =
    @"/var/mobile/Library/Caches/com.minhquandev.fftool.hud-settings.plist";
static const unsigned long long kFFToolAPILogLimit = 512ULL * 1024ULL;
static const NSUInteger kFFToolAPILogKeep = 384U * 1024U;

static NSError *FFToolAPIMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:FFToolAPIErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description ?: @"Unknown API error" }];
}

static BOOL FFToolAPIEnsureDirectory(NSString *filePath, NSError **error) {
    NSString *directory = [filePath stringByDeletingLastPathComponent];
    return [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:error];
}

@interface FFAPIModuleRecord : NSObject
@property(nonatomic, copy) FFToolAPIModuleStartHandler startHandler;
@property(nonatomic, copy, nullable) FFToolAPIModuleStopHandler stopHandler;
@property(nonatomic, assign, getter=isRunning) BOOL running;
@property(nonatomic, assign, getter=isStarting) BOOL starting;
@end

@implementation FFAPIModuleRecord
@end

@interface FFToolAPI ()
- (instancetype)initPrivate;
@property(nonatomic, assign, getter=isReady) BOOL ready;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, strong) NSLock *stateLock;
@property(nonatomic, strong) NSLock *logLock;
@property(nonatomic, strong) NSRecursiveLock *moduleLock;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FFAPIModuleRecord *> *modules;
@end

@implementation FFToolAPI

+ (instancetype)sharedAPI {
    static FFToolAPI *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FFToolAPI alloc] initPrivate];
    });
    return instance;
}

- (instancetype)init {
    return [FFToolAPI sharedAPI];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _version = @"1.0.0";
        _stateLock = [[NSLock alloc] init];
        _logLock = [[NSLock alloc] init];
        _moduleLock = [[NSRecursiveLock alloc] init];
        _modules = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)initializeWithError:(NSError **)error {
    [self.stateLock lock];
    if (self.ready) {
        [self.stateLock unlock];
        return YES;
    }

    NSError *directoryError = nil;
    BOOL directoryReady = FFToolAPIEnsureDirectory(kFFToolAPILogPath, &directoryError);
    if (!directoryReady) {
        [self.stateLock unlock];
        if (error) *error = directoryError ?: FFToolAPIMakeError(1, @"Cannot create FF Tool API cache directory");
        return NO;
    }

    self.ready = YES;
    [self.stateLock unlock];

    [self logCategory:@"API"
              message:[NSString stringWithFormat:@"FFToolAPI %@ initialized | pid=%d | iOS=%@",
                       self.version, getpid(), UIDevice.currentDevice.systemVersion ?: @"unknown"]];
    return YES;
}

- (NSDictionary<NSString *, id> *)capabilityReport {
    return @{
        @"version": self.version ?: @"unknown",
        @"ready": @(self.isReady),
        @"deviceTelemetry": @YES,
        @"persistentSettings": @YES,
        @"structuredLogging": @YES,
        @"inProcessEventBus": @YES,
        @"moduleLifecycleRegistry": @YES,
        @"systemOverlayCoordination": @YES,
        @"ownProcessDiagnosticsOnly": @YES,
        @"arbitraryProcessMemory": @NO,
        @"kernelMemoryReadWrite": @NO,
        @"gameInjection": @NO
    };
}

- (NSDictionary<NSString *, id> *)deviceSnapshot {
    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;

    NSString *batteryState = @"unknown";
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging: batteryState = @"charging"; break;
        case UIDeviceBatteryStateFull: batteryState = @"full"; break;
        case UIDeviceBatteryStateUnplugged: batteryState = @"unplugged"; break;
        default: break;
    }

    NSString *thermalState = @"unknown";
    if (@available(iOS 11.0, *)) {
        switch (NSProcessInfo.processInfo.thermalState) {
            case NSProcessInfoThermalStateNominal: thermalState = @"nominal"; break;
            case NSProcessInfoThermalStateFair: thermalState = @"fair"; break;
            case NSProcessInfoThermalStateSerious: thermalState = @"serious"; break;
            case NSProcessInfoThermalStateCritical: thermalState = @"critical"; break;
            default: break;
        }
    }

    CGRect bounds = UIScreen.mainScreen.bounds;
    NSMutableDictionary<NSString *, id> *snapshot = [@{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"systemVersion": device.systemVersion ?: @"unknown",
        @"deviceModel": device.model ?: @"unknown",
        @"deviceName": device.name ?: @"unknown",
        @"processID": @(getpid()),
        @"processUptime": @(NSProcessInfo.processInfo.systemUptime),
        @"thermalState": thermalState,
        @"screenWidth": @(CGRectGetWidth(bounds)),
        @"screenHeight": @(CGRectGetHeight(bounds)),
        @"screenScale": @(UIScreen.mainScreen.scale),
        @"batteryState": batteryState
    } mutableCopy];

    if (device.batteryLevel >= 0.0f) snapshot[@"batteryLevel"] = @(device.batteryLevel);
    else snapshot[@"batteryLevel"] = NSNull.null;

    return [snapshot copy];
}

- (void)logCategory:(NSString *)category message:(NSString *)message {
    @autoreleasepool {
        [self.logLock lock];
        @try {
            NSError *directoryError = nil;
            if (!FFToolAPIEnsureDirectory(kFFToolAPILogPath, &directoryError)) {
                NSLog(@"[FFToolAPI] log directory error: %@", directoryError);
                return;
            }

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
                              category.length ? category : @"API",
                              message ?: @""];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            int fd = open(kFFToolAPILogPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_APPEND, 0644);
            if (fd < 0) {
                NSLog(@"[FFToolAPI] open log failed: errno=%d", errno);
                return;
            }

            if (flock(fd, LOCK_EX) != 0) {
                NSLog(@"[FFToolAPI] lock log failed: errno=%d", errno);
                close(fd);
                return;
            }

            struct stat info;
            if (fstat(fd, &info) == 0 && (unsigned long long)info.st_size > kFFToolAPILogLimit) {
                off_t keep = (off_t)MIN((unsigned long long)kFFToolAPILogKeep, (unsigned long long)info.st_size);
                off_t offset = info.st_size - keep;
                NSMutableData *tail = [NSMutableData dataWithLength:(NSUInteger)keep];
                ssize_t readCount = pread(fd, tail.mutableBytes, (size_t)keep, offset);
                if (readCount >= 0) {
                    tail.length = (NSUInteger)readCount;
                    if (ftruncate(fd, 0) == 0) {
                        (void)lseek(fd, 0, SEEK_SET);
                        const uint8_t *bytes = (const uint8_t *)tail.bytes;
                        size_t remaining = tail.length;
                        while (remaining > 0) {
                            ssize_t written = write(fd, bytes, remaining);
                            if (written < 0 && errno == EINTR) continue;
                            if (written <= 0) break;
                            bytes += written;
                            remaining -= (size_t)written;
                        }
                    }
                }
            }

            const uint8_t *bytes = (const uint8_t *)data.bytes;
            size_t remaining = data.length;
            while (remaining > 0) {
                ssize_t written = write(fd, bytes, remaining);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) break;
                bytes += written;
                remaining -= (size_t)written;
            }
            (void)fsync(fd);
            (void)flock(fd, LOCK_UN);
            close(fd);
            NSLog(@"[FFToolAPI] %@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
        } @catch (NSException *exception) {
            NSLog(@"[FFToolAPI] log write exception: %@", exception);
        } @finally {
            [self.logLock unlock];
        }
    }
}

- (NSDictionary<NSString *, id> *)settingsWithDefaults:(NSDictionary<NSString *, id> *)defaults {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:kFFToolAPISettingsPath];
    NSMutableDictionary *result = defaults ? [defaults mutableCopy] : [NSMutableDictionary dictionary];
    if ([stored isKindOfClass:NSDictionary.class]) [result addEntriesFromDictionary:stored];
    return [result copy];
}

- (BOOL)saveSettings:(NSDictionary<NSString *, id> *)settings error:(NSError **)error {
    if (![settings isKindOfClass:NSDictionary.class]) {
        if (error) *error = FFToolAPIMakeError(2, @"Settings must be a property-list dictionary");
        return NO;
    }

    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:settings
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&serializationError];
    if (!data) {
        if (error) *error = serializationError ?: FFToolAPIMakeError(3, @"Settings contain unsupported values");
        return NO;
    }

    NSError *directoryError = nil;
    if (!FFToolAPIEnsureDirectory(kFFToolAPISettingsPath, &directoryError)) {
        if (error) *error = directoryError ?: FFToolAPIMakeError(4, @"Cannot create settings directory");
        return NO;
    }

    NSError *writeError = nil;
    BOOL saved = [data writeToFile:kFFToolAPISettingsPath options:NSDataWritingAtomic error:&writeError];
    if (!saved && error) *error = writeError ?: FFToolAPIMakeError(5, @"Could not persist settings");
    if (saved) [self publishEvent:@"settings.changed" payload:@{ @"keyCount": @(settings.count) }];
    return saved;
}

- (void)publishEvent:(NSString *)eventName payload:(NSDictionary<NSString *, id> *)payload {
    if (!eventName.length) return;
    NSDictionary *safePayload = [payload isKindOfClass:NSDictionary.class] ? [payload copy] : @{};
    [[NSNotificationCenter defaultCenter] postNotificationName:FFToolAPIEventDidPublishNotification
                                                        object:self
                                                      userInfo:@{
        @"eventName": eventName,
        @"payload": safePayload
    }];
}

- (id)observeEvent:(NSString *)eventName handler:(FFToolAPIEventHandler)handler {
    if (!eventName.length || !handler) return nil;
    return [[NSNotificationCenter defaultCenter]
        addObserverForName:FFToolAPIEventDidPublishNotification
                    object:self
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        NSDictionary *info = notification.userInfo;
        NSString *publishedName = info[@"eventName"];
        if (![publishedName isEqualToString:eventName]) return;
        NSDictionary *payload = info[@"payload"];
        handler(publishedName, [payload isKindOfClass:NSDictionary.class] ? payload : @{});
    }];
}

- (void)removeEventObserver:(id)observer {
    if (observer) [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

- (BOOL)registerModuleNamed:(NSString *)name
               startHandler:(FFToolAPIModuleStartHandler)startHandler
                stopHandler:(FFToolAPIModuleStopHandler)stopHandler
                      error:(NSError **)error {
    if (!name.length || !startHandler) {
        if (error) *error = FFToolAPIMakeError(10, @"Module name and start handler are required");
        return NO;
    }

    [self.moduleLock lock];
    if (self.modules[name]) {
        [self.moduleLock unlock];
        if (error) *error = FFToolAPIMakeError(11, [NSString stringWithFormat:@"Module already registered: %@", name]);
        return NO;
    }

    FFAPIModuleRecord *record = [[FFAPIModuleRecord alloc] init];
    record.startHandler = startHandler;
    record.stopHandler = stopHandler;
    self.modules[name] = record;
    [self.moduleLock unlock];

    [self publishEvent:@"module.registered" payload:@{ @"name": name }];
    return YES;
}

- (BOOL)startModuleNamed:(NSString *)name error:(NSError **)error {
    [self.moduleLock lock];
    FFAPIModuleRecord *record = self.modules[name];
    if (!record) {
        [self.moduleLock unlock];
        if (error) *error = FFToolAPIMakeError(12, [NSString stringWithFormat:@"Unknown module: %@", name ?: @"(nil)"]);
        return NO;
    }
    if (record.isRunning) {
        [self.moduleLock unlock];
        return YES;
    }
    if (record.isStarting) {
        [self.moduleLock unlock];
        if (error) *error = FFToolAPIMakeError(16, [NSString stringWithFormat:@"Module is already starting: %@", name]);
        return NO;
    }
    record.starting = YES;
    FFToolAPIModuleStartHandler start = record.startHandler;
    [self.moduleLock unlock];

    NSError *startError = nil;
    BOOL started = start ? start(&startError) : YES;

    [self.moduleLock lock];
    record.running = started;
    record.starting = NO;
    [self.moduleLock unlock];

    if (!started) {
        if (error) *error = startError ?: FFToolAPIMakeError(13, [NSString stringWithFormat:@"Module failed to start: %@", name]);
        [self publishEvent:@"module.start_failed" payload:@{ @"name": name }];
        return NO;
    }
    [self publishEvent:@"module.started" payload:@{ @"name": name }];
    return YES;
}

- (BOOL)stopModuleNamed:(NSString *)name error:(NSError **)error {
    [self.moduleLock lock];
    FFAPIModuleRecord *record = self.modules[name];
    if (!record) {
        [self.moduleLock unlock];
        if (error) *error = FFToolAPIMakeError(14, [NSString stringWithFormat:@"Unknown module: %@", name ?: @"(nil)"]);
        return NO;
    }
    if (!record.isRunning) {
        [self.moduleLock unlock];
        return YES;
    }
    FFToolAPIModuleStopHandler stop = record.stopHandler;
    [self.moduleLock unlock];

    @try {
        if (stop) stop();
    } @catch (NSException *exception) {
        if (error) *error = FFToolAPIMakeError(15, [NSString stringWithFormat:@"Module stop exception: %@", exception.reason ?: exception.name]);
        return NO;
    }

    [self.moduleLock lock];
    record.running = NO;
    [self.moduleLock unlock];
    [self publishEvent:@"module.stopped" payload:@{ @"name": name }];
    return YES;
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)moduleStatus {
    [self.moduleLock lock];
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithCapacity:self.modules.count];
    [self.modules enumerateKeysAndObjectsUsingBlock:^(NSString *name, FFAPIModuleRecord *record, BOOL *stop) {
        status[name] = @{
            @"registered": @YES,
            @"running": @(record.isRunning),
            @"starting": @(record.isStarting)
        };
    }];
    [self.moduleLock unlock];
    return [status copy];
}

- (NSDictionary<NSString *, id> *)selfTest {
    NSMutableDictionary *checks = [NSMutableDictionary dictionary];

    NSError *initError = nil;
    BOOL initialized = [self initializeWithError:&initError];
    checks[@"initialize"] = @{
        @"passed": @(initialized),
        @"detail": initError.localizedDescription ?: (initialized ? @"API initialized" : @"API initialization failed")
    };

    NSString *testPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"fftool-api-selftest-%@.plist", NSUUID.UUID.UUIDString]];
    NSDictionary *testObject = @{ @"probe": @"fftool-api", @"value": @42 };
    BOOL storagePassed = [testObject writeToFile:testPath atomically:YES];
    NSDictionary *readBack = storagePassed ? [NSDictionary dictionaryWithContentsOfFile:testPath] : nil;
    storagePassed = storagePassed && [readBack[@"probe"] isEqual:@"fftool-api"] && [readBack[@"value"] isEqual:@42];
    [[NSFileManager defaultManager] removeItemAtPath:testPath error:nil];
    checks[@"storage_roundtrip"] = @{
        @"passed": @(storagePassed),
        @"detail": storagePassed ? @"Temporary property-list write/read passed" :
                   (storageError.localizedDescription ?: @"Temporary property-list roundtrip failed")
    };

    __block BOOL eventDelivered = NO;
    id observer = [self observeEvent:@"selftest.probe" handler:^(__unused NSString *name, __unused NSDictionary *payload) {
        eventDelivered = YES;
    }];
    [self publishEvent:@"selftest.probe" payload:@{ @"probe": @YES }];
    [self removeEventObserver:observer];
    checks[@"event_bus"] = @{
        @"passed": @(eventDelivered),
        @"detail": eventDelivered ? @"In-process event delivered" : @"Event was not delivered"
    };

    NSDictionary *device = [self deviceSnapshot];
    BOOL devicePassed = [device[@"systemVersion"] isKindOfClass:NSString.class] &&
                        [device[@"processID"] respondsToSelector:@selector(intValue)];
    checks[@"device_snapshot"] = @{
        @"passed": @(devicePassed),
        @"detail": devicePassed ? @"Device/app telemetry available" : @"Device snapshot incomplete"
    };

    NSUInteger passedCount = 0;
    for (NSDictionary *item in checks.allValues) {
        if ([item[@"passed"] boolValue]) passedCount++;
    }
    return @{
        @"apiVersion": self.version ?: @"unknown",
        @"passed": @(passedCount == checks.count),
        @"passedCount": @(passedCount),
        @"checkCount": @(checks.count),
        @"checks": [checks copy],
        @"capabilities": [self capabilityReport],
        @"device": device
    };
}

@end
