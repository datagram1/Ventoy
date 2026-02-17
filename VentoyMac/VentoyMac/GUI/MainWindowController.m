/******************************************************************************
 * MainWindowController.m — Main application window with programmatic UI
 *
 * OWNER: WP7 — Only WP7 may modify this file.
 *****************************************************************************/

#import "MainWindowController.h"
#import "VTTypes.h"
#import "VTDiskMonitor.h"
#import "VTDiskOperations.h"
#import "VTLog.h"
#import "VTBridge.h"
#import "VTDriveCell.h"

static const CGFloat kMargin = 20.0;
static const CGFloat kSpacing = 12.0;
static const CGFloat kLogHeight = 150.0;

@interface MainWindowController ()

// UI elements
@property (nonatomic, strong) NSPopUpButton *drivePopup;
@property (nonatomic, strong) NSTextField *driveNameLabel;
@property (nonatomic, strong) NSTextField *driveSizeLabel;
@property (nonatomic, strong) NSTextField *drivePathLabel;
@property (nonatomic, strong) NSTextField *driveVentoyLabel;
@property (nonatomic, strong) NSButton *gptRadio;
@property (nonatomic, strong) NSButton *mbrRadio;
@property (nonatomic, strong) NSButton *secureBootCheckbox;
@property (nonatomic, strong) NSTextField *volumeLabelField;
@property (nonatomic, strong) NSTextField *warningLabel;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *installButton;
@property (nonatomic, strong) NSButton *updateButton;
@property (nonatomic, strong) NSButton *logToggleButton;
@property (nonatomic, strong) NSScrollView *logScrollView;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, assign) BOOL logVisible;
@property (nonatomic, strong) NSLayoutConstraint *logHeightConstraint;
@property (nonatomic, strong) NSTextField *versionLabel;

@end

@implementation MainWindowController

#pragma mark - Initialization

- (instancetype)initWithDiskMonitor:(VTDiskMonitor *)monitor
                     diskOperations:(VTDiskOperations *)operations {
    NSRect frame = NSMakeRect(0, 0, 520, 460);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Ventoy for macOS";
    window.minSize = NSMakeSize(480, 400);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _diskMonitor = monitor;
        _diskOperations = operations;
        _logVisible = NO;
        [self _setupUI];
        [self _registerNotifications];
        [self _refreshDriveList];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Construction

- (NSTextField *)_createLabel:(NSString *)text bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    if (bold) {
        label.font = [NSFont boldSystemFontOfSize:13.0];
    } else {
        label.font = [NSFont systemFontOfSize:13.0];
    }
    return label;
}

