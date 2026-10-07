import CoreServices
import Foundation

public struct AppBundleInfo: Equatable, Sendable {
    public let identifier: String
    public let version: AppVersion
}

/// Downloads a release, proves it is ours, and puts it in place of the running app.
public struct UpdatePreparer: Sendable {
    public let publicKey: String
    public let bundleIdentifier: String
    public let currentVersion: AppVersion
    public let workFolder: URL

    public init(publicKey: String, bundleIdentifier: String, currentVersion: AppVersion, workFolder: URL) {
        self.publicKey = publicKey
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.workFolder = workFolder
    }

    /// Downloads the archive, checks its signature, unpacks it and checks the app inside.
    /// Returns the unpacked app, ready for `UpdateInstaller.swap`.
    public func prepare(_ offer: UpdateOffer, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard let signatureURL = offer.signatureURL else { throw UpdateError.unsigned }
        guard ReleaseFeed.isAllowed(offer.archiveURL), ReleaseFeed.isAllowed(signatureURL) else { throw UpdateError.insecureURL }
        guard offer.version > currentVersion else { throw UpdateError.notNewer }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workFolder)
        try fileManager.createDirectory(at: workFolder, withIntermediateDirectories: true)
        try Task.checkCancellation()

        let signature = try await downloadText(signatureURL)
        try Task.checkCancellation()
        let archive = workFolder.appendingPathComponent("update.zip")
        try await FileDownloader(destination: archive, progress: progress).run(offer.archiveURL)
        try Task.checkCancellation()

        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        try Task.checkCancellation()
        guard UpdateSignature.isValid(signature: signature, for: data, publicKey: publicKey) else {
            throw UpdateError.badSignature
        }
        try Task.checkCancellation()
        let app = try UpdateInstaller.unpack(archive, into: workFolder.appendingPathComponent("unpacked"))
        try Task.checkCancellation()
        let info = try UpdateInstaller.bundleInfo(of: app)
        guard info.identifier == bundleIdentifier, info.version == offer.version else { throw UpdateError.wrongApp }
        guard info.version > currentVersion else { throw UpdateError.notNewer }
        try Task.checkCancellation()
        try UpdateInstaller.verifyCodeSignature(of: app)
        try Task.checkCancellation()
        return app
    }

    private func downloadText(_ url: URL) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            guard let text = String(data: data, encoding: .utf8) else { throw UpdateError.badSignature }
            return text
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }
}

public enum UpdateInstaller {
    /// Throws when the running app cannot be replaced where it is.
    public static func checkReplaceable(_ app: URL) throws {
        guard app.pathExtension == "app" else { throw UpdateError.install("not an app bundle") }
        // Gatekeeper runs apps opened straight from a download from a read-only copy.
        if app.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let parent = app.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: parent.path), fileManager.isWritableFile(atPath: app.path) else {
            throw UpdateError.notWritable(fileManager.displayName(atPath: parent.path))
        }
    }

    public static func bundleInfo(of app: URL) throws -> AppBundleInfo {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let versionText = plist["CFBundleShortVersionString"] as? String,
              let version = AppVersion(versionText) else {
            throw UpdateError.wrongApp
        }
        return AppBundleInfo(identifier: identifier, version: version)
    }

    /// Unzips with ditto, which keeps the bundle's symlinks, permissions and signature.
    public static func unpack(_ archive: URL, into folder: URL) throws -> URL {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], failure: .noAppInArchive)
        let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.noAppInArchive }
        return apps[0]
    }

    public static func verifyCodeSignature(of app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path], failure: .codeSignature)
    }

    /// Puts `newApp` at `installedApp` in one atomic swap. The old copy ends up in the
    /// returned temporary folder, which `relaunchAfterExit` deletes.
    ///
    /// Swapping directory entries never writes into the running app's files, so the
    /// running process keeps working until it quits.
    public static func swap(installedApp: URL, with newApp: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging: URL
        do {
            // A temporary folder on the same volume, so the swap is a rename.
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
        let staged = staging.appendingPathComponent(installedApp.lastPathComponent)
        do {
            try fileManager.moveItem(at: newApp, to: staged)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw UpdateError.install(error.localizedDescription)
        }
        if renamex_np(staged.path, installedApp.path, UInt32(RENAME_SWAP)) != 0 {
            let reason = String(cString: strerror(errno))
            try? fileManager.removeItem(at: staging)
            throw UpdateError.install(reason)
        }
        // Launch Services still remembers the old version at this path.
        LSRegisterURL(installedApp as CFURL, true)
        return staging
    }

    /// Starts a small shell process that waits for `processID` to end, deletes
    /// `cleanup`, then opens `app`. Set MISTERFTP_UPDATE_NO_RELAUNCH to skip the open.
    public static func relaunchAfterExit(app: URL, cleanup: URL?, processID: Int32 = getpid()) throws {
        let cleanupPath = cleanup.flatMap { isTemporaryFolder($0) ? $0.path : nil } ?? ""
        let script = """
        pid="$1"; app="$2"; cleanup="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if [ -n "$cleanup" ]; then rm -rf "$cleanup"; fi
        if [ -z "$MISTERFTP_UPDATE_NO_RELAUNCH" ]; then /usr/bin/open "$app"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "misterftp-update", String(processID), app.path, cleanupPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Only folders the system makes for replacing items are deleted automatically.
    static func isTemporaryFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/TemporaryItems/") || path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    private static func run(_ tool: String, _ arguments: [String], failure: UpdateError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw failure
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure }
    }
}
