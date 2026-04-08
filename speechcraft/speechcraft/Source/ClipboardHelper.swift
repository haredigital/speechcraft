import Cocoa
import AVFoundation
import ApplicationServices

extension AppDelegate {

    // MARK: - Speak Selection (TTS)

    /// Toggles speak-selection: if TTS is currently speaking, stop; otherwise
    /// capture the selected text from the frontmost app and start speaking it.
    /// Triggered by a lone Right Command tap (see handleEvent in AppDelegate).
    func toggleSpeakSelection() {
        if speechSynth?.isSpeaking == true {
            speechSynth?.stopSpeaking(at: .immediate)
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

    /// Speaks the given text via AVSpeechSynthesizer using the best available
    /// system voice. Prefers the "Premium" Ava voice introduced in macOS 14+
    /// when installed; otherwise falls back to the default en-US voice.
    private func speak(_ text: String) {
        // Lazily instantiate the synthesizer on first use
        if speechSynth == nil {
            speechSynth = AVSpeechSynthesizer()
        }

        // Stop any in-progress speech before starting new speech
        if speechSynth?.isSpeaking == true {
            speechSynth?.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // Pick the best voice. Premium voices were introduced in macOS Sonoma (14)
        // and sound dramatically better than the classic synthesized voices.
        // Fall back gracefully on older systems or voices the user hasn't downloaded.
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

        // Default rate (0.5) sounds robotic — bump slightly for a more natural cadence
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        NSLog("[SpeechCraft-TTS] speaking \(text.count) characters with voice \(utterance.voice?.identifier ?? "default")")
        speechSynth?.speak(utterance)
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