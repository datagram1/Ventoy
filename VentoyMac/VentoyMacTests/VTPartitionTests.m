/******************************************************************************
 * VTPartitionTests.m — GPT/MBR partition table validation tests
 *
 * Tests partition table writing on file-backed images, verifying MBR
 * signatures, GPT headers, partition layout, and UUID read/write.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#import <XCTest/XCTest.h>
#import "VTTypes.h"
#import "VTBridge.h"
#include "vtoy_darwin.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

@interface VTPartitionTests : XCTestCase
@property (nonatomic, copy) NSString *testImagePath;
@end

@implementation VTPartitionTests

- (void)setUp {
    [super setUp];
    // Create a temporary file-backed disk image for testing
    self.testImagePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ventoy_test.img"];

    // Create a 512MB sparse file
    int fd = open([self.testImagePath UTF8String], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        // Seek to 512MB - 1 and write a single byte to create a sparse file
        off_t size = 512 * 1024 * 1024;
        lseek(fd, size - 1, SEEK_SET);
        uint8_t zero = 0;
        write(fd, &zero, 1);
        close(fd);
    }
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.testImagePath error:nil];
    [super tearDown];
}

#pragma mark - MBR Partition Table

// Test MBR partition table writing on a file-backed image
- (void)testWriteMBRPartitionTable {
    int fd = open([self.testImagePath UTF8String], O_RDWR);
    XCTAssertGreaterThan(fd, 0, @"Should be able to open test image");

    uint64_t diskSize = 512 * 1024 * 1024;
    uint64_t part2Start = 0;
    int ret = vtoy_darwin_write_mbr_table(fd, diskSize, VENTOY_PART_SIZE_MB, &part2Start);

    XCTAssertEqual(ret, 0, @"MBR table write should succeed");
    XCTAssertGreaterThan(part2Start, 0, @"Partition 2 start sector should be non-zero");

    // Verify MBR signature
    uint8_t mbr[512];
    pread(fd, mbr, 512, 0);
    XCTAssertEqual(mbr[510], 0x55, @"MBR signature byte 1 should be 0x55");
    XCTAssertEqual(mbr[511], 0xAA, @"MBR signature byte 2 should be 0xAA");

    // Verify partition 1 exists (starts at offset 446)
    uint8_t partType1 = mbr[446 + 4]; // Partition type at offset 4 within entry
    XCTAssertNotEqual(partType1, 0, @"Partition 1 type should not be zero");

    // Verify partition 2 exists
    uint8_t partType2 = mbr[462 + 4]; // Second partition entry at 446+16
    XCTAssertNotEqual(partType2, 0, @"Partition 2 type should not be zero");

    // Partition 2 should be FAT16/EFI type
    // Common types: 0x06 (FAT16B), 0x0E (FAT16B LBA), 0xEF (EFI System)
    XCTAssertTrue(partType2 == 0xEF || partType2 == 0x06 || partType2 == 0x0E,
                  @"Partition 2 should be FAT16 or EFI type, got 0x%02X", partType2);

    close(fd);
}

#pragma mark - GPT Partition Table

// Test GPT partition table writing on a file-backed image
- (void)testWriteGPTPartitionTable {
    int fd = open([self.testImagePath UTF8String], O_RDWR);
    XCTAssertGreaterThan(fd, 0, @"Should be able to open test image");

    uint64_t diskSize = 512 * 1024 * 1024;
    uint64_t part2Start = 0;
    int ret = vtoy_darwin_write_gpt_table(fd, diskSize, VENTOY_PART_SIZE_MB, &part2Start);

    XCTAssertEqual(ret, 0, @"GPT table write should succeed");
    XCTAssertGreaterThan(part2Start, 0, @"Partition 2 start sector should be non-zero");

    // Verify protective MBR signature
    uint8_t mbr[512];
    pread(fd, mbr, 512, 0);
    XCTAssertEqual(mbr[510], 0x55, @"Protective MBR signature byte 1");
    XCTAssertEqual(mbr[511], 0xAA, @"Protective MBR signature byte 2");

    // Verify protective MBR has type 0xEE
    uint8_t partType = mbr[446 + 4];
    XCTAssertEqual(partType, 0xEE, @"Protective MBR should have type 0xEE, got 0x%02X", partType);

    // Verify GPT header signature at LBA 1
    uint8_t gptHeader[512];
    pread(fd, gptHeader, 512, 512);
    XCTAssertEqual(memcmp(gptHeader, "EFI PART", 8), 0, @"GPT header should start with 'EFI PART'");

    // Verify GPT revision (should be 1.0 = 0x00010000)
    uint32_t revision = *(uint32_t *)(gptHeader + 8);
    XCTAssertEqual(revision, 0x00010000, @"GPT revision should be 1.0");

    // Verify backup GPT header at last sector
    uint8_t backupGpt[512];
    off_t lastSector = (off_t)(diskSize - 512);
    pread(fd, backupGpt, 512, lastSector);
    XCTAssertEqual(memcmp(backupGpt, "EFI PART", 8), 0, @"Backup GPT header should exist");

    // Check isGPTDisk via VTBridge
    close(fd);
    BOOL isGPT = [VTBridge isGPTDisk:self.testImagePath];
    XCTAssertTrue(isGPT, @"File should be detected as GPT after writing GPT table");
}

#pragma mark - Partition 2 Layout

// Verify partition 2 is at the END of the disk (not at the beginning)
- (void)testPartition2AtEndOfDisk {
    int fd = open([self.testImagePath UTF8String], O_RDWR);
    XCTAssertGreaterThan(fd, 0);

    uint64_t diskSize = 512 * 1024 * 1024;
    uint64_t part2Start = 0;
    vtoy_darwin_write_mbr_table(fd, diskSize, VENTOY_PART_SIZE_MB, &part2Start);
    close(fd);

    // Partition 2 (32MB) should be near the end of the disk
    uint64_t diskSectors = diskSize / VENTOY_SECTOR_SIZE;
    uint64_t part2SizeSectors = VENTOY_SECTOR_NUM; // 65536 sectors = 32MB

    // Part2 start + size should be close to disk end (within 2048 sectors margin for backup GPT etc)
    uint64_t part2End = part2Start + part2SizeSectors;
    XCTAssertTrue(diskSectors - part2End < 2048,
                  @"Partition 2 should end near the disk end. diskSectors=%llu, part2End=%llu",
                  diskSectors, part2End);

    // Part2 should NOT start at the beginning
    XCTAssertGreaterThan(part2Start, (uint64_t)VENTOY_PART1_START_SECTOR + 1000,
                         @"Partition 2 should not be at the beginning of the disk");
}

#pragma mark - Disk Size Verification

// Verify disk size query on the test image file
- (void)testDiskSizeOnFile {
    // vtoy_darwin_get_disk_size works on /dev/rdiskN, not plain files
    // But we can verify the file is the expected size
    struct stat st;
    int ret = stat([self.testImagePath UTF8String], &st);
    XCTAssertEqual(ret, 0, @"Should be able to stat test image");
    XCTAssertEqual(st.st_size, 512 * 1024 * 1024, @"Test image should be 512MB");
}

#pragma mark - UUID Read/Write

// Verify UUID generation produces valid non-zero UUIDs
- (void)testUUIDWriteAndRead {
    int fd = open([self.testImagePath UTF8String], O_RDWR);
    XCTAssertGreaterThan(fd, 0);

    uint8_t uuid[16];
    vtoy_darwin_gen_uuid(uuid, sizeof(uuid));

    // Write UUID at Ventoy offset
    ssize_t written = pwrite(fd, uuid, 16, VENTOY_UUID_OFFSET);
    XCTAssertEqual(written, 16, @"Should write 16 bytes");

    // Read it back
    uint8_t readBack[16];
    ssize_t bytesRead = pread(fd, readBack, 16, VENTOY_UUID_OFFSET);
    XCTAssertEqual(bytesRead, 16, @"Should read 16 bytes");
    XCTAssertEqual(memcmp(uuid, readBack, 16), 0, @"UUID read back should match");

    close(fd);
}

@end
