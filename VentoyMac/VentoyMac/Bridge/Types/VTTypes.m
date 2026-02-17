/******************************************************************************
 * VTTypes.m — Shared type implementations
 *
 * OWNER: Gate 0 (not modified during Wave 1)
 *****************************************************************************/

#import "VTTypes.h"

NSNotificationName const VTDiskAppearedNotification = @"VTDiskAppearedNotification";
NSNotificationName const VTDiskDisappearedNotification = @"VTDiskDisappearedNotification";
NSNotificationName const VTLogEntryAddedNotification = @"VTLogEntryAddedNotification";

NSErrorDomain const VTErrorDomain = @"com.knws.VentoyMac.error";

@implementation VTDiskInfo

- (NSString *)humanReadableSize {
    double size = (double)self.sizeInBytes;
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    int unitIndex = 0;
    while (size >= 1024.0 && unitIndex < (int)units.count - 1) {
        size /= 1024.0;
        unitIndex++;
    }
    return [NSString stringWithFormat:@"%.1f %@", size, units[unitIndex]];
}

- (NSString *)displayName {
    NSMutableString *name = [NSMutableString string];
    if (self.vendorName.length > 0) {
        [name appendString:self.vendorName];
    }
    if (self.productName.length > 0) {
        if (name.length > 0) [name appendString:@" "];
        [name appendString:self.productName];
    }
    if (name.length == 0) {
        [name appendFormat:@"USB Drive (%@)", self.bsdName];
    }
    return [name copy];
}

@end
