#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <libgen.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_status.h>
#include <objc/runtime.h>
#include <ptrauth.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef uint64_t CGSSpaceID;

extern int CGSMainConnectionID(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(int cid);
extern int CGSSpaceGetType(int cid, CGSSpaceID sid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int mask, CFArrayRef windowList);
extern CFStringRef SLSCopyManagedDisplayForWindow(int cid, uint32_t wid);
extern CFStringRef SLSCopyBestManagedDisplayForRect(int cid, CGRect rect);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);

static const int kCGSSpaceUser = 0;
static const int kCGSSpaceFullscreen = 4;
static const int kSpacesMaskAll = 0x7;
static const uint64_t kSuccessMarker = 0x79616265;

static kern_return_t (*g_thread_convert_thread_state)(thread_act_t thread, int direction,
                                                      thread_state_flavor_t flavor,
                                                      thread_state_t in_state,
                                                      mach_msg_type_number_t in_state_count,
                                                      thread_state_t out_state,
                                                      mach_msg_type_number_t *out_state_count);

static NSString *socket_path(void);

static const unsigned char kArm64ShellCodeTemplate[] = {
    0xFF, 0xC3, 0x00, 0xD1, 0xFD, 0x7B, 0x02, 0xA9, 0xFD, 0x83, 0x00, 0x91,
    0xA0, 0xC3, 0x1F, 0xB8, 0xE1, 0x0B, 0x00, 0xF9, 0xE0, 0x23, 0x00, 0x91,
    0x08, 0x00, 0x80, 0xD2, 0xE8, 0x07, 0x00, 0xF9, 0xE1, 0x03, 0x08, 0xAA,
    0xE2, 0x01, 0x00, 0x10, 0xE2, 0x23, 0xC1, 0xDA, 0xE3, 0x03, 0x08, 0xAA,
    0x49, 0x01, 0x00, 0x10, 0x29, 0x01, 0x40, 0xF9, 0x20, 0x01, 0x3F, 0xD6,
    0xA0, 0x4C, 0x8C, 0xD2, 0x20, 0x2C, 0xAF, 0xF2, 0x09, 0x00, 0x00, 0x10,
    0x20, 0x01, 0x1F, 0xD6, 0xFD, 0x7B, 0x42, 0xA9, 0xFF, 0xC3, 0x00, 0x91,
    0xC0, 0x03, 0x5F, 0xD6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x7F, 0x23, 0x03, 0xD5, 0xFF, 0xC3, 0x00, 0xD1, 0xFD, 0x7B, 0x02, 0xA9,
    0xFD, 0x83, 0x00, 0x91, 0xA0, 0xC3, 0x1F, 0xB8, 0xE1, 0x0B, 0x00, 0xF9,
    0x21, 0x00, 0x80, 0xD2, 0x60, 0x01, 0x00, 0x10, 0x09, 0x01, 0x00, 0x10,
    0x29, 0x01, 0x40, 0xF9, 0x20, 0x01, 0x3F, 0xD6, 0x09, 0x00, 0x80, 0x52,
    0xE0, 0x03, 0x09, 0xAA, 0xFD, 0x7B, 0x42, 0xA9, 0xFF, 0xC3, 0x00, 0x91,
    0xFF, 0x0F, 0x5F, 0xD6,
};

static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static NSString *space_type_label(CGSSpaceID sid) {
    int type = CGSSpaceGetType(CGSMainConnectionID(), sid);
    if (type == kCGSSpaceUser) return @"user";
    if (type == kCGSSpaceFullscreen) return @"fullscreen";
    return [NSString stringWithFormat:@"type-%d", type];
}

static NSArray<NSDictionary *> *managed_display_spaces(void) {
    CFArrayRef raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID());
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSString *window_display_uuid(uint32_t wid) {
    CFStringRef display = SLSCopyManagedDisplayForWindow(CGSMainConnectionID(), wid);
    if (display) return CFBridgingRelease(display);

    CGRect frame = CGRectZero;
    if (SLSGetWindowBounds(CGSMainConnectionID(), wid, &frame) != kCGErrorSuccess) {
        return nil;
    }

    display = SLSCopyBestManagedDisplayForRect(CGSMainConnectionID(), frame);
    return display ? CFBridgingRelease(display) : nil;
}

