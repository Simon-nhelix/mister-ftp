import Foundation

/// Runs FTP work one call at a time on a private serial queue and keeps one
/// logged-in connection alive between calls.
///
/// When the server drops an idle connection, the next call reconnects and,
/// if `retry` is true, runs the work again.
public final class FTPSession: @unchecked Sendable {
    public let credentials: FTPCredentials
    private let queue: DispatchQueue
    private var connection: FTPConnection?   // only touched on `queue`
    private let lock = NSLock()
    private var current: FTPConnection?       // for abort() from other threads

    public init(credentials: FTPCredentials, label: String) {
        self.credentials = credentials
        queue = DispatchQueue(label: "misterftp.session.\(label)", qos: .userInitiated)
    }

    public func perform<T>(retry: Bool = true, _ work: @escaping (FTPConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.performNow(retry: retry, work) })
            }
        }
    }

    /// Same as `perform`, for callers that already run on a background thread.
    public func performBlocking<T>(retry: Bool = true, _ work: (FTPConnection) throws -> T) throws -> T {
        try queue.sync { try performNow(retry: retry, work) }
    }

    private func performNow<T>(retry: Bool, _ work: (FTPConnection) throws -> T) throws -> T {
        let first = try liveConnection()
        do {
            return try work(first)
        } catch let error as FTPError where error.isConnectionLost && retry && !first.isAborted {
            drop(first)
            return try work(try liveConnection())
        } catch {
            if let active = connection, !active.isUsable { drop(active) }
            throw error
        }
    }

    private func liveConnection() throws -> FTPConnection {
        if let existing = connection, existing.isUsable { return existing }
        if let stale = connection { drop(stale) }
        let fresh = try FTPConnection(credentials: credentials)
        do {
            try fresh.login()
        } catch {
            fresh.close()
            throw error
        }
        connection = fresh
        lock.lock()
        current = fresh
        lock.unlock()
        return fresh
    }

    private func drop(_ old: FTPConnection) {
        old.close()
        if connection === old { connection = nil }
        lock.lock()
        if current === old { current = nil }
        lock.unlock()
    }

    /// Stops the call that is running now. Safe from any thread.
    public func abortCurrent() {
        lock.lock()
        let active = current
        lock.unlock()
        active?.abort()
    }

    /// Logs out and closes the connection after queued work finishes.
    public func close() {
        queue.async {
            self.connection?.quit()
            self.connection = nil
            self.lock.lock()
            self.current = nil
            self.lock.unlock()
        }
    }
}
