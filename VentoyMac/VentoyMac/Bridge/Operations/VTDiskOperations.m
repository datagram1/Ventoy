/******************************************************************************
 * VTDiskOperations.m — Ventoy install/update engine
 *
 * OWNER: WP5 — Only WP5 may modify this file.
 *****************************************************************************/

#import "VTDiskOperations.h"
#import "VTPrivilegedTask.h"
#import "VTTypes.h"
#include "vtoy_darwin.h"
#include <sys/stat.h>
#include <compression.h>

#pragma mark - Private Interface

@interface VTDiskOperations ()
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) dispatch_queue_t operationQueue;
@end

#pragma mark - Implementation

@implementation VTDiskOperations {
    BOOL _isOperationInProgress;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _operationQueue = dispatch_queue_create("com.knws.ventoymac.diskops", DISPATCH_QUEUE_SERIAL);
        _isOperationInProgress = NO;
        _cancelled = NO;
    }
    return self;
}

#pragma mark - Public: Boot Asset Path

- (NSString *)bootAssetPath {
    return [[NSBundle mainBundle] pathForResource:@"ventoy_boot" ofType:nil];
}

#pragma mark - Public: Version Detection

- (nullable NSString *)ventoyVersionOnDisk:(VTDiskInfo *)disk {
    // TODO: Version detection requires fat_io_lib integration (Wave 2).
    // To detect the installed Ventoy version, we would need to mount or
    // directly read the FAT16 filesystem on partition 2 and parse the
    // Ventoy configuration files. This will be implemented when the
    // fat_io_lib C library is integrated.
    return nil;
}

#pragma mark - Public: Cancel

- (void)cancelCurrentOperation {
    self.cancelled = YES;
}

#pragma mark - Public: Install

- (void)installVentoyToDisk:(VTDiskInfo *)disk
             partitionStyle:(VTPartitionStyle)style
                 secureBoot:(BOOL)secureBoot
                volumeLabel:(NSString *)label
                   progress:(VTProgressBlock)progress
                 completion:(VTCompletionBlock)completion {

    if (self.isOperationInProgress) {
        NSError *err = [NSError errorWithDomain:VTErrorDomain
                                           code:VTErrorCodeWriteFailed
                                       userInfo:@{NSLocalizedDescriptionKey: @"An operation is already in progress"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
        return;
    }

    self.cancelled = NO;
    _isOperationInProgress = YES;

    dispatch_async(self.operationQueue, ^{
        NSError *error = nil;
        BOOL success = [self _performInstallToDisk:disk
                                    partitionStyle:style
                                        secureBoot:secureBoot
                                       volumeLabel:label
                                          progress:progress
                                             error:&error];

        self->_isOperationInProgress = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, error);
        });
    });
}

#pragma mark - Public: Update

- (void)updateVentoyOnDisk:(VTDiskInfo *)disk
                secureBoot:(BOOL)secureBoot
                  progress:(VTProgressBlock)progress
                completion:(VTCompletionBlock)completion {

    if (self.isOperationInProgress) {
        NSError *err = [NSError errorWithDomain:VTErrorDomain
                                           code:VTErrorCodeWriteFailed
                                       userInfo:@{NSLocalizedDescriptionKey: @"An operation is already in progress"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
        return;
    }

    self.cancelled = NO;
    _isOperationInProgress = YES;

    dispatch_async(self.operationQueue, ^{
        NSError *error = nil;
        BOOL success = [self _performUpdateOnDisk:disk
                                       secureBoot:secureBoot
                                         progress:progress
                                            error:&error];

        self->_isOperationInProgress = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, error);
        });
    });
}

#pragma mark - Private: Install Flow

