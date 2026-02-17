/******************************************************************************
 * main.m — Application entry point (NIB-less)
 *
 * OWNER: WP8 — Only WP8 may modify this file.
 *****************************************************************************/

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
