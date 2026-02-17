/******************************************************************************
 * VTDiskMonitor.h — USB drive detection via DiskArbitration framework
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP4 implements VTDiskMonitor.m against this interface.
 *****************************************************************************/

#import <Foundation/Foundation.h>
#import "VTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VTDiskMonitorDelegate <NSObject>
@optional
- (void)diskMonitor:(id)monitor didDetectDisk:(VTDiskInfo *)disk;
- (void)diskMonitor:(id)monitor didRemoveDisk:(VTDiskInfo *)disk;
@end

@interface VTDiskMonitor : NSObject

@property (nonatomic, weak, nullable) id<VTDiskMonitorDelegate> delegate;
@property (nonatomic, readonly) BOOL isMonitoring;

/// Start monitoring for USB drive insertion/removal.
- (void)startMonitoring;

/// Stop monitoring.
- (void)stopMonitoring;

/// Current list of connected USB/removable drives.
- (NSArray<VTDiskInfo *> *)connectedUSBDrives;

/// Force a refresh of the drive list.
- (void)refreshDriveList;

@end

NS_ASSUME_NONNULL_END
