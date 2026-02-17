/******************************************************************************
 * vtoy_darwin.h — macOS platform abstraction layer for Ventoy
 *
 * Replaces Linux-specific /sys/block, /proc/mounts, parted/fdisk, etc.
 * with macOS equivalents using ioctl, DiskArbitration, diskutil.
 *
 * This file is created by Gate 0 and is READ-ONLY during Wave 1.
 * WP1 implements vtoy_darwin.c against this interface.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#ifndef VTOY_DARWIN_H
#define VTOY_DARWIN_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Get total disk size in bytes.
 * Uses ioctl(DKIOCGETBLOCKCOUNT) * ioctl(DKIOCGETBLOCKSIZE) on /dev/rdiskN.
 * Returns 0 on failure.
 */
uint64_t vtoy_darwin_get_disk_size(const char *disk);

/*
 * Check if any partition of the disk is currently mounted.
 * Returns 1 if mounted, 0 if not, -1 on error.
 */
int vtoy_darwin_is_mounted(const char *disk);

/*
 * Unmount all partitions of a disk.
 * Calls: diskutil unmountDisk /dev/diskN
 * Returns 0 on success, non-zero on failure.
 */
int vtoy_darwin_unmount_disk(const char *disk);

/*
 * Get partition device path for a given disk and partition number.
 * E.g., disk="disk4", partnum=1 → out="/dev/disk4s1"
 * Writes to 'out' buffer of size 'outlen'.
 */
void vtoy_darwin_get_partition_name(const char *disk, int partnum, char *out, size_t outlen);

/*
 * Write MBR partition table directly to disk.
 * Creates Ventoy's two-partition layout (part1=exFAT at start, part2=FAT16 at end).
 * fd must be an open file descriptor to /dev/rdiskN with write access.
 * Returns 0 on success, non-zero on failure.
 * Sets *part2_start_sector as output.
 */
int vtoy_darwin_write_mbr_table(int fd, uint64_t disk_size_bytes, uint64_t reserve_mb,
                                 uint64_t *part2_start_sector);

/*
 * Write GPT partition table directly to disk.
 * Creates protective MBR + GPT header + partition entries + backup GPT.
 * fd must be an open file descriptor to /dev/rdiskN with write access.
 * Returns 0 on success, non-zero on failure.
 * Sets *part2_start_sector as output.
 */
int vtoy_darwin_write_gpt_table(int fd, uint64_t disk_size_bytes, uint64_t reserve_mb,
                                 uint64_t *part2_start_sector);

/*
 * Format a partition as exFAT.
 * partition: e.g. "/dev/rdisk4s1"
 * label: e.g. "Ventoy"
 * Returns 0 on success.
 */
int vtoy_darwin_format_exfat(const char *partition, const char *label);

/*
 * Format a partition as FAT16.
 * partition: e.g. "/dev/rdisk4s2"
 * label: e.g. "VTOYEFI"
 * Returns 0 on success.
 */
int vtoy_darwin_format_fat16(const char *partition, const char *label);

/*
 * Force macOS to re-read the partition table of a disk.
 * Call after raw partition table writes.
 * Returns 0 on success.
 */
int vtoy_darwin_reprobe_disk(const char *disk);

/*
 * Generate a 16-byte random UUID using arc4random_buf.
 * uuid: output buffer (must be at least 'len' bytes, typically 16)
 */
void vtoy_darwin_gen_uuid(void *uuid, size_t len);

/*
 * Get the start sector of a partition.
 * Replaces Linux /sys/class/block/<part>/start.
 * Returns the start sector (LBA), or 0 on failure.
 */
uint64_t vtoy_darwin_get_partition_offset(const char *disk, int partnum);

/*
 * Get the sector count of a partition.
 * Replaces Linux /sys/class/block/<part>/size.
 * Returns sector count, or 0 on failure.
 */
uint64_t vtoy_darwin_get_partition_size(const char *disk, int partnum);

#ifdef __cplusplus
}
#endif

#endif /* VTOY_DARWIN_H */