- (NSTextField *)_createValueLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:13.0];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (void)_setupUI {
    NSView *contentView = self.window.contentView;

    /* ── Version label (top-right) ────────────────────────── */
    NSString *bundledVersion = [VTBridge bundledVentoyVersion];
    NSString *versionText = bundledVersion
        ? [NSString stringWithFormat:@"Ventoy %@", bundledVersion]
        : @"v1.0.0";
    self.versionLabel = [self _createLabel:versionText bold:NO];
    self.versionLabel.alignment = NSTextAlignmentRight;
    self.versionLabel.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:self.versionLabel];

    /* ── Drive popup ──────────────────────────────────────── */
    NSTextField *driveLabel = [self _createLabel:@"USB Drive:" bold:YES];
    [contentView addSubview:driveLabel];

    self.drivePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.drivePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.drivePopup.target = self;
    self.drivePopup.action = @selector(_driveSelectionChanged:);
    [contentView addSubview:self.drivePopup];

    /* ── Drive info rows (below popup) ─────────────────────── */
    NSTextField *sizeKey = [self _createLabel:@"Size:" bold:YES];
    self.driveSizeLabel = [self _createValueLabel:@"—"];
    NSTextField *ventoyKey = [self _createLabel:@"Ventoy:" bold:YES];
    self.driveVentoyLabel = [self _createValueLabel:@"Not Installed"];

    [contentView addSubview:sizeKey];
    [contentView addSubview:self.driveSizeLabel];
    [contentView addSubview:ventoyKey];
    [contentView addSubview:self.driveVentoyLabel];

    // Keep for _updateDriveInfo compatibility (not displayed)
    self.driveNameLabel = [NSTextField labelWithString:@"—"];
    self.drivePathLabel = [NSTextField labelWithString:@"—"];

    /* ── Partition style (radio buttons) ──────────────────── */
    NSTextField *partStyleLabel = [self _createLabel:@"Partition Style:" bold:YES];
    [contentView addSubview:partStyleLabel];

    self.gptRadio = [NSButton radioButtonWithTitle:@"GPT" target:self action:@selector(_partStyleChanged:)];
    self.gptRadio.translatesAutoresizingMaskIntoConstraints = NO;
    self.gptRadio.state = NSControlStateValueOn;
    [contentView addSubview:self.gptRadio];

    self.mbrRadio = [NSButton radioButtonWithTitle:@"MBR" target:self action:@selector(_partStyleChanged:)];
    self.mbrRadio.translatesAutoresizingMaskIntoConstraints = NO;
    self.mbrRadio.state = NSControlStateValueOff;
    [contentView addSubview:self.mbrRadio];

    /* ── Secure boot checkbox ─────────────────────────────── */
    NSTextField *secBootLabel = [self _createLabel:@"Secure Boot:" bold:YES];
    [contentView addSubview:secBootLabel];

    self.secureBootCheckbox = [NSButton checkboxWithTitle:@"Enable Secure Boot"
                                                  target:nil
                                                  action:nil];
    self.secureBootCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.secureBootCheckbox.state = NSControlStateValueOff;
    [contentView addSubview:self.secureBootCheckbox];

    /* ── Volume label ─────────────────────────────────────── */
    NSTextField *volLabel = [self _createLabel:@"Volume Label:" bold:YES];
    [contentView addSubview:volLabel];

    self.volumeLabelField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.volumeLabelField.translatesAutoresizingMaskIntoConstraints = NO;
    self.volumeLabelField.stringValue = @"Ventoy";
    self.volumeLabelField.placeholderString = @"Ventoy";
    self.volumeLabelField.bezelStyle = NSTextFieldRoundedBezel;
    [contentView addSubview:self.volumeLabelField];

    /* ── Warning label ────────────────────────────────────── */
    self.warningLabel = [self _createLabel:@"Install will erase all data on the selected USB drive." bold:NO];
    self.warningLabel.textColor = [NSColor systemRedColor];
    self.warningLabel.font = [NSFont systemFontOfSize:11.0];
    [contentView addSubview:self.warningLabel];

    /* ── Progress bar ─────────────────────────────────────── */
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;
    [contentView addSubview:self.progressBar];

    /* ── Status label ─────────────────────────────────────── */
    self.statusLabel = [self _createLabel:@"Ready" bold:NO];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:self.statusLabel];

    /* ── Buttons ──────────────────────────────────────────── */
    self.installButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.installButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.installButton.title = @"Install";
    self.installButton.bezelStyle = NSBezelStyleRounded;
    self.installButton.keyEquivalent = @"\r";
    self.installButton.hasDestructiveAction = YES;
    self.installButton.target = self;
    self.installButton.action = @selector(installAction:);
    [contentView addSubview:self.installButton];

    self.updateButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.updateButton.title = @"Update";
    self.updateButton.bezelStyle = NSBezelStyleRounded;
    self.updateButton.target = self;
    self.updateButton.action = @selector(updateAction:);
    self.updateButton.enabled = NO;
    [contentView addSubview:self.updateButton];

    self.logToggleButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.logToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.logToggleButton.title = @"Show Log";
    self.logToggleButton.bezelStyle = NSBezelStyleRounded;
    self.logToggleButton.target = self;
    self.logToggleButton.action = @selector(logToggleAction:);
    [contentView addSubview:self.logToggleButton];

    /* ── Log scroll view ──────────────────────────────────── */
    self.logScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.logScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logScrollView.hasVerticalScroller = YES;
    self.logScrollView.hasHorizontalScroller = NO;
    self.logScrollView.borderType = NSBezelBorder;
    self.logScrollView.autohidesScrollers = YES;
    self.logScrollView.hidden = YES;

    self.logTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.richText = YES;
    self.logTextView.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.logTextView.backgroundColor = [NSColor textBackgroundColor];
    self.logTextView.autoresizingMask = NSViewWidthSizable;
    self.logTextView.textContainer.widthTracksTextView = YES;
    self.logScrollView.documentView = self.logTextView;
    [contentView addSubview:self.logScrollView];

    /* ── Auto Layout constraints ──────────────────────────── */
    CGFloat labelColWidth = 110.0;

    [NSLayoutConstraint activateConstraints:@[

        // Version label — top right
        [self.versionLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:kMargin],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Drive label + popup — top row (popup stops before version label)
        [driveLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [driveLabel.centerYAnchor constraintEqualToAnchor:self.drivePopup.centerYAnchor],
        [driveLabel.widthAnchor constraintEqualToConstant:labelColWidth],

        [self.drivePopup.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:kMargin],
        [self.drivePopup.leadingAnchor constraintEqualToAnchor:driveLabel.trailingAnchor constant:4.0],
        [self.drivePopup.trailingAnchor constraintEqualToAnchor:self.versionLabel.leadingAnchor constant:-8.0],

        // Size row (below popup)
        [sizeKey.topAnchor constraintEqualToAnchor:self.drivePopup.bottomAnchor constant:10.0],
        [sizeKey.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [sizeKey.widthAnchor constraintEqualToConstant:labelColWidth],
        [self.driveSizeLabel.centerYAnchor constraintEqualToAnchor:sizeKey.centerYAnchor],
        [self.driveSizeLabel.leadingAnchor constraintEqualToAnchor:sizeKey.trailingAnchor constant:4.0],
        [self.driveSizeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Ventoy version row
        [ventoyKey.topAnchor constraintEqualToAnchor:sizeKey.bottomAnchor constant:4.0],
        [ventoyKey.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [ventoyKey.widthAnchor constraintEqualToConstant:labelColWidth],
        [self.driveVentoyLabel.centerYAnchor constraintEqualToAnchor:ventoyKey.centerYAnchor],
        [self.driveVentoyLabel.leadingAnchor constraintEqualToAnchor:ventoyKey.trailingAnchor constant:4.0],
        [self.driveVentoyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Partition style row
        [partStyleLabel.topAnchor constraintEqualToAnchor:ventoyKey.bottomAnchor constant:kSpacing + 4.0],
        [partStyleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [partStyleLabel.widthAnchor constraintEqualToConstant:labelColWidth],

        [self.gptRadio.centerYAnchor constraintEqualToAnchor:partStyleLabel.centerYAnchor],
        [self.gptRadio.leadingAnchor constraintEqualToAnchor:partStyleLabel.trailingAnchor constant:4.0],

        [self.mbrRadio.centerYAnchor constraintEqualToAnchor:partStyleLabel.centerYAnchor],
        [self.mbrRadio.leadingAnchor constraintEqualToAnchor:self.gptRadio.trailingAnchor constant:16.0],

        // Secure boot row
        [secBootLabel.topAnchor constraintEqualToAnchor:partStyleLabel.bottomAnchor constant:kSpacing],
        [secBootLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [secBootLabel.widthAnchor constraintEqualToConstant:labelColWidth],

        [self.secureBootCheckbox.centerYAnchor constraintEqualToAnchor:secBootLabel.centerYAnchor],
        [self.secureBootCheckbox.leadingAnchor constraintEqualToAnchor:secBootLabel.trailingAnchor constant:4.0],

        // Volume label row
        [volLabel.topAnchor constraintEqualToAnchor:secBootLabel.bottomAnchor constant:kSpacing],
        [volLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [volLabel.widthAnchor constraintEqualToConstant:labelColWidth],

        [self.volumeLabelField.centerYAnchor constraintEqualToAnchor:volLabel.centerYAnchor],
        [self.volumeLabelField.leadingAnchor constraintEqualToAnchor:volLabel.trailingAnchor constant:4.0],
        [self.volumeLabelField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Warning label
        [self.warningLabel.topAnchor constraintEqualToAnchor:volLabel.bottomAnchor constant:kSpacing],
        [self.warningLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [self.warningLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Progress bar
        [self.progressBar.topAnchor constraintEqualToAnchor:self.warningLabel.bottomAnchor constant:8.0],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Status label
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:6.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],

        // Button row
        [self.installButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:kSpacing],
        [self.installButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [self.installButton.widthAnchor constraintGreaterThanOrEqualToConstant:80.0],

        [self.updateButton.centerYAnchor constraintEqualToAnchor:self.installButton.centerYAnchor],
        [self.updateButton.leadingAnchor constraintEqualToAnchor:self.installButton.trailingAnchor constant:12.0],
        [self.updateButton.widthAnchor constraintGreaterThanOrEqualToConstant:80.0],

        [self.logToggleButton.centerYAnchor constraintEqualToAnchor:self.installButton.centerYAnchor],
        [self.logToggleButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],
        [self.logToggleButton.widthAnchor constraintGreaterThanOrEqualToConstant:90.0],

        // Log scroll view
        [self.logScrollView.topAnchor constraintEqualToAnchor:self.installButton.bottomAnchor constant:kSpacing],
        [self.logScrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:kMargin],
        [self.logScrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-kMargin],
        [self.logScrollView.bottomAnchor constraintLessThanOrEqualToAnchor:contentView.bottomAnchor constant:-kMargin],
    ]];

    // Log height constraint — 0 when hidden, kLogHeight when visible
    self.logHeightConstraint = [self.logScrollView.heightAnchor constraintEqualToConstant:0.0];
    self.logHeightConstraint.active = YES;
}

#pragma mark - Notifications

- (void)_registerNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_diskAppeared:)
                                                 name:VTDiskAppearedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_diskDisappeared:)
                                                 name:VTDiskDisappearedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_logEntryAdded:)
                                                 name:VTLogEntryAddedNotification
                                               object:nil];
}

- (void)_diskAppeared:(NSNotification *)note {
    [self _refreshDriveList];
}

- (void)_diskDisappeared:(NSNotification *)note {
    [self _refreshDriveList];
}

- (void)_logEntryAdded:(NSNotification *)note {
    VTLogEntry *entry = note.userInfo[@"entry"];
    if (!entry) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAttributedString *attrStr = [entry attributedString];
        NSMutableAttributedString *newline = [[NSMutableAttributedString alloc]
            initWithString:@"\n"];
        [[self.logTextView textStorage] appendAttributedString:attrStr];
        [[self.logTextView textStorage] appendAttributedString:newline];
        [self.logTextView scrollToEndOfDocument:nil];
    });
}

#pragma mark - Drive List Management

- (void)_refreshDriveList {
    NSArray<VTDiskInfo *> *drives = [self.diskMonitor connectedUSBDrives];

    [self.drivePopup removeAllItems];

    if (drives.count == 0) {
        [self.drivePopup addItemWithTitle:@"No USB drives detected"];
        self.drivePopup.enabled = NO;
        self.installButton.enabled = NO;
        self.updateButton.enabled = NO;
        [self _clearDriveInfo];
        return;
    }

    self.drivePopup.enabled = YES;
    self.installButton.enabled = YES;

    for (VTDiskInfo *disk in drives) {
        NSString *title = [disk displayName];
        [self.drivePopup addItemWithTitle:title];
        self.drivePopup.lastItem.representedObject = disk;
    }

    [self _updateDriveInfo];
}

- (void)_clearDriveInfo {
    self.driveNameLabel.stringValue = @"—";
    self.driveSizeLabel.stringValue = @"—";
    self.drivePathLabel.stringValue = @"—";
    self.driveVentoyLabel.stringValue = @"Not Installed";
}

- (void)_updateDriveInfo {
    VTDiskInfo *disk = self.drivePopup.selectedItem.representedObject;
    if (!disk) {
        [self _clearDriveInfo];
        self.updateButton.enabled = NO;
        return;
    }

    // Build display name from vendor/product
    NSMutableString *driveName = [NSMutableString string];
    if (disk.vendorName.length > 0) {
        [driveName appendString:disk.vendorName];
    }
    if (disk.productName.length > 0) {
        if (driveName.length > 0) [driveName appendString:@" "];
        [driveName appendString:disk.productName];
    }
    if (driveName.length == 0) {
        [driveName appendString:disk.bsdName];
    }

    self.driveNameLabel.stringValue = driveName;
    self.driveSizeLabel.stringValue = [disk humanReadableSize];
    self.drivePathLabel.stringValue = disk.devicePath;

    // Show placeholder while checking version in background
    self.driveVentoyLabel.stringValue = @"Checking...";
    self.updateButton.enabled = NO;

    // Detect installed Ventoy version in background (disk I/O may be slow)
    NSString *rawPath = disk.rawDevicePath;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *version = [VTBridge ventoyVersionFromDisk:rawPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // Ensure the same drive is still selected
            VTDiskInfo *currentDisk = strongSelf.drivePopup.selectedItem.representedObject;
            if (![currentDisk.rawDevicePath isEqualToString:rawPath]) return;

            if (version) {
                disk.ventoyVersion = version;
                strongSelf.driveVentoyLabel.stringValue = version;
                strongSelf.updateButton.enabled = YES;
                [[VTLog sharedLog] info:@"Ventoy %@ detected on %@", version, disk.devicePath];
            } else {
                disk.ventoyVersion = nil;
                strongSelf.driveVentoyLabel.stringValue = @"Not Installed";
                strongSelf.updateButton.enabled = NO;
            }
        });
    });
}

