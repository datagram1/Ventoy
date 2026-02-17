/******************************************************************************
 * VTDriveCell.m — Custom table cell for drive display
 *
 * OWNER: WP7 — Only WP7 may modify this file.
 *****************************************************************************/

#import "VTDriveCell.h"

@implementation VTDriveCell

- (void)configureWithDiskInfo:(VTDiskInfo *)diskInfo {
    self.textField.stringValue = [diskInfo displayName];
    // Set icon to external drive icon using SF Symbols
    self.imageView.image = [NSImage imageWithSystemSymbolName:@"externaldrive.fill"
                                    accessibilityDescription:@"USB Drive"];
}

@end
