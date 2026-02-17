/******************************************************************************
 * AppDelegate.h — Application delegate
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP8 implements AppDelegate.m against this interface.
 *****************************************************************************/

#import <Cocoa/Cocoa.h>

@class VTDiskMonitor;
@class MainWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainWindowController *mainWindowController;
@property (nonatomic, strong) VTDiskMonitor *diskMonitor;

@end
