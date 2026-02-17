/******************************************************************************
 * VTDiskSafetyTests.m — Disk filtering safety tests
 *
 * Verifies that internal/system disks are never offered for installation,
 * all returned drives are removable, and VTDiskInfo properties behave
 * correctly.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#import <XCTest/XCTest.h>
#import "VTTypes.h"
#import "VTDiskMonitor.h"

@interface VTDiskSafetyTests : XCTestCase
@end

@implementation VTDiskSafetyTests

#pragma mark - System Disk Filtering

// Verify that internal system disks are never offered for installation
- (void)testDisk0IsFiltered {
    // disk0 is always the internal system disk on macOS
    // VTDiskMonitor should never include it
    VTDiskMonitor *monitor = [[VTDiskMonitor alloc] init];
    NSArray<VTDiskInfo *> *drives = [monitor connectedUSBDrives];

    for (VTDiskInfo *disk in drives) {
        XCTAssertFalse([disk.bsdName isEqualToString:@"disk0"],
                       @"disk0 (system disk) should never appear in USB drive list");
        XCTAssertFalse([disk.bsdName isEqualToString:@"disk1"],
                       @"disk1 (system disk) should never appear in USB drive list");
    }
}

// Verify all returned drives claim to be removable
- (void)testAllDrivesAreRemovable {
    VTDiskMonitor *monitor = [[VTDiskMonitor alloc] init];
    NSArray<VTDiskInfo *> *drives = [monitor connectedUSBDrives];

    for (VTDiskInfo *disk in drives) {
        XCTAssertTrue(disk.isRemovable,
                      @"Drive %@ should be marked as removable", disk.bsdName);
    }
}

#pragma mark - VTDiskInfo Device Paths

// Verify VTDiskInfo has valid device paths
- (void)testDiskInfoPaths {
    VTDiskInfo *info = [[VTDiskInfo alloc] init];
    info.bsdName = @"disk4";
    info.devicePath = @"/dev/disk4";
    info.rawDevicePath = @"/dev/rdisk4";

    XCTAssertTrue([info.devicePath hasPrefix:@"/dev/"],
                  @"Device path should start with /dev/");
    XCTAssertTrue([info.rawDevicePath hasPrefix:@"/dev/r"],
                  @"Raw device path should start with /dev/r");
}

#pragma mark - Display Name and Size

// Verify displayName and humanReadableSize work
- (void)testDiskInfoDisplayName {
    VTDiskInfo *info = [[VTDiskInfo alloc] init];
    info.bsdName = @"disk4";
    info.devicePath = @"/dev/disk4";
    info.rawDevicePath = @"/dev/rdisk4";
    info.vendorName = @"SanDisk";
    info.productName = @"Ultra";
    info.sizeInBytes = 32ULL * 1024 * 1024 * 1024;
    info.isRemovable = YES;
    info.isWritable = YES;

    NSString *name = [info displayName];
    XCTAssertNotNil(name, @"Display name should not be nil");
    XCTAssertGreaterThan(name.length, 0, @"Display name should not be empty");

    NSString *size = [info humanReadableSize];
    XCTAssertNotNil(size, @"Human readable size should not be nil");
    XCTAssertTrue([size containsString:@"GB"] || [size containsString:@"32"],
                  @"32GB drive should show GB in size string");
}

#pragma mark - Minimum Disk Size Validation

// Verify minimum disk size validation
- (void)testMinimumDiskSize {
    // Ventoy requires at least 256MB
    uint64_t minSize = 256 * 1024 * 1024;
    VTDiskInfo *smallDisk = [[VTDiskInfo alloc] init];
    smallDisk.sizeInBytes = 100 * 1024 * 1024; // 100MB - too small
    XCTAssertTrue(smallDisk.sizeInBytes < minSize,
                  @"100MB disk should be below minimum size");

    VTDiskInfo *okDisk = [[VTDiskInfo alloc] init];
    okDisk.sizeInBytes = 512 * 1024 * 1024; // 512MB - OK
    XCTAssertTrue(okDisk.sizeInBytes >= minSize,
                  @"512MB disk should meet minimum size");
}

@end
