/******************************************************************************
 * VTLog.h — Thread-safe logging with GUI integration
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP6 implements VTLog.m against this interface.
 *****************************************************************************/

#import <Foundation/Foundation.h>
#import "VTTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VTLogLevel) {
    VTLogLevelDebug = 0,
    VTLogLevelInfo,
    VTLogLevelWarn,
    VTLogLevelError
};

@interface VTLogEntry : NSObject
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, assign, readonly) VTLogLevel level;
@property (nonatomic, copy, readonly) NSDate *timestamp;
- (NSAttributedString *)attributedString;
@end

@interface VTLog : NSObject

+ (instancetype)sharedLog;

- (void)debug:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
- (void)info:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
- (void)warn:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
- (void)error:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

/// All log entries (observable via VTLogEntryAddedNotification).
@property (nonatomic, readonly) NSArray<VTLogEntry *> *logEntries;

/// Clear all log entries.
- (void)clear;

/// Path to the log file on disk.
@property (nonatomic, readonly) NSString *logFilePath;

@end

NS_ASSUME_NONNULL_END
