import Cocoa
import SwiftUI
import AVFoundation

extension AppDelegate {
    // MARK: - Modal Chat Handling
    /// Handle Option+A hotkey: record audio then send to LLM and display response.
    func handleModalHotkey() {
        if isRecording && modalMode {
            modalMode = false
            let pb = NSPasteboard.general
            let prevCount = pb.changeCount
            simulateCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let newPB = NSPasteboard.general
                if newPB.changeCount > prevCount,
                   let sel = newPB.string(forType: .string), !sel.isEmpty {
                    self.modalSelectedText = sel
                } else {
                    self.modalSelectedText = nil
                }
                self.stopModalRecording()
            }
        } else {
            modalMode = true
            modalSelectedText = nil
            startModalRecording()
        }
    }

    /// Performs chat completion for the given transcript and optional selected text.
    func performModalChat(transcript: String, selectedText: String?) {
        DispatchQueue.main.async { self.transcribeState = .transcribing }
        let endpoint: String
        let apiKey: String
        switch serviceType {
        case .openAI:
            endpoint = "https://api.openai.com/v1/chat/completions"
            guard let key = openAIKey, !key.isEmpty else { return }
            apiKey = "Bearer \(key)"
        case .azure:
            guard let ep = azureChatEndpoint, let key = azureKey,
                  !ep.isEmpty, !key.isEmpty else { return }
            endpoint = ep
            apiKey = key
        }
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if serviceType == .openAI {
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        // Build payload
        var contentArr: [[String: Any]] = []
        if #available(macOS 13.0, *) {
            if let screenshot = captureScreenshotDataURI() {
                contentArr.append([
                    "type": "image_url",
                    "image_url": ["url": screenshot]
                ])
            }
        }
        if let sel = selectedText, !sel.isEmpty {
            contentArr.append(["type": "text", "text": sel])
        }
        contentArr.append(["type": "text", "text": transcript])
        // System instruction for Markdown formatting
        let systemMsg: [String: Any] = [
            "role": "system",
            "content":
            """
Please format your response in valid Markdown, using explicit newline characters.
For numbered lists, start each item on its own line, for example:
1. First item
2. Second item

For bullet lists, use hyphens, for example:
- First bullet
- Second bullet

Use paragraphs separated by blank lines and horizontal rules as '---'.
"""
        ]
        let userMsg: [String: Any] = ["role": "user", "content": contentArr]
        let messages: [[String: Any]] = [systemMsg, userMsg]
        let payload: [String: Any] = serviceType == .openAI
            ? ["model": openAIChatModel, "messages": messages]
            : ["messages": messages]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        // Send request
        URLSession.shared.dataTask(with: request) { data, _, error in
            var resultText = ""
            if let error = error {
                resultText = "Error: \(error.localizedDescription)"
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let msg = (first["message"] as? [String: Any])?["content"] as? String {
                resultText = msg
            } else {
                resultText = "No response"
            }
            DispatchQueue.main.async {
                self.showModal(resultText)
                self.transcribeState = .ready
            }
        }.resume()
    }

    /// Displays the LLM response in a separate window with Markdown rendering.
    func showModal(_ text: String) {
        if let window = responseWindow {
            window.close()
            responseWindow = nil
        }
        let markdownView = MarkdownResponseView(text: text)
        let host = NSHostingController(rootView: markdownView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.title = "Response"
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        responseWindow = win
    }

    /// Begins modal audio recording.
    func startModalRecording() {
        let tmpDir = FileManager.default.temporaryDirectory
        let filename = "speechcraft_modal_\(Date().timeIntervalSince1970).wav"
        modalAudioURL = tmpDir.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: modalAudioURL!, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            isRecording = true
            DispatchQueue.main.async { self.transcribeState = .recording }
        } catch {
            NSLog("startModalRecording error: \(error)")
        }
    }

    /// Stops modal recording and triggers transcription.
    func stopModalRecording() {
        audioRecorder?.stop()
        isRecording = false
        DispatchQueue.main.async { self.transcribeState = .transcribing }
        guard let url = modalAudioURL else { return }
        getTranscription(of: url) { transcription in
            self.performModalChat(transcript: transcription,
                                  selectedText: self.modalSelectedText)
        }
    }

    /// Transcribes an audio file via GPT or Azure, invokes completion on main thread.
    func getTranscription(of fileURL: URL, completion: @escaping (String) -> Void) {
        let endpointURL: String
        let authHeader: (String, String)
        switch serviceType {
        case .openAI:
            endpointURL = "https://api.openai.com/v1/audio/transcriptions"
            guard let key = openAIKey, !key.isEmpty else { return }
            authHeader = ("Authorization", "Bearer \(key)")
        case .azure:
            guard let ep = azureTranscribeEndpoint, let key = azureKey else { return }
            endpointURL = ep
            authHeader = ("api-key", key)
        }
        guard let url = URL(string: endpointURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeader.1, forHTTPHeaderField: authHeader.0)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let modelName = transcriptionModel
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(modelName)\r\n".data(using: .utf8)!)
        if let data = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            let fname = fileURL.lastPathComponent
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fname)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, _, error in
            // Always clean up the temp audio file once we've sent it (or failed to)
            // — security/privacy hardening: avoid leaving recordings on disk forever.
            defer { try? FileManager.default.removeItem(at: fileURL) }

            var text = ""
            if let err = error {
                NSLog("getTranscription error: \(err)")
            } else if let d = data,
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let t = json["text"] as? String {
                text = t
            }
            DispatchQueue.main.async { completion(text) }
        }.resume()
    }

    // MARK: - Script Chat Handling
    /// Handle Option+D hotkey: record audio then generate AppleScript and execute.
    func handleScriptHotkey() {
        if isRecording && scriptMode {
            scriptMode = false
            let pb = NSPasteboard.general
            let prevCount = pb.changeCount
            simulateCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let newPB = NSPasteboard.general
                if newPB.changeCount > prevCount,
                   let sel = newPB.string(forType: .string), !sel.isEmpty {
                    self.scriptSelectedText = sel
                } else {
                    self.scriptSelectedText = nil
                }
                self.stopScriptRecording()
            }
        } else {
            scriptMode = true
            scriptSelectedText = nil
            startScriptRecording()
        }
    }

    /// Begins script audio recording.
    func startScriptRecording() {
        let tmpDir = FileManager.default.temporaryDirectory
        let filename = "speechcraft_script_\(Date().timeIntervalSince1970).wav"
        scriptAudioURL = tmpDir.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: scriptAudioURL!, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            isRecording = true
            DispatchQueue.main.async { self.transcribeState = .recording }
        } catch {
            NSLog("startScriptRecording error: \(error)")
        }
    }

    /// Stops script recording and triggers transcription.
    func stopScriptRecording() {
        audioRecorder?.stop()
        isRecording = false
        DispatchQueue.main.async { self.transcribeState = .transcribing }
        guard let url = scriptAudioURL else { return }
        getTranscription(of: url) { transcription in
            self.performScriptAction(transcript: transcription,
                                     selectedText: self.scriptSelectedText)
        }
    }

    /// Generates AppleScript via LLM and executes it.
    func performScriptAction(transcript: String, selectedText: String?) {
        DispatchQueue.main.async { self.transcribeState = .transcribing }
        let endpoint: String
        let apiKey: String
        switch serviceType {
        case .openAI:
            endpoint = "https://api.openai.com/v1/chat/completions"
            guard let key = openAIKey, !key.isEmpty else { return }
            apiKey = "Bearer \(key)"
        case .azure:
            guard let ep = azureChatEndpoint, let key = azureKey,
                  !ep.isEmpty, !key.isEmpty else { return }
            endpoint = ep
            apiKey = key
        }
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if serviceType == .openAI {
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        // Build payload with screenshot, selected text, and transcript
        var contentArr: [[String: Any]] = []
        if #available(macOS 13.0, *) {
            if let screenshot = captureScreenshotDataURI() {
                contentArr.append([
                    "type": "image_url",
                    "image_url": ["url": screenshot]
                ])
            }
        }
        if let sel = selectedText, !sel.isEmpty {
            contentArr.append(["type": "text", "text": sel])
        }
        contentArr.append(["type": "text", "text": transcript])
        // System prompt for AppleScript generation
        let systemMsg: [String: Any] = [
            "role": "system",
            "content": UserDefaults.standard.string(forKey: "ScriptPrompt") ?? ""
        ]
        let userMsg: [String: Any] = ["role": "user", "content": contentArr]
        let messages: [[String: Any]] = [systemMsg, userMsg]
        let payload: [String: Any] = serviceType == .openAI
            ? ["model": openAIChatModel, "messages": messages]
            : ["messages": messages]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, _, error in
            var scriptCode = ""
            if let error = error {
                NSLog("Script generation error: \(error.localizedDescription)")
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let msg = (first["message"] as? [String: Any])?["content"] as? String {
                scriptCode = msg
            }
            // Log generated AppleScript (will require user approval before execution)
            NSLog("Generated AppleScript (pending approval): \(scriptCode)")
            // Prepare script for execution (strip fences)
            var execCode = scriptCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if execCode.hasPrefix("```") , let nl = execCode.firstIndex(of: "\n") {
                execCode = String(execCode[execCode.index(after: nl)...])
            }
            if execCode.hasSuffix("```") {
                execCode = String(execCode.dropLast(3))
            }
            execCode = execCode.trimmingCharacters(in: .whitespacesAndNewlines)

            // SECURITY GATE: never execute LLM-generated AppleScript without explicit
            // user approval. The script is shown in a confirmation dialog and will
            // only run if the user clicks "Run Script". This prevents prompt-injection
            // attacks via the audio transcription path from achieving arbitrary code
            // execution on the user's Mac. See SECURITY_AUDIT.md Finding 1.
            DispatchQueue.main.async {
                let approved = self.confirmAppleScriptExecution(execCode)
                if !approved {
                    NSLog("AppleScript execution cancelled by user")
                    let cancelMd = """
### Generated AppleScript (NOT executed)

```applescript
\(scriptCode)
```

> Cancelled by user. The script was not run on your Mac.
"""
                    self.showModal(cancelMd)
                    self.transcribeState = .ready
                    return
                }

                NSLog("Executing AppleScript: \(execCode)")
                // Execute and capture result or error
                var resultString = ""
                if let appleScript = NSAppleScript(source: execCode) {
                    var errDict: NSDictionary?
                    let descriptor = appleScript.executeAndReturnError(&errDict)
                    if let err = errDict as? [String: Any] {
                        // Show AppleScript error in result
                        NSLog("AppleScript execution error: \(err)")
                        if let msg = err[NSAppleScript.errorMessage] as? String {
                            resultString = "Error: \(msg)"
                        } else {
                            resultString = "Error: \(err)"
                        }
                    } else {
                        // No error, capture descriptor value
                        resultString = descriptor.stringValue ?? ""
                    }
                }
                let fullMd = """
### Generated AppleScript

```applescript
\(scriptCode)
```

### Execution Result

```
\(resultString)
```
"""
                self.showModal(fullMd)
                self.transcribeState = .ready
            }
        }.resume()
    }

    /// Show a modal confirmation dialog with the generated AppleScript and let the user
    /// approve or cancel execution. Returns true if approved, false if cancelled.
    /// Defaults to Cancel for safety — user must explicitly click Run Script.
    private func confirmAppleScriptExecution(_ scriptCode: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Approve AppleScript execution?"
        alert.informativeText = """
SpeechCraft generated this AppleScript from your spoken instruction. Review it carefully — AppleScript can control any app on your Mac, including destructive operations like deleting files or sending emails.

Only click "Run Script" if the code below matches what you intended.
"""
        alert.alertStyle = .warning

        // Cancel is the default (safer); Run Script requires explicit choice
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run Script")

        // Show the script in a scrollable text view as the alert's accessory view
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = scriptCode
        textView.isEditable = false
        textView.font = NSFont.userFixedPitchFont(ofSize: 12)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        alert.accessoryView = scrollView

        let response = alert.runModal()
        // First button (Cancel) returns .alertFirstButtonReturn,
        // Second button (Run Script) returns .alertSecondButtonReturn
        return response == .alertSecondButtonReturn
    }
    
    // MARK: - Window Delegate Cleanup
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win == responseWindow { responseWindow = nil }
        if win == preferencesWindow { preferencesWindow = nil }
    }
}
