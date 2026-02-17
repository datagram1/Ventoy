/******************************************************************************
 * vtoy_darwin.c -- macOS platform abstraction layer for Ventoy
 *
 * OWNER: WP1 -- Only WP1 may modify this file.
 *
 * Implements all functions declared in vtoy_darwin.h, providing macOS-native
 * equivalents for disk I/O, partition table management, formatting, and
 * partition introspection. Replaces Linux /sys/block, parted, fdisk, etc.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#include "vtoy_darwin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/disk.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <errno.h>

/* ---------------------------------------------------------------------------
 * Constants
 * --------------------------------------------------------------------------- */

#define SECTOR_SIZE          512
#define PART1_START          2048
#define VENTOY_SECTOR_NUM   65536    /* 32MB / 512 = 65536 sectors */
#define MBR_ENTRY_OFFSET     446
#define MBR_ENTRY_SIZE        16
#define MBR_SIG_OFFSET       510
#define GPT_HEADER_SIZE       92
#define GPT_ENTRY_SIZE       128
#define GPT_ENTRY_COUNT      128
#define GPT_ENTRIES_SECTORS   32     /* 128 entries * 128 bytes / 512 = 32 sectors */

/* Ventoy EFI partition attribute: bit 63 set (platform required) */
#define VENTOY_EFI_PART_ATTR 0x8000000000000000ULL

/* ---------------------------------------------------------------------------
 * CRC32 implementation (standard IEEE 802.3 / ISO 3309 polynomial)
 * --------------------------------------------------------------------------- */

static uint32_t vtoy_crc32_table[256];
static int vtoy_crc32_table_init = 0;

static void vtoy_crc32_init(void)
{
    uint32_t i, j, crc;

    if (vtoy_crc32_table_init)
        return;

    for (i = 0; i < 256; i++) {
        crc = i;
        for (j = 0; j < 8; j++) {
            if (crc & 1)
                crc = (crc >> 1) ^ 0xEDB88320U;
            else
                crc = crc >> 1;
        }
        vtoy_crc32_table[i] = crc;
    }
    vtoy_crc32_table_init = 1;
}

static uint32_t vtoy_crc32(const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFFU;
    size_t i;

    vtoy_crc32_init();

    for (i = 0; i < len; i++)
        crc = vtoy_crc32_table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);

    return crc ^ 0xFFFFFFFFU;
}

/* ---------------------------------------------------------------------------
 * Helper: encode a GUID from individual fields into a 16-byte mixed-endian
 * buffer (as stored on disk in GPT entries).
 *
 * GPT stores GUIDs in "mixed endian": the first three components are
 * little-endian, the last two are big-endian (network order).
 * --------------------------------------------------------------------------- */

static void vtoy_encode_guid(uint8_t *out,
                              uint32_t d1, uint16_t d2, uint16_t d3,
                              uint8_t d4_0, uint8_t d4_1,
                              uint8_t d4_2, uint8_t d4_3,
                              uint8_t d4_4, uint8_t d4_5,
                              uint8_t d4_6, uint8_t d4_7)
{
    /* d1: little-endian 32-bit */
    out[0]  = (uint8_t)(d1 & 0xFF);
    out[1]  = (uint8_t)((d1 >> 8) & 0xFF);
    out[2]  = (uint8_t)((d1 >> 16) & 0xFF);
    out[3]  = (uint8_t)((d1 >> 24) & 0xFF);
    /* d2: little-endian 16-bit */
    out[4]  = (uint8_t)(d2 & 0xFF);
    out[5]  = (uint8_t)((d2 >> 8) & 0xFF);
    /* d3: little-endian 16-bit */
    out[6]  = (uint8_t)(d3 & 0xFF);
    out[7]  = (uint8_t)((d3 >> 8) & 0xFF);
    /* d4: big-endian (byte order preserved) */
    out[8]  = d4_0;
    out[9]  = d4_1;
    out[10] = d4_2;
    out[11] = d4_3;
    out[12] = d4_4;
    out[13] = d4_5;
    out[14] = d4_6;
    out[15] = d4_7;
}

/* ---------------------------------------------------------------------------
 * Helper: write a little-endian uint32 into a byte buffer
 * --------------------------------------------------------------------------- */
static void put_le32(uint8_t *buf, uint32_t val)
{
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    buf[2] = (uint8_t)((val >> 16) & 0xFF);
    buf[3] = (uint8_t)((val >> 24) & 0xFF);
}

