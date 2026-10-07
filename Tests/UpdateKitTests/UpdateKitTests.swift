import CryptoKit
import XCTest
@testable import UpdateKit

final class UpdateKitTests: XCTestCase {
    // MARK: Versions

    func testVersionParsingAndOrder() throws {
        XCTAssertEqual(AppVersion("v1.0.1")?.description, "1.0.1")
        XCTAssertEqual(AppVersion("1.2.0-beta.1")?.description, "1.2.0")
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.0.0")), try XCTUnwrap(AppVersion("1.0.1")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.9")), try XCTUnwrap(AppVersion("1.10")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9")), try XCTUnwrap(AppVersion("1")))
        XCTAssertFalse(try XCTUnwrap(AppVersion("2.0")) < XCTUnwrap(AppVersion("2.0.0")))
        for bad in ["", "v", "1..0", "1.a", "-1.0", "1.2.3.4.5", "１.0"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    // MARK: Release feed

    private let releaseJSON = """
    {
      "tag_name": "v1.0.1",
      "name": "MiSTer FTP 1.0.1",
      "body": "- Fix Delete doing nothing.\\n- In-app updates.",
      "html_url": "https://github.com/Simon-nhelix/mister-ftp/releases/tag/v1.0.1",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"name": "MiSTer-FTP-1.0.1.zip", "size": 2187894,
         "browser_download_url": "https://github.com/Simon-nhelix/mister-ftp/releases/download/v1.0.1/MiSTer-FTP-1.0.1.zip"},
        {"name": "MiSTer-FTP-1.0.1.zip.sig", "size": 89,
         "browser_download_url": "https://github.com/Simon-nhelix/mister-ftp/releases/download/v1.0.1/MiSTer-FTP-1.0.1.zip.sig"}
      ]
    }
    """

    func testReleaseDecodingAndOffer() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(releaseJSON.utf8))
        let offer = try XCTUnwrap(ReleaseFeed.offer(from: release))
        XCTAssertEqual(offer.version, AppVersion("1.0.1"))
        XCTAssertEqual(offer.title, "MiSTer FTP 1.0.1")
        XCTAssertEqual(offer.archiveSize, 2_187_894)
        XCTAssertEqual(offer.archiveURL.lastPathComponent, "MiSTer-FTP-1.0.1.zip")
        XCTAssertEqual(offer.signatureURL?.lastPathComponent, "MiSTer-FTP-1.0.1.zip.sig")
        XCTAssertTrue(offer.notes.hasPrefix("- Fix Delete"))
        XCTAssertEqual(ReleaseFeed.latestReleaseURL(repository: "Simon-nhelix/mister-ftp")?.absoluteString,
                       "https://api.github.com/repos/Simon-nhelix/mister-ftp/releases/latest")
    }

    func testOfferRules() throws {
        func release(_ edit: (inout [String: Any]) -> Void) throws -> GitHubRelease {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(releaseJSON.utf8)) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["draft"] = true }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["prerelease"] = true }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["tag_name"] = "latest" }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["assets"] = [] }))
        // A release without the signature file can still be offered, but only as a link.
        let unsigned = try release { object in
            object["assets"] = (object["assets"] as! [[String: Any]]).filter { !($0["name"] as! String).hasSuffix(".sig") }
        }
        XCTAssertNil(try XCTUnwrap(ReleaseFeed.offer(from: unsigned)).signatureURL)

        // Title fallbacks
        let noName = try release { $0["name"] = NSNull() }
        XCTAssertEqual(ReleaseFeed.offer(from: noName)?.title, "v1.0.1")

        let emptyName = try release { $0["name"] = "   \n" }
        XCTAssertEqual(ReleaseFeed.offer(from: emptyName)?.title, "v1.0.1")

        // Notes fallbacks
        let noBody = try release { $0["body"] = NSNull() }
        XCTAssertEqual(ReleaseFeed.offer(from: noBody)?.notes, "")

        let emptyBody = try release { $0["body"] = "   \n" }
        XCTAssertEqual(ReleaseFeed.offer(from: emptyBody)?.notes, "")

        // Archive fallback: pick any valid zip if the exact match isn't present
        let otherArchive = try release { object in
            object["assets"] = [
                ["name": "MiSTer-FTP-1.0.1-macOS.zip", "size": 100, "browser_download_url": "https://example.com/other.zip"]
            ]
        }
        XCTAssertEqual(ReleaseFeed.offer(from: otherArchive)?.archiveURL.lastPathComponent, "other.zip")

        // Wrong prefix in asset -> ignored
        let wrongPrefix = try release { object in
            object["assets"] = [
                ["name": "Other-FTP-1.0.1.zip", "size": 100, "browser_download_url": "https://example.com/other.zip"]
            ]
        }
        XCTAssertNil(ReleaseFeed.offer(from: wrongPrefix))
    }

    func testOnlySafeDownloadAddresses() {
        XCTAssertTrue(ReleaseFeed.isAllowed(URL(string: "https://github.com/a.zip")!))
        XCTAssertTrue(ReleaseFeed.isAllowed(URL(string: "http://127.0.0.1:8765/a.zip")!))
        XCTAssertTrue(ReleaseFeed.isAllowed(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(string: "http://github.com/a.zip")!))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(string: "ftp://example.com/a.zip")!))
    }

    // MARK: Signatures

    func testSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let privateKey = key.rawRepresentation.base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("MiSTer-FTP-1.0.1.zip".utf8)
        let signature = try UpdateSignature.sign(data, privateKey: privateKey)

        XCTAssertTrue(UpdateSignature.isValid(signature: signature, for: data, publicKey: publicKey))
        XCTAssertTrue(UpdateSignature.isValid(signature: signature + "\n", for: data, publicKey: publicKey + "\n"))
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data + Data([0]), publicKey: publicKey))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data, publicKey: otherKey))
        XCTAssertFalse(UpdateSignature.isValid(signature: "not base64", for: data, publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data, publicKey: ""))
    }

    // MARK: Download, check, swap

    private var root: URL!
    private let signingKey = Curve25519.Signing.PrivateKey()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A tiny signed app bundle whose executable is a copy of /usr/bin/true.
    private func makeApp(in folder: URL, identifier: String = "com.example.misterftp-test", version: String) throws -> URL {
        let app = folder.appendingPathComponent("Test App.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Test App").path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Test App",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        return app
    }

    /// Zips `app` like the release script does and signs the zip. Returns an offer with file URLs.
    private func makeOffer(for app: URL, version: String, signWith key: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateOffer {
        let release = root.appendingPathComponent("release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let zip = release.appendingPathComponent("MiSTer-FTP-\(version).zip")
        try shell("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let signature = try UpdateSignature.sign(Data(contentsOf: zip), privateKey: (key ?? signingKey).rawRepresentation.base64EncodedString())
        let sig = release.appendingPathComponent(zip.lastPathComponent + ".sig")
        try Data(signature.utf8).write(to: sig)
        return UpdateOffer(version: AppVersion(version)!, title: "Test \(version)", notes: "", pageURL: URL(string: "https://example.com")!,
                           archiveURL: zip, archiveSize: 0, signatureURL: sig)
    }

    private func preparer(current: String, identifier: String = "com.example.misterftp-test") -> UpdatePreparer {
        UpdatePreparer(publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(), bundleIdentifier: identifier,
                       currentVersion: AppVersion(current)!, workFolder: root.appendingPathComponent("work-\(UUID().uuidString)"))
    }

    func testPrepareSwapAndCleanUp() async throws {
        let installedFolder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        let installed = try makeApp(in: installedFolder, version: "1.0.0")
        let newBuild = try makeApp(in: root.appendingPathComponent("build"), version: "1.0.1")
        let offer = try makeOffer(for: newBuild, version: "1.0.1")

        try UpdateInstaller.checkReplaceable(installed)
        let progress = ProgressLog()
        let unpacked = try await preparer(current: "1.0.0").prepare(offer) { done, total in progress.add(done, total) }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: unpacked).version, AppVersion("1.0.1"))
        XCTAssertGreaterThan(progress.last, 0)

        let oldCopyFolder = try UpdateInstaller.swap(installedApp: installed, with: unpacked)
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.1"))
        let oldCopy = oldCopyFolder.appendingPathComponent(installed.lastPathComponent)
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: oldCopy).version, AppVersion("1.0.0"))
        XCTAssertNoThrow(try UpdateInstaller.verifyCodeSignature(of: installed))
        XCTAssertTrue(UpdateInstaller.isTemporaryFolder(oldCopyFolder))

        // The helper waits for a process that already ended, then deletes the old copy.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        setenv("MISTERFTP_UPDATE_NO_RELAUNCH", "1", 1)
        defer { unsetenv("MISTERFTP_UPDATE_NO_RELAUNCH") }
        try UpdateInstaller.relaunchAfterExit(app: installed, cleanup: oldCopyFolder, processID: finished.processIdentifier)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: oldCopyFolder.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCopyFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    func testRelaunchOpensTheAppAfterTheProcessEnds() async throws {
        // A bundle whose executable is a shell script that leaves a marker file.
        let marker = root.appendingPathComponent("launched")
        let app = root.appendingPathComponent("Launch Probe.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("probe")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.misterftp-launch-probe",
            "CFBundleExecutable": "probe",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        unsetenv("MISTERFTP_UPDATE_NO_RELAUNCH")
        try UpdateInstaller.relaunchAfterExit(app: app, cleanup: nil, processID: finished.processIdentifier)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the helper did not open the app")
    }

    func testPrepareRefusesBadUpdates() async throws {
        let newBuild = try makeApp(in: root.appendingPathComponent("build"), version: "1.0.1")

        let forged = try makeOffer(for: newBuild, version: "1.0.1", signWith: Curve25519.Signing.PrivateKey())
        await assertThrows(.badSignature) { _ = try await self.preparer(current: "1.0.0").prepare(forged) { _, _ in } }

        let good = try makeOffer(for: newBuild, version: "1.0.1")
        await assertThrows(.wrongApp) { _ = try await self.preparer(current: "1.0.0", identifier: "com.example.other").prepare(good) { _, _ in } }
        await assertThrows(.notNewer) { _ = try await self.preparer(current: "1.0.1").prepare(good) { _, _ in } }

        let unsigned = UpdateOffer(version: good.version, title: "", notes: "", pageURL: good.pageURL,
                                   archiveURL: good.archiveURL, archiveSize: 0, signatureURL: nil)
        await assertThrows(.unsigned) { _ = try await self.preparer(current: "1.0.0").prepare(unsigned) { _, _ in } }

        // The tag says 1.0.2 but the app inside is 1.0.1.
        let mislabeled = UpdateOffer(version: AppVersion("1.0.2")!, title: "", notes: "", pageURL: good.pageURL,
                                     archiveURL: good.archiveURL, archiveSize: 0, signatureURL: good.signatureURL)
        await assertThrows(.wrongApp) { _ = try await self.preparer(current: "1.0.0").prepare(mislabeled) { _, _ in } }
    }

    func testReplaceableChecks() throws {
        XCTAssertThrowsError(try UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/MiSTer FTP.app"))) {
            XCTAssertEqual($0 as? UpdateError, .translocated)
        }
        XCTAssertThrowsError(try UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) {
            guard case .notWritable = $0 as? UpdateError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(UpdateInstaller.isTemporaryFolder(URL(fileURLWithPath: "/Applications")))
    }

    // MARK: Helpers

    private func assertThrows(_ expected: UpdateError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateError, expected, file: file, line: line)
        }
    }

    private func shell(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var last: Int64 = 0

    func add(_ done: Int64, _ total: Int64) {
        lock.lock()
        last = done
        lock.unlock()
    }
}
