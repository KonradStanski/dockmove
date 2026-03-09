#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef windowList, uint64_t sid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int mask, CFArrayRef windowList);

static int g_listen_fd = -1;
static pthread_t g_server_thread;

static NSString *socket_path(void) {
    return [NSString stringWithFormat:@"/tmp/dockmove.%u.sock", getuid()];
}

static CFArrayRef array_from_window_id(uint32_t wid) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    const void *values[] = {number};
    CFArrayRef result = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return result;
}

static bool window_is_on_space(uint32_t wid, uint64_t sid) {
    CFArrayRef window_list = array_from_window_id(wid);
    CFArrayRef spaces = SLSCopySpacesForWindows(SLSMainConnectionID(), 0x7, window_list);
    CFRelease(window_list);
    if (!spaces) return false;

    bool found = false;
    CFIndex count = CFArrayGetCount(spaces);
    for (CFIndex index = 0; index < count; ++index) {
        CFNumberRef value = CFArrayGetValueAtIndex(spaces, index);
        uint64_t current = 0;
        CFNumberGetValue(value, kCFNumberSInt64Type, &current);
        if (current == sid) {
            found = true;
            break;
        }
    }

    CFRelease(spaces);
    return found;
}

static void write_response(int fd, const char *response) {
    (void) write(fd, response, strlen(response));
}

static void handle_client(int fd) {
    char buffer[512] = {0};
    ssize_t bytes = read(fd, buffer, sizeof(buffer) - 1);
    if (bytes <= 0) return;

    uint32_t wid = 0;
    unsigned long long sid = 0;
    if (strncmp(buffer, "ping", 4) == 0) {
        write_response(fd, "pong\n");
        return;
    }

    if (sscanf(buffer, "move %u %llu", &wid, &sid) == 2) {
        CFArrayRef window_list = array_from_window_id(wid);
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list, (uint64_t) sid);
        CFRelease(window_list);

        for (int attempt = 0; attempt < 20; ++attempt) {
            if (window_is_on_space(wid, (uint64_t) sid)) {
                write_response(fd, "ok\n");
                return;
            }
            usleep(10000);
        }

        write_response(fd, "error move-not-observed\n");
        return;
    }

    write_response(fd, "error unknown-command\n");
}

static void *server_main(__unused void *context) {
    for (;;) {
        int client = accept(g_listen_fd, NULL, 0);
        if (client == -1) continue;
        handle_client(client);
        close(client);
    }
    return NULL;
}

__attribute__((constructor)) static void boot_payload(void) {
    @autoreleasepool {
        NSString *path = socket_path();
        unlink(path.fileSystemRepresentation);

        g_listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (g_listen_fd == -1) return;

        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));

        if (bind(g_listen_fd, (struct sockaddr *) &address, sizeof(address)) == -1) {
            close(g_listen_fd);
            g_listen_fd = -1;
            return;
        }

        if (listen(g_listen_fd, 16) == -1) {
            close(g_listen_fd);
            g_listen_fd = -1;
            return;
        }

        pthread_create(&g_server_thread, NULL, server_main, NULL);
        pthread_detach(g_server_thread);
    }
}