- (BOOL)_performInstallToDisk:(VTDiskInfo *)disk
               partitionStyle:(VTPartitionStyle)style
                   secureBoot:(BOOL)secureBoot
                  volumeLabel:(NSString *)label
                     progress:(VTProgressBlock)progress
                        error:(NSError **)outError {

    /* Step 1: Validate */
    [self _reportProgress:progress stage:VTInstallStageValidating percent:0.0 message:@"Validating disk..."];

    if (!disk.isRemovable) {
        *outError = [self _errorWithCode:VTErrorCodeDiskNotRemovable message:@"Disk is not removable"];
        return NO;
    }
    if (!disk.isWritable) {
        *outError = [self _errorWithCode:VTErrorCodeDiskNotWritable message:@"Disk is not writable"];
        return NO;
    }
    /* Minimum size: 256MB (need room for both partitions) */
    if (disk.sizeInBytes < 256 * 1024 * 1024) {
        *outError = [self _errorWithCode:VTErrorCodeDiskTooSmall message:@"Disk too small (minimum 256MB)"];
        return NO;
    }

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 1b: Acquire admin privileges (shows macOS auth dialog) */
    [self _reportProgress:progress stage:VTInstallStageValidating percent:2.0 message:@"Requesting admin privileges..."];
    if (![self _acquirePrivilegesOrError:outError]) {
        return NO;
    }

    /* Step 2: Wipe the disk clean (removes old partition tables/filesystems that confuse macOS) */
    [self _reportProgress:progress stage:VTInstallStageUnmounting percent:5.0 message:@"Preparing disk..."];

    {
        NSError *wipeError = nil;
        NSString *diskDevice = [NSString stringWithFormat:@"/dev/%@", disk.bsdName];
        int wipeRet = [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                                   arguments:@[@"eraseDisk", @"free", @"YOURNAME", @"MBR", diskDevice]
                                                       error:&wipeError];
        if (wipeRet != 0) {
            /* If eraseDisk fails, try force-unmounting and zeroing the first sectors manually */
            [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                         arguments:@[@"unmountDisk", @"force", diskDevice]
                                             error:nil];
        }
    }
    sleep(1);

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 3: Write our custom partition table */
    [self _reportProgress:progress stage:VTInstallStagePartitioning percent:10.0 message:@"Writing partition table..."];

    int fd = [self _openRawDevicePrivileged:disk.rawDevicePath error:outError];
    if (fd < 0) {
        return NO;
    }

    uint64_t part2StartSector = 0;
    int ret;
    if (style == VTPartitionStyleGPT) {
        ret = vtoy_darwin_write_gpt_table(fd, disk.sizeInBytes, 0, &part2StartSector);
    } else {
        ret = vtoy_darwin_write_mbr_table(fd, disk.sizeInBytes, 0, &part2StartSector);
    }

    if (ret != 0) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodePartitioningFailed message:@"Failed to write partition table"];
        return NO;
    }
    close(fd);
    sync();

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 4: Force-unmount to prevent macOS from showing repair dialogs */
    [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                 arguments:@[@"unmountDisk", @"force",
                                             [NSString stringWithFormat:@"/dev/%@", disk.bsdName]]
                                     error:nil];

    /* Reprobe to create partition device nodes */
    vtoy_darwin_reprobe_disk([disk.bsdName UTF8String]);
    sleep(1);

    /* Force-unmount again (macOS may have auto-mounted the new partitions) */
    [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                 arguments:@[@"unmountDisk", @"force",
                                             [NSString stringWithFormat:@"/dev/%@", disk.bsdName]]
                                     error:nil];
    sleep(1);

    /* Step 5: Format partition 1 (exFAT) */
    [self _reportProgress:progress stage:VTInstallStageFormattingPart1 percent:20.0 message:@"Formatting partition 1 (exFAT)..."];

    char part1Raw[64], part2Raw[64];
    snprintf(part1Raw, sizeof(part1Raw), "/dev/r%ss1", [disk.bsdName UTF8String]);
    snprintf(part2Raw, sizeof(part2Raw), "/dev/r%ss2", [disk.bsdName UTF8String]);

    NSString *part1RawStr = [NSString stringWithUTF8String:part1Raw];
    if (![self _privilegedFormatExFAT:part1RawStr label:label error:outError]) {
        return NO;
    }

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 6: Format partition 2 (FAT16) */
    [self _reportProgress:progress stage:VTInstallStageFormattingPart2 percent:30.0 message:@"Formatting partition 2 (FAT16)..."];

    NSString *part2RawStr = [NSString stringWithUTF8String:part2Raw];
    if (![self _privilegedFormatFAT16:part2RawStr label:@"VTOYEFI" error:outError]) {
        return NO;
    }

    /* Aggressively unmount after formatting — macOS auto-mounts new volumes
     * and will block pwrite() to the whole-disk device if any partition is mounted */
    NSString *diskDevice = [NSString stringWithFormat:@"/dev/%@", disk.bsdName];
    for (int attempt = 0; attempt < 3; attempt++) {
        [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                     arguments:@[@"unmountDisk", @"force", diskDevice]
                                         error:nil];
        usleep(500000); /* 0.5s between attempts */
    }

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 7: Write boot code (boot.img) */
    [self _reportProgress:progress stage:VTInstallStageWritingBootCode percent:40.0 message:@"Writing boot code..."];

    NSString *bootAssets = [self bootAssetPath];
    if (!bootAssets) {
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"Boot assets not found in app bundle"];
        return NO;
    }

    /* Force unmount one more time immediately before opening */
    [VTPrivilegedTask executeWithPrivileges:@"/usr/sbin/diskutil"
                                 arguments:@[@"unmountDisk", @"force", diskDevice]
                                     error:nil];

    fd = [self _openRawDevicePrivileged:disk.rawDevicePath error:outError];
    if (fd < 0) {
        return NO;
    }

    /* Write boot.img (first 446 bytes — boot code only, don't overwrite partition table) */
    NSString *bootImgPath = [bootAssets stringByAppendingPathComponent:@"boot/boot.img"];
    NSData *bootImg = [NSData dataWithContentsOfFile:bootImgPath];
    if (!bootImg || bootImg.length < 446) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"boot.img not found or too small"];
        return NO;
    }

    if (![self _sectorAlignedWrite:fd data:bootImg.bytes offset:0 length:446]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write boot code"];
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 7: Write core.img */
    [self _reportProgress:progress stage:VTInstallStageWritingCore percent:50.0 message:@"Writing GRUB core image..."];

    NSString *coreImgPath = [bootAssets stringByAppendingPathComponent:@"boot/core.img"];
    NSData *coreImg = [NSData dataWithContentsOfFile:coreImgPath];
    if (!coreImg) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"core.img not found"];
        return NO;
    }

    /*
     * MBR: write at sector 1 (byte offset 512)
     * GPT: write at sector 34 (byte offset 34*512 = 17408) to avoid overwriting GPT headers
     */
    off_t coreOffset = (style == VTPartitionStyleGPT) ? (34 * VENTOY_SECTOR_SIZE) : VENTOY_SECTOR_SIZE;

    /* Pad core.img to sector boundary — macOS raw devices require sector-aligned I/O */
    size_t coreWriteLen = ((coreImg.length + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    uint8_t *corePadded = calloc(1, coreWriteLen);
    if (!corePadded) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Out of memory"];
        return NO;
    }
    memcpy(corePadded, coreImg.bytes, coreImg.length);
    ssize_t written = pwrite(fd, corePadded, coreWriteLen, coreOffset);
    free(corePadded);
    if (written != (ssize_t)coreWriteLen) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write core image"];
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 8: Write ventoy.disk.img.xz (decompress + write to partition 2) */
    [self _reportProgress:progress stage:VTInstallStageWritingVentoyImage percent:60.0 message:@"Writing Ventoy EFI image..."];

    if (![self _writeVentoyImageFromAssets:bootAssets toFd:fd atSector:part2StartSector error:outError]) {
        close(fd);
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 9: Write UUID and signature */
    [self _reportProgress:progress stage:VTInstallStageWritingUUID percent:80.0 message:@"Writing disk UUID..."];

    uint8_t uuid[16];
    vtoy_darwin_gen_uuid(uuid, sizeof(uuid));

    if (![self _sectorAlignedWrite:fd data:uuid offset:VENTOY_UUID_OFFSET length:16]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write UUID"];
        return NO;
    }

    /* Write disk signature (first 4 bytes of UUID at offset 440) */
    if (![self _sectorAlignedWrite:fd data:uuid offset:VENTOY_SIGNATURE_OFFSET length:4]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write disk signature"];
        return NO;
    }

    /* Step 10: Sync and close */
    [self _reportProgress:progress stage:VTInstallStageSyncing percent:90.0 message:@"Syncing..."];
    fsync(fd);
    close(fd);

    [self _reportProgress:progress stage:VTInstallStageComplete percent:100.0 message:@"Installation complete!"];
    return YES;
}

#pragma mark - Private: Update Flow

- (BOOL)_performUpdateOnDisk:(VTDiskInfo *)disk
                  secureBoot:(BOOL)secureBoot
                    progress:(VTProgressBlock)progress
                       error:(NSError **)outError {

    /* Step 1: Validate */
    [self _reportProgress:progress stage:VTInstallStageValidating percent:0.0 message:@"Validating disk..."];

    if (!disk.isRemovable) {
        *outError = [self _errorWithCode:VTErrorCodeDiskNotRemovable message:@"Disk is not removable"];
        return NO;
    }
    if (!disk.isWritable) {
        *outError = [self _errorWithCode:VTErrorCodeDiskNotWritable message:@"Disk is not writable"];
        return NO;
    }

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 1b: Acquire admin privileges */
    [self _reportProgress:progress stage:VTInstallStageValidating percent:2.0 message:@"Requesting admin privileges..."];
    if (![self _acquirePrivilegesOrError:outError]) {
        return NO;
    }

    /* Step 2: Unmount */
    [self _reportProgress:progress stage:VTInstallStageUnmounting percent:5.0 message:@"Unmounting disk..."];

    if (vtoy_darwin_unmount_disk([disk.bsdName UTF8String]) != 0) {
        *outError = [self _errorWithCode:VTErrorCodeDiskIsMounted message:@"Failed to unmount disk"];
        return NO;
    }

    if (self.cancelled) {
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 3: Open raw device and verify Ventoy is installed */
    [self _reportProgress:progress stage:VTInstallStageValidating percent:10.0 message:@"Verifying existing Ventoy installation..."];

    int fd = [self _openRawDevicePrivileged:disk.rawDevicePath error:outError];
    if (fd < 0) {
        return NO;
    }

    /* Read existing UUID from offset 384 to verify Ventoy is installed */
    uint8_t existingUUID[16];
    memset(existingUUID, 0, sizeof(existingUUID));
    if (![self _sectorAlignedRead:fd buffer:existingUUID offset:VENTOY_UUID_OFFSET length:16]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeVentoyNotInstalled message:@"Failed to read disk UUID area"];
        return NO;
    }

    /* Check if UUID area is all zeros (no Ventoy installed) */
    BOOL allZeros = YES;
    for (int i = 0; i < 16; i++) {
        if (existingUUID[i] != 0) {
            allZeros = NO;
            break;
        }
    }
    if (allZeros) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeVentoyNotInstalled message:@"Ventoy is not installed on this disk"];
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 4: Determine partition 2 start sector from existing partition table */
    uint64_t part2StartSector = vtoy_darwin_get_partition_offset([disk.bsdName UTF8String], 2);
    if (part2StartSector == 0) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeVentoyNotInstalled message:@"Cannot find partition 2 — disk layout may be corrupted"];
        return NO;
    }

    /* Detect partition style from existing table (check for GPT signature at LBA 1) */
    uint8_t gptSig[8];
    if (![self _sectorAlignedRead:fd buffer:gptSig offset:VENTOY_SECTOR_SIZE length:8]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to read partition table"];
        return NO;
    }
    /* "EFI PART" signature at byte offset 512 indicates GPT */
    VTPartitionStyle style = VTPartitionStyleMBR;
    if (memcmp(gptSig, "EFI PART", 8) == 0) {
        style = VTPartitionStyleGPT;
    }

    /* Step 5: Write boot code (boot.img) */
    [self _reportProgress:progress stage:VTInstallStageWritingBootCode percent:20.0 message:@"Updating boot code..."];

    NSString *bootAssets = [self bootAssetPath];
    if (!bootAssets) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"Boot assets not found in app bundle"];
        return NO;
    }

    NSString *bootImgPath = [bootAssets stringByAppendingPathComponent:@"boot/boot.img"];
    NSData *bootImg = [NSData dataWithContentsOfFile:bootImgPath];
    if (!bootImg || bootImg.length < 446) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"boot.img not found or too small"];
        return NO;
    }

    if (![self _sectorAlignedWrite:fd data:bootImg.bytes offset:0 length:446]) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write boot code"];
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 6: Write core.img */
    [self _reportProgress:progress stage:VTInstallStageWritingCore percent:40.0 message:@"Updating GRUB core image..."];

    NSString *coreImgPath = [bootAssets stringByAppendingPathComponent:@"boot/core.img"];
    NSData *coreImg = [NSData dataWithContentsOfFile:coreImgPath];
    if (!coreImg) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"core.img not found"];
        return NO;
    }

    off_t coreOffset = (style == VTPartitionStyleGPT) ? (34 * VENTOY_SECTOR_SIZE) : VENTOY_SECTOR_SIZE;

    /* Pad core.img to sector boundary */
    size_t updateCoreLen = ((coreImg.length + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    uint8_t *updateCorePad = calloc(1, updateCoreLen);
    if (!updateCorePad) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Out of memory"];
        return NO;
    }
    memcpy(updateCorePad, coreImg.bytes, coreImg.length);
    ssize_t updateCoreWritten = pwrite(fd, updateCorePad, updateCoreLen, coreOffset);
    free(updateCorePad);
    if (updateCoreWritten != (ssize_t)updateCoreLen) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write core image"];
        return NO;
    }

    if (self.cancelled) {
        close(fd);
        *outError = [self _errorWithCode:VTErrorCodeUserCancelled message:@"Operation cancelled"];
        return NO;
    }

    /* Step 7: Write ventoy.disk.img.xz to partition 2 */
    [self _reportProgress:progress stage:VTInstallStageWritingVentoyImage percent:60.0 message:@"Updating Ventoy EFI image..."];

    if (![self _writeVentoyImageFromAssets:bootAssets toFd:fd atSector:part2StartSector error:outError]) {
        close(fd);
        return NO;
    }

    /* Step 8: Preserve existing UUID (do NOT overwrite) */
    /* UUID is already on disk, no action needed. */

    /* Step 9: Sync and close */
    [self _reportProgress:progress stage:VTInstallStageSyncing percent:90.0 message:@"Syncing..."];
    fsync(fd);
    close(fd);

    [self _reportProgress:progress stage:VTInstallStageComplete percent:100.0 message:@"Update complete!"];
    return YES;
}

#pragma mark - Private: Ventoy Image Writer (shared between install and update)

- (BOOL)_writeVentoyImageFromAssets:(NSString *)bootAssets
                              toFd:(int)fd
                          atSector:(uint64_t)part2StartSector
                             error:(NSError **)outError {

    NSString *ventoyImgPath = [bootAssets stringByAppendingPathComponent:@"ventoy/ventoy.disk.img.xz"];
    NSData *ventoyImgXZ = [NSData dataWithContentsOfFile:ventoyImgPath];
    if (!ventoyImgXZ) {
        *outError = [self _errorWithCode:VTErrorCodeBootAssetsNotFound message:@"ventoy.disk.img.xz not found"];
        return NO;
    }

    /* Decompress XZ data using macOS compression framework.
     * ventoy.disk.img is 32MB (VENTOY_PART_SIZE_MB * 1024 * 1024) */
    size_t decompressedSize = VENTOY_PART_SIZE_MB * 1024 * 1024;
    uint8_t *decompressedData = malloc(decompressedSize);
    if (!decompressedData) {
        *outError = [self _errorWithCode:VTErrorCodeDecompressionFailed message:@"Out of memory for decompression"];
        return NO;
    }

    /* Try LZMA decompression (XZ uses LZMA2 internally) */
    size_t actualSize = compression_decode_buffer(decompressedData, decompressedSize,
                                                   ventoyImgXZ.bytes, ventoyImgXZ.length,
                                                   NULL, COMPRESSION_LZMA);

    off_t part2Offset = (off_t)(part2StartSector * VENTOY_SECTOR_SIZE);

    if (actualSize == 0 || actualSize > decompressedSize) {
        /*
         * If macOS compression framework can't handle XZ directly,
         * fall back to system xz command.
         */
        free(decompressedData);

        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ventoy.disk.img"];
        NSString *xzCmd = [NSString stringWithFormat:@"xz -dk -c '%@' > '%@'", ventoyImgPath, tmpPath];
        if (system([xzCmd UTF8String]) != 0) {
            *outError = [self _errorWithCode:VTErrorCodeDecompressionFailed message:@"Failed to decompress ventoy.disk.img.xz"];
            return NO;
        }

        NSData *decompressed = [NSData dataWithContentsOfFile:tmpPath];
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

        if (!decompressed) {
            *outError = [self _errorWithCode:VTErrorCodeDecompressionFailed message:@"Failed to read decompressed image"];
            return NO;
        }

        /* Pad to sector boundary for raw device I/O */
        size_t imgWriteLen = ((decompressed.length + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
        uint8_t *imgPadded = calloc(1, imgWriteLen);
        if (!imgPadded) {
            *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Out of memory"];
            return NO;
        }
        memcpy(imgPadded, decompressed.bytes, decompressed.length);
        ssize_t imgWritten = pwrite(fd, imgPadded, imgWriteLen, part2Offset);
        free(imgPadded);
        if (imgWritten != (ssize_t)imgWriteLen) {
            *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write Ventoy EFI image"];
            return NO;
        }
    } else {
        /* Pad to sector boundary for raw device I/O */
        size_t imgWriteLen = ((actualSize + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
        uint8_t *imgPadded = calloc(1, imgWriteLen);
        if (!imgPadded) {
            free(decompressedData);
            *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Out of memory"];
            return NO;
        }
        memcpy(imgPadded, decompressedData, actualSize);
        free(decompressedData);
        ssize_t imgWritten = pwrite(fd, imgPadded, imgWriteLen, part2Offset);
        free(imgPadded);
        if (imgWritten != (ssize_t)imgWriteLen) {
            *outError = [self _errorWithCode:VTErrorCodeWriteFailed message:@"Failed to write Ventoy EFI image"];
            return NO;
        }
    }

    return YES;
}

#pragma mark - Private: Helpers

- (void)_reportProgress:(VTProgressBlock)progress
                  stage:(VTInstallStage)stage
                percent:(double)percent
                message:(NSString *)message {
    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(stage, percent, message);
        });
    }
}

- (NSError *)_errorWithCode:(VTErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:VTErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Private: Sector-Aligned I/O

/*
 * macOS raw disk devices (/dev/rdiskN) require ALL reads and writes to be
 * sector-aligned — both the offset and length must be multiples of 512 bytes.
 * Sub-sector I/O (e.g. writing 446 bytes of boot code) returns EINVAL.
 *
 * These helpers implement a read-modify-write pattern: read the enclosing
 * full sector(s), overlay the data, and write the full sector(s) back.
 */

- (BOOL)_sectorAlignedRead:(int)fd buffer:(void *)buffer offset:(off_t)offset length:(size_t)length {
    off_t sectorStart = (offset / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    off_t sectorEnd = ((offset + length + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    size_t alignedLen = (size_t)(sectorEnd - sectorStart);

    uint8_t *alignedBuf = malloc(alignedLen);
    if (!alignedBuf) return NO;

    ssize_t n = pread(fd, alignedBuf, alignedLen, sectorStart);
    if (n != (ssize_t)alignedLen) {
        free(alignedBuf);
        return NO;
    }

    memcpy(buffer, alignedBuf + (offset - sectorStart), length);
    free(alignedBuf);
    return YES;
}

- (BOOL)_sectorAlignedWrite:(int)fd data:(const void *)data offset:(off_t)offset length:(size_t)length {
    off_t sectorStart = (offset / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    off_t sectorEnd = ((offset + length + VENTOY_SECTOR_SIZE - 1) / VENTOY_SECTOR_SIZE) * VENTOY_SECTOR_SIZE;
    size_t alignedLen = (size_t)(sectorEnd - sectorStart);

    uint8_t *alignedBuf = malloc(alignedLen);
    if (!alignedBuf) return NO;

    /* Read existing sector(s) first */
    ssize_t n = pread(fd, alignedBuf, alignedLen, sectorStart);
    if (n != (ssize_t)alignedLen) {
        free(alignedBuf);
        return NO;
    }

    /* Overlay our data */
    memcpy(alignedBuf + (offset - sectorStart), data, length);

    /* Write back full sector(s) */
    ssize_t w = pwrite(fd, alignedBuf, alignedLen, sectorStart);
    free(alignedBuf);
    return (w == (ssize_t)alignedLen);
}

#pragma mark - Private: Privileged Helpers

- (BOOL)_acquirePrivilegesOrError:(NSError **)outError {
    NSError *authError = nil;
    if (![VTPrivilegedTask acquirePrivileges:&authError]) {
        if (outError) {
            *outError = authError ?: [self _errorWithCode:VTErrorCodePrivilegeEscalationFailed
                                                  message:@"Failed to acquire admin privileges"];
        }
        return NO;
    }
    return YES;
}

- (int)_openRawDevicePrivileged:(NSString *)rawDevicePath error:(NSError **)outError {
    /* Try direct open first (may work if already root or device is accessible) */
    int fd = open([rawDevicePath UTF8String], O_RDWR);
    if (fd >= 0) return fd;

    /* Permission denied — use privileges to chmod the raw device */
    if (errno == EACCES) {
        [VTPrivilegedTask executeWithPrivileges:@"/bin/chmod"
                                     arguments:@[@"0666", rawDevicePath]
                                         error:nil];
        fd = open([rawDevicePath UTF8String], O_RDWR);
        if (fd >= 0) return fd;
    }

    if (outError) {
        *outError = [self _errorWithCode:VTErrorCodeWriteFailed
                                 message:[NSString stringWithFormat:@"Cannot open %@: %s",
                                          rawDevicePath, strerror(errno)]];
    }
    return -1;
}

- (BOOL)_privilegedFormatExFAT:(NSString *)partition label:(NSString *)label error:(NSError **)outError {
    NSError *execError = nil;
    int ret = [VTPrivilegedTask executeWithPrivileges:@"/sbin/newfs_exfat"
                                           arguments:@[@"-v", label, partition]
                                               error:&execError];
    if (ret != 0) {
        if (outError) {
            *outError = execError ?: [self _errorWithCode:VTErrorCodeFormattingFailed
                                                  message:@"Failed to format partition as exFAT"];
        }
        return NO;
    }
    return YES;
}

- (BOOL)_privilegedFormatFAT16:(NSString *)partition label:(NSString *)label error:(NSError **)outError {
    NSError *execError = nil;
    int ret = [VTPrivilegedTask executeWithPrivileges:@"/sbin/newfs_msdos"
                                           arguments:@[@"-F", @"16", @"-v", label, partition]
                                               error:&execError];
    if (ret != 0) {
        if (outError) {
            *outError = execError ?: [self _errorWithCode:VTErrorCodeFormattingFailed
                                                  message:@"Failed to format partition as FAT16"];
        }
        return NO;
    }
    return YES;
}

@end
