import Cocoa
import SwiftUI
import AVFoundation
import ApplicationServices
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var eventTap: CFMachPort?
    // SwiftUI Preferences window
    var preferencesWindow: NSWindow?
    /// Window used to display markdown-rendered AI responses
    var responseWindow: NSWindow?
    var runLoopSource: CFRunLoopSource?
    var audioRecorder: AVAudioRecorder?
    // Silence-detection auto-stop
    private var silenceTimer: Timer?
    private var lastVoiceDate: Date?
    /// dB level below which is considered silence
    private let silenceLevelThreshold: Float = -30.0
    var isRecording = false
    var audioURL: URL?
    /// Virtual keycode for the Right Option key. Used as the push-to-talk trigger.
    /// We can't use fn because macOS consumes it for the system Dictation shortcut
    /// (AppleFnUsageType=3) BEFORE user event taps see it. Right Option has no default
    /// system behavior and is rarely used for shortcuts (Left Option = 58 handles those).
    private static let rightOptionKeyCode: Int64 = 61
    /// Virtual keycode for the ISO Section key (§ on UK/European keyboards,
    /// physical position to the left of the 1 key). When the user taps this
    /// alone, we intercept it and synthesize Cmd+Ctrl+Shift+4 to trigger
    /// macOS's region-screenshot-to-clipboard gesture. On US ANSI keyboards
    /// this keycode doesn't correspond to a physical key, so the binding
    /// is a no-op on those layouts.
    private static let isoSectionKeyCode: Int64 = 10
    /// Virtual keycode for the "4" key on the number row. Used to synthesize
    /// Cmd+Ctrl+Shift+4 when the user taps the § key.
    private static let fourKeyCode: CGKeyCode = 21
    /// Virtual keycode for the Right Command key. Used as the "speak selection" (TTS)
    /// trigger. Tap (without any other key) to speak the current selection via
    /// AVSpeechSynthesizer; tap again to stop. Chord detection (see chordDetectedWhile-
    /// RightCmdHeld) ensures Cmd+C, Cmd+V, and other chord shortcuts still work
    /// normally when the user holds Right Command while pressing another key.
    private static let rightCommandKeyCode: Int64 = 54
    /// Tracks whether the Right Option key is currently held down.
    /// Used to implement push-to-talk: press Right Option to start recording,
    /// release to stop + transcribe. Toggled by each flagsChanged event with keycode 61.
    private var isPttKeyPressed = false
    /// Whether the current recording was started via push-to-talk (as opposed to Option+S toggle).
    /// If true, releasing the PTT key will stop the recording. If false, PTT release is
    /// ignored — this prevents a stray Right Option tap from cancelling a toggle-started
    /// recording.
    private var recordingStartedByPtt = false
    /// Tracks Right Command press state for the push-to-talk hotkey.
    /// Toggled on each flagsChanged event with keycode 54.
    /// Unlike Right Option's PTT, Right Command does NOT auto-submit on release
    /// regardless of the PTTAutoSubmitOnRelease preference. It's the "record
    /// without submit" variant for code editors, long-form writing, and any
    /// context where pressing Return would be destructive.
    var isRightCmdPressed = false
    /// Parallel to recordingStartedByPtt but for Right Command PTT. Ensures
    /// that releasing Right Command only stops recordings it started, not
    /// recordings started via Right Option toggle or Option+S hotkey.
    var recordingStartedByRightCmdPtt = false
    /// Lazily created speech synthesizer used by the "speak selection" feature
    /// when TTSEngine preference is set to "local". AVSpeechSynthesizer requires
    /// no entitlements and makes no network calls — all voice rendering happens
    /// locally via macOS TTS engines. Non-private so the extension methods in
    /// ClipboardHelper.swift can access it.
    var speechSynth: AVSpeechSynthesizer?
    /// Audio player used for OpenAI TTS playback (MP3 bytes from the
    /// /v1/audio/speech endpoint). Non-private for the same reason — accessed
    /// from the ClipboardHelper extension. Stored at instance level so the
    /// "tap again to stop" toggle can reach in and stop playback.
    var ttsAudioPlayer: AVAudioPlayer?
    /// Temp file URL for the current OpenAI TTS playback. Cleaned up after
    /// playback completes or is stopped.
    var ttsAudioFileURL: URL?

    /// When true, the NEXT insertTranscript() call will simulate a Return keypress
    /// shortly after pasting the transcribed text. Set by the PTT release handler
    /// when "PTTAutoSubmitOnRelease" is enabled; cleared by insertTranscript after
    /// firing. Only the regular dictation path consults this flag — instruction,
    /// modal, and script hotkeys never auto-submit.
    var pendingAutoSubmit = false

    /// Tracks whether the most recent insertTranscript() call ended with actual
    /// whitespace (space, tab, newline). Used to decide whether the NEXT insertion
    /// should be prefixed with a space to avoid concatenating consecutive dictations.
    ///
    /// Crucially, punctuation is NOT treated as a separator — a period ends a
    /// sentence but still needs a space before the next word ("hello. world",
    /// not "hello.world"). Only real whitespace characters tell us the cursor
    /// is already at a clean word boundary.
    ///
    /// Starts at true so the first dictation never gets a leading space — we
    /// assume the user placed their cursor at a sensible position (empty field,
    /// after a newline, etc.) before dictating the first time.
    var lastInsertedEndedWithWhitespace = true
    // Instruction recording mode
    var instructionMode = false
    var originalSelectedText: String?
    // Status bar item to indicate recording/transcribing state
    var statusItem: NSStatusItem?
    // Modal recording mode flag
    var modalMode = false
    // Captured selected text for modal
    var modalSelectedText: String?
    // Temporary URL for modal audio recording
    var modalAudioURL: URL?
    enum TranscribeState {
        case ready, recording, transcribing, error
    }
    // Configurable transcription model and prompt
    var transcriptionModel = UserDefaults.standard.string(forKey: "TranscriptionModel") ?? "gpt-4o-mini-transcribe"
    let availableModels = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper"]
    var transcriptionPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
    
    // Service configuration
    enum ServiceType: String { case openAI = "OpenAI", azure = "Azure" }
    /// Current service type, read directly from UserDefaults
    var serviceType: ServiceType {
        ServiceType(rawValue: UserDefaults.standard.string(forKey: "ServiceType") ?? "OpenAI") ?? .openAI
    }
    /// OpenAI API key from settings
    /// Hardened: read API key from Keychain instead of plain UserDefaults.
    /// See KeychainStore.swift for the migration logic.
    var openAIKey: String? {
        KeychainStore.get("OpenAIKey")
    }
    /// OpenAI chat model from settings
    var openAIChatModel: String {
        UserDefaults.standard.string(forKey: "OpenAIChatModel") ?? "gpt-4o"
    }
    /// Azure API key — also stored in Keychain.
    var azureKey: String? {
        KeychainStore.get("AzureKey")
    }
    /// Azure transcription endpoint from settings
    var azureTranscribeEndpoint: String? {
        UserDefaults.standard.string(forKey: "AzureTranscribeEndpoint")
    }
    /// Azure chat endpoint from settings
    var azureChatEndpoint: String? {
        UserDefaults.standard.string(forKey: "AzureChatEndpoint")
    }
    let defaults = UserDefaults.standard
    // MARK: - HotKey Capture
    struct HotKey: Codable {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags.RawValue
        let character: String
    }
    private enum HotKeyCaptureType { case record, instruction, modal, script }
    private var keyCaptureMonitor: Any?
    private var captureType: HotKeyCaptureType?
    // Record hotkey (load or default Option+S)
    var recordHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "RecordHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        return HotKey(keyCode: 1, modifiers: CGEventFlags.maskAlternate.rawValue, character: "S")
    }()
    // Instruction hotkey (load or default Option+Shift+S)
    var instructionHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "InstructionHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        let mods = CGEventFlags.maskAlternate.union(.maskShift).rawValue
        return HotKey(keyCode: 1, modifiers: mods, character: "S")
    }()
    // Modal hotkey (load or default Option+A)
    var modalHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "ModalHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        // keyCode 0 is 'A', Option modifier
        return HotKey(keyCode: 0, modifiers: CGEventFlags.maskAlternate.rawValue, character: "A")
    }()
    // Script hotkey (load or default Option+D)
    var scriptHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "ScriptHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        // keyCode 2 is 'D', Option modifier
        return HotKey(keyCode: 2, modifiers: CGEventFlags.maskAlternate.rawValue, character: "D")
    }()
    // Script recording mode flag
    var scriptMode = false
    // Captured selected text for script
    var scriptSelectedText: String?
    // Temporary URL for script audio recording
    var scriptAudioURL: URL?

    /// Returns a human-readable description of a HotKey (e.g. "⌥⇧S").
    func hotKeyDescription(_ hk: HotKey) -> String {
        var parts = ""
        let flags = CGEventFlags(rawValue: hk.modifiers)
        if flags.contains(.maskCommand) { parts += "⌘" }
        if flags.contains(.maskAlternate) { parts += "⌥" }
        if flags.contains(.maskControl) { parts += "⌃" }
        if flags.contains(.maskShift) { parts += "⇧" }
        parts += hk.character.uppercased()
        return parts
    }

    // MARK: - Transcription State
    var transcribeState: TranscribeState = .ready {
        didSet {
            updateStatusIcon()
            updateRecordingOverlay()
        }
    }

    /// Floating on-screen indicator shown while dictation is active.
    /// Pre-created at app launch (see applicationDidFinishLaunching) so the
    /// first dictation doesn't pay NSPanel/SwiftUI initialization cost on
    /// the main thread. Lives for the app lifetime.
    var recordingOverlay: RecordingOverlayWindow?

    /// Watches the screenshot directory for new screenshots and auto-copies
    /// them to the clipboard. Created lazily at launch if
    /// "AutoCopyScreenshots" preference is enabled.
    var screenshotWatcher: ScreenshotWatcher?

    /// Drives the recording overlay based on the current transcribeState.
    /// Shows a "Listening…" pill during recording, morphs to "Transcribing…"
    /// once the upload starts, and hides when we return to ready or error.
    /// Appearance is instant (no fade-in) to eliminate any perceived latency;
    /// fade-out remains animated because hide latency doesn't matter.
    func updateRecordingOverlay() {
        guard let overlay = recordingOverlay else { return }
        switch transcribeState {
        case .recording:
            overlay.show(mode: .recording)
        case .transcribing:
            if overlay.isVisible {
                overlay.updateMode(.transcribing)
            } else {
                overlay.show(mode: .transcribing)
            }
        case .ready, .error:
            overlay.hide()
        }
    }

    // MARK: Configuration Check
    /// Returns true if required keys and endpoints are configured
    private var isConfigured: Bool {
        switch serviceType {
        case .openAI:
            return !(openAIKey?.isEmpty ?? true)
        case .azure:
            return !(azureKey?.isEmpty ?? true) &&
                   !(azureTranscribeEndpoint?.isEmpty ?? true) &&
                   !(azureChatEndpoint?.isEmpty ?? true)
        }
    }

    /// Ensure state is error if unconfigured
    private func updateConfigurationState() {
        if !isConfigured {
            transcribeState = .error
        } else if transcribeState == .error {
            transcribeState = .ready
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default preferences FIRST, before any other code reads
        // preference values. register(defaults:) provides fallback values for
        // unset keys, but only for reads that happen AFTER this call. If we
        // read a preference before registering defaults, we get the default
        // default (false/0/nil) instead of our registered default. This bit
        // us hard on AutoCopyScreenshots: we read it before registering, got
        // false, and never started the watcher.
        UserDefaults.standard.register(defaults: [
            // Include screenshots in GPT requests by default
            "EnableScreenshots": true,
            // Silence detection defaults
            "EnableAutoSilenceStop": false,
            "SilenceTimeout": 2.0,
            // Default transcription model — gpt-4o-mini-transcribe for cost/accuracy balance
            "TranscriptionModel": "gpt-4o-mini-transcribe",
            // Default to auto-submit (press Return) on PTT release. Turn off in
            // Preferences if dictating into apps where Enter would be destructive
            // (code editors, long-form writing, etc.).
            "PTTAutoSubmitOnRelease": true,
            // Default to auto-copying new screenshots to the clipboard. The
            // original file still lands in the screenshot save location
            // (usually ~/Desktop) — this just adds the image to the pasteboard
            // so it can be pasted without opening the file.
            "AutoCopyScreenshots": true,
            // Default to binding the § key (ISO keycode 10, to the left of 1
            // on UK/European Mac keyboards) to trigger Cmd+Ctrl+Shift+4
            // (region screenshot → clipboard). Turn off if you need to type §
            // literally or are on a US keyboard (where it's a no-op anyway).
            "SectionKeyTriggersScreenshot": true,
            // New default: enable GPT-4o proofreading of transcripts
            "EnableProofreading": true,
            // Default model for proofreading — mini variant to keep costs low
            "ProofreadingModel": "gpt-4o-mini",
            // Default prompt for transcription
            "TranscriptionPrompt": "Transcribe everything and do not truncate text",
            // Default prompt for AppleScript generation: include activation of target apps
            "ScriptPrompt": "You are an assistant that generates AppleScript commands for macOS based on provided instructions. Always launch or activate the target application before issuing commands (e.g., 'tell application \"AppName\" to activate'). Only output valid AppleScript code without additional explanation."
        ])

        // Register as the macOS Services provider for "SpeechCraft: Read Aloud".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // One-time credential migration: move any API keys from plain UserDefaults
        // to the macOS Keychain. Idempotent — safe to run on every launch.
        KeychainStore.migrateFromUserDefaults(keys: ["OpenAIKey", "AzureKey"])

        // Pre-create the recording overlay window ahead of first dictation so
        // the NSPanel + SwiftUI initialization cost (~30-80ms) is paid at
        // launch rather than on the user's first press of Right Option.
        recordingOverlay = RecordingOverlayWindow()

        // Start the screenshot watcher if enabled. It monitors the screenshot
        // save directory (usually ~/Desktop) and auto-copies new screenshot
        // files to the clipboard so the user can paste them into other apps
        // without having to open the file first. Reading the preference AFTER
        // the register(defaults:) call above ensures we see the registered
        // default of true for first-launch users.
        if UserDefaults.standard.bool(forKey: "AutoCopyScreenshots") {
            screenshotWatcher = ScreenshotWatcher()
            screenshotWatcher?.start()
        }

        // Check and request Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            // Prompt displayed; user must allow in System Settings → Privacy & Security → Accessibility
            NSLog("Accessibility permission not yet granted; requested via system prompt.")
        }
        // Check and request microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Microphone Access Required"
                        alert.informativeText = "Please enable Microphone access for SpeechCraft in System Settings → Privacy & Security → Microphone."
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Please enable Microphone access for SpeechCraft in System Settings → Privacy & Security → Microphone."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        setupEventTap()
        setupStatusItem()
        transcribeState = .ready
        // Validate configuration
        updateConfigurationState()
    }

    func setupEventTap() {
        // Watch both keyDown (for hotkeys like Option+S) AND flagsChanged
        // (for push-to-talk via the fn modifier key, which never fires
        // keyDown events — it only shows up as a modifier state change).
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let eventTap = eventTap else {
            NSLog("Failed to create event tap.")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        let mySelf = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
        return mySelf.handleEvent(proxy: proxy, type: type, event: event)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Push-to-talk via Right Option key:
        // Right Option is a modifier, so it only generates flagsChanged events,
        // never keyDown. Each press or release of any modifier key fires a
        // flagsChanged event with the specific virtual keycode of the key that
        // changed. We detect press vs release by toggling our own tracked state
        // each time the Right Option keycode (61) appears.
        //
        // We can't use the fn key for PTT because macOS intercepts it for the
        // system Dictation shortcut (AppleFnUsageType=3 on this user's Mac)
        // before any user event tap sees the press.
        //
        // Only start recording if we're in .ready state (API key configured).
        // Only stop a recording on PTT release if it was started by PTT (tracked
        // via recordingStartedByPtt) — this prevents a stray Right Option tap
        // from cancelling a recording started via the Option+S toggle hotkey.
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Right Command — push-to-talk recording WITHOUT auto-submit.
            // Identical to Right Option PTT except it never arms the
            // pendingAutoSubmit flag, so the transcribed text is pasted
            // without pressing Return afterward. Use this hotkey when
            // dictating into code editors, long-form writing, or any
            // context where an accidental Return would break things.
            //
            // Cmd+letter chord shortcuts (Cmd+C, Cmd+V, etc.) continue
            // to work normally while Right Command is held — our event
            // tap passes those keyDowns through to the active app
            // unchanged. The recording continues in parallel with any
            // accidental chord presses.
            //
            // Speak Selection / Read Aloud (formerly triggered by a
            // lone Right Command tap) has moved to the right-click
            // Services menu. See NSServices entry in Info.plist.
            if keyCode == Self.rightCommandKeyCode {
                isRightCmdPressed.toggle()
                if isRightCmdPressed {
                    // Press → start recording if idle and configured
                    if !isRecording && transcribeState == .ready {
                        startRecording()
                        isRecording = true
                        recordingStartedByRightCmdPtt = true
                    }
                } else {
                    // Release → stop recording if Right Cmd owns it.
                    // Critically: do NOT arm pendingAutoSubmit — this
                    // is the "no Return" variant.
                    if isRecording && recordingStartedByRightCmdPtt {
                        stopRecording()
                        isRecording = false
                        recordingStartedByRightCmdPtt = false
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            if keyCode == Self.rightOptionKeyCode {
                // Toggle our tracked state — the first event is a press,
                // the second is a release, and so on.
                isPttKeyPressed.toggle()
                if isPttKeyPressed {
                    // Just pressed → start recording if idle and configured
                    if !isRecording && transcribeState == .ready {
                        startRecording()
                        isRecording = true
                        recordingStartedByPtt = true
                    }
                } else {
                    // Just released → stop only if PTT owns this recording
                    if isRecording && recordingStartedByPtt {
                        // Arm the auto-submit flag if the preference is on.
                        // insertTranscript() will check and clear this after pasting.
                        if UserDefaults.standard.bool(forKey: "PTTAutoSubmitOnRelease") {
                            pendingAutoSubmit = true
                        }
                        stopRecording()
                        isRecording = false
                        recordingStartedByPtt = false
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Filter to modifier bits only
            let maskFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let rawFlags = event.flags.intersection(maskFlags)
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // § key → Cmd+Ctrl+Shift+4 (region screenshot to clipboard).
            // On UK/European ISO keyboards the § key sits to the left of 1;
            // on US keyboards keycode 10 doesn't exist so this is a no-op.
            // We only fire on a clean § tap (no other modifiers held) to
            // avoid hijacking Shift+§ (which types ±) or Alt+§.
            if keyCode == Self.isoSectionKeyCode && rawFlags.rawValue == 0
                && UserDefaults.standard.bool(forKey: "SectionKeyTriggersScreenshot") {
                triggerRegionScreenshotToClipboard()
                return nil  // consume the § press, don't let it type anything
            }

            // If unconfigured, open Settings on either hotkey
            if transcribeState == .error {
                if keyCode == recordHotKey.keyCode && rawFlags.rawValue == recordHotKey.modifiers {
                    openSettings(nil); return nil
                }
                if keyCode == instructionHotKey.keyCode && rawFlags.rawValue == instructionHotKey.modifiers {
                    openSettings(nil); return nil
                }
            }
            // Instruction hotkey
            if keyCode == instructionHotKey.keyCode && rawFlags.rawValue == instructionHotKey.modifiers {
                handleInstructionHotkey(); return nil
            }
            // Record/Stop hotkey
            if keyCode == recordHotKey.keyCode && rawFlags.rawValue == recordHotKey.modifiers {
                toggleRecording(); return nil
            }
            // Modal hotkey: show response in modal dialog
            if keyCode == modalHotKey.keyCode && rawFlags.rawValue == modalHotKey.modifiers {
                handleModalHotkey(); return nil
            }
            // Script hotkey: record, generate AppleScript, and execute
            if keyCode == scriptHotKey.keyCode && rawFlags.rawValue == scriptHotKey.modifiers {
                handleScriptHotkey(); return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
    
    /// Synthesizes a Cmd+Ctrl+Shift+4 keystroke, which macOS interprets as
    /// "start a region screenshot and copy the result to the clipboard"
    /// (the Ctrl modifier is what differentiates clipboard-copy from the
    /// default save-to-file behavior of Cmd+Shift+4).
    ///
    /// Uses `.privateState` source + explicit flags (lessons learned from
    /// the simulateReturn modifier-contamination bug) to ensure the event
    /// goes out exactly as we intend, with no leftover modifier state from
    /// previous synthetic events.
    func triggerRegionScreenshotToClipboard() {
        let src = CGEventSource(stateID: .privateState)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: Self.fourKeyCode, keyDown: true) {
            keyDown.flags = modifiers
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: Self.fourKeyCode, keyDown: false) {
            keyUp.flags = modifiers
            keyUp.post(tap: .cghidEventTap)
        }
    }

    func toggleRecording() {
        if !isRecording {
            startRecording()
            isRecording = true
            // Option+S toggle explicitly owns this recording — clear the PTT flag
            // so a stray Right Option release doesn't cancel it.
            recordingStartedByPtt = false
        } else {
            stopRecording()
            isRecording = false
            recordingStartedByPtt = false
        }
    }

    func startRecording() {
        // AVAudioSession is unavailable on macOS; AVAudioRecorder works without explicit session setup
        let tmpDir = FileManager.default.temporaryDirectory
        let filename = "speechcraft_\(Date().timeIntervalSince1970).wav"
        audioURL = tmpDir.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: audioURL!, settings: settings)
            // Enable metering for silence detection
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            NSLog("startRecording: Recording started")
            transcribeState = .recording
            // Auto-stop on silence if enabled
            let autoStop = UserDefaults.standard.bool(forKey: "EnableAutoSilenceStop")
            if autoStop {
                let timeout = UserDefaults.standard.double(forKey: "SilenceTimeout")
                NSLog("startRecording: Auto-silence-stop enabled (timeout = %.2f s)", timeout)
                lastVoiceDate = Date()
                // Schedule periodic level checks
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.checkSilence()
                }
            }
        } catch {
            NSLog("Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        // Invalidate silence detection timer
        if let timer = silenceTimer {
            timer.invalidate()
            silenceTimer = nil
            NSLog("stopRecording: silence timer invalidated")
        }
        audioRecorder?.stop()
        transcribeState = .transcribing
        audioRecorder = nil
        guard let url = audioURL else { return }
        if instructionMode {
            transcribeInstruction(fileURL: url)
        } else {
            transcribe(fileURL: url)
        }
    }
    
    /// Periodically called to detect silence and auto-stop recording
    private func checkSilence() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        let now = Date()
        NSLog("checkSilence: level = %.1f dB", level)
        if level > silenceLevelThreshold {
            // Detected voice, reset timer
            lastVoiceDate = now
        } else if let last = lastVoiceDate {
            let silenceDuration = now.timeIntervalSince(last)
            let timeout = UserDefaults.standard.double(forKey: "SilenceTimeout")
            if silenceDuration >= timeout {
                NSLog("checkSilence: silence for %.2f s, timeout %.2f s reached, auto-stopping", silenceDuration, timeout)
                // Stop timer and recording
                silenceTimer?.invalidate()
                silenceTimer = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.stopRecording()
                    self.isRecording = false
                }
            }
        }
    }

    func transcribe(fileURL: URL) {
        // Determine endpoint and API key based on service type
        let endpointURL: String
        let apiKey: String
        switch serviceType {
        case .openAI:
            endpointURL = "https://api.openai.com/v1/audio/transcriptions"
            guard let key = openAIKey, !key.isEmpty else {
                NSLog("OpenAI API key not configured")
                return
            }
            apiKey = key
        case .azure:
            guard let ep = azureTranscribeEndpoint, !ep.isEmpty,
                  let key = azureKey, !key.isEmpty else {
                NSLog("Azure endpoint or API key not configured")
                return
            }
            endpointURL = ep
            apiKey = key
        }
        guard let url = URL(string: endpointURL) else {
            NSLog("Invalid transcription endpoint URL: \(endpointURL)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if serviceType == .openAI {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        // Add model param (configurable)
        let params = ["model": transcriptionModel]
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // Add audio file
        let filename = fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // Add prompt if provided
        if !transcriptionPrompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(transcriptionPrompt)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Perform request without streaming
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Always clean up the temp audio file once we've sent it (or failed to)
            // — security/privacy hardening: avoid leaving recordings on disk forever.
            defer { try? FileManager.default.removeItem(at: fileURL) }

            if let error = error {
                NSLog("Transcription error: \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                NSLog("Failed to parse transcription response")
                return
            }
            DispatchQueue.main.async {
                // After transcription: either proofread via GPT-4o or insert raw text
                if self.defaults.bool(forKey: "EnableProofreading") {
                    self.proofreadTranscript(transcript: text)
                } else {
                    self.insertTranscript(text)
                    self.transcribeState = .ready
                }
            }
        }.resume()
    }

    // Handle Option+Shift+S: copy selection and record audio for instruction
    private func handleInstructionHotkey() {
        if !isRecording {
            instructionMode = true
            let pasteboard = NSPasteboard.general
            let prevChangeCount = pasteboard.changeCount
            simulateCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let pb = NSPasteboard.general
            if pb.changeCount > prevChangeCount, let copied = pb.string(forType: .string) {
                self.originalSelectedText = copied
            } else {
                self.originalSelectedText = nil
            }
            self.startRecording()
            self.isRecording = true
            }
        } else if isRecording && instructionMode {
            stopRecording()
            isRecording = false
        }
    }
   

    // MARK: - Status Item Indicator
    /// Draws a filled circle image for the given state.
    private func statusImage(for state: TranscribeState) -> NSImage {
        let diameter: CGFloat = 14
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        let color: NSColor
        switch state {
        case .ready: color = .systemGreen
        case .recording: color = .systemRed
        case .transcribing: color = .systemBlue
        case .error: color = .systemRed
        }
        color.setFill()
        let rect = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Creates the status bar item and sets initial icon.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        configureMenu()
    }

    /// Updates the status bar icon based on current state.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        switch transcribeState {
        case .error:
            if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Not Configured") {
                img.isTemplate = true
                button.image = img
                button.contentTintColor = .systemRed
            }
        default:
            // Clear any tint when showing colored circles
            button.contentTintColor = nil
            button.image = statusImage(for: transcribeState)
        }
    }
    // MARK: - Status Item Menu
    private func configureMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()
        // Settings item
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        if let gearIcon = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings") {
            gearIcon.isTemplate = true
            settingsItem.image = gearIcon
        }
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        // Model submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelSub = NSMenu(title: "Model")
        for m in availableModels {
            let it = NSMenuItem(title: m, action: #selector(selectModel(_:)), keyEquivalent: "")
            it.target = self
            it.state = (m == transcriptionModel ? .on : .off)
            modelSub.addItem(it)
        }
        menu.setSubmenu(modelSub, for: modelItem)
        menu.addItem(modelItem)
        // Prompt
        menu.addItem(NSMenuItem(title: "Set Prompt…", action: #selector(setPrompt(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        // Change Record Hotkey
        let recordHK = NSMenuItem(title: "Change Record Hotkey… (Currently: \(hotKeyDescription(recordHotKey)))", action: #selector(changeRecordHotkey(_:)), keyEquivalent: "")
        recordHK.target = self
        menu.addItem(recordHK)
        // Change Instruction Hotkey
        let instrHK = NSMenuItem(title: "Change Instruction Hotkey… (Currently: \(hotKeyDescription(instructionHotKey)))", action: #selector(changeInstructionHotkey(_:)), keyEquivalent: "")
        instrHK.target = self
        menu.addItem(instrHK)
        // Change Modal Hotkey
        let modalHK = NSMenuItem(title: "Change Modal Hotkey… (Currently: \(hotKeyDescription(modalHotKey)))", action: #selector(changeModalHotkey(_:)), keyEquivalent: "")
        modalHK.target = self
        menu.addItem(modalHK)
        // Change Script Hotkey
        let scriptHK = NSMenuItem(title: "Change Script Hotkey… (Currently: \(hotKeyDescription(scriptHotKey)))", action: #selector(changeScriptHotkey(_:)), keyEquivalent: "")
        scriptHK.target = self
        menu.addItem(scriptHK)
        // Quit
        let quit = NSMenuItem(title: "Quit SpeechCraft", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        transcriptionModel = sender.title
        defaults.set(transcriptionModel, forKey: "TranscriptionModel")
        // update checks
        if let items = statusItem?.menu?.item(withTitle: "Model")?.submenu?.items {
        for it in items { it.state = (it.title == transcriptionModel ? .on : .off) }
        }
    }

    @objc private func setPrompt(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Set Transcription Prompt"
        alert.informativeText = "Enter a custom prompt for the transcription (optional):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = transcriptionPrompt
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            transcriptionPrompt = tf.stringValue
            defaults.set(transcriptionPrompt, forKey: "TranscriptionPrompt")
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    
    // MARK: - HotKey Capture Methods
    @objc func changeRecordHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .record)
    }

    @objc func changeInstructionHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .instruction)
    }
    @objc func changeModalHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .modal)
    }
    @objc func changeScriptHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .script)
    }

    private func beginHotKeyCapture(type: HotKeyCaptureType) {
        captureType = type
        // Inform user
        let alert = NSAlert()
        alert.messageText = "Press desired hotkey"
        alert.informativeText = "Now press the key combination you want to assign."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: NSApp.mainWindow ?? NSWindow()) { _ in }
        // Install local monitor
        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let type = self.captureType else { return event }
            // Filter to modifier bits only
            let maskMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let rawMods = UInt64(event.modifierFlags.intersection(maskMods).rawValue)
            let char = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let hk = HotKey(keyCode: event.keyCode, modifiers: rawMods, character: char)
            switch type {
            case .record:
                self.recordHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "RecordHotKey")
                }
            case .instruction:
                self.instructionHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "InstructionHotKey")
                }
            case .modal:
                self.modalHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "ModalHotKey")
                }
            case .script:
                self.scriptHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "ScriptHotKey")
                }
            }
            self.captureType = nil
            if let monitor = self.keyCaptureMonitor {
                NSEvent.removeMonitor(monitor)
                self.keyCaptureMonitor = nil
            }
            
            self.configureMenu()
            return nil
        }
    }

    // MARK: - Settings
    @objc private func openSettings(_ sender: Any?) {
        if preferencesWindow == nil {
            let contentView = PreferencesView()
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Preferences"
            window.contentViewController = hostingController
            // Keep delegate so we can clear on close
            window.delegate = self
            // Don't auto-release; we manage lifecycle via preferencesWindow property and delegate
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        preferencesWindow?.center()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    // MARK: - Instruction Mode
    private func transcribeInstruction(fileURL: URL) {
        // Transcribe the spoken instruction using stored credentials
        let endpointURL: String
        let authHeader: (String, String)
        switch serviceType {
        case .openAI:
            endpointURL = "https://api.openai.com/v1/audio/transcriptions"
            guard let key = openAIKey, !key.isEmpty else {
                NSLog("OpenAI API key not configured")
                return
            }
            authHeader = ("Authorization", "Bearer \(key)")
        case .azure:
            guard let ep = azureTranscribeEndpoint, !ep.isEmpty,
                  let key = azureKey, !key.isEmpty else {
                NSLog("Azure transcription endpoint or API key not configured")
                return
            }
            endpointURL = ep
            authHeader = ("api-key", key)
        }
        guard let url = URL(string: endpointURL) else {
            NSLog("Invalid transcription endpoint URL: \(endpointURL)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeader.1, forHTTPHeaderField: authHeader.0)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        // Add model param for instruction transcription
        let params = ["model": transcriptionModel]
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        let filename = fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // Add prompt if provided
        if !transcriptionPrompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(transcriptionPrompt)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Always clean up the temp audio file once we've sent it (or failed to)
            // — security/privacy hardening: avoid leaving recordings on disk forever.
            defer { try? FileManager.default.removeItem(at: fileURL) }

            if let error = error {
                NSLog("Instruction transcription error: \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instruction = json["text"] as? String else {
                NSLog("Failed to parse instruction transcription response or instruction missing")
                return
            }
            let original = self.originalSelectedText
            self.callChat(instruction: instruction, text: original ?? "") { result in
                DispatchQueue.main.async {
                    self.insertTranscript(result)
                    self.transcribeState = .ready
                    self.instructionMode = false
                    self.originalSelectedText = nil
                }
            }
        }.resume()
    }

    /// Captures the screen where the cursor is using ScreenCaptureKit and returns a base64-encoded PNG data URI.
    /// Captures a one‐off screenshot of the frontmost application using ScreenCaptureKit
    /// and returns it as a PNG data URI.
    @available(macOS 13.0, *)
    func captureScreenshotDataURI() -> String? {
        // Honor user preference: skip screenshots if disabled
        if !defaults.bool(forKey: "EnableScreenshots") {
            return nil
        }
        // 1) Identify frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            NSLog("captureScreenshotDataURI: no frontmost application")
            return nil
        }

        // 2) Fetch shareable content (only on‐screen windows)
        var shareableContent: SCShareableContent?
        let contentSem = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                NSLog("captureScreenshotDataURI: error fetching content: \(error.localizedDescription)")
            }
            shareableContent = content
            contentSem.signal()
        }
        _ = contentSem.wait(timeout: .now() + 5)

        guard let content = shareableContent else {
            NSLog("captureScreenshotDataURI: no shareable content")
            return nil
        }

        // 3) Exclude every other app’s windows
        let appsToExclude = content.applications.filter { $0.bundleIdentifier != bundleID }

        // 4) Pick a display (we’ll just pick the first one)
        guard let scDisplay = content.displays.first else {
            NSLog("captureScreenshotDataURI: no displays available")
            return nil
        }

        // 5) Build a filter that leaves only the frontmost app’s windows
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: appsToExclude,
            exceptingWindows: []
        )

        // 6) Screenshot configuration
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor  = true

        // 7) Fire off the async screenshot
        var resultURI: String?
        let captureSem = DispatchSemaphore(value: 0)
        Task {
            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                // Downscale if max dimension > 1280px
                let maxSide = max(cgImage.width, cgImage.height)
                let finalCG: CGImage
                if maxSide > 1280 {
                    let scale = 1280.0 / Double(maxSide)
                    let ciSrc = CIImage(cgImage: cgImage)
                    if let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
                        scaleFilter.setValue(ciSrc, forKey: kCIInputImageKey)
                        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
                        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
                        let ciCtx = CIContext()
                        if let outCI = scaleFilter.outputImage,
                           let scaledCG = ciCtx.createCGImage(outCI, from: outCI.extent) {
                            finalCG = scaledCG
                        } else {
                            finalCG = cgImage
                        }
                    } else {
                        finalCG = cgImage
                    }
                } else {
                    finalCG = cgImage
                }
                let bitmap = NSBitmapImageRep(cgImage: finalCG)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let b64 = png.base64EncodedString()
                    resultURI = "data:image/png;base64,\(b64)"
                }
            } catch {
                NSLog("captureScreenshotDataURI: screenshot error: \(error)")
            }
            captureSem.signal()
        }
        _ = captureSem.wait(timeout: .now() + 5)
        return resultURI
    }

    // Chat functions moved to ChatService.swift
}
