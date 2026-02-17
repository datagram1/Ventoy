/******************************************************************************
 * MainWindowController.h — Main application window
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP7 implements MainWindowController.m against this interface.
 *****************************************************************************/

#import <Cocoa/Cocoa.h>

@class VTDiskMonitor;
@class VTDiskOperations;

NS_ASSUME_NONNULL_BEGIN

@interface MainWindowController : NSWindowController

@property (nonatomic, strong) VTDiskMonitor *diskMonitor;
@property (nonatomic, strong) VTDiskOperations *diskOperations;

/// Create the window controller with its programmatic UI.
- (instancetype)initWithDiskMonitor:(VTDiskMonitor *)monitor
                     diskOperations:(VTDiskOperations *)operations;

@end

NS_ASSUME_NONNULL_END
