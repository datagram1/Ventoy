/******************************************************************************
 * VTBridge.h — Objective-C to C core bridge
 *
 * Thin wrapper that exposes Ventoy C functions as ObjC class methods.
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP6 implements VTBridge.m against this interface.
 *****************************************************************************/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VTBridge : NSObject

/// Read Ventoy version from an installed disk's FAT partition.
/// Returns nil if Ventoy is not installed or cannot be read.
+ (nullable NSString *)ventoyVersionFromDisk:(NSString *)diskPath;

/// Check if a disk uses GPT partition style.
+ (BOOL)isGPTDisk:(NSString *)diskPath;

/// Validate partition layout for non-destructive install.
/// Returns: 0 = invalid, 1 = free space available, 2 = needs shrink.
+ (int)checkPartitionLayout:(NSString *)diskPath;

/// Compute CRC32 checksum of data.
+ (uint32_t)crc32ForData:(NSData *)data;

/// Generate a random 16-byte UUID.
+ (NSData *)generateUUID;

/// Get human-readable size string (e.g. "32.0 GB").
+ (NSString *)humanReadableSize:(uint64_t)bytes;

/// Get the bundled Ventoy core version string.
+ (nullable NSString *)bundledVentoyVersion;

@end

NS_ASSUME_NONNULL_END
