// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.
#include "precomp.h"
#include "common.h"

// WSLGd for weaselway. The system distro is only there because WSL creates the
// "wslg" shared-memory share (virtiofs, DAX) only when one is configured; the
// user distro mounts that share itself and mutter hands its frames over on it.
// The compositor, the RDP client and audio all run elsewhere, and the user
// distro works out the vsock port, the VM ID and the share's NT path on its
// own. So all that is left here is the part of /mnt/wslg that WSL's init in the
// user distro expects any WSLg system distro to provide:
//
//  - .X11-unix, which it bind mounts over the user distro's /tmp/.X11-unix
//    (weaselway's prep takes that back again);
//  - runtime-dir, which WSL's generated wslg-session user unit symlinks
//    wayland-0 and wayland-0.lock into. mutter creates its wayland-0 lock
//    through that symlink, so the directory has to exist and be writable.

constexpr auto c_userName = "wslg";

constexpr auto c_versionFile = "/etc/versions.txt";
constexpr auto c_versionMount = SHARE_PATH "/versions.txt";
constexpr auto c_x11RuntimeDir = SHARE_PATH "/.X11-unix";
constexpr auto c_xdgRuntimeDir = SHARE_PATH "/runtime-dir";
constexpr auto c_stdErrLogFile = SHARE_PATH "/stderr.log";

void LogPrint(int level, const char *func, int line, const char *fmt, ...) noexcept
{
    std::array<char, 128> buffer;
    struct timeval tv;
    struct tm *time;
    va_list va_args;

    gettimeofday(&tv, NULL);
    time = localtime(&tv.tv_sec);
    strftime(buffer.data(), buffer.size(), "%H:%M:%S", time);
    fprintf(stderr, "[%s.%03ld] <%d>WSLGd: %s:%u: ",
        buffer.data(), (tv.tv_usec / 1000),
        level, func, line);

    va_start(va_args, fmt);
    vfprintf(stderr, fmt, va_args);
    va_end(va_args);
    fprintf(stderr, "\n");

    return;
}

void LogException(const char *message, const char *exceptionDescription) noexcept
{
    LogPrint(LOG_LEVEL_EXCEPTION, __FUNCTION__, __LINE__, "%s %s", message ? message : "Exception:", exceptionDescription);
    return;
}

int main(int Argc, char *Argv[])
try {
    wil::g_LogExceptionCallback = LogException;

    // Open a file for logging errors and set it to stderr.
    {
        const char *errLog = getenv("WSLG_ERR_LOG_PATH");
        if (!errLog) {
            errLog = c_stdErrLogFile;
        }
        wil::unique_fd stdErrLogFd(open(errLog, (O_RDWR | O_CREAT), (S_IRUSR | S_IRGRP | S_IROTH)));
        if (stdErrLogFd && (stdErrLogFd.get() != STDERR_FILENO)) {
            dup2(stdErrLogFd.get(), STDERR_FILENO);
        }
    }

    // Ensure the daemon is launched as root.
    if (geteuid() != 0) {
        LOG_ERROR("must be run as root.");
        return 1;
    }

    auto passwordEntry = getpwnam(c_userName);
    THROW_ERRNO_IF(ENOENT, !passwordEntry);

    // Bind mount the versions.txt file, which says which system distro this is.
    {
        wil::unique_fd fd(open(c_versionMount, (O_RDWR | O_CREAT), (S_IRUSR | S_IRGRP | S_IROTH)));
        THROW_LAST_ERROR_IF(!fd);
    }

    THROW_LAST_ERROR_IF(mount(c_versionFile, c_versionMount, NULL, MS_BIND | MS_RDONLY, NULL) < 0);

    std::filesystem::create_directories(c_x11RuntimeDir);
    THROW_LAST_ERROR_IF(chmod(c_x11RuntimeDir, 0777) < 0);

    std::filesystem::create_directories(c_xdgRuntimeDir);
    THROW_LAST_ERROR_IF(chown(c_xdgRuntimeDir, passwordEntry->pw_uid, passwordEntry->pw_gid) < 0);
    THROW_LAST_ERROR_IF(chmod(c_xdgRuntimeDir, 0777) < 0);

    LOG_INFO("ready; nothing else to do");

    // Stay up for the lifetime of the VM, as WSLGd always has: this is the
    // system distro's boot command, and what WSL makes of it exiting is not
    // something to find out the hard way.
    for (;;) {
        pause();
    }
}
CATCH_RETURN_ERRNO();