static NSArray<NSNumber *> *space_ids_for_window(uint32_t wid) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    const void *values[] = {number};
    CFArrayRef window_list = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);

    CFArrayRef raw = SLSCopySpacesForWindows(CGSMainConnectionID(), kSpacesMaskAll, window_list);
    CFRelease(window_list);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *space_records_for_display(NSString *display_uuid) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *display_info in managed_display_spaces()) {
        NSString *candidate = display_info[@"Display Identifier"];
        if (display_uuid && ![candidate isEqualToString:display_uuid]) continue;

        NSDictionary *current_space = display_info[@"Current Space"];
        uint64_t current_sid = [current_space[@"ManagedSpaceID"] unsignedLongLongValue];
        NSInteger user_index = 0;
        NSInteger all_index = 0;

        for (NSDictionary *space_info in display_info[@"Spaces"]) {
            all_index += 1;
            uint64_t sid = [space_info[@"ManagedSpaceID"] unsignedLongLongValue];
            NSString *type = space_type_label(sid);
            NSNumber *user_value = nil;
            if ([type isEqualToString:@"user"]) {
                user_index += 1;
                user_value = @(user_index);
            }

            [records addObject:@{
                @"display_uuid": candidate ?: @"",
                @"space_id": @(sid),
                @"current": @(sid == current_sid),
                @"type": type,
                @"all_index": @(all_index),
                @"user_index": user_value ?: [NSNull null],
            }];
        }
    }
    return records;
}

static void command_list_spaces(void) {
    for (NSDictionary *record in space_records_for_display(nil)) {
        NSString *user_index = record[@"user_index"] == [NSNull null]
            ? @"-"
            : [record[@"user_index"] stringValue];
        printf("display=%s space_id=%llu type=%s current=%s all_index=%s user_index=%s\n",
               [record[@"display_uuid"] UTF8String],
               [record[@"space_id"] unsignedLongLongValue],
               [record[@"type"] UTF8String],
               [record[@"current"] boolValue] ? "yes" : "no",
               [[record[@"all_index"] stringValue] UTF8String],
               user_index.UTF8String);
    }
}

static void command_list_windows(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    NSArray *windows = CFBridgingRelease(raw);
    for (NSDictionary *window in windows) {
        int layer = [window[(id) kCGWindowLayer] intValue];
        if (layer != 0) continue;

        NSNumber *wid = window[(id) kCGWindowNumber];
        NSString *owner = window[(id) kCGWindowOwnerName] ?: @"";
        NSString *title = window[(id) kCGWindowName] ?: @"";
        NSDictionary *bounds = window[(id) kCGWindowBounds] ?: @{};

        printf("window_id=%u owner=%s title=%s bounds=%s\n",
               wid.unsignedIntValue,
               owner.UTF8String,
               title.UTF8String,
               [[bounds description] UTF8String]);
    }
}

static void command_window_space(uint32_t wid) {
    NSString *display_uuid = window_display_uuid(wid) ?: @"";
    NSArray<NSNumber *> *spaces = space_ids_for_window(wid);
    printf("window_id=%u display=%s spaces=", wid, display_uuid.UTF8String);
    for (NSUInteger i = 0; i < spaces.count; ++i) {
        printf("%s%llu", i == 0 ? "" : ",", spaces[i].unsignedLongLongValue);
    }
    printf("\n");
}

static uint64_t resolve_space_id_from_index(uint32_t wid, NSInteger requested_index, NSString *display_override) {
    NSString *display_uuid = display_override ?: window_display_uuid(wid);
    if (!display_uuid) {
        fail(@"unable to determine the window's display");
    }

    for (NSDictionary *record in space_records_for_display(display_uuid)) {
        NSNumber *user_index = record[@"user_index"];
        if (user_index != (id) [NSNull null] && user_index.integerValue == requested_index) {
            return [record[@"space_id"] unsignedLongLongValue];
        }
    }

    fail([NSString stringWithFormat:@"no user space %ld found on display %@", (long) requested_index, display_uuid]);
    return 0;
}

static int connect_payload_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == -1) return -1;

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socket_path().fileSystemRepresentation, sizeof(address.sun_path));

    if (connect(fd, (struct sockaddr *) &address, sizeof(address)) == -1) {
        close(fd);
        return -1;
    }

    return fd;
}

static NSString *send_payload_command(NSString *command) {
    int fd = connect_payload_socket();
    if (fd == -1) return nil;

    NSData *data = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (write(fd, data.bytes, data.length) != (ssize_t) data.length) {
        close(fd);
        return nil;
    }

    char buffer[256] = {0};
    ssize_t bytes = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (bytes <= 0) return nil;
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger) bytes encoding:NSUTF8StringEncoding];
}

static BOOL payload_is_alive(void) {
    NSString *reply = send_payload_command(@"ping");
    return reply && [reply hasPrefix:@"pong"];
}

static pid_t dock_pid(void) {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    for (NSRunningApplication *app in apps) {
        if (app.finishedLaunching) return app.processIdentifier;
    }
    return 0;
}

static uid_t dock_uid(void) {
    pid_t pid = dock_pid();
    if (!pid) return getuid();

    struct proc_bsdinfo info = {0};
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, PROC_PIDTBSDINFO_SIZE);
    if (bytes != PROC_PIDTBSDINFO_SIZE) return getuid();
    return info.pbi_uid;
}

