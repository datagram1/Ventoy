/******************************************************************************
 * VTDiskOperations.h — Ventoy install/update engine
 *
 * Gate 0 header — READ-ONLY during Wave 1.
 * WP5 implements VTDiskOperations.m against this interface.
 *****************************************************************************/

#import <Foundation/Foundation.h>
#import "VTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface VTDiskOperations : NSObject

/// Install Ventoy to a disk. Destroys all existing data.
/// Runs on a background queue; callbacks dispatched to main queue.
- (void)installVentoyToDisk:(VTDiskInfo *)disk
             partitionStyle:(VTPartitionStyle)style
                 secureBoot:(BOOL)secureBoot
                volumeLabel:(NSString *)label
                   progress:(VTProgressBlock)progress
                 completion:(VTCompletionBlock)completion;

/// Update Ventoy on a disk. Preserves partition 1 (ISO files).
- (void)updateVentoyOnDisk:(VTDiskInfo *)disk
                secureBoot:(BOOL)secureBoot
                  progress:(VTProgressBlock)progress
                completion:(VTCompletionBlock)completion;

/// Check if a disk has Ventoy installed. Returns version string or nil.
- (nullable NSString *)ventoyVersionOnDisk:(VTDiskInfo *)disk;

/// Path to the bundled boot assets directory inside the app bundle.
- (NSString *)bootAssetPath;

/// Cancel any in-progress operation.
- (void)cancelCurrentOperation;

@property (nonatomic, readonly) BOOL isOperationInProgress;

@end

NS_ASSUME_NONNULL_END
