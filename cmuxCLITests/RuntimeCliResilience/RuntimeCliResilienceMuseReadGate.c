// SUPERMUX:begin runtime-cli-resilience-muse-read-gate
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_bool gated;

static int blocks_repeat_materialization(const char *path) {
    const char *enabled = getenv("CMUX_MUSE_REVIEW_BLOCK_REPEAT");
    if (!(enabled && strcmp(enabled, "1") == 0 && atomic_load(&gated) &&
          path && strstr(path, "/.cmux/hooks/muse/"))) { return 0; }
    const char *attempts = getenv("CMUX_MUSE_REVIEW_ATTEMPTS");
    if (attempts) {
        int fd = open(attempts, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd < 0 || write(fd, "r", 1) != 1) { _exit(125); }
        close(fd);
    }
    return 1;
}

// Test-only OS gate: pause the real settings read after script preflight, without replacing CLI logic.
static void gate_settings_read(const char *path, int flags) {
    const char *ready = getenv("CMUX_MUSE_REVIEW_READY");
    const char *release = getenv("CMUX_MUSE_REVIEW_RELEASE");
    const char *suffix = "/.config/muse/settings.json";
    size_t length = path ? strlen(path) : 0;
    if (!ready || !release || length < strlen(suffix) || (flags & O_ACCMODE) != O_RDONLY ||
        strcmp(path + length - strlen(suffix), suffix) != 0 || atomic_exchange(&gated, 1)) {
        return;
    }
    int fd = open(ready, O_WRONLY);
    if (fd < 0 || write(fd, "g", 1) != 1) { _exit(125); }
    close(fd);
    fd = open(release, O_RDONLY);
    char byte;
    if (fd < 0 || read(fd, &byte, 1) != 1) { _exit(125); }
    close(fd);
}

static int gated_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    gate_settings_read(path, flags);
    if (blocks_repeat_materialization(path)) { errno = EACCES; return -1; }
    return open(path, flags, mode);
}

extern int open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
static int gated_open_nocancel(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    gate_settings_read(path, flags);
    if (blocks_repeat_materialization(path)) { errno = EACCES; return -1; }
    return open_nocancel(path, flags, mode);
}

__attribute__((used)) static struct { const void *replacement; const void *original; }
interpositions[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)gated_open, (const void *)open },
    { (const void *)gated_open_nocancel, (const void *)open_nocancel }
};
// SUPERMUX:end runtime-cli-resilience-muse-read-gate
