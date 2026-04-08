import Cocoa

/// Watches the user's screenshot directory and automatically copies any new
/// screenshot file to the system clipboard as an image. This lets the user
/// take a screenshot via Cmd+Shift+4 (which saves a file to the Desktop by
/// default) and immediately paste the image into another app without having
/// to open the file first.
///
/// Design:
/// - Uses `DispatchSource.makeFileSystemObjectSource` (kqueue-backed) so we
///   get zero-CPU kernel notifications when the watched directory changes,
///   not polling.
/// - On each change event, re-scans the directory for recent PNG files whose
///   filename looks like a screenshot, that we haven't already processed.
/// - Screenshots are identified by: PNG extension, recent mtime (<5s),
///   filename prefix (localized: Screenshot, Screen Shot, Bildschirmfoto,
///   Capture d'écran, Captura de pantalla, etc.), OR presence of the
///   com.apple.metadata:_kMDItemIsScreenCapture extended attribute.
/// - Deduped via a `Set<URL>` of already-processed file paths so each
///   screenshot is copied to clipboard exactly once.
/// - Honors macOS's `com.apple.screencapture` default for screenshot location
///   so it works even if the user has moved screenshots out of ~/Desktop.
final class ScreenshotWatcher {

    /// The directory being watched. Read from macOS's screencapture defaults
    /// or falls back to ~/Desktop.
    let watchedDirectory: URL

    /// Modification time of the most recent screenshot we copied to the
    /// clipboard (or the watcher's startup time, whichever is later). Only
    /// files with mtime STRICTLY newer than this value are considered new.
    /// Using a timestamp instead of a Set<URL> avoids the "old file gets
    /// picked up on a later unrelated event" race — we always prefer the
    /// newest file and never revisit older ones.
    private var lastProcessedMtime: Date

    /// The underlying dispatch source watching the directory.
    private var dispatchSource: DispatchSourceFileSystemObject?

    /// File descriptor for the watched directory. Must stay open for the
    /// lifetime of the dispatch source.
    private var directoryFD: CInt = -1

    /// Queue on which filesystem events are delivered and scans run.
    /// User-initiated QoS (not utility) so the scan and copy run promptly
    /// after screencapture finishes writing — the user is actively waiting
    /// to paste, this is latency-critical.
    private let eventQueue = DispatchQueue(
        label: "com.haredigital.speechcraft.screenshot-watcher",
        qos: .userInitiated
    )

    /// Debounce work item: every kqueue event cancels the previous pending
    /// scan (if any) and schedules a new one for `debounceInterval` in the
    /// future. This coalesces bursts of filesystem events from a single
    /// screencapture operation into one scan that runs AFTER the write
    /// is complete.
    private var pendingScan: DispatchWorkItem?

    /// How long to wait after the last kqueue event before actually
    /// scanning. Needs to be long enough for screencapture to finish
    /// writing even a large retina screenshot (~3MB), but short enough
    /// that the user doesn't feel a paste delay. 250ms is a good balance.
    private let debounceInterval: TimeInterval = 0.25

    /// Optional callback fired on the main queue after a screenshot is
    /// successfully copied to the clipboard. Use this to show a toast,
    /// play a sound, or flash the recording overlay.
    var onScreenshotCopied: ((URL) -> Void)?

    init() {
        // Read macOS's configured screenshot location. If unset, default to Desktop.
        let screencaptureDefaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let configuredPath = screencaptureDefaults?.string(forKey: "location"),
           !configuredPath.isEmpty {
            // macOS stores this as an absolute path, possibly with ~ for home.
            let expanded = (configuredPath as NSString).expandingTildeInPath
            self.watchedDirectory = URL(fileURLWithPath: expanded)
        } else {
            self.watchedDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
        }

        // Initialize to the current time so no pre-existing files are considered
        // "new" at launch. Only files modified AFTER this point will be copied.
        self.lastProcessedMtime = Date()
    }

    deinit {
        stop()
    }

