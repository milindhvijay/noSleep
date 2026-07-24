// noSleepDaemon.c

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *legacyLockPath = "/tmp/noSleep.lock";
static const char *rootDomainName = "IOPMrootDomain";
static const char *osascriptPath = "/usr/bin/osascript";
static const char *afplayPath = "/usr/bin/afplay";
static const char *devNullPath = "/dev/null";
static const char *glassSoundPath = "/System/Library/Sounds/Glass.aiff";
static char *const childEnvironment[] = {
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    NULL
};

static char appDir[PATH_MAX];
static char lockPath[PATH_MAX];
static int lockFD = -1;
static int signalQueueFD = -1;

static io_service_t rootDomainService = 0;
static IONotificationPortRef notifyPort = NULL;
static io_object_t notifierObject = 0;
static CFRunLoopSourceRef powerSource = NULL;
static CFFileDescriptorRef signalFileDescriptor = NULL;
static CFRunLoopSourceRef signalSource = NULL;
static IOPMAssertionID assertionID = 0;
static bool assertionActive = false;
static bool signalHandlersInstalled = false;
static struct sigaction previousSIGTERMAction;
static struct sigaction previousSIGINTAction;

static bool is_regular_file(mode_t mode) {
    return (mode & S_IFMT) == S_IFREG;
}

static bool is_directory(mode_t mode) {
    return (mode & S_IFMT) == S_IFDIR;
}

static bool write_all(int fd, const char *buffer, size_t length) {
    size_t offset = 0;

    while (offset < length) {
        ssize_t written = write(fd, buffer + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
        } else if (written == -1 && errno == EINTR) {
            continue;
        } else {
            return false;
        }
    }

    return true;
}

static ssize_t read_retry(int fd, void *buffer, size_t length) {
    ssize_t count;

    do {
        count = read(fd, buffer, length);
    } while (count < 0 && errno == EINTR);

    return count;
}

static bool build_paths(void) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        fputs("[ERROR] HOME is not set\n", stderr);
        return false;
    }

    int appWritten = snprintf(appDir, sizeof(appDir), "%s/Library/Application Support/noSleep", home);
    int lockWritten = snprintf(lockPath, sizeof(lockPath), "%s/noSleep.lock", appDir);

    if (appWritten <= 0 || lockWritten <= 0 ||
        (size_t)appWritten >= sizeof(appDir) || (size_t)lockWritten >= sizeof(lockPath)) {
        fputs("[ERROR] noSleep paths are too long\n", stderr);
        return false;
    }

    return true;
}

static bool ensure_app_directory(void) {
    if (mkdir(appDir, 0700) != 0 && errno != EEXIST) {
        perror("[ERROR] mkdir");
        return false;
    }

    struct stat info;
    if (lstat(appDir, &info) != 0 ||
        !is_directory(info.st_mode) ||
        info.st_uid != getuid()) {
        fputs("[ERROR] Refusing insecure state directory\n", stderr);
        return false;
    }

    if ((info.st_mode & (S_IWGRP | S_IWOTH)) != 0 && chmod(appDir, 0700) != 0) {
        perror("[ERROR] chmod");
        return false;
    }

    return true;
}

static bool lock_file_is_safe(int fd) {
    struct stat info;
    if (fstat(fd, &info) != 0) {
        return false;
    }

    return is_regular_file(info.st_mode) &&
           info.st_uid == getuid() &&
           info.st_nlink == 1;
}

static bool process_is_running(pid_t pid) {
    if (pid <= 1) {
        return false;
    }

    if (kill(pid, 0) == 0) {
        return true;
    }

    return errno == EPERM;
}

static bool process_is_noSleep(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_pidpath((int)pid, path, sizeof(path));
    if (length <= 0) {
        return false;
    }
    path[sizeof(path) - 1] = '\0';

    const char *name = strrchr(path, '/');
    name = name == NULL ? path : name + 1;
    return strcmp(name, "noSleep") == 0 || strcmp(name, "noSleepDaemon") == 0;
}

