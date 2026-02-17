/******************************************************************************
 * VTPrivilegedTask.m — Privilege escalation wrapper for disk write operations
 *
 * Uses Apple's Security.framework Authorization Services to execute commands
 * as root. AuthorizationExecuteWithPrivileges is deprecated but remains
 * functional on macOS 13+. The modern alternative (SMJobBless with a
 * privileged helper tool) is significantly more complex and will be
 * considered for a future release.
 *
 * Copyright (c) 2026, Key Network Services Ltd
 * License: GPL v3 (inherited from Ventoy)
 *****************************************************************************/

#import "VTPrivilegedTask.h"
#import "VTTypes.h"
#import <Security/Authorization.h>
#import <sys/wait.h>

/// Static authorization reference shared across all calls.
static AuthorizationRef sAuthRef = NULL;

#pragma mark - Private Helpers

/// Create an NSError in VTErrorDomain with the privilege escalation error code.
static NSError *VTPrivilegeError(NSString *description) {
    return [NSError errorWithDomain:VTErrorDomain
                               code:VTErrorCodePrivilegeEscalationFailed
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

/// Map an OSStatus from Authorization Services to a human-readable NSError.
static NSError *VTErrorFromAuthStatus(OSStatus status) {
    switch (status) {
        case errAuthorizationCanceled:
            return VTPrivilegeError(@"User cancelled authentication");
        case errAuthorizationDenied:
            return VTPrivilegeError(@"Authorization denied");
        case errAuthorizationToolExecuteFailure:
            return VTPrivilegeError(@"Failed to execute privileged command");
        case errAuthorizationInteractionNotAllowed:
            return VTPrivilegeError(@"User interaction is not allowed");
        case errAuthorizationToolEnvironmentError:
            return VTPrivilegeError(@"Privileged tool encountered an environment error");
        default: {
            NSString *msg = [NSString stringWithFormat:
                @"Authorization failed with status %d", (int)status];
            return VTPrivilegeError(msg);
        }
    }
}

@implementation VTPrivilegedTask

#pragma mark - Acquire Privileges

+ (BOOL)acquirePrivileges:(NSError * _Nullable *)error {
    @synchronized (self) {
        // If we already hold a valid authorization, return immediately.
        if (sAuthRef != NULL) {
            return YES;
        }

        OSStatus status;

        // Create an empty authorization reference.
        status = AuthorizationCreate(NULL,
                                     kAuthorizationEmptyEnvironment,
                                     kAuthorizationFlagDefaults,
                                     &sAuthRef);
        if (status != errAuthorizationSuccess) {
            sAuthRef = NULL;
            if (error) {
                *error = VTErrorFromAuthStatus(status);
            }
            return NO;
        }

        // Define the right we need: the ability to execute commands as root.
        AuthorizationItem rightItem = {
            .name = kAuthorizationRightExecute,
            .valueLength = 0,
            .value = NULL,
            .flags = 0
        };
        AuthorizationRights rights = {
            .count = 1,
            .items = &rightItem
        };

        // Request the right. This will show the macOS authentication dialog
        // if the user has not already authenticated.
        AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed
                                 | kAuthorizationFlagPreAuthorize
                                 | kAuthorizationFlagExtendRights;

        status = AuthorizationCopyRights(sAuthRef, &rights,
                                         kAuthorizationEmptyEnvironment,
                                         flags, NULL);
        if (status != errAuthorizationSuccess) {
            AuthorizationFree(sAuthRef, kAuthorizationFlagDefaults);
            sAuthRef = NULL;
            if (error) {
                *error = VTErrorFromAuthStatus(status);
            }
            return NO;
        }

        return YES;
    }
}

#pragma mark - Execute With Privileges

+ (int)executeWithPrivileges:(NSString *)command
                   arguments:(NSArray<NSString *> *)arguments
                       error:(NSError * _Nullable *)error {
    return [self executeWithPrivileges:command
                             arguments:arguments
                                output:NULL
                                 error:error];
}

+ (int)executeWithPrivileges:(NSString *)command
                   arguments:(NSArray<NSString *> *)arguments
                      output:(NSString * _Nullable * _Nullable)output
                       error:(NSError * _Nullable *)error {
    @synchronized (self) {
        if (output) {
            *output = nil;
        }

        // Ensure we have a valid authorization reference.
        if (sAuthRef == NULL) {
            if (error) {
                *error = VTPrivilegeError(
                    @"No authorization acquired. Call acquirePrivileges: first.");
            }
            return -1;
        }

        // Build the C argument array. AuthorizationExecuteWithPrivileges
        // expects a NULL-terminated array of C strings.
        NSUInteger argCount = arguments.count;
        const char **args = calloc(argCount + 1, sizeof(char *));
        if (args == NULL) {
            if (error) {
                *error = VTPrivilegeError(@"Memory allocation failed");
            }
            return -1;
        }

        for (NSUInteger i = 0; i < argCount; i++) {
            args[i] = [arguments[i] UTF8String];
        }
        args[argCount] = NULL;

        // Suppress the deprecation warning for AuthorizationExecuteWithPrivileges.
        // This API is deprecated since macOS 10.7 but remains functional through
        // macOS 15 (Sequoia). The modern replacement (SMJobBless / XPC privileged
        // helper) requires a separate helper tool, launchd plist, code-signing
        // entitlements, and SMAuthorizedClients entries — substantially more
        // complexity for v1.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

        FILE *pipe = NULL;
        OSStatus status = AuthorizationExecuteWithPrivileges(
            sAuthRef,
            [command fileSystemRepresentation],
            kAuthorizationFlagDefaults,
            (char *const *)args,
            (output != NULL) ? &pipe : NULL
        );

#pragma clang diagnostic pop

        free(args);

        if (status != errAuthorizationSuccess) {
            if (pipe) {
                fclose(pipe);
            }
            if (error) {
                *error = VTErrorFromAuthStatus(status);
            }
            return -1;
        }

        // Read stdout from the pipe if the caller wants output.
        if (pipe != NULL) {
            if (output != NULL) {
                NSMutableData *data = [NSMutableData data];
                char buffer[4096];
                size_t bytesRead;

                while ((bytesRead = fread(buffer, 1, sizeof(buffer), pipe)) > 0) {
                    [data appendBytes:buffer length:bytesRead];
                }

                *output = [[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding];
            }
            fclose(pipe);
        }

        // Wait for the child process to finish and collect the exit status.
        // AuthorizationExecuteWithPrivileges forks a child process; we must
        // reap it to avoid zombie processes and to obtain the exit code.
        int exitStatus = 0;
        int waitResult;
        do {
            waitResult = waitpid(-1, &exitStatus, 0);
        } while (waitResult == -1 && errno == EINTR);

        if (waitResult == -1) {
            // waitpid failed — this can happen if the child was already reaped.
            // Not a fatal error; we just can't determine the exit code.
            return -1;
        }

        if (WIFEXITED(exitStatus)) {
            return WEXITSTATUS(exitStatus);
        }

        // The child was killed by a signal.
        if (WIFSIGNALED(exitStatus)) {
            if (error) {
                NSString *msg = [NSString stringWithFormat:
                    @"Privileged command terminated by signal %d", WTERMSIG(exitStatus)];
                *error = VTPrivilegeError(msg);
            }
            return -1;
        }

        return -1;
    }
}

#pragma mark - Release Privileges

+ (void)releasePrivileges {
    @synchronized (self) {
        if (sAuthRef != NULL) {
            AuthorizationFree(sAuthRef, kAuthorizationFlagDestroyRights);
            sAuthRef = NULL;
        }
    }
}

#pragma mark - Query

+ (BOOL)hasPrivileges {
    @synchronized (self) {
        return (sAuthRef != NULL);
    }
}

@end