static void put_le64(uint8_t *buf, uint64_t val)
{
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    buf[2] = (uint8_t)((val >> 16) & 0xFF);
    buf[3] = (uint8_t)((val >> 24) & 0xFF);
    buf[4] = (uint8_t)((val >> 32) & 0xFF);
    buf[5] = (uint8_t)((val >> 40) & 0xFF);
    buf[6] = (uint8_t)((val >> 48) & 0xFF);
    buf[7] = (uint8_t)((val >> 56) & 0xFF);
}

static uint32_t get_le32(const uint8_t *buf)
{
    return (uint32_t)buf[0]
         | ((uint32_t)buf[1] << 8)
         | ((uint32_t)buf[2] << 16)
         | ((uint32_t)buf[3] << 24);
}

static uint64_t get_le64(const uint8_t *buf)
{
    return (uint64_t)buf[0]
         | ((uint64_t)buf[1] << 8)
         | ((uint64_t)buf[2] << 16)
         | ((uint64_t)buf[3] << 24)
         | ((uint64_t)buf[4] << 32)
         | ((uint64_t)buf[5] << 40)
         | ((uint64_t)buf[6] << 48)
         | ((uint64_t)buf[7] << 56);
}

/* ---------------------------------------------------------------------------
 * Helper: encode a UTF-16LE partition name into a GPT entry name field.
 * GPT names are 36 UTF-16LE code units (72 bytes).
 * --------------------------------------------------------------------------- */
static void vtoy_encode_utf16le_name(uint8_t *out, const char *name, size_t max_bytes)
{
    size_t i;
    size_t name_len = strlen(name);
    size_t max_chars = max_bytes / 2;

    memset(out, 0, max_bytes);

    for (i = 0; i < name_len && i < max_chars; i++) {
        out[i * 2]     = (uint8_t)name[i];
        out[i * 2 + 1] = 0;
    }
}

/* ===========================================================================
 * PUBLIC API
 * =========================================================================== */

/* ---------------------------------------------------------------------------
 * vtoy_darwin_get_disk_size
 *
 * Opens /dev/rdiskN (raw device for speed) and queries the block count and
 * block size via ioctl, returning their product as the total disk size in bytes.
 * --------------------------------------------------------------------------- */
uint64_t vtoy_darwin_get_disk_size(const char *disk)
{
    char path[64];
    int fd;
    uint64_t block_count = 0;
    uint32_t block_size = 0;

    if (!disk)
        return 0;

    snprintf(path, sizeof(path), "/dev/r%s", disk);

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "vtoy_darwin_get_disk_size: open(%s) failed: %s\n",
                path, strerror(errno));
        return 0;
    }

    if (ioctl(fd, DKIOCGETBLOCKCOUNT, &block_count) < 0) {
        fprintf(stderr, "vtoy_darwin_get_disk_size: DKIOCGETBLOCKCOUNT failed: %s\n",
                strerror(errno));
        close(fd);
        return 0;
    }

    if (ioctl(fd, DKIOCGETBLOCKSIZE, &block_size) < 0) {
        fprintf(stderr, "vtoy_darwin_get_disk_size: DKIOCGETBLOCKSIZE failed: %s\n",
                strerror(errno));
        close(fd);
        return 0;
    }

    close(fd);
    return (uint64_t)block_count * (uint64_t)block_size;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_is_mounted
 *
 * Uses getmntinfo() to enumerate all mounted filesystems and checks if any
 * mount source path contains the given disk name (e.g. "disk4" matches
 * "/dev/disk4s1", "/dev/disk4s2", etc.).
 * --------------------------------------------------------------------------- */