static pid_t read_lock_pid(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }

    if (!lock_file_is_safe(fd)) {
        close(fd);
        return -1;
    }

    char buffer[32];
    ssize_t count = read_retry(fd, buffer, sizeof(buffer) - 1);
    close(fd);

    if (count <= 0) {
        return -1;
    }

    buffer[count] = '\0';
    char *end = NULL;
    errno = 0;
    long pid = strtol(buffer, &end, 10);
    if (errno != 0 || pid <= 1 || pid > INT_MAX || end == buffer) {
        return -1;
    }
    while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r') {
        end++;
    }
    if (*end != '\0') {
        return -1;
    }

    return (pid_t)pid;
}

static void close_lock(void) {
    if (lockFD >= 0) {
        close(lockFD);
        lockFD = -1;
    }
}

static void close_signal_queue(void) {
    if (signalQueueFD >= 0) {
        close(signalQueueFD);
        signalQueueFD = -1;
    }
}

static bool set_close_on_exec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        return false;
    }

    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static bool ignore_signal(int signalNumber, struct sigaction *previousAction) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);

    return sigaction(signalNumber, &action, previousAction) == 0;
}

static void restore_signal_handlers(void) {
    if (signalHandlersInstalled) {
        sigaction(SIGTERM, &previousSIGTERMAction, NULL);
        sigaction(SIGINT, &previousSIGINTAction, NULL);
        signalHandlersInstalled = false;
    }
}

static bool add_signal_to_queue(int signalNumber) {
    struct kevent event;
    EV_SET(&event, (uintptr_t)signalNumber, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, NULL);

    return kevent(signalQueueFD, &event, 1, NULL, 0, NULL) == 0;
}

static void shutdown_signal_received(CFFileDescriptorRef descriptor, CFOptionFlags callBackTypes, void *context) {
    (void)descriptor;
    (void)callBackTypes;
    (void)context;

    struct kevent events[4];
    struct timespec timeout = {0, 0};

    for (;;) {
        int count = kevent(signalQueueFD, NULL, 0, events, 4, &timeout);
        if (count > 0) {
            CFRunLoopStop(CFRunLoopGetCurrent());
            return;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }

    CFFileDescriptorEnableCallBacks(signalFileDescriptor, kCFFileDescriptorReadCallBack);
}

static void cleanup_signal_handling(void) {
    if (signalSource != NULL) {
        CFRunLoopSourceInvalidate(signalSource);
        CFRelease(signalSource);
        signalSource = NULL;
    }

    if (signalFileDescriptor != NULL) {
        CFFileDescriptorInvalidate(signalFileDescriptor);
        CFRelease(signalFileDescriptor);
        signalFileDescriptor = NULL;
        signalQueueFD = -1;
    } else {
        close_signal_queue();
    }

    restore_signal_handlers();
}

static bool setup_signal_handling(void) {
    bool sigtermIgnored = false;
    bool sigintIgnored = false;

    signalQueueFD = kqueue();
    if (signalQueueFD < 0 || !set_close_on_exec(signalQueueFD)) {
        close_signal_queue();
        return false;
    }

    if (!ignore_signal(SIGTERM, &previousSIGTERMAction)) {
        close_signal_queue();
        return false;
    }
    sigtermIgnored = true;

    if (!ignore_signal(SIGINT, &previousSIGINTAction)) {
        sigaction(SIGTERM, &previousSIGTERMAction, NULL);
        close_signal_queue();
        return false;
    }
    sigintIgnored = true;
    signalHandlersInstalled = true;

    if (!add_signal_to_queue(SIGTERM) || !add_signal_to_queue(SIGINT)) {
        if (sigintIgnored) {
            sigaction(SIGINT, &previousSIGINTAction, NULL);
        }
        if (sigtermIgnored) {
            sigaction(SIGTERM, &previousSIGTERMAction, NULL);
        }
        signalHandlersInstalled = false;
        close_signal_queue();
        return false;
    }

    CFFileDescriptorContext context = {0, NULL, NULL, NULL, NULL};
    signalFileDescriptor = CFFileDescriptorCreate(
        kCFAllocatorDefault,
        signalQueueFD,
        true,
        shutdown_signal_received,
        &context
    );
    if (signalFileDescriptor == NULL) {
        cleanup_signal_handling();
        return false;
    }

    signalSource = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, signalFileDescriptor, 0);
    if (signalSource == NULL) {
        cleanup_signal_handling();
        return false;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), signalSource, kCFRunLoopDefaultMode);
    CFFileDescriptorEnableCallBacks(signalFileDescriptor, kCFFileDescriptorReadCallBack);
    return true;
}

