/******************************************************************************
 * VTDiskMonitor.m — USB drive detection via DiskArbitration framework
 *
 * OWNER: WP4 — Only WP4 may modify this file.
 *****************************************************************************/

#import "VTDiskMonitor.h"
#import <DiskArbitration/DiskArbitration.h>
#import <IOKit/storage/IOMedia.h>
#import <IOKit/IOKitLib.h>

#pragma mark - Forward declarations

static void diskAppearedCallback(DADiskRef disk, void *context);
static void diskDisappearedCallback(DADiskRef disk, void *context);

#pragma mark - Private interface

@interface VTDiskMonitor () {
    DASessionRef _session;
    dispatch_queue_t _monitorQueue;
}
@property (nonatomic, strong) NSMutableArray<VTDiskInfo *> *drives;
@end

#pragma mark - Implementation

@implementation VTDiskMonitor {
    BOOL _isMonitoring;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _drives = [NSMutableArray array];
        _isMonitoring = NO;
    }
    return self;
}

- (void)dealloc {
    if (_isMonitoring) {
        [self stopMonitoring];
    }
}

#pragma mark - Monitoring lifecycle

- (BOOL)isMonitoring {
    return _isMonitoring;
}

- (void)startMonitoring {
    if (_isMonitoring) {
        return;
    }

    _monitorQueue = dispatch_queue_create("com.knws.ventoymac.diskmonitor", DISPATCH_QUEUE_SERIAL);

    _session = DASessionCreate(kCFAllocatorDefault);
    if (!_session) {
        NSLog(@"VTDiskMonitor: Failed to create DiskArbitration session");
        return;
    }

    /* Build a matching dictionary that filters for whole disks only */
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(match, kDADiskDescriptionMediaWholeKey, kCFBooleanTrue);

    /* Register appear/disappear callbacks */
    DARegisterDiskAppearedCallback(_session, match, diskAppearedCallback, (__bridge void *)self);
    DARegisterDiskDisappearedCallback(_session, match, diskDisappearedCallback, (__bridge void *)self);

    /* Schedule the session on our serial queue */
    DASessionSetDispatchQueue(_session, _monitorQueue);

    _isMonitoring = YES;

    CFRelease(match);
}

- (void)stopMonitoring {
    if (!_isMonitoring) {
        return;
    }

    DAUnregisterCallback(_session, diskAppearedCallback, (__bridge void *)self);
    DAUnregisterCallback(_session, diskDisappearedCallback, (__bridge void *)self);

    DASessionSetDispatchQueue(_session, NULL);

    CFRelease(_session);
    _session = NULL;

    _isMonitoring = NO;
}

#pragma mark - Public accessors

- (NSArray<VTDiskInfo *> *)connectedUSBDrives {
    @synchronized (self.drives) {
        return [self.drives copy];
    }
}

#pragma mark - Refresh

