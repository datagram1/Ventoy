/******************************************************************************
 * VTLog.m — Thread-safe logging with GUI integration
 *
 * OWNER: WP6 — Only WP6 may modify this file.
 *****************************************************************************/

#import "VTLog.h"
#import <Cocoa/Cocoa.h>

@interface VTLogEntry ()
@property (nonatomic, copy, readwrite) NSString *message;
@property (nonatomic, assign, readwrite) VTLogLevel level;
@property (nonatomic, copy, readwrite) NSDate *timestamp;
@end

@implementation VTLogEntry

- (NSAttributedString *)attributedString {
    NSColor *color;
    switch (self.level) {
        case VTLogLevelDebug: color = [NSColor secondaryLabelColor]; break;
        case VTLogLevelInfo:  color = [NSColor labelColor]; break;
        case VTLogLevelWarn:  color = [NSColor systemOrangeColor]; break;
        case VTLogLevelError: color = [NSColor systemRedColor]; break;
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";

    NSString *prefix;
    switch (self.level) {
        case VTLogLevelDebug: prefix = @"DEBUG"; break;
        case VTLogLevelInfo:  prefix = @"INFO "; break;
        case VTLogLevelWarn:  prefix = @"WARN "; break;
        case VTLogLevelError: prefix = @"ERROR"; break;
    }

    NSString *formatted = [NSString stringWithFormat:@"[%@] %@ %@",
                           [fmt stringFromDate:self.timestamp], prefix, self.message];

    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
    };

    return [[NSAttributedString alloc] initWithString:formatted attributes:attrs];
}

@end

@interface VTLog ()
@property (nonatomic, strong) NSMutableArray<VTLogEntry *> *mutableLogEntries;
@property (nonatomic, strong) dispatch_queue_t logQueue;
@property (nonatomic, strong) NSFileHandle *logFileHandle;
@end

@implementation VTLog

+ (instancetype)sharedLog {
    static VTLog *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VTLog alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableLogEntries = [NSMutableArray array];
        _logQueue = dispatch_queue_create("com.knws.ventoymac.log", DISPATCH_QUEUE_SERIAL);
        [self _openLogFile];
    }
    return self;
}

- (NSArray<VTLogEntry *> *)logEntries {
    __block NSArray *entries;
    dispatch_sync(self.logQueue, ^{
        entries = [self.mutableLogEntries copy];
    });
    return entries;
}

- (NSString *)logFilePath {
    NSString *logDir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                        stringByAppendingPathComponent:@"Logs"];
    return [logDir stringByAppendingPathComponent:@"VentoyMac.log"];
}

- (void)_openLogFile {
    NSString *path = self.logFilePath;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }

    self.logFileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    [self.logFileHandle seekToEndOfFile];
}

- (void)debug:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self _logWithLevel:VTLogLevelDebug format:format args:args];
    va_end(args);
}

- (void)info:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self _logWithLevel:VTLogLevelInfo format:format args:args];
    va_end(args);
}

- (void)warn:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self _logWithLevel:VTLogLevelWarn format:format args:args];
    va_end(args);
}

- (void)error:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self _logWithLevel:VTLogLevelError format:format args:args];
    va_end(args);
}

- (void)_logWithLevel:(VTLogLevel)level format:(NSString *)format args:(va_list)args {
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];

    VTLogEntry *entry = [[VTLogEntry alloc] init];
    entry.message = message;
    entry.level = level;
    entry.timestamp = [NSDate date];

    dispatch_async(self.logQueue, ^{
        [self.mutableLogEntries addObject:entry];

        // Write to log file
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *prefix;
        switch (level) {
            case VTLogLevelDebug: prefix = @"DEBUG"; break;
            case VTLogLevelInfo:  prefix = @"INFO "; break;
            case VTLogLevelWarn:  prefix = @"WARN "; break;
            case VTLogLevelError: prefix = @"ERROR"; break;
        }
        NSString *line = [NSString stringWithFormat:@"[%@] %@ %@\n",
                          [fmt stringFromDate:entry.timestamp], prefix, message];
        [self.logFileHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];

        // Also log to stderr
        fprintf(stderr, "%s", [line UTF8String]);

        // Post notification on main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:VTLogEntryAddedNotification
                                                                object:entry];
        });
    });
}

- (void)clear {
    dispatch_async(self.logQueue, ^{
        [self.mutableLogEntries removeAllObjects];
    });
}

- (void)dealloc {
    [self.logFileHandle closeFile];
}

@end