- (void)_driveSelectionChanged:(id)sender {
    [self _updateDriveInfo];
}

#pragma mark - Radio Button Handling

- (void)_partStyleChanged:(NSButton *)sender {
    if (sender == self.gptRadio) {
        self.gptRadio.state = NSControlStateValueOn;
        self.mbrRadio.state = NSControlStateValueOff;
    } else {
        self.gptRadio.state = NSControlStateValueOff;
        self.mbrRadio.state = NSControlStateValueOn;
    }
}

#pragma mark - Actions

- (void)installAction:(id)sender {
    VTDiskInfo *disk = self.drivePopup.selectedItem.representedObject;
    if (!disk) return;

    // Disable buttons during install
    self.installButton.enabled = NO;
    self.updateButton.enabled = NO;
    self.drivePopup.enabled = NO;

    VTPartitionStyle style = (self.gptRadio.state == NSControlStateValueOn)
        ? VTPartitionStyleGPT
        : VTPartitionStyleMBR;
    BOOL secureBoot = (self.secureBootCheckbox.state == NSControlStateValueOn);
    NSString *label = self.volumeLabelField.stringValue;
    if (label.length == 0) label = @"Ventoy";

    [[VTLog sharedLog] info:@"Starting Ventoy install on %@...", disk.devicePath];

    __weak __typeof__(self) weakSelf = self;
    [self.diskOperations installVentoyToDisk:disk
                             partitionStyle:style
                                 secureBoot:secureBoot
                                volumeLabel:label
                                   progress:^(VTInstallStage stage, double percent, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressBar.doubleValue = percent;
            strongSelf.statusLabel.stringValue = message;
        });
    }
                                 completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.installButton.enabled = YES;
            strongSelf.updateButton.enabled = YES;
            strongSelf.drivePopup.enabled = YES;

            if (success) {
                [[VTLog sharedLog] info:@"Ventoy install completed successfully on %@.", disk.devicePath];
                strongSelf.statusLabel.stringValue = @"Installation complete!";
                NSAlert *done = [[NSAlert alloc] init];
                done.messageText = @"Success";
                done.informativeText = @"Ventoy has been installed. You can now copy ISO files to the Ventoy partition.";
                [done runModal];
            } else {
                [[VTLog sharedLog] error:@"Ventoy install failed on %@: %@", disk.devicePath, error.localizedDescription];
                strongSelf.statusLabel.stringValue =
                    [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
                NSAlert *fail = [[NSAlert alloc] init];
                fail.messageText = @"Installation Failed";
                fail.informativeText = error.localizedDescription;
                fail.alertStyle = NSAlertStyleCritical;
                [fail runModal];
            }

            strongSelf.progressBar.doubleValue = 0;
            [strongSelf _refreshDriveList];
        });
    }];
}

