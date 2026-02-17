/******************************************************************************
 * VTBridgeTests.m — Unit tests for VTBridge utility methods
 *
 * Tests CRC32 validation, UUID generation, human-readable sizes,
 * and bundled version detection.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#import <XCTest/XCTest.h>
#import "VTBridge.h"
#import "VTTypes.h"

@interface VTBridgeTests : XCTestCase
@end

@implementation VTBridgeTests

#pragma mark - CRC32 Test Vectors

// CRC32 test vectors (from RFC 3720 / POSIX cksum / zlib)
- (void)testCRC32EmptyData {
    NSData *empty = [NSData data];
    uint32_t crc = [VTBridge crc32ForData:empty];
    XCTAssertEqual(crc, 0x00000000, @"CRC32 of empty data should be 0");
}

- (void)testCRC32KnownVector {
    // "123456789" -> CRC32 = 0xCBF43926
    NSData *data = [@"123456789" dataUsingEncoding:NSASCIIStringEncoding];
    uint32_t crc = [VTBridge crc32ForData:data];
    XCTAssertEqual(crc, 0xCBF43926, @"CRC32 of '123456789' should be 0xCBF43926, got 0x%08X", crc);
}

- (void)testCRC32SingleByte {
    // CRC32 of single byte 'a' (0x61) = 0xE8B7BE43
    uint8_t byte = 'a';
    NSData *data = [NSData dataWithBytes:&byte length:1];
    uint32_t crc = [VTBridge crc32ForData:data];
    XCTAssertEqual(crc, 0xE8B7BE43, @"CRC32 of 'a' should be 0xE8B7BE43, got 0x%08X", crc);
}

- (void)testCRC32AllZeros {
    uint8_t zeros[32] = {0};
    NSData *data = [NSData dataWithBytes:zeros length:32];
    uint32_t crc = [VTBridge crc32ForData:data];
    XCTAssertEqual(crc, 0x190A55AD, @"CRC32 of 32 zero bytes should be 0x190A55AD, got 0x%08X", crc);
}

#pragma mark - UUID Generation

- (void)testGenerateUUID {
    NSData *uuid1 = [VTBridge generateUUID];
    NSData *uuid2 = [VTBridge generateUUID];
    XCTAssertEqual(uuid1.length, 16, @"UUID should be 16 bytes");
    XCTAssertEqual(uuid2.length, 16, @"UUID should be 16 bytes");
    XCTAssertFalse([uuid1 isEqualToData:uuid2], @"Two UUIDs should not be identical");
}

#pragma mark - Human-Readable Size

- (void)testHumanReadableSizeBytes {
    XCTAssertEqualObjects([VTBridge humanReadableSize:512], @"512 B");
}

- (void)testHumanReadableSizeKB {
    XCTAssertEqualObjects([VTBridge humanReadableSize:1536], @"1.5 KB");
}

- (void)testHumanReadableSizeMB {
    XCTAssertEqualObjects([VTBridge humanReadableSize:1048576], @"1.0 MB");
}

- (void)testHumanReadableSizeGB {
    // 32 GB
    XCTAssertEqualObjects([VTBridge humanReadableSize:34359738368ULL], @"32.0 GB");
}

- (void)testHumanReadableSizeTB {
    // 1 TB
    XCTAssertEqualObjects([VTBridge humanReadableSize:1099511627776ULL], @"1.0 TB");
}

#pragma mark - Bundled Version

- (void)testBundledVentoyVersion {
    // When running tests, the bundle may not contain ventoy_boot assets
    // Just verify the method doesn't crash
    NSString *version = [VTBridge bundledVentoyVersion];
    // version may be nil in test context, that's OK
    if (version) {
        XCTAssertGreaterThan(version.length, 0, @"Version should be non-empty if present");
    }
}

@end