static NSString *socket_path(void) {
    return [NSString stringWithFormat:@"/tmp/dockmove.%u.sock", dock_uid()];
}

static NSString *payload_path_for_executable(const char *argv0) {
    char resolved[PATH_MAX] = {0};
    if (!realpath(argv0, resolved)) return nil;

    char directory[PATH_MAX] = {0};
    strlcpy(directory, resolved, sizeof(directory));
    char *dir = dirname(directory);

    return [NSString stringWithFormat:@"%s/dockmove-payload.dylib", dir];
}

static int inject_payload(NSString *payload_path) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:payload_path]) {
        fprintf(stderr, "payload not found at %s\n", payload_path.UTF8String);
        return 1;
    }

    pid_t pid = dock_pid();
    if (!pid) {
        fprintf(stderr, "could not locate Dock.app\n");
        return 1;
    }

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t error = task_for_pid(mach_task_self(), pid, &task);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid(Dock) failed: %s\n", mach_error_string(error));
        fprintf(stderr, "This usually means SIP/debug restrictions or insufficient privileges.\n");
        return 1;
    }

    mach_vm_address_t stack = 0;
    mach_vm_address_t code = 0;
    const vm_size_t stack_size = 16 * 1024;
    uint64_t stack_marker = 0xCAFEBABE;

    if (mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "failed to allocate remote stack\n");
        return 1;
    }

    if (mach_vm_write(task, stack, (vm_offset_t) &stack_marker, (mach_msg_type_number_t) sizeof(stack_marker)) != KERN_SUCCESS) {
        fprintf(stderr, "failed to write remote stack\n");
        return 1;
    }

    if (vm_protect(task, stack, stack_size, true, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        fprintf(stderr, "failed to protect remote stack\n");
        return 1;
    }

    const size_t code_size = sizeof(kArm64ShellCodeTemplate) + 16 + PATH_MAX;
    uint8_t *shellcode = calloc(1, code_size);
    memcpy(shellcode, kArm64ShellCodeTemplate, sizeof(kArm64ShellCodeTemplate));

    uint64_t pthread_address =
        (uint64_t) ptrauth_strip(dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"), ptrauth_key_function_pointer);
    uint64_t dlopen_address =
        (uint64_t) ptrauth_strip(dlsym(RTLD_DEFAULT, "dlopen"), ptrauth_key_function_pointer);
    memcpy(shellcode + 88, &pthread_address, sizeof(uint64_t));
    memcpy(shellcode + 160, &dlopen_address, sizeof(uint64_t));
    strlcpy((char *) shellcode + 168, payload_path.fileSystemRepresentation, PATH_MAX);

    if (mach_vm_allocate(task, &code, code_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "failed to allocate remote code segment\n");
        free(shellcode);
        return 1;
    }

    if (mach_vm_write(task, code, (vm_offset_t) shellcode, (mach_msg_type_number_t) code_size) != KERN_SUCCESS) {
        fprintf(stderr, "failed to write remote code segment\n");
        free(shellcode);
        return 1;
    }
    free(shellcode);

    if (vm_protect(task, code, code_size, false, VM_PROT_EXECUTE | VM_PROT_READ) != KERN_SUCCESS) {
        fprintf(stderr, "failed to make remote code executable\n");
        return 1;
    }

    void *kernel = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (!kernel) {
        fprintf(stderr, "failed to open libsystem_kernel.dylib\n");
        return 1;
    }
    g_thread_convert_thread_state = dlsym(kernel, "thread_convert_thread_state");
    dlclose(kernel);
    if (!g_thread_convert_thread_state) {
        fprintf(stderr, "failed to resolve thread_convert_thread_state\n");
        return 1;
    }

    thread_act_t thread = MACH_PORT_NULL;
    error = thread_create(task, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "failed to create remote thread: %s\n", mach_error_string(error));
        return 1;
    }

    arm_thread_state64_t thread_state = {};
    arm_thread_state64_t machine_thread_state = {};
    mach_msg_type_number_t thread_count = ARM_THREAD_STATE64_COUNT;
    mach_msg_type_number_t machine_thread_count = ARM_THREAD_STATE64_COUNT;

    __darwin_arm_thread_state64_set_pc_fptr(thread_state, ptrauth_sign_unauthenticated((void *) code, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(thread_state, stack + (stack_size / 2));

    error = g_thread_convert_thread_state(thread, 2, ARM_THREAD_STATE64,
                                          (thread_state_t) &thread_state, thread_count,
                                          (thread_state_t) &machine_thread_state, &machine_thread_count);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "failed to convert thread state: %s\n", mach_error_string(error));
        return 1;
    }

    error = thread_terminate(thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "failed to terminate staging thread: %s\n", mach_error_string(error));
        return 1;
    }

    error = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t) &machine_thread_state, machine_thread_count, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "failed to start remote thread: %s\n", mach_error_string(error));
        return 1;
    }

    usleep(15000);

    for (int i = 0; i < 10; ++i) {
        mach_msg_type_number_t current_count = ARM_THREAD_STATE64_COUNT;
        error = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t) &thread_state, &current_count);
        if (error == KERN_SUCCESS && thread_state.__x[0] == kSuccessMarker) {
            thread_terminate(thread);
            return 0;
        }
        usleep(20000);
    }

    thread_terminate(thread);
    fprintf(stderr, "injection timed out before the loader thread reported success\n");
    return 1;
}

