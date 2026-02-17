/******************************************************************************
 * AppDelegate.m — Application delegate
 *
 * OWNER: WP8 — Only WP8 may modify this file.
 *****************************************************************************/

#import "AppDelegate.h"
#import "MainWindowController.h"
#import "VTDiskMonitor.h"
#import "VTDiskOperations.h"
#import "VTLog.h"
#import "VTBridge.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[VTLog sharedLog] info:@"VentoyMac starting..."];

    // Create main menu programmatically (no XIB)
    [self _createMainMenu];

    // Create disk monitor
    self.diskMonitor = [[VTDiskMonitor alloc] init];

    // Create disk operations
    VTDiskOperations *diskOps = [[VTDiskOperations alloc] init];

    // Create main window
    self.mainWindowController = [[MainWindowController alloc] initWithDiskMonitor:self.diskMonitor
                                                                  diskOperations:diskOps];
    [self.mainWindowController showWindow:self];
    [self.mainWindowController.window makeKeyAndOrderFront:self];

    // Start monitoring for USB drives
    [self.diskMonitor startMonitoring];

    [[VTLog sharedLog] info:@"VentoyMac ready."];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[VTLog sharedLog] info:@"VentoyMac shutting down..."];
    [self.diskMonitor stopMonitoring];
}

#pragma mark - Menu Bar (Programmatic)

- (void)_createMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // Application menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"VentoyMac"];
    [appMenu addItemWithTitle:@"About Ventoy for macOS"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide VentoyMac"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit VentoyMac"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    fileMenuItem.submenu = fileMenu;
    [mainMenu addItem:fileMenuItem];

    // Edit menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];

    // Window menu
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize"
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom"
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    windowMenuItem.submenu = windowMenu;
    [mainMenu addItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];

    // Help menu
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [helpMenu addItemWithTitle:@"VentoyMac Help"
                        action:@selector(showHelp:)
                 keyEquivalent:@"?"];
    helpMenuItem.submenu = helpMenu;
    [mainMenu addItem:helpMenuItem];
    [NSApp setHelpMenu:helpMenu];

    [NSApp setMainMenu:mainMenu];
}

- (IBAction)orderFrontStandardAboutPanel:(id)sender {
    NSString *ventoyVersion = [VTBridge bundledVentoyVersion] ?: @"1.0.0";

    NSDictionary *options = @{
        @"ApplicationName": @"Ventoy for macOS",
        @"Version": @"1.0.0",
        @"Copyright": @"GPL v3 — Based on Ventoy by longpanda.\nmacOS port by Key Network Services Ltd.",
        @"ApplicationVersion": [NSString stringWithFormat:@"Ventoy Core: %@", ventoyVersion],
    };

    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

@end
