import Darwin
import Foundation

public enum SingleInstanceGuardError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another ntfsmac instance is already running."
        case .unavailable(let reason):
            return "The ntfsmac instance lock is unavailable: \(reason)"
        }
    }
}

/// Holds an atomic, per-user file lock for the lifetime of the GUI process.
///
/// Open-file-description locks conflict across independently opened descriptors, including two
/// app launches racing at the same time. Closing the descriptor releases the lock automatically;
/// the harmless lock file remains so no cleanup race can let a second process through.
public final class SingleInstanceGuard {
    public let lockFileURL: URL

    private var fileDescriptor: Int32?

    public convenience init(fileManager: FileManager = .default) throws {
        try self.init(
            lockFileURL: Self.defaultLockFileURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public init(lockFileURL: URL, fileManager: FileManager = .default) throws {
        self.lockFileURL = lockFileURL

        do {
            try fileManager.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SingleInstanceGuardError.unavailable(error.localizedDescription)
        }

        let descriptor = lockFileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw SingleInstanceGuardError.unavailable(Self.posixErrorDescription())
        }

        guard Self.setLock(on: descriptor, type: Int16(F_WRLCK)) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EAGAIN || lockError == EACCES {
                throw SingleInstanceGuardError.alreadyRunning
            }
            throw SingleInstanceGuardError.unavailable(String(cString: strerror(lockError)))
        }

        fileDescriptor = descriptor
    }

    deinit {
        release()
    }

    /// Releases the lock deterministically. Repeated calls are safe.
    public func release() {
        guard let descriptor = fileDescriptor else { return }
        fileDescriptor = nil
        _ = Self.setLock(on: descriptor, type: Int16(F_UNLCK))
        Darwin.close(descriptor)
    }

    public static func defaultLockFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ntfsmac", isDirectory: true)
            .appendingPathComponent("gui-instance.lock", isDirectory: false)
    }

    private static func setLock(on descriptor: Int32, type: Int16) -> Int32 {
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: type,
            l_whence: Int16(SEEK_SET)
        )
        return Darwin.fcntl(descriptor, F_OFD_SETLK, &lock)
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
