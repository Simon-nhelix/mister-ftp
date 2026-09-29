import XCTest
@testable import FTPKit

/// Runs against a real MiSTer only when `MISTER_FTP_TEST_HOST` is set.
/// Writes go to a fresh folder under `/tmp` on the MiSTer (RAM, not the SD card)
/// and the folder is removed at the end.
final class LiveMiSTerTests: XCTestCase {
    private var host: String!

    override func setUpWithError() throws {
        guard let value = ProcessInfo.processInfo.environment["MISTER_FTP_TEST_HOST"], !value.isEmpty else {
            throw XCTSkip("Set MISTER_FTP_TEST_HOST to run live tests")
        }
        host = value
    }

    func testDiscoveryFindsMiSTer() async throws {
        let started = Date()
        let finder = MiSTerFinder(credentials: FTPCredentials(host: ""), preferredHosts: [])
        var found: DiscoveredDevice?
        var cells = 0
        var summary: DiscoverySummary?
        for await event in finder.events() {
            switch event {
            case .found(let device): if found == nil { found = device; print("found \(device) after \(Date().timeIntervalSince(started))s") }
            case .cell: cells += 1
            case .finished(let result): summary = result
            default: break
            }
        }
        print("discovery finished after \(Date().timeIntervalSince(started))s, cell events: \(cells), summary: \(String(describing: summary))")
        XCTAssertEqual(found?.address, host)
        XCTAssertFalse(summary?.localNetworkBlocked ?? true)
    }

    func testBrowseAndRoundTripInTmp() async throws {
        let session = FTPSession(credentials: FTPCredentials(host: host), label: "test")
        defer { session.close() }

        let root = try await session.perform { try $0.list("/media/fat") }
        XCTAssertTrue(root.contains { $0.name == "games" && $0.isDirectory })

        let base = "/tmp/misterftp-test-\(UUID().uuidString.prefix(8))"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var big = Data(count: 3 * 1024 * 1024 + 123)
        big.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        }
        let bigURL = work.appendingPathComponent("big.bin")
        try big.write(to: bigURL)
        let koreanURL = work.appendingPathComponent("한글 이름 (1).txt")
        try Data("안녕 MiSTer".utf8).write(to: koreanURL)

        try await session.perform { connection in
            try connection.ensureDirectory(base)
            try connection.ensureDirectory(base) // second call must not fail
            try connection.ensureDirectory(base + "/sub dir")
            var last: Int64 = 0
            try connection.upload(bigURL, to: base + "/big.bin") { last = $0 }
            XCTAssertEqual(last, Int64(big.count))
            try connection.upload(koreanURL, to: base + "/sub dir/한글 이름 (1).txt") { _ in }
        }

        let listing = try await session.perform { try $0.list(base) }
        XCTAssertEqual(Set(listing.map(\.name)), ["big.bin", "sub dir"])
        XCTAssertEqual(listing.first { $0.name == "big.bin" }?.size, Int64(big.count))
        let nested = try await session.perform { try $0.list(base + "/sub dir") }
        XCTAssertEqual(nested.map(\.name), ["한글 이름 (1).txt"])

        let back = work.appendingPathComponent("back.bin")
        try await session.perform { try $0.download(base + "/big.bin", to: back) { _ in } }
        XCTAssertEqual(try Data(contentsOf: back), big)

        try await session.perform { try $0.rename(base + "/big.bin", to: base + "/renamed.bin") }
        let renamed = try await session.perform { try $0.stat(base + "/renamed.bin") }
        XCTAssertEqual(renamed?.size, Int64(big.count))
        let missing = try await session.perform { try $0.stat(base + "/big.bin") }
        XCTAssertNil(missing)

        let folder = FTPItem(name: RemotePath.lastComponent(base), path: base, kind: .directory, size: nil, modified: nil)
        try await session.perform { try $0.deleteRecursively(folder) }
        let gone = try await session.perform { try $0.stat(base) }
        XCTAssertNil(gone)
    }

    func testAbortStopsUploadAndSessionRecovers() async throws {
        let session = FTPSession(credentials: FTPCredentials(host: host), label: "abort")
        defer { session.close() }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("abort.bin")
        try Data(count: 40 * 1024 * 1024).write(to: url)
        let remote = "/tmp/misterftp-abort-\(UUID().uuidString.prefix(8)).bin"

        let aborter = Task.detached {
            try await Task.sleep(nanoseconds: 150_000_000)
            session.abortCurrent()
        }
        do {
            try await session.perform(retry: false) { try $0.upload(url, to: remote) { _ in } }
            XCTFail("upload should have been cancelled")
        } catch let error as FTPError {
            XCTAssertEqual(error, .cancelled)
        }
        _ = try await aborter.value

        // The session must reconnect on its own and keep working.
        let listing = try await session.perform { try $0.list("/media/fat") }
        XCTAssertFalse(listing.isEmpty)
        try? await session.perform { try $0.deleteFile(remote) }
        let gone = try await session.perform { try $0.stat(remote) }
        XCTAssertNil(gone)
    }
}