- (void)refreshDriveList {
    @synchronized (self.drives) {
        [self.drives removeAllObjects];
    }

    if (!_session) {
        return;
    }

    /*
     * Enumerate all IOMedia objects and feed whole-disk entries through
     * the same handleDiskAppeared: path used by the live callbacks.
     */
    io_iterator_t iterator;
    CFMutableDictionaryRef matchDict = IOServiceMatching("IOMedia");
    /* Filter to whole media only */
    CFDictionarySetValue(matchDict, CFSTR("Whole"), kCFBooleanTrue);

    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) {
        NSLog(@"VTDiskMonitor: IOServiceGetMatchingServices failed: %d", kr);
        return;
    }

    io_object_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        DADiskRef disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, _session, entry);
        if (disk) {
            [self handleDiskAppeared:disk];
            CFRelease(disk);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

#pragma mark - C callbacks

static void diskAppearedCallback(DADiskRef disk, void *context) {
    VTDiskMonitor *monitor = (__bridge VTDiskMonitor *)context;
    [monitor handleDiskAppeared:disk];
}

static void diskDisappearedCallback(DADiskRef disk, void *context) {
    VTDiskMonitor *monitor = (__bridge VTDiskMonitor *)context;
    [monitor handleDiskDisappeared:disk];
}

#pragma mark - Disk event handling

- (void)handleDiskAppeared:(DADiskRef)disk {
    CFDictionaryRef description = DADiskCopyDescription(disk);
    if (!description) {
        return;
    }

    /* Extract BSD name */
    CFStringRef cfBsdName = CFDictionaryGetValue(description, kDADiskDescriptionMediaBSDNameKey);
    if (!cfBsdName) {
        CFRelease(description);
        return;
    }
    NSString *bsdName = (__bridge NSString *)cfBsdName;

    /* Skip internal system disks (disk0, disk1 are typically the internal drive) */
    if ([bsdName isEqualToString:@"disk0"] || [bsdName isEqualToString:@"disk1"]) {
        CFRelease(description);
        return;
    }

    /* Extract removable flag */
    CFBooleanRef cfRemovable = CFDictionaryGetValue(description, kDADiskDescriptionMediaRemovableKey);
    BOOL isRemovable = cfRemovable ? CFBooleanGetValue(cfRemovable) : NO;

    /* Extract bus type (protocol) */
    CFStringRef cfBusType = CFDictionaryGetValue(description, kDADiskDescriptionDeviceProtocolKey);
    NSString *busType = cfBusType ? (__bridge NSString *)cfBusType : nil;

    /* Filter: must be a real USB device — reject disk images and non-USB protocols */
    BOOL isUSB = busType && [busType caseInsensitiveCompare:@"USB"] == NSOrderedSame;
    if (!isUSB) {
        CFRelease(description);
        return;
    }

    /* Extract size */
    CFNumberRef cfSize = CFDictionaryGetValue(description, kDADiskDescriptionMediaSizeKey);
    uint64_t sizeInBytes = 0;
    if (cfSize) {
        CFNumberGetValue(cfSize, kCFNumberSInt64Type, &sizeInBytes);
    }
    if (sizeInBytes == 0) {
        CFRelease(description);
        return;
    }

    /* Extract writable flag */
    CFBooleanRef cfWritable = CFDictionaryGetValue(description, kDADiskDescriptionMediaWritableKey);
    BOOL isWritable = cfWritable ? CFBooleanGetValue(cfWritable) : NO;

    /* Extract vendor and product names */
    CFStringRef cfVendor = CFDictionaryGetValue(description, kDADiskDescriptionDeviceVendorKey);
    NSString *vendorName = cfVendor ? [(__bridge NSString *)cfVendor stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;

    CFStringRef cfProduct = CFDictionaryGetValue(description, kDADiskDescriptionDeviceModelKey);
    NSString *productName = cfProduct ? [(__bridge NSString *)cfProduct stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;

    CFRelease(description);

    /* Build VTDiskInfo */
    VTDiskInfo *diskInfo = [[VTDiskInfo alloc] init];
    diskInfo.bsdName = bsdName;
    diskInfo.devicePath = [NSString stringWithFormat:@"/dev/%@", bsdName];
    diskInfo.rawDevicePath = [NSString stringWithFormat:@"/dev/r%@", bsdName];
    diskInfo.vendorName = vendorName;
    diskInfo.productName = productName;
    diskInfo.busType = busType;
    diskInfo.sizeInBytes = sizeInBytes;
    diskInfo.isRemovable = isRemovable;
    diskInfo.isWritable = isWritable;
    diskInfo.ventoyVersion = nil;

    /* Add to drives array (thread-safe) */
    @synchronized (self.drives) {
        /* Avoid duplicates */
        for (VTDiskInfo *existing in self.drives) {
            if ([existing.bsdName isEqualToString:bsdName]) {
                return;
            }
        }
        [self.drives addObject:diskInfo];
    }

    /* Notify delegate and post notification on main queue */
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(diskMonitor:didDetectDisk:)]) {
            [self.delegate diskMonitor:self didDetectDisk:diskInfo];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:VTDiskAppearedNotification
                                                            object:diskInfo];
    });
}

- (void)handleDiskDisappeared:(DADiskRef)disk {
    const char *bsdNameCStr = DADiskGetBSDName(disk);
    if (!bsdNameCStr) {
        return;
    }
    NSString *bsdName = [NSString stringWithUTF8String:bsdNameCStr];

    VTDiskInfo *removedDisk = nil;

    @synchronized (self.drives) {
        for (VTDiskInfo *info in self.drives) {
            if ([info.bsdName isEqualToString:bsdName]) {
                removedDisk = info;
                break;
            }
        }
        if (removedDisk) {
            [self.drives removeObject:removedDisk];
        }
    }

    if (!removedDisk) {
        return;
    }

    /* Notify delegate and post notification on main queue */
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(diskMonitor:didRemoveDisk:)]) {
            [self.delegate diskMonitor:self didRemoveDisk:removedDisk];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:VTDiskDisappearedNotification
                                                            object:removedDisk];
    });
}

@end
