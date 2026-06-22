// Lock.swift

import Darwin
import Foundation

var lockFD: Int32 = -1

private func isRegularFile(_ mode: mode_t) -> Bool {
    return (mode & S_IFMT) == S_IFREG
}

private func isDirectory(_ mode: mode_t) -> Bool {
    return (mode & S_IFMT) == S_IFDIR
}

private func isSymlink(_ mode: mode_t) -> Bool {
    return (mode & S_IFMT) == S_IFLNK
}

private func ensureAppDirectory() -> Bool {
    do {
        try FileManager.default.createDirectory(
            atPath: APP_DIR,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        fputs("[ERROR] Could not create \(APP_DIR): \(error)\n", stderr)
        return false
    }

    var statInfo = stat()
    guard lstat(APP_DIR, &statInfo) == 0,
          isDirectory(statInfo.st_mode),
          statInfo.st_uid == getuid() else {
        fputs("[ERROR] Refusing insecure state directory: \(APP_DIR)\n", stderr)
        return false
    }

    if (statInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
        guard chmod(APP_DIR, 0o700) == 0 else {
            fputs("[ERROR] Could not secure state directory: \(APP_DIR)\n", stderr)
            return false
        }
    }

    return true
}

private func lockFileIsSafe(_ fd: Int32) -> Bool {
    var statInfo = stat()
    guard fstat(fd, &statInfo) == 0 else { return false }
    return isRegularFile(statInfo.st_mode)
        && statInfo.st_uid == getuid()
        && statInfo.st_nlink == 1
}

private func closeLock() {
    if lockFD >= 0 {
        close(lockFD)
        lockFD = -1
    }
}

private func writeAll(_ fd: Int32, _ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return false }

        var offset = 0
        while offset < buffer.count {
            let written = write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                return false
            }
        }

        return true
    }
}

func acquireLock() -> Bool {
    if let legacyPID = readLockPID(from: LEGACY_LOCKFILE),
       processIsRunning(legacyPID),
       isNoSleepProcess(legacyPID) {
        return false
    }

    guard ensureAppDirectory() else { return false }

    lockFD = open(LOCKFILE, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { return false }

    guard lockFileIsSafe(lockFD) else {
        fputs("[ERROR] Refusing insecure lock file: \(LOCKFILE)\n", stderr)
        closeLock()
        return false
    }

    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        closeLock()
        return false
    }

    let pidStr = "\(getpid())\n"
    guard ftruncate(lockFD, 0) == 0,
          writeAll(lockFD, pidStr),
          fsync(lockFD) == 0 else {
        unlink(LOCKFILE)
        flock(lockFD, LOCK_UN)
        closeLock()
        return false
    }

    return true
}

func readLockPID(from path: String = LOCKFILE) -> Int32? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    guard lockFileIsSafe(fd) else { return nil }

    var buffer = [UInt8](repeating: 0, count: 32)
    let count = read(fd, &buffer, buffer.count - 1)
    guard count > 0 else { return nil }

    let data = Data(buffer.prefix(Int(count)))
    guard let pidStr = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) else {
        return nil
    }

    return Int32(pidStr)
}

func removeLockFileIfSafe() {
    _ = removeOwnedFileIfPresent(LOCKFILE)
}

@discardableResult
func removeOwnedFileIfPresent(_ path: String) -> Bool {
    var statInfo = stat()
    guard lstat(path, &statInfo) == 0,
          statInfo.st_uid == getuid(),
          (isRegularFile(statInfo.st_mode) || isSymlink(statInfo.st_mode)) else {
        return false
    }

    return unlink(path) == 0
}

@discardableResult
func removeOwnedDirectoryIfPresent(_ path: String) -> Bool {
    var statInfo = stat()
    guard lstat(path, &statInfo) == 0,
          statInfo.st_uid == getuid(),
          isDirectory(statInfo.st_mode) else {
        return false
    }

    do {
        try FileManager.default.removeItem(atPath: path)
        return true
    } catch {
        return false
    }
}

func releaseLock() {
    if lockFD >= 0 {
        // unlink before releasing the lock so no other process can
        // acquire the lock on this inode and then have it deleted
        unlink(LOCKFILE)
        flock(lockFD, LOCK_UN)
        closeLock()
    }
}