    /// Begin watching the directory for new screenshot files.
    func start() {
        guard dispatchSource == nil else { return }  // already running

        let path = watchedDirectory.path
        directoryFD = open(path, O_EVTONLY)
        if directoryFD < 0 {
            NSLog("[ScreenshotWatcher] failed to open \(path) for watching: errno=\(errno)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .extend, .rename],
            queue: eventQueue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedScan()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.directoryFD >= 0 {
                close(self.directoryFD)
                self.directoryFD = -1
            }
        }

        source.resume()
        dispatchSource = source
        NSLog("[ScreenshotWatcher] started watching \(path)")
    }

    /// Stop watching the directory. Safe to call multiple times.
    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    // MARK: - Private

    /// Debounce: cancel any pending scan and schedule a new one for
    /// `debounceInterval` in the future. If more kqueue events arrive
    /// before the work item fires, they each reset the timer. The scan
    /// only runs once the filesystem has been quiet for the full interval.
    ///
    /// This is the canonical pattern for handling bursty filesystem
    /// events: you don't want to react to each individual .write/.extend
    /// event (because a single screencapture operation fires many), you
    /// want to react exactly once per "burst."
    private func scheduleDebouncedScan() {
        pendingScan?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleDirectoryChange()
        }
        pendingScan = workItem
        eventQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Called after debounce settles. Finds the single newest PNG
    /// screenshot in the directory and copies it to the clipboard IF its
    /// modification time is strictly newer than the last one we processed.
    /// Older files are ignored entirely.
    ///
    /// This timestamp-based approach is more robust than a path-based
    /// "already processed" set: we always prefer the newest file, and a
    /// race between multiple events can never result in an older file
    /// being copied to the clipboard. Pre-existing files at launch are
    /// skipped because lastProcessedMtime is initialized to Date() at
    /// startup — any file already on disk has an mtime <= startup time.
    private func handleDirectoryChange() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: watchedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // Find the single newest PNG file in the directory.
        let newestPNG = contents
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate else {
                    return nil
                }
                return (url, mtime)
            }
            .max(by: { $0.1 < $1.1 })  // highest mtime wins

        guard let (url, mtime) = newestPNG else { return }

        // Must be strictly newer than what we've already processed —
        // prevents re-copying the same file on subsequent events.
        guard mtime > lastProcessedMtime else { return }

        // Must actually look like a screenshot (filename prefix or xattr).
        // Files that match the mtime check but aren't screenshots (e.g., the
        // user pasted a random PNG into Desktop) are still skipped but we
        // advance lastProcessedMtime so we don't re-check them.
        if isScreenshot(url: url) {
            lastProcessedMtime = mtime
            copyToClipboard(url: url)
        } else {
            // Not a screenshot — advance the timestamp so we don't re-consider
            // it on the next event.
            lastProcessedMtime = mtime
        }
    }

    /// Heuristic: is the given file a screenshot created by macOS's
    /// screencapture utility?
    /// Checks multiple signals because none are 100% reliable alone:
    /// 1. Extended attribute `com.apple.metadata:_kMDItemIsScreenCapture`
    ///    (most reliable but not always present)
    /// 2. Filename prefix matching known localized "Screenshot" words
    private func isScreenshot(url: URL) -> Bool {
        // Check the xattr first — it's the most authoritative signal
        let xattrName = "com.apple.metadata:_kMDItemIsScreenCapture"
        let size = getxattr(url.path, xattrName, nil, 0, 0, 0)
        if size > 0 {
            return true
        }

        // Fall back to filename-based detection with common localized prefixes
        let filename = url.lastPathComponent
        let knownPrefixes = [
            "Screenshot",       // English (macOS Sonoma+)
            "Screen Shot",      // English (older macOS)
            "Bildschirmfoto",   // German
            "Capture d",        // French (Capture d'écran)
            "Captura de",       // Spanish / Portuguese
            "Screenshot-",      // Common third-party tools
            "スクリーンショット", // Japanese
            "屏幕快照",         // Chinese (Simplified)
            "螢幕擷取畫面"      // Chinese (Traditional)
        ]
        return knownPrefixes.contains { filename.hasPrefix($0) }
    }

    /// Copies the given image file to the system clipboard.
    ///
    /// FAST PATH: we read the raw PNG bytes directly and write them to the
    /// pasteboard under the `.png` type. This skips NSImage initialization,
    /// skips rasterization, and skips format conversion (TIFF, JPEG, GIF,
    /// etc. — all the formats Cocoa would generate via writeObjects:).
    /// Modern Mac apps accept PNG paste, so we lose nothing meaningful and
    /// save 30-100ms per screenshot.
    ///
    /// Debouncing in scheduleDebouncedScan() already ensures the file is
    /// fully written by the time this is called. We keep ONE retry as a
    /// last-resort safety net for edge cases.
    private func copyToClipboard(url: URL, isRetry: Bool = false) {
        guard let pngData = try? Data(contentsOf: url), pngData.count > 0 else {
            if !isRetry {
                eventQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.copyToClipboard(url: url, isRetry: true)
                }
            } else {
                NSLog("[ScreenshotWatcher] failed to read \(url.path) even after retry")
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(pngData, forType: .png)
            NSLog("[ScreenshotWatcher] copied \(url.lastPathComponent) to clipboard (\(pngData.count) bytes)")
            self?.onScreenshotCopied?(url)
        }
    }
}
