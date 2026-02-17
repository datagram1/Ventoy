/******************************************************************************
 * VTBridge.m — Objective-C to C core bridge
 *
 * OWNER: WP6 — Only WP6 may modify this file.
 *****************************************************************************/

#import "VTBridge.h"
#import "VTTypes.h"
#include "vtoy_darwin.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

@implementation VTBridge

+ (nullable NSString *)ventoyVersionFromDisk:(NSString *)diskPath {
    // Full implementation requires fat_io_lib integration (Wave 2)
    // For now, check if disk has Ventoy UUID signature
    int fd = open([diskPath UTF8String], O_RDONLY);
    if (fd < 0) return nil;

    uint8_t uuid[16];
    memset(uuid, 0, sizeof(uuid));
    ssize_t n = pread(fd, uuid, 16, VENTOY_UUID_OFFSET);
    close(fd);

    if (n != 16) return nil;

    // Check if UUID is all zeros (not installed)
    BOOL allZero = YES;
    for (int i = 0; i < 16; i++) {
        if (uuid[i] != 0) { allZero = NO; break; }
    }
    if (allZero) return nil;

    // Ventoy is installed but we can't read the version without fat_io_lib
    // Return "installed" as a placeholder
    return @"(installed)";
}

+ (BOOL)isGPTDisk:(NSString *)diskPath {
    int fd = open([diskPath UTF8String], O_RDONLY);
    if (fd < 0) return NO;

    // Read LBA 1 (byte offset 512) for GPT signature
    uint8_t buf[512];
    ssize_t n = pread(fd, buf, 512, 512);
    close(fd);

    if (n != 512) return NO;

    // GPT signature is "EFI PART" at the start of the header
    return (memcmp(buf, "EFI PART", 8) == 0);
}

+ (int)checkPartitionLayout:(NSString *)diskPath {
    // Check if the disk has a valid Ventoy partition layout
    // Returns: 0 = invalid/empty, 1 = valid Ventoy layout, 2 = needs modification

    int fd = open([diskPath UTF8String], O_RDONLY);
    if (fd < 0) return 0;

    // Read MBR
    uint8_t mbr[512];
    ssize_t n = pread(fd, mbr, 512, 0);
    close(fd);

    if (n != 512) return 0;

    // Check MBR signature
    if (mbr[510] != 0x55 || mbr[511] != 0xAA) return 0;

    // Check if partition 1 exists (bytes 446-461)
    // FsFlag at offset 450
    uint8_t fsFlag1 = mbr[450];
    uint8_t fsFlag2 = mbr[466];

    if (fsFlag1 == 0 && fsFlag2 == 0) return 0;  // No partitions

    // If partition 2 has EFI type (0xEF), looks like Ventoy layout
    if (fsFlag2 == 0xEF) return 1;

    // Has partitions but not Ventoy layout
    return 2;
}

+ (uint32_t)crc32ForData:(NSData *)data {
    // Standard CRC32 (same polynomial as zlib/gzip: 0xEDB88320)
    static uint32_t crc_table[256];
    static BOOL table_computed = NO;

    if (!table_computed) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t crc = i;
            for (int j = 0; j < 8; j++) {
                if (crc & 1)
                    crc = (crc >> 1) ^ 0xEDB88320;
                else
                    crc = crc >> 1;
            }
            crc_table[i] = crc;
        }
        table_computed = YES;
    }

    uint32_t crc = 0xFFFFFFFF;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        crc = crc_table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

+ (NSData *)generateUUID {
    uint8_t uuid[16];
    vtoy_darwin_gen_uuid(uuid, sizeof(uuid));
    return [NSData dataWithBytes:uuid length:sizeof(uuid)];
}

+ (NSString *)humanReadableSize:(uint64_t)bytes {
    if (bytes < 1024ULL) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    } else if (bytes < 1024ULL * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    } else if (bytes < 1024ULL * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024)];
    } else if (bytes < 1024ULL * 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024 * 1024)];
    } else {
        return [NSString stringWithFormat:@"%.1f TB", bytes / (1024.0 * 1024 * 1024 * 1024)];
    }
}

+ (nullable NSString *)bundledVentoyVersion {
    NSString *versionPath = [[NSBundle mainBundle] pathForResource:@"version"
                                                            ofType:nil
                                                       inDirectory:@"ventoy_boot/ventoy"];
    if (!versionPath) return nil;

    NSString *version = [NSString stringWithContentsOfFile:versionPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    return [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
