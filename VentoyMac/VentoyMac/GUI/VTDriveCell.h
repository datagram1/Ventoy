/******************************************************************************
 * VTDriveCell.h — Custom table cell for drive list display
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP7 implements VTDriveCell.m against this interface.
 *****************************************************************************/

#import <Cocoa/Cocoa.h>
#import "VTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface VTDriveCell : NSTableCellView

/// Configure the cell with disk info.
- (void)configureWithDiskInfo:(VTDiskInfo *)diskInfo;

@end

NS_ASSUME_NONNULL_END