- (void)updateAction:(id)sender {
    VTDiskInfo *disk = self.drivePopup.selectedItem.representedObject;
    if (!disk) return;

    // Disable buttons during update
    self.installButton.enabled = NO;
    self.updateButton.enabled = NO;
    self.drivePopup.enabled = NO;

    BOOL secureBoot = (self.secureBootCheckbox.state == NSControlStateValueOn);

    [[VTLog sharedLog] info:@"Starting Ventoy update on %@...", disk.devicePath];

    __weak __typeof__(self) weakSelf = self;
    [self.diskOperations updateVentoyOnDisk:disk
                                secureBoot:secureBoot
                                  progress:^(VTInstallStage stage, double percent, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressBar.doubleValue = percent;
            strongSelf.statusLabel.stringValue = message;
        });
    }
                                completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.installButton.enabled = YES;
            strongSelf.updateButton.enabled = YES;
            strongSelf.drivePopup.enabled = YES;

            if (success) {
                [[VTLog sharedLog] info:@"Ventoy update completed successfully on %@.", disk.devicePath];
                strongSelf.statusLabel.stringValue = @"Update complete!";
                NSAlert *done = [[NSAlert alloc] init];
                done.messageText = @"Success";
                done.informativeText = @"Ventoy has been updated. Your ISO files are preserved.";
                [done runModal];
            } else {
                [[VTLog sharedLog] error:@"Ventoy update failed on %@: %@", disk.devicePath, error.localizedDescription];
                strongSelf.statusLabel.stringValue =
                    [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
                NSAlert *fail = [[NSAlert alloc] init];
                fail.messageText = @"Update Failed";
                fail.informativeText = error.localizedDescription;
                fail.alertStyle = NSAlertStyleCritical;
                [fail runModal];
            }

            strongSelf.progressBar.doubleValue = 0;
            [strongSelf _refreshDriveList];
        });
    }];
}

- (void)logToggleAction:(id)sender {
    self.logVisible = !self.logVisible;

    if (self.logVisible) {
        self.logToggleButton.title = @"Hide Log";
        self.logScrollView.hidden = NO;
        self.logHeightConstraint.constant = kLogHeight;
    } else {
        self.logToggleButton.title = @"Show Log";
        self.logHeightConstraint.constant = 0.0;
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        [self.window.contentView layoutSubtreeIfNeeded];
    } completionHandler:^{
        if (!self.logVisible) {
            self.logScrollView.hidden = YES;
        }
    }];
}

@end