static bool acquire_lock(void) {
    pid_t legacyPID = read_lock_pid(legacyLockPath);
    if (legacyPID > 1 && process_is_running(legacyPID) && process_is_noSleep(legacyPID)) {
        return false;
    }

    if (!ensure_app_directory()) {
        return false;
    }

    int fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        return false;
    }

    if (!lock_file_is_safe(fd)) {
        fputs("[ERROR] Refusing insecure lock file\n", stderr);
        close(fd);
        return false;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return false;
    }

    char pidText[32];
    int length = snprintf(pidText, sizeof(pidText), "%d\n", getpid());
    if (length <= 0 || (size_t)length >= sizeof(pidText) ||
        ftruncate(fd, 0) != 0 ||
        !write_all(fd, pidText, (size_t)length) ||
        fsync(fd) != 0) {
        unlink(lockPath);
        flock(fd, LOCK_UN);
        close(fd);
        return false;
    }

    lockFD = fd;
    return true;
}

static void release_lock(void) {
    if (lockFD >= 0) {
        unlink(lockPath);
        flock(lockFD, LOCK_UN);
        close_lock();
    }
}

static io_service_t get_root_domain_service(void) {
    if (rootDomainService == 0) {
        CFMutableDictionaryRef matching = IOServiceMatching(rootDomainName);
        if (matching == NULL) {
            return 0;
        }
        rootDomainService = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    }

    return rootDomainService;
}

static bool current_lid_closed(void) {
    io_service_t service = get_root_domain_service();
    if (service == 0) {
        return false;
    }

    CFTypeRef property = IORegistryEntryCreateCFProperty(
        service,
        CFSTR("AppleClamshellState"),
        kCFAllocatorDefault,
        0
    );
    if (property == NULL) {
        return false;
    }

    bool closed = false;
    if (CFGetTypeID(property) == CFBooleanGetTypeID()) {
        closed = CFBooleanGetValue((CFBooleanRef)property);
    }

    CFRelease(property);
    return closed;
}

static bool current_on_ac_power(void) {
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (snapshot == NULL) {
        return false;
    }

    CFStringRef type = IOPSGetProvidingPowerSourceType(snapshot);
    bool onAC = type != NULL && CFEqual(type, CFSTR(kIOPSACPowerValue));

    CFRelease(snapshot);
    return onAC;
}

static void spawn_and_wait(const char *path, char *const argv[], int timeoutTenths) {
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        return;
    }

    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return;
    }

    sigset_t defaultSignals;
    sigemptyset(&defaultSignals);
    sigaddset(&defaultSignals, SIGTERM);
    sigaddset(&defaultSignals, SIGINT);

    bool actionsOK =
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, devNullPath, O_RDONLY, 0) == 0 &&
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, devNullPath, O_WRONLY, 0) == 0 &&
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, devNullPath, O_WRONLY, 0) == 0;
    bool attributesOK =
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 &&
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF) == 0;
    if (!actionsOK || !attributesOK) {
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        return;
    }

    pid_t pid = 0;
    int result = posix_spawn(&pid, path, &actions, &attributes, argv, childEnvironment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (result != 0) {
        return;
    }

    for (int attempt = 0; attempt < timeoutTenths; attempt++) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid || (waited < 0 && errno == ECHILD)) {
            return;
        }
        if (waited < 0) {
            break;
        }
        usleep(100000);
    }

    kill(pid, SIGTERM);
    for (int attempt = 0; attempt < 10; attempt++) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid || (waited < 0 && errno == ECHILD)) {
            return;
        }
        if (waited < 0) {
            break;
        }
        usleep(100000);
    }

    kill(pid, SIGKILL);
    (void)waitpid(pid, NULL, 0);
}

static void spawn_notification(const char *script) {
    char *const argv[] = {
        (char *)osascriptPath,
        (char *)"-e",
        (char *)script,
        NULL
    };

    spawn_and_wait(osascriptPath, argv, 30);
}

static void play_sound(const char *soundPath) {
    char *const argv[] = {
        (char *)afplayPath,
        (char *)soundPath,
        NULL
    };

    spawn_and_wait(afplayPath, argv, 30);
}