int vtoy_darwin_is_mounted(const char *disk)
{
    struct statfs *mntbuf;
    int count, i;

    if (!disk)
        return -1;

    count = getmntinfo(&mntbuf, MNT_NOWAIT);
    if (count <= 0)
        return -1;

    for (i = 0; i < count; i++) {
        if (strstr(mntbuf[i].f_mntfromname, disk) != NULL)
            return 1;
    }

    return 0;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_unmount_disk
 *
 * Invokes `diskutil unmountDisk /dev/diskN` to unmount all partitions.
 * --------------------------------------------------------------------------- */
int vtoy_darwin_unmount_disk(const char *disk)
{
    char cmd[128];
    int ret;

    if (!disk)
        return -1;

    snprintf(cmd, sizeof(cmd), "diskutil unmountDisk /dev/%s", disk);
    ret = system(cmd);

    return (ret == 0) ? 0 : -1;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_get_partition_name
 *
 * Formats the macOS partition device path: /dev/diskNsM
 * --------------------------------------------------------------------------- */
void vtoy_darwin_get_partition_name(const char *disk, int partnum,
                                     char *out, size_t outlen)
{
    if (!disk || !out || outlen == 0)
        return;

    snprintf(out, outlen, "/dev/%ss%d", disk, partnum);
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_write_mbr_table
 *
 * Writes a classic MBR partition table with Ventoy's two-partition layout:
 *   Partition 1: exFAT/NTFS (type 0x07), starts at sector 2048
 *   Partition 2: EFI System (type 0xEF), 32MB at end of disk
 * --------------------------------------------------------------------------- */
int vtoy_darwin_write_mbr_table(int fd, uint64_t disk_size_bytes,
                                 uint64_t reserve_mb,
                                 uint64_t *part2_start_sector)
{
    uint8_t mbr[SECTOR_SIZE];
    uint64_t disk_sectors;
    uint64_t part2_start;
    uint64_t part1_sectors;
    uint64_t part2_sectors;
    uint8_t *entry;

    if (fd < 0 || !part2_start_sector)
        return -1;

    disk_sectors = disk_size_bytes / SECTOR_SIZE;

    /* Account for reserved space at end of disk */
    if (reserve_mb > 0) {
        uint64_t reserve_sectors = (reserve_mb * 1024 * 1024) / SECTOR_SIZE;
        if (reserve_sectors >= disk_sectors)
            return -1;
        disk_sectors -= reserve_sectors;
    }

    /* Calculate partition 2 start: place it at the end */
    part2_start = disk_sectors - VENTOY_SECTOR_NUM;

    /* Align part2_start down to 4KB boundary (sector % 8 == 0) */
    if (part2_start % 8 != 0)
        part2_start -= (part2_start % 8);

    part1_sectors = part2_start - PART1_START;
    part2_sectors = VENTOY_SECTOR_NUM;

    /* Build MBR */
    memset(mbr, 0, sizeof(mbr));

    /* --- Partition entry 1 (bytes 446-461) --- */
    entry = mbr + MBR_ENTRY_OFFSET;
    entry[0] = 0x80;                         /* Active/bootable */
    /* CHS start: Head=0, Sector=2, Cylinder=0 (LBA mode placeholder) */
    entry[1] = 0x00;                         /* StartHead */
    entry[2] = 0x02;                         /* StartSector */
    entry[3] = 0x00;                         /* StartCylinder */
    entry[4] = 0x07;                         /* FsFlag: exFAT/NTFS/HPFS */
    /* CHS end: max values for LBA mode */
    entry[5] = 0xFE;                         /* EndHead */
    entry[6] = 0x3F;                         /* EndSector */
    entry[7] = 0xFF;                         /* EndCylinder */
    /* StartSectorId (LE32) */
    put_le32(entry + 8, (uint32_t)PART1_START);
    /* SectorCount (LE32) */
    put_le32(entry + 12, (uint32_t)part1_sectors);

    /* --- Partition entry 2 (bytes 462-477) --- */
    entry = mbr + MBR_ENTRY_OFFSET + MBR_ENTRY_SIZE;
    entry[0] = 0x00;                         /* Not active */
    /* CHS start: use LBA max values */
    entry[1] = 0x00;                         /* StartHead */
    entry[2] = 0x02;                         /* StartSector */
    entry[3] = 0x00;                         /* StartCylinder */
    entry[4] = 0xEF;                         /* FsFlag: EFI System Partition */
    /* CHS end: max values */
    entry[5] = 0xFE;                         /* EndHead */
    entry[6] = 0x3F;                         /* EndSector */
    entry[7] = 0xFF;                         /* EndCylinder */
    /* StartSectorId (LE32) */
    put_le32(entry + 8, (uint32_t)part2_start);
    /* SectorCount (LE32) */
    put_le32(entry + 12, (uint32_t)part2_sectors);

    /* Partition entries 3 and 4 are already zeroed */

    /* MBR signature */
    mbr[MBR_SIG_OFFSET]     = 0x55;
    mbr[MBR_SIG_OFFSET + 1] = 0xAA;

    /* Write MBR to disk */
    if (pwrite(fd, mbr, SECTOR_SIZE, 0) != SECTOR_SIZE) {
        fprintf(stderr, "vtoy_darwin_write_mbr_table: pwrite failed: %s\n",
                strerror(errno));
        return -1;
    }

    *part2_start_sector = part2_start;
    return 0;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_write_gpt_table
 *
 * Writes a complete GPT disk layout:
 *   Sector 0:                Protective MBR
 *   Sector 1:                Primary GPT Header
 *   Sectors 2-33:            Primary Partition Entry Array (128 entries)
 *   ...data...
 *   Sectors N-33 to N-2:     Backup Partition Entry Array
 *   Sector N-1:              Backup GPT Header
 *
 * Two partitions:
 *   1) Basic Data Partition ("Ventoy") from sector 2048 to part2_start-1
 *   2) EFI System Partition ("VTOYEFI") 32MB at end of usable space
 * --------------------------------------------------------------------------- */
int vtoy_darwin_write_gpt_table(int fd, uint64_t disk_size_bytes,
                                 uint64_t reserve_mb,
                                 uint64_t *part2_start_sector)
{
    uint8_t mbr[SECTOR_SIZE];
    uint8_t header[SECTOR_SIZE];
    uint8_t *entries = NULL;
    uint8_t *ent;
    uint64_t disk_sectors;
    uint64_t part1_start, part1_end;
    uint64_t part2_start, part2_end;
    uint64_t first_usable, last_usable;
    uint64_t backup_header_lba;
    uint64_t backup_entries_lba;
    uint32_t entries_crc, header_crc;
    uint8_t disk_guid[16];
    uint8_t part1_guid[16];
    uint8_t part2_guid[16];
    size_t entries_size;

    if (fd < 0 || !part2_start_sector)
        return -1;

    disk_sectors = disk_size_bytes / SECTOR_SIZE;

    /* Account for reserved space */
    if (reserve_mb > 0) {
        uint64_t reserve_sectors = (reserve_mb * 1024 * 1024) / SECTOR_SIZE;
        if (reserve_sectors >= disk_sectors)
            return -1;
        disk_sectors -= reserve_sectors;
    }

    /* Key LBA positions */
    first_usable = 34;                              /* After primary GPT */
    last_usable  = disk_sectors - 34;               /* Before backup GPT */
    backup_header_lba  = disk_sectors - 1;
    backup_entries_lba = disk_sectors - 33;

    /* Partition layout */
    part1_start = PART1_START;
    part2_start = last_usable - VENTOY_SECTOR_NUM + 1;

    /* Align part2_start down to 4KB boundary */
    if (part2_start % 8 != 0)
        part2_start -= (part2_start % 8);

    /* Partition 2 must be exactly VENTOY_SECTOR_NUM sectors (GRUB validates this) */
    part2_end   = part2_start + VENTOY_SECTOR_NUM - 1;
    part1_end   = part2_start - 1;

    /* Generate random GUIDs */
    vtoy_darwin_gen_uuid(disk_guid, sizeof(disk_guid));
    vtoy_darwin_gen_uuid(part1_guid, sizeof(part1_guid));
    vtoy_darwin_gen_uuid(part2_guid, sizeof(part2_guid));

    /* -----------------------------------------------------------------------
     * Protective MBR (sector 0)
     * ----------------------------------------------------------------------- */
    memset(mbr, 0, sizeof(mbr));

    /* Single partition entry covering the entire disk as type 0xEE */
    {
        uint8_t *pe = mbr + MBR_ENTRY_OFFSET;
        uint64_t mbr_sectors = disk_sectors - 1;

        pe[0] = 0x00;                               /* Not active */
        pe[1] = 0x00;                               /* StartHead */
        pe[2] = 0x02;                               /* StartSector */
        pe[3] = 0x00;                               /* StartCylinder */
        pe[4] = 0xEE;                               /* GPT Protective */
        pe[5] = 0xFE;                               /* EndHead */
        pe[6] = 0x3F;                               /* EndSector */
        pe[7] = 0xFF;                               /* EndCylinder */
        put_le32(pe + 8, 1);                         /* Start at LBA 1 */

        /* Cap at 0xFFFFFFFF if disk is larger than 2TB */
        if (mbr_sectors > 0xFFFFFFFFULL)
            put_le32(pe + 12, 0xFFFFFFFF);
        else
            put_le32(pe + 12, (uint32_t)mbr_sectors);
    }

    mbr[MBR_SIG_OFFSET]     = 0x55;
    mbr[MBR_SIG_OFFSET + 1] = 0xAA;

    if (pwrite(fd, mbr, SECTOR_SIZE, 0) != SECTOR_SIZE) {
        fprintf(stderr, "vtoy_darwin_write_gpt_table: pwrite protective MBR failed: %s\n",
                strerror(errno));
        return -1;
    }

    /* -----------------------------------------------------------------------
     * Build Partition Entry Array (128 entries x 128 bytes = 16384 bytes)
     * ----------------------------------------------------------------------- */
    entries_size = (size_t)GPT_ENTRY_COUNT * GPT_ENTRY_SIZE;
    entries = (uint8_t *)calloc(1, entries_size);
    if (!entries)
        return -1;

    /* Entry 1: Basic Data Partition ("Ventoy") */
    ent = entries;

    /* Type GUID: EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 (Microsoft Basic Data) */
    vtoy_encode_guid(ent + 0,
                     0xEBD0A0A2, 0xB9E5, 0x4433,
                     0x87, 0xC0,
                     0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7);

    /* Unique partition GUID */
    memcpy(ent + 16, part1_guid, 16);

    /* Starting LBA (LE64) */
    put_le64(ent + 32, part1_start);

    /* Ending LBA (LE64) */
    put_le64(ent + 40, part1_end);

    /* Attributes: none */
    put_le64(ent + 48, 0);

    /* Name: "Ventoy" in UTF-16LE (offset 56, 72 bytes) */
    vtoy_encode_utf16le_name(ent + 56, "Ventoy", 72);

    /* Entry 2: EFI System Partition ("VTOYEFI") */
    ent = entries + GPT_ENTRY_SIZE;

    /* Type GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI System) */
    vtoy_encode_guid(ent + 0,
                     0xC12A7328, 0xF81F, 0x11D2,
                     0xBA, 0x4B,
                     0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B);

    /* Unique partition GUID */
    memcpy(ent + 16, part2_guid, 16);

    /* Starting LBA */
    put_le64(ent + 32, part2_start);

    /* Ending LBA */
    put_le64(ent + 40, part2_end);

    /* Attributes: platform required */
    put_le64(ent + 48, VENTOY_EFI_PART_ATTR);

    /* Name: "VTOYEFI" in UTF-16LE */
    vtoy_encode_utf16le_name(ent + 56, "VTOYEFI", 72);

    /* CRC32 of the partition entries */
    entries_crc = vtoy_crc32(entries, entries_size);

    /* -----------------------------------------------------------------------
     * Primary GPT Header (sector 1)
     * ----------------------------------------------------------------------- */
    memset(header, 0, sizeof(header));

    /* Signature: "EFI PART" */
    memcpy(header + 0, "EFI PART", 8);

    /* Revision: 1.0 */
    put_le32(header + 8, 0x00010000);

    /* Header size */
    put_le32(header + 12, GPT_HEADER_SIZE);

    /* HeaderCRC32: set to 0 during calculation, filled in below */
    put_le32(header + 16, 0);

    /* Reserved */
    put_le32(header + 20, 0);

    /* MyLBA */
    put_le64(header + 24, 1);

    /* AlternateLBA */
    put_le64(header + 32, backup_header_lba);

    /* FirstUsableLBA */
    put_le64(header + 40, first_usable);

    /* LastUsableLBA */
    put_le64(header + 48, last_usable);

    /* DiskGUID (16 bytes at offset 56) */
    memcpy(header + 56, disk_guid, 16);

    /* PartitionEntryStartLBA */
    put_le64(header + 72, 2);

    /* NumberOfPartitionEntries */
    put_le32(header + 80, GPT_ENTRY_COUNT);

    /* SizeOfPartitionEntry */
    put_le32(header + 84, GPT_ENTRY_SIZE);

    /* PartitionEntryCRC32 */
    put_le32(header + 88, entries_crc);

    /* Compute and set HeaderCRC32 */
    header_crc = vtoy_crc32(header, GPT_HEADER_SIZE);
    put_le32(header + 16, header_crc);

    /* Write primary GPT header */
    if (pwrite(fd, header, SECTOR_SIZE, SECTOR_SIZE) != SECTOR_SIZE) {
        fprintf(stderr, "vtoy_darwin_write_gpt_table: pwrite primary header failed: %s\n",
                strerror(errno));
        free(entries);
        return -1;
    }

    /* Write primary partition entries (sectors 2-33) */
    if (pwrite(fd, entries, entries_size, 2 * SECTOR_SIZE) != (ssize_t)entries_size) {
        fprintf(stderr, "vtoy_darwin_write_gpt_table: pwrite primary entries failed: %s\n",
                strerror(errno));
        free(entries);
        return -1;
    }

    /* -----------------------------------------------------------------------
     * Backup Partition Entries (sectors disk_sectors-33 to disk_sectors-2)
     * ----------------------------------------------------------------------- */
    if (pwrite(fd, entries, entries_size,
               (off_t)(backup_entries_lba * SECTOR_SIZE)) != (ssize_t)entries_size) {
        fprintf(stderr, "vtoy_darwin_write_gpt_table: pwrite backup entries failed: %s\n",
                strerror(errno));
        free(entries);
        return -1;
    }

    /* -----------------------------------------------------------------------
     * Backup GPT Header (last sector)
     *
     * Same as primary but with MyLBA/AlternateLBA swapped and
     * PartitionEntryStartLBA pointing to backup entries.
     * ----------------------------------------------------------------------- */
    /* Clear the primary CRC before modifying */
    put_le32(header + 16, 0);

    /* MyLBA = backup location */
    put_le64(header + 24, backup_header_lba);

    /* AlternateLBA = primary location */
    put_le64(header + 32, 1);

    /* PartitionEntryStartLBA = backup entries */
    put_le64(header + 72, backup_entries_lba);

    /* Recompute header CRC */
    header_crc = vtoy_crc32(header, GPT_HEADER_SIZE);
    put_le32(header + 16, header_crc);

    /* Write backup GPT header */
    if (pwrite(fd, header, SECTOR_SIZE,
               (off_t)(backup_header_lba * SECTOR_SIZE)) != SECTOR_SIZE) {
        fprintf(stderr, "vtoy_darwin_write_gpt_table: pwrite backup header failed: %s\n",
                strerror(errno));
        free(entries);
        return -1;
    }

    free(entries);
    *part2_start_sector = part2_start;
    return 0;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_format_exfat
 *
 * Formats a partition as exFAT using newfs_exfat.
 * --------------------------------------------------------------------------- */
int vtoy_darwin_format_exfat(const char *partition, const char *label)
{
    char cmd[256];
    int ret;

    if (!partition || !label)
        return -1;

    snprintf(cmd, sizeof(cmd), "newfs_exfat -v \"%s\" %s", label, partition);
    ret = system(cmd);

    return (ret == 0) ? 0 : -1;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_format_fat16
 *
 * Formats a partition as FAT16 using newfs_msdos.
 * --------------------------------------------------------------------------- */
int vtoy_darwin_format_fat16(const char *partition, const char *label)
{
    char cmd[256];
    int ret;

    if (!partition || !label)
        return -1;

    snprintf(cmd, sizeof(cmd), "newfs_msdos -F 16 -v \"%s\" %s", label, partition);
    ret = system(cmd);

    return (ret == 0) ? 0 : -1;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_reprobe_disk
 *
 * Forces macOS to re-read the partition table by running diskutil list.
 * --------------------------------------------------------------------------- */
int vtoy_darwin_reprobe_disk(const char *disk)
{
    char cmd[128];
    int ret;

    if (!disk)
        return -1;

    /* sync pending writes */
    sync();

    /* diskutil list forces the kernel to re-read the partition table */
    snprintf(cmd, sizeof(cmd), "diskutil list /dev/%s", disk);
    ret = system(cmd);

    return (ret == 0) ? 0 : -1;
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_gen_uuid
 *
 * Fills a buffer with cryptographically random bytes using arc4random_buf.
 * --------------------------------------------------------------------------- */
void vtoy_darwin_gen_uuid(void *uuid, size_t len)
{
    if (!uuid || len == 0)
        return;

    arc4random_buf(uuid, len);
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_get_partition_offset
 *
 * Reads the partition table (MBR or GPT) directly from the disk device and
 * returns the starting LBA of the given partition number (1-indexed).
 * --------------------------------------------------------------------------- */
uint64_t vtoy_darwin_get_partition_offset(const char *disk, int partnum)
{
    char path[64];
    int fd;
    uint8_t sector[SECTOR_SIZE];
    ssize_t n;

    if (!disk || partnum < 1)
        return 0;

    snprintf(path, sizeof(path), "/dev/r%s", disk);

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "vtoy_darwin_get_partition_offset: open(%s) failed: %s\n",
                path, strerror(errno));
        return 0;
    }

    /* Read sector 0 (MBR or Protective MBR) */
    n = pread(fd, sector, SECTOR_SIZE, 0);
    if (n != SECTOR_SIZE) {
        close(fd);
        return 0;
    }

    /* Check for valid MBR signature */
    if (sector[510] != 0x55 || sector[511] != 0xAA) {
        close(fd);
        return 0;
    }

    /* Check if this is a protective MBR (GPT disk) */
    if (sector[MBR_ENTRY_OFFSET + 4] == 0xEE) {
        /* GPT disk -- read partition entries from sector 2 onwards */
        uint8_t entry_buf[GPT_ENTRY_SIZE];
        off_t entry_offset;

        if (partnum > GPT_ENTRY_COUNT) {
            close(fd);
            return 0;
        }

        /* GPT entries start at LBA 2, each is 128 bytes, partnum is 1-indexed */
        entry_offset = (off_t)(2 * SECTOR_SIZE) + (off_t)(partnum - 1) * GPT_ENTRY_SIZE;

        n = pread(fd, entry_buf, GPT_ENTRY_SIZE, entry_offset);
        if (n != GPT_ENTRY_SIZE) {
            close(fd);
            return 0;
        }

        close(fd);
        /* StartLBA is at offset 32 in the GPT entry */
        return get_le64(entry_buf + 32);
    } else {
        /* MBR disk -- read partition entry directly */
        uint8_t *pe;

        if (partnum > 4) {
            close(fd);
            return 0;
        }

        pe = sector + MBR_ENTRY_OFFSET + (partnum - 1) * MBR_ENTRY_SIZE;
        close(fd);

        /* StartSectorId is at offset 8 in the partition entry (LE32) */
        return (uint64_t)get_le32(pe + 8);
    }
}

/* ---------------------------------------------------------------------------
 * vtoy_darwin_get_partition_size
 *
 * Reads the partition table (MBR or GPT) directly from the disk device and
 * returns the sector count of the given partition number (1-indexed).
 * --------------------------------------------------------------------------- */
uint64_t vtoy_darwin_get_partition_size(const char *disk, int partnum)
{
    char path[64];
    int fd;
    uint8_t sector[SECTOR_SIZE];
    ssize_t n;

    if (!disk || partnum < 1)
        return 0;

    snprintf(path, sizeof(path), "/dev/r%s", disk);

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "vtoy_darwin_get_partition_size: open(%s) failed: %s\n",
                path, strerror(errno));
        return 0;
    }

    /* Read sector 0 (MBR or Protective MBR) */
    n = pread(fd, sector, SECTOR_SIZE, 0);
    if (n != SECTOR_SIZE) {
        close(fd);
        return 0;
    }

    /* Check for valid MBR signature */
    if (sector[510] != 0x55 || sector[511] != 0xAA) {
        close(fd);
        return 0;
    }

    /* Check if this is a protective MBR (GPT disk) */
    if (sector[MBR_ENTRY_OFFSET + 4] == 0xEE) {
        /* GPT disk */
        uint8_t entry_buf[GPT_ENTRY_SIZE];
        off_t entry_offset;
        uint64_t start_lba, end_lba;

        if (partnum > GPT_ENTRY_COUNT) {
            close(fd);
            return 0;
        }

        entry_offset = (off_t)(2 * SECTOR_SIZE) + (off_t)(partnum - 1) * GPT_ENTRY_SIZE;

        n = pread(fd, entry_buf, GPT_ENTRY_SIZE, entry_offset);
        if (n != GPT_ENTRY_SIZE) {
            close(fd);
            return 0;
        }

        close(fd);

        /* StartLBA at offset 32, EndLBA at offset 40 */
        start_lba = get_le64(entry_buf + 32);
        end_lba   = get_le64(entry_buf + 40);

        if (end_lba < start_lba)
            return 0;

        return end_lba - start_lba + 1;
    } else {
        /* MBR disk */
        uint8_t *pe;

        if (partnum > 4) {
            close(fd);
            return 0;
        }

        pe = sector + MBR_ENTRY_OFFSET + (partnum - 1) * MBR_ENTRY_SIZE;
        close(fd);

        /* SectorCount is at offset 12 in the partition entry (LE32) */
        return (uint64_t)get_le32(pe + 12);
    }
}
