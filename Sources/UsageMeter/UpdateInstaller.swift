import AppKit
import Observation
import Security

/// Downloads, verifies, and installs a newer build in place, then relaunches —
/// the seamless counterpart to `UpdateChecker`'s notify-only path.
///
/// The release pipeline ships a notarized, stapled `.zip`, and `URLSession`
/// downloads carry no quarantine attribute, so the whole swap happens without
/// any Gatekeeper prompt: stream the zip to a staging dir, unzip, pin the code
/// signature to our Developer ID team, replace the bundle atomically, and hand
/// off to a tiny detached shell that relaunches once this process exits.
/// Failures before the swap land in `.failed` and the menu falls back to the
/// browser download; a failure after the swap (the new build is already on
/// disk) lands in `.installedNeedsRestart` instead.
@MainActor
@Observable
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    enum Phase: Equatable {
        case idle
        /// Fraction complete, or nil while the total size is still unknown.
        case downloading(Double?)
        case installing
        case relaunching
        /// The swap succeeded but the auto-relaunch couldn't start — the update
        /// is on disk and just needs a quit + reopen.
        case installedNeedsRestart
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Whether the running copy can be swapped in place. False for dev builds
    /// (`swift run` has no .app bundle), translocated copies (macOS runs those
    /// from a read-only mount), and installs the user can't write to — the
    /// menu falls back to the browser download in those cases. Computed once:
    /// the bundle's location can't change while we're running.
    let canInstallInPlace = UpdateInstaller.isEligibleBundle(at: Bundle.main.bundleURL)

    /// The in-flight download, kept so the menu can offer Cancel.
    private var downloader: ZipDownloader?

    nonisolated static func isEligibleBundle(at url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        guard !url.path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
            && fm.isDeletableFile(atPath: url.path)
    }

    func install(_ update: AvailableUpdate) async {
        guard let zipURL = update.zipURL, canInstallInPlace else { return }
        switch phase {
        case .idle, .failed: break
        default: return  // mid-flight, or already installed
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMeterUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let zipFile = staging.appendingPathComponent("update.zip")

            phase = .downloading(nil)
            let downloader = ZipDownloader(destination: zipFile) { fraction in
                Task { @MainActor [weak self] in
                    // Late progress must never overwrite a later phase.
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            }
            self.downloader = downloader
            defer { self.downloader = nil }
            try await downloader.download(from: zipURL)

            phase = .installing
            let newApp = try await Self.extractApp(from: zipFile, into: staging)
            try await Self.verify(appAt: newApp, expectedVersion: update.version)
            let installed = try await Self.swapIn(newApp)

            // Past this point the new build is on disk; failures must not send
            // the user to a redundant second install.
            phase = .relaunching
            do {
                try relaunch(installed)
            } catch {
                phase = .installedNeedsRestart
            }
        } catch let error as URLError where error.code == .cancelled {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    // MARK: - Steps

    /// `ditto -x -k` preserves the signature and bundle structure exactly —
    /// the same tool the release pipeline zips with.
    nonisolated private static func extractApp(from zip: URL, into dir: URL) async throws -> URL {
        let result = try await ProcessTools.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zip.path, dir.path],
            timeout: 120)
        guard result.exitCode == 0 else {
            throw InstallError.installFailed("couldn't unpack the update")
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.installFailed("no app found in the update")
        }
        return app
    }

    /// Nothing gets installed unless the unpacked bundle (a) is the version the
    /// release advertised and (b) satisfies a code requirement pinning our
    /// bundle ID and Developer ID team. A compromised GitHub release alone —
    /// without the signing certificate — can't ship code through this path.
    /// Async so the strict-validation pass (it hashes every sealed resource,
    /// including the bundled node_modules) runs off the main actor.
    nonisolated private static func verify(appAt url: URL, expectedVersion: String) async throws {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let plist =
            (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL), options: [], format: nil)) as? [String: Any]
        guard let version = plist?["CFBundleShortVersionString"] as? String,
            UpdateChecker.isSameVersion(version, expectedVersion)
        else {
            throw InstallError.verificationFailed("downloaded version doesn't match the release")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else {
            throw InstallError.verificationFailed("update isn't code-signed")
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.erichermanson.usagemeter"
        let teamID = "2YN57RAL6Q"  // the Developer ID team every release is signed with
        let requirementText =
            "anchor apple generic and identifier \"\(bundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess, let req = requirement
        else {
            throw InstallError.verificationFailed("couldn't build the signing requirement")
        }

        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
        guard SecStaticCodeCheckValidityWithErrors(code, flags, req, nil) == errSecSuccess else {
            throw InstallError.verificationFailed("signature doesn't match this app's developer")
        }
    }

    /// The safe-save dance: the verified bundle slides into place and the old
    /// one is disposed of in a single, crash-safe operation. The running
    /// process keeps executing from its (now unlinked) old binary. Async to
    /// keep the directory move off the main actor.
    nonisolated private static func swapIn(_ newApp: URL) async throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        guard let installed = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newApp)
        else {
            throw InstallError.installFailed("couldn't replace the app bundle")
        }
        return installed
    }

    /// A detached shell outlives us: it waits (bounded, ~60s) for this PID to
    /// exit, then opens the freshly installed build. If termination is somehow
    /// vetoed, the timed-out `open` just activates the running instance.
    private func relaunch(_ appURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "i=0; while /bin/kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt 600 ]; "
                + "do /bin/sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$0\"",
            appURL.path,
        ]
        // run() only returns once the helper has spawned, so we can quit
        // immediately and let it do its half.
        try helper.run()
        NSApplication.shared.terminate(nil)
    }
}

/// Streams the zip straight to `destination` — URLSession's download task
/// writes to disk itself, so the payload never sits in memory — with real
/// progress callbacks and a bounded stall timeout instead of URLSession's
/// 7-day default.
private final class ZipDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileResult: Result<Void, Error>?
    private var task: URLSessionDownloadTask?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 300  // give up on a stalled download
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws {
        // The session retains its delegate (us) until invalidated.
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    /// Surfaces in `download(from:)` as `URLError.cancelled`.
    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(
            totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Runs before didComplete; the temp file must be claimed synchronously.
        fileResult = Result {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallError.downloadFailed
            }
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        let cont = continuation
        continuation = nil
        if let error {
            cont?.resume(throwing: error)
            return
        }
        switch fileResult {
        case .success: cont?.resume(returning: ())
        case .failure(let error): cont?.resume(throwing: error)
        case nil: cont?.resume(throwing: InstallError.downloadFailed)
        }
    }
}

private enum InstallError: LocalizedError {
    case downloadFailed
    case installFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "the download failed"
        case .installFailed(let reason): return reason
        case .verificationFailed(let reason): return reason
        }
    }
}
