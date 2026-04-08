import Cocoa
import AVFoundation
import ApplicationServices

extension AppDelegate {

    // MARK: - Services (right-click Read Aloud)

    /// macOS Services entry point: invoked when the user picks
    /// "SpeechCraft: Read Aloud" from a right-click Services menu.
    ///
    /// The selected text arrives on the passed `NSPasteboard` (NOT the
    /// general pasteboard), which is important: we read from here and
    /// DON'T need to save/restore the user's clipboard, because this
    /// pasteboard is scoped to the service invocation.
    ///
    /// Signature is dictated by macOS's service dispatching — the method
    /// name is `speakSelectionService`, and macOS calls it as
    /// `speakSelectionService:userData:error:` via the Objective-C runtime.
    /// The `@objc` attribute makes it visible to Cocoa.
    @objc func speakSelectionService(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text selected to read aloud." as NSString
            return
        }
        // Route through the same dispatcher as Right Command's old TTS
        // behavior — honors the "local" vs "openai" TTSEngine preference
        // and any voice selection the user has configured.
        speak(text)
    }

    // MARK: - Speak Selection (TTS)

    /// Returns true if any TTS engine is currently producing audio, regardless
    /// of whether it's local AVSpeech or OpenAI cloud TTS.
    private var isCurrentlySpeaking: Bool {
        (speechSynth?.isSpeaking == true) || (ttsAudioPlayer?.isPlaying == true)
    }

    /// Stops whichever TTS engine is currently speaking (if any). Also cleans
    /// up any leftover temp audio file from an OpenAI playback.
    private func stopCurrentSpeech() {
        if speechSynth?.isSpeaking == true {
            speechSynth?.stopSpeaking(at: .immediate)
        }
        if ttsAudioPlayer?.isPlaying == true {
            ttsAudioPlayer?.stop()
        }
        ttsAudioPlayer = nil
        if let url = ttsAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            ttsAudioFileURL = nil
        }
    }

    /// Toggles speak-selection: if TTS is currently speaking, stop; otherwise
    /// capture the selected text from the frontmost app and start speaking it.
    /// Triggered by a lone Right Command tap (see handleEvent in AppDelegate).
    func toggleSpeakSelection() {
        if isCurrentlySpeaking {
            stopCurrentSpeech()
            return
        }
        speakCurrentSelection()
    }

    /// Captures the current selection via Cmd+C simulation, then speaks it.
    /// Falls back to whatever is already on the clipboard if no selection is
    /// present. Always restores the user's original clipboard contents when done.
    private func speakCurrentSelection() {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Ask the frontmost app to copy its current selection to the clipboard.
        simulateCopy()

        // The system needs a beat to process the simulated Cmd+C and update the
        // pasteboard. 120ms is conservative but reliable across all apps tested.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let textToSpeak: String?
            if pasteboard.changeCount > previousChangeCount,
               let selection = pasteboard.string(forType: .string),
               !selection.isEmpty {
                // Cmd+C updated the pasteboard — there was a selection
                textToSpeak = selection
            } else if let clip = previousString, !clip.isEmpty {
                // Nothing selected — fall back to existing clipboard contents
                textToSpeak = clip
            } else {
                textToSpeak = nil
            }

            // Restore the user's clipboard to whatever it was before we clobbered it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pasteboard.clearContents()
                if let prev = previousString {
                    pasteboard.setString(prev, forType: .string)
                }
            }

            guard let text = textToSpeak, !text.isEmpty else {
                NSLog("[SpeechCraft-TTS] nothing to speak — no selection and clipboard was empty")
                NSSound.beep()
                return
            }

            self.speak(text)
        }
    }

    /// Speaks the given text using the TTS engine selected in Preferences.
    /// Dispatcher: "local" uses AVSpeechSynthesizer (free, offline, decent quality),
    /// "openai" uses the gpt-4o-mini-tts API (costs ~$0.015/min, requires network,
    /// dramatically better quality). Falls back to local if OpenAI is selected
    /// but the API key is missing or the call fails.
    private func speak(_ text: String) {
        let engine = UserDefaults.standard.string(forKey: "TTSEngine") ?? "local"

        if engine == "openai", let key = openAIKey, !key.isEmpty {
            speakViaOpenAI(text, apiKey: key)
        } else {
            if engine == "openai" {
                NSLog("[SpeechCraft-TTS] OpenAI engine selected but no API key — falling back to local")
            }
            speakLocally(text)
        }
    }

    /// Speaks text via macOS's built-in AVSpeechSynthesizer using the best
    /// available installed voice. Prefers "Premium" neural voices introduced
    /// in macOS Sonoma (14+); falls back progressively to Enhanced voices and
    /// finally the default en-US voice. Runs fully offline, zero cost.
    private func speakLocally(_ text: String) {
        if speechSynth == nil {
            speechSynth = AVSpeechSynthesizer()
        }
        if speechSynth?.isSpeaking == true {
            speechSynth?.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        let preferredVoices = [
            "com.apple.voice.premium.en-US.Ava",
            "com.apple.voice.enhanced.en-US.Ava",
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.voice.enhanced.en-US.Zoe",
            "com.apple.voice.premium.en-US.Evan",
        ]
        for identifier in preferredVoices {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                utterance.voice = voice
                break
            }
        }
        if utterance.voice == nil {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        NSLog("[SpeechCraft-TTS] local speak \(text.count) chars via \(utterance.voice?.identifier ?? "default")")
        speechSynth?.speak(utterance)
    }

    /// Speaks text via OpenAI's gpt-4o-mini-tts model over HTTPS.
    /// Posts to https://api.openai.com/v1/audio/speech with the text and
    /// selected voice, receives MP3 bytes in the response body, writes to
    /// a temp file, and plays via AVAudioPlayer. On any failure (network,
    /// auth, decode) logs the error and falls back to local TTS so the
    /// feature stays useful even when offline.
    ///
    /// Pricing (Apr 2026): $0.60/1M input tokens + $12/1M audio tokens,
    /// approximately $0.015 per minute of generated audio. Typical
    /// selection (100 words, ~20 seconds of speech) costs ~$0.005.
    private func speakViaOpenAI(_ text: String, apiKey: String) {
        let voice = UserDefaults.standard.string(forKey: "TTSOpenAIVoice") ?? "nova"
        let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            NSLog("[SpeechCraft-TTS] failed to encode request body — falling back to local")
            speakLocally(text)
            return
        }
        request.httpBody = bodyData

        NSLog("[SpeechCraft-TTS] openai speak \(text.count) chars with voice \(voice)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[SpeechCraft-TTS] openai network error: \(error.localizedDescription) — falling back to local")
                DispatchQueue.main.async { self.speakLocally(text) }
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let bodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                NSLog("[SpeechCraft-TTS] openai returned \(http.statusCode): \(bodyString) — falling back to local")
                DispatchQueue.main.async { self.speakLocally(text) }
                return
            }

            guard let audioData = data, audioData.count > 0 else {
                NSLog("[SpeechCraft-TTS] openai returned empty audio — falling back to local")
                DispatchQueue.main.async { self.speakLocally(text) }
                return
            }

            // Write MP3 to a temp file and play via AVAudioPlayer.
            // We use a file rather than Data(contentsOf:) because
            // AVAudioPlayer(data:) can fail on some MP3 streams from
            // OpenAI while AVAudioPlayer(contentsOf:) handles them reliably.
            let tmpDir = FileManager.default.temporaryDirectory
            let tmpURL = tmpDir.appendingPathComponent("speechcraft_tts_\(UUID().uuidString).mp3")
            do {
                try audioData.write(to: tmpURL)
            } catch {
                NSLog("[SpeechCraft-TTS] failed to write temp audio file: \(error) — falling back to local")
                DispatchQueue.main.async { self.speakLocally(text) }
                return
            }

            DispatchQueue.main.async {
                do {
                    let player = try AVAudioPlayer(contentsOf: tmpURL)
                    self.ttsAudioPlayer = player
                    self.ttsAudioFileURL = tmpURL
                    player.volume = 1.0
                    player.prepareToPlay()
                    player.play()
                } catch {
                    NSLog("[SpeechCraft-TTS] AVAudioPlayer init failed: \(error) — falling back to local")
                    try? FileManager.default.removeItem(at: tmpURL)
                    self.speakLocally(text)
                }
            }
        }.resume()
    }

    // MARK: - Transcript Insertion


    /// Inserts the given transcript into the frontmost application via paste.
    ///
    /// Automatically prepends a space when the previous insertion didn't end
    /// with whitespace and the new transcript starts with a "content" character
    /// (letter, number, opening bracket, opening quote). This prevents consecutive
    /// dictations from concatenating: "First dictation." + "Second dictation."
    /// becomes "First dictation. Second dictation." instead of
    /// "First dictation.Second dictation.".
    ///
    /// Important: punctuation (period, comma, etc.) at the END of the previous
    /// insert does NOT count as a separator — a period still needs a space after
    /// it before the next word. Only actual whitespace (space, tab, newline)
    /// means "the cursor is at a clean word boundary."
    ///
    /// Conversely, punctuation at the START of the new text (like ",", ".", "?")
    /// does not get a leading space prepended, because those should stick to
    /// the previous word ("hello" + "," → "hello," not "hello ,").
    func insertTranscript(_ transcript: String) {
        var textToInsert = transcript

        // Only true whitespace counts as "already at a word boundary."
        // Punctuation endings (period, comma, etc.) do NOT satisfy this —
        // they end sentences/clauses but still need a space before the next word.
        if !lastInsertedEndedWithWhitespace, let first = transcript.first {
            let startsWithContent = first.isLetter || first.isNumber
                || first == "(" || first == "[" || first == "{"
                || first == "\"" || first == "'"
                || first == "$" || first == "#" || first == "@"
            if startsWithContent {
                textToInsert = " " + transcript
            }
        }

        // Record how this insert ended so the next call can decide.
        // Only actual whitespace characters count — no punctuation.
        if let last = textToInsert.last {
            lastInsertedEndedWithWhitespace = last.isWhitespace || last.isNewline
        } else {
            lastInsertedEndedWithWhitespace = true
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(textToInsert, forType: .string)
        simulatePaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            if let prev = previousString {
                pasteboard.setString(prev, forType: .string)
            }
        }

        // PTT auto-submit: if the previous PTT release armed this flag, fire a
        // Return keypress after the paste has had time to land. 120ms delay
        // matches our other "wait for simulated key event to propagate" hooks.
        // The flag is always cleared here regardless of whether we fire, so a
        // single arm only triggers a single submit.
        if pendingAutoSubmit {
            pendingAutoSubmit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.simulateReturn()
            }
        }
    }

    /// Simulates a Cmd+V paste keystroke.
    func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Simulates a Return / Enter keystroke (not keypad Enter).
    /// Used by the PTT auto-submit feature to press Return after pasting
    /// the transcribed text, so dictated chat messages / form entries can
    /// be submitted in a single press-hold-release motion.
    ///
    /// IMPORTANT: we explicitly clear `flags` to an empty CGEventFlags.
    /// Without this, the Return event can inherit leftover modifier state
    /// from the previous simulatePaste call (which held Cmd down for the
    /// Cmd+V paste) — the target app would then receive Cmd+Return instead
    /// of a plain Return and do the wrong thing (or nothing at all). The
    /// explicit empty-flags override forces the event to go out as a
    /// standalone Return regardless of any lingering CGEvent session state.
    ///
    /// We also use `.privateState` for the event source instead of
    /// `.hidSystemState` so our synthetic events don't share modifier state
    /// with the real hardware event stream — cleaner isolation.
    func simulateReturn() {
        let src = CGEventSource(stateID: .privateState)
        let returnKeyCode: CGKeyCode = 36
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: returnKeyCode, keyDown: true) {
            keyDown.flags = CGEventFlags()
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: returnKeyCode, keyDown: false) {
            keyUp.flags = CGEventFlags()
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Simulates a Cmd+C copy keystroke.
    func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cKeyCode: CGKeyCode = 8
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}