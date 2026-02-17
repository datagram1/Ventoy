/******************************************************************************
 * VTTypes.h — Shared type definitions for VentoyMac
 *
 * This file is created by Gate 0 and is READ-ONLY during Wave 1.
 * All agents may #import this file but NONE may modify it.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#ifndef VT_TYPES_H
#define VT_TYPES_H

#import <Foundation/Foundation.h>

#pragma mark - Enums

typedef NS_ENUM(NSInteger, VTPartitionStyle) {
    VTPartitionStyleMBR = 0,
    VTPartitionStyleGPT = 1
};

typedef NS_ENUM(NSInteger, VTInstallStage) {
    VTInstallStageValidating = 0,
    VTInstallStageUnmounting,
    VTInstallStagePartitioning,
    VTInstallStageFormattingPart1,
    VTInstallStageFormattingPart2,
    VTInstallStageWritingBootCode,
    VTInstallStageWritingCore,
    VTInstallStageWritingVentoyImage,
    VTInstallStageWritingUUID,
    VTInstallStageSecureBootProcessing,
    VTInstallStageSyncing,
    VTInstallStageVerifying,
    VTInstallStageComplete,
    VTInstallStageFailed
};

#pragma mark - Block Types

@class VTDiskInfo;

typedef void (^VTProgressBlock)(VTInstallStage stage, double percent, NSString * _Nonnull message);
typedef void (^VTCompletionBlock)(BOOL success, NSError * _Nullable error);

#pragma mark - Notification Names

extern NSNotificationName const _Nonnull VTDiskAppearedNotification;
extern NSNotificationName const _Nonnull VTDiskDisappearedNotification;
extern NSNotificationName const _Nonnull VTLogEntryAddedNotification;

#pragma mark - Error Domain

extern NSErrorDomain const _Nonnull VTErrorDomain;

typedef NS_ENUM(NSInteger, VTErrorCode) {
    VTErrorCodeDiskNotRemovable = 1000,
    VTErrorCodeDiskNotWritable,
    VTErrorCodeDiskIsMounted,
    VTErrorCodeDiskTooSmall,
    VTErrorCodePartitioningFailed,
    VTErrorCodeFormattingFailed,
    VTErrorCodeWriteFailed,
    VTErrorCodeVerificationFailed,
    VTErrorCodeBootAssetsNotFound,
    VTErrorCodeDecompressionFailed,
    VTErrorCodePrivilegeEscalationFailed,
    VTErrorCodeVentoyNotInstalled,
    VTErrorCodeUserCancelled
};

#pragma mark - Constants

#define VENTOY_PART_SIZE_MB         32
#define VENTOY_SECTOR_SIZE          512
#define VENTOY_SECTOR_NUM           65536       // 32MB / 512
#define VENTOY_PART1_START_SECTOR   2048        // 1MB offset
#define VENTOY_EFI_PART_ATTR        0x8000000000000000ULL
#define VENTOY_UUID_OFFSET          384
#define VENTOY_SIGNATURE_OFFSET     440

#pragma mark - VTDiskInfo

@interface VTDiskInfo : NSObject

@property (nonatomic, copy, nonnull) NSString *bsdName;
@property (nonatomic, copy, nonnull) NSString *devicePath;
@property (nonatomic, copy, nonnull) NSString *rawDevicePath;
@property (nonatomic, copy, nullable) NSString *vendorName;
@property (nonatomic, copy, nullable) NSString *productName;
@property (nonatomic, copy, nullable) NSString *busType;
@property (nonatomic, assign) uint64_t sizeInBytes;
@property (nonatomic, assign) BOOL isRemovable;
@property (nonatomic, assign) BOOL isWritable;
@property (nonatomic, assign) VTPartitionStyle partitionStyle;
@property (nonatomic, copy, nullable) NSString *ventoyVersion;

- (nonnull NSString *)humanReadableSize;
- (nonnull NSString *)displayName;

@end

#endif /* VT_TYPES_H */
