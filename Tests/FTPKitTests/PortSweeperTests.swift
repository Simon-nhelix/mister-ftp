import Darwin
import Foundation
import XCTest
@testable import FTPKit

final class PortSweeperTests: XCTestCase {
    private let loopback = IPv4("127.0.0.1")!

    func testListeningLoopbackPortIsOpen() throws {
        let endpoint = try makeLoopbackSocket(listening: true)
        defer { close(endpoint.fd) }

        var results: [PortSweeper.Result] = []
        PortSweeper.sweep([loopback], port: endpoint.port, timeout: 2,
                          isCancelled: { false }) { host, result in
            XCTAssertEqual(host, loopback)
            results.append(result)
        }

        XCTAssertEqual(results, [.open])
    }

    func testBoundButNotListeningLoopbackPortIsUnavailable() throws {
        // Keep the port reserved for the entire sweep, so another process cannot
        // claim the ephemeral port between choosing it and connecting to it.
        let endpoint = try makeLoopbackSocket(listening: false)
        defer { close(endpoint.fd) }

        var results: [PortSweeper.Result] = []
        PortSweeper.sweep([loopback], port: endpoint.port, timeout: 2,
                          isCancelled: { false }) { host, result in
            XCTAssertEqual(host, loopback)
            results.append(result)
        }

        // Darwin may refuse a bound non-listening port or silently drop the SYN.
        // Both mean the port is unavailable; it must not report an open port.
        XCTAssertTrue(results == [.refused] || results == [.noAnswer], "Unexpected result: \(results)")
    }

    func testCancellationStopsBeforeNextBatch() throws {
        let endpoint = try makeLoopbackSocket(listening: true)
        defer { close(endpoint.fd) }

        var cancelled = false
        var starts: [[IPv4]] = []
        var results: [PortSweeper.Result] = []
        PortSweeper.sweep([loopback, loopback], port: endpoint.port, timeout: 2,
                          batchSize: 1, isCancelled: { cancelled },
                          onStart: { starts.append($0) }) { host, result in
            XCTAssertEqual(host, loopback)
            results.append(result)
            cancelled = true
        }

        XCTAssertEqual(starts, [[loopback]])
        XCTAssertEqual(results, [.open])
    }

    /// An ephemeral TCP port bound exclusively to 127.0.0.1. The caller owns fd.
    private func makeLoopbackSocket(listening: Bool) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var keepOpen = false
        defer { if !keepOpen { close(fd) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: loopback.value.bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        if listening {
            guard listen(fd, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        keepOpen = true
        return (fd, UInt16(bigEndian: assigned.sin_port))
    }
}