static void ensure_payload_loaded(NSString *payload_path) {
    if (payload_is_alive()) return;
    if (inject_payload(payload_path) != 0) exit(1);

    for (int i = 0; i < 20; ++i) {
        if (payload_is_alive()) return;
        usleep(50000);
    }

    fail(@"payload injection completed but the Dock payload socket never came up");
}

static uint32_t parse_u32(const char *value, const char *flag) {
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (!value[0] || (end && *end)) {
        fail([NSString stringWithFormat:@"invalid value for %s: %s", flag, value]);
    }
    return (uint32_t) parsed;
}

static uint64_t parse_u64(const char *value, const char *flag) {
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (!value[0] || (end && *end)) {
        fail([NSString stringWithFormat:@"invalid value for %s: %s", flag, value]);
    }
    return (uint64_t) parsed;
}

static void usage(void) {
    puts("dockmove commands:");
    puts("  list-spaces");
    puts("  list-windows");
    puts("  window-space --window-id <id>");
    puts("  inject");
    puts("  move-window --window-id <id> (--space-id <sid> | --space-index <n>) [--display-uuid <uuid>]");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            usage();
            return 1;
        }

        NSString *command = [NSString stringWithUTF8String:argv[1]];
        NSString *payload_path = payload_path_for_executable(argv[0]);

        if ([command isEqualToString:@"list-spaces"]) {
            command_list_spaces();
            return 0;
        }

        if ([command isEqualToString:@"list-windows"]) {
            command_list_windows();
            return 0;
        }

        if ([command isEqualToString:@"window-space"]) {
            uint32_t wid = 0;
            for (int i = 2; i < argc; i += 2) {
                if (i + 1 >= argc) fail(@"missing value for window-space flag");
                if (strcmp(argv[i], "--window-id") == 0) {
                    wid = parse_u32(argv[i + 1], "--window-id");
                } else {
                    fail([NSString stringWithFormat:@"unknown flag: %s", argv[i]]);
                }
            }
            if (!wid) fail(@"--window-id is required");
            command_window_space(wid);
            return 0;
        }

        if ([command isEqualToString:@"inject"]) {
            return inject_payload(payload_path);
        }

        if ([command isEqualToString:@"move-window"]) {
            uint32_t wid = 0;
            uint64_t sid = 0;
            NSInteger space_index = 0;
            NSString *display_uuid = nil;

            for (int i = 2; i < argc; i += 2) {
                if (i + 1 >= argc) fail(@"missing value for move-window flag");
                if (strcmp(argv[i], "--window-id") == 0) {
                    wid = parse_u32(argv[i + 1], "--window-id");
                } else if (strcmp(argv[i], "--space-id") == 0) {
                    sid = parse_u64(argv[i + 1], "--space-id");
                } else if (strcmp(argv[i], "--space-index") == 0) {
                    space_index = (NSInteger) parse_u64(argv[i + 1], "--space-index");
                } else if (strcmp(argv[i], "--display-uuid") == 0) {
                    display_uuid = [NSString stringWithUTF8String:argv[i + 1]];
                } else {
                    fail([NSString stringWithFormat:@"unknown flag: %s", argv[i]]);
                }
            }

            if (!wid) fail(@"--window-id is required");
            if ((sid == 0) == (space_index == 0)) {
                fail(@"specify exactly one of --space-id or --space-index");
            }
            if (space_index > 0) {
                sid = resolve_space_id_from_index(wid, space_index, display_uuid);
            }

            ensure_payload_loaded(payload_path);
            NSString *reply = send_payload_command([NSString stringWithFormat:@"move %u %llu", wid, sid]);
            if (!reply || ![reply hasPrefix:@"ok"]) {
                fail([NSString stringWithFormat:@"move failed, payload reply: %@", reply ?: @"<none>"]);
            }
            printf("moved window %u to space %llu\n", wid, sid);
            return 0;
        }

        usage();
        return 1;
    }
}