static void notify_preventing(void) {
    spawn_notification(
        "display notification \"Sleep prevention active\" "
        "with title \"noSleep\" "
        "subtitle \"AC Power + Lid Closed\""
    );
}

static void notify_restored(const char *reason) {
    const char *script = NULL;

    if (strcmp(reason, "battery") == 0) {
        script =
            "display notification \"Normal behaviour restored\" "
            "with title \"noSleep\" "
            "subtitle \"Switched to battery\"";
    } else if (strcmp(reason, "lid") == 0) {
        script =
            "display notification \"Normal behaviour restored\" "
            "with title \"noSleep\" "
            "subtitle \"Lid opened\"";
    } else {
        script =
            "display notification \"Normal behaviour restored\" "
            "with title \"noSleep\" "
            "subtitle \"Ready to sleep\"";
    }

    spawn_notification(script);
    play_sound(glassSoundPath);
}

static bool prevent_sleep(void) {
    if (assertionActive) {
        return false;
    }

    IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventSystemSleep,
        kIOPMAssertionLevelOn,
        CFSTR("noSleep - lid closed on AC power"),
        &assertionID
    );

    if (result == kIOReturnSuccess) {
        assertionActive = true;
        return true;
    }

    return false;
}

static bool allow_sleep(void) {
    if (!assertionActive) {
        return false;
    }

    IOPMAssertionRelease(assertionID);
    assertionID = 0;
    assertionActive = false;
    return true;
}

static void apply_state_change(void) {
    bool onAC = current_on_ac_power();
    bool lidClosed = current_lid_closed();

    if (onAC && lidClosed) {
        if (prevent_sleep()) {
            notify_preventing();
        }
    } else {
        if (allow_sleep()) {
            if (!onAC) {
                notify_restored("battery");
            } else if (!lidClosed) {
                notify_restored("lid");
            } else {
                notify_restored("ready");
            }
        }
    }
}

static void state_changed(void *context) {
    (void)context;
    apply_state_change();
}

static void clamshell_changed(void *refCon, io_service_t service, natural_t messageType, void *messageArgument) {
    (void)refCon;
    (void)service;
    (void)messageType;
    (void)messageArgument;
    apply_state_change();
}

static bool setup_clamshell_notification(void) {
    io_service_t service = get_root_domain_service();
    if (service == 0) {
        return false;
    }

    notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    if (notifyPort == NULL) {
        return false;
    }

    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(notifyPort);
    if (source == NULL) {
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);

    kern_return_t result = IOServiceAddInterestNotification(
        notifyPort,
        service,
        kIOGeneralInterest,
        clamshell_changed,
        NULL,
        &notifierObject
    );

    return result == KERN_SUCCESS;
}

static bool setup_power_source_notification(void) {
    powerSource = IOPSNotificationCreateRunLoopSource(state_changed, NULL);
    if (powerSource == NULL) {
        return false;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, kCFRunLoopDefaultMode);
    return true;
}

static void close_standard_descriptors(void) {
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
}

static void cleanup(void) {
    allow_sleep();

    if (powerSource != NULL) {
        CFRunLoopSourceInvalidate(powerSource);
        CFRelease(powerSource);
        powerSource = NULL;
    }

    if (notifierObject != 0) {
        IOObjectRelease(notifierObject);
        notifierObject = 0;
    }

    if (notifyPort != NULL) {
        IONotificationPortDestroy(notifyPort);
        notifyPort = NULL;
    }

    if (rootDomainService != 0) {
        IOObjectRelease(rootDomainService);
        rootDomainService = 0;
    }

    release_lock();
    cleanup_signal_handling();
}

int main(void) {
    if (!build_paths()) {
        return 1;
    }

    if (!setup_signal_handling()) {
        fputs("[ERROR] Failed to initialize daemon signal handling\n", stderr);
        return 1;
    }

    if (!acquire_lock()) {
        fputs("[ERROR] Another instance is already running\n", stderr);
        cleanup();
        return 1;
    }

    if (!setup_clamshell_notification() ||
        !setup_power_source_notification()) {
        fputs("[ERROR] Failed to initialize daemon notifications\n", stderr);
        cleanup();
        return 1;
    }

    apply_state_change();
    close_standard_descriptors();
    CFRunLoopRun();
    cleanup();
    return 0;
}
