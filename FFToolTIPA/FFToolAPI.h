#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const FFToolAPIErrorDomain;
FOUNDATION_EXPORT NSString * const FFToolAPIEventDidPublishNotification;

typedef void (^FFToolAPIEventHandler)(NSString *eventName, NSDictionary *payload);
typedef BOOL (^FFToolAPIModuleStartHandler)(NSError * _Nullable * _Nullable error);
typedef void (^FFToolAPIModuleStopHandler)(void);

@interface FFToolAPI : NSObject

@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, copy, readonly) NSString *version;

+ (instancetype)sharedAPI;

/// Initializes the local API services. Safe to call more than once.
- (BOOL)initializeWithError:(NSError * _Nullable * _Nullable)error;

/// Reports the APIs provided by this build and their security boundaries.
- (NSDictionary<NSString *, id> *)capabilityReport;

/// Device/app telemetry only; does not inspect another process.
- (NSDictionary<NSString *, id> *)deviceSnapshot;

/// Runs storage, event-bus and device-service smoke tests.
- (NSDictionary<NSString *, id> *)selfTest;

/// Thread-safe structured log writer. Uses the existing FF Tool HUD log.
- (void)logCategory:(NSString *)category message:(NSString *)message;

/// Shared property-list settings store used by the dashboard and HUD process.
- (NSDictionary<NSString *, id> *)settingsWithDefaults:(NSDictionary<NSString *, id> *)defaults;
- (BOOL)saveSettings:(NSDictionary<NSString *, id> *)settings
               error:(NSError * _Nullable * _Nullable)error;

/// In-process event bus for FF Tool modules.
- (void)publishEvent:(NSString *)eventName payload:(NSDictionary<NSString *, id> *)payload;
- (nullable id)observeEvent:(NSString *)eventName handler:(FFToolAPIEventHandler)handler;
- (void)removeEventObserver:(nullable id)observer;

/// Small lifecycle registry so optional FF Tool modules share one startup contract.
- (BOOL)registerModuleNamed:(NSString *)name
               startHandler:(FFToolAPIModuleStartHandler)startHandler
                stopHandler:(nullable FFToolAPIModuleStopHandler)stopHandler
                      error:(NSError * _Nullable * _Nullable)error;
- (BOOL)startModuleNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)stopModuleNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)moduleStatus;

@end

NS_ASSUME_NONNULL_END
