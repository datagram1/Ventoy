/******************************************************************************
 * VTPrivilegedTask.h — Privilege escalation wrapper for disk write operations
 *
 * macOS requires root access to write to raw disk devices (/dev/rdiskN).
 * This class wraps Apple's Security.framework Authorization Services to
 * acquire and manage admin privileges for the Ventoy install/update engine.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VTPrivilegedTask : NSObject

/// Acquire admin privileges. Shows the macOS authorization dialog.
/// Returns YES if the user authenticated successfully.
+ (BOOL)acquirePrivileges:(NSError * _Nullable *)error;

/// Execute a command with root privileges using the previously acquired authorization.
/// Returns the command's exit status (0 = success).
+ (int)executeWithPrivileges:(NSString *)command
                   arguments:(NSArray<NSString *> *)arguments
                       error:(NSError * _Nullable *)error;

/// Execute a command with root privileges and capture stdout.
+ (int)executeWithPrivileges:(NSString *)command
                   arguments:(NSArray<NSString *> *)arguments
                      output:(NSString * _Nullable * _Nullable)output
                       error:(NSError * _Nullable *)error;

/// Release any held authorization reference.
+ (void)releasePrivileges;

/// Whether we currently hold a valid authorization.
+ (BOOL)hasPrivileges;

@end

NS_ASSUME_NONNULL_END
