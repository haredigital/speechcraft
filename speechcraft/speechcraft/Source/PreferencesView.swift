import SwiftUI
import Cocoa

/// A unified Preferences window with sidebar navigation across settings categories.
struct PreferencesView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case transcription = "Transcription"
        case hotkeys = "Hotkeys"
        var id: Self { self }
    }
    @State private var selection: Tab = .general

    var body: some View {
        NavigationView {
            // Sidebar navigation
            List(selection: $selection) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: iconName(for: tab))
                        .tag(tab)
                }
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 150)

            // Detail pane: fill available space
            detailView(for: selection)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationViewStyle(DoubleColumnNavigationViewStyle())
        // Set a reasonable default width so form fields have room
        .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000, minHeight: 400)
    }

    private func iconName(for tab: Tab) -> String {
        switch tab {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .hotkeys: return "keyboard"
        }
    }

    @ViewBuilder
    private func detailView(for tab: Tab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView()
        case .transcription:
            TranscriptionSettingsView()
        case .hotkeys:
            HotkeysSettingsView()
        }
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    @AppStorage("ServiceType") private var serviceType: String = "OpenAI"
    @AppStorage("OpenAIChatModel") private var openAIChatModel: String = "gpt-3.5-turbo"
    @AppStorage("AzureTranscribeEndpoint") private var azureTranscribeEndpoint: String = ""
    @AppStorage("AzureChatEndpoint") private var azureChatEndpoint: String = ""
    // Auto-stop recording on silence
    @AppStorage("EnableAutoSilenceStop") private var enableAutoSilenceStop: Bool = false
    // Duration of silence (in seconds) before auto-stop
    @AppStorage("SilenceTimeout") private var silenceTimeout: Double = 2.0

    // Hardened: API keys live in Keychain, not UserDefaults.
    // We mirror them into local @State so SwiftUI can bind, and write back
    // to Keychain on every edit via .onChange.
    @State private var openAIKey: String = KeychainStore.get("OpenAIKey") ?? ""
    @State private var azureKey: String = KeychainStore.get("AzureKey") ?? ""

    var body: some View {
        Form {
            Picker("Service", selection: $serviceType) {
                Text("OpenAI").tag("OpenAI")
                Text("Azure").tag("Azure")
            }
            .pickerStyle(RadioGroupPickerStyle())

            if serviceType == "OpenAI" {
                SecureField("API Key", text: $openAIKey)
                    .onChange(of: openAIKey) { newValue in
                        KeychainStore.set(newValue, forKey: "OpenAIKey")
                    }
                Picker("Chat Model", selection: $openAIChatModel) {
                    Text("gpt-4o").tag("gpt-4o")
                    Text("gpt-4o-mini").tag("gpt-4o-mini")
                }
                .pickerStyle(PopUpButtonPickerStyle())
            } else {
                SecureField("API Key", text: $azureKey)
                    .onChange(of: azureKey) { newValue in
                        KeychainStore.set(newValue, forKey: "AzureKey")
                    }
                TextField("Transcribe Endpoint", text: $azureTranscribeEndpoint)
                TextField("Chat Endpoint", text: $azureChatEndpoint)
            }
            Section(header: Text("Silence Detection")) {
                Toggle("Auto-stop recording on silence", isOn: $enableAutoSilenceStop)
                Text("Silence duration")
                Stepper(value: $silenceTimeout, in: 0.5...10.0, step: 0.5) {
                    Text("\(silenceTimeout, specifier: "%.1f") sec")
                }
                .disabled(!enableAutoSilenceStop)
            }
        }
        .padding()
    }
}

// MARK: - Transcription Settings
struct TranscriptionSettingsView: View {
    @AppStorage("TranscriptionModel") private var transcriptionModel: String = "gpt-4o-mini-transcribe"
    @AppStorage("TranscriptionPrompt") private var transcriptionPrompt: String = ""
    // Control for including screenshots in all GPT requests
    @AppStorage("EnableScreenshots") private var enableScreenshots: Bool = true
    // Control for enabling GPT-4o proofreading of transcripts
    @AppStorage("EnableProofreading") private var enableProofreading: Bool = true
    // Model selection for GPT-4o proofreading
    @AppStorage("ProofreadingModel") private var proofreadingModel: String = "gpt-4o"
    private let proofreadingModels = ["gpt-4o", "gpt-4o-mini"]
    private let availableModels = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper"]

    var body: some View {
        Form {
            Picker("Transcription Model", selection: $transcriptionModel) {
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(PopUpButtonPickerStyle())

            TextField("Prompt (optional)", text: $transcriptionPrompt)
            // Screenshot and proofread options
            Toggle("Include screenshots in GPT requests", isOn: $enableScreenshots)
            Toggle("Enable GPT-4o proofreading", isOn: $enableProofreading)
            Picker("Proofreading Model", selection: $proofreadingModel) {
                ForEach(proofreadingModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(PopUpButtonPickerStyle())
            .disabled(!enableProofreading)
        }
        .padding()
    }
}

// MARK: - Hotkeys Settings
struct HotkeysSettingsView: View {
    @State private var recordKeyDesc: String = ""
    @State private var instructionKeyDesc: String = ""
    @State private var modalKeyDesc: String = ""
    @State private var scriptKeyDesc: String = ""

    var body: some View {
        Form {
            HStack {
                Text("Record Hotkey")
                Spacer()
                Text(recordKeyDesc)
                Button("Change") { changeRecordHotkey() }
            }
            HStack {
                Text("Instruction Hotkey")
                Spacer()
                Text(instructionKeyDesc)
                Button("Change") { changeInstructionHotkey() }
            }
            HStack {
                Text("Modal Hotkey")
                Spacer()
                Text(modalKeyDesc)
                Button("Change") { changeModalHotkey() }
            }
            HStack {
                Text("Script Hotkey")
                Spacer()
                Text(scriptKeyDesc)
                Button("Change") { changeScriptHotkey() }
            }
        }
        .padding()
        .onAppear(perform: loadCurrentHotkeys)
    }

    private func loadCurrentHotkeys() {
        if let delegate = NSApp.delegate as? AppDelegate {
            recordKeyDesc      = delegate.hotKeyDescription(delegate.recordHotKey)
            instructionKeyDesc = delegate.hotKeyDescription(delegate.instructionHotKey)
            modalKeyDesc       = delegate.hotKeyDescription(delegate.modalHotKey)
            scriptKeyDesc      = delegate.hotKeyDescription(delegate.scriptHotKey)
        }
    }

    private func changeRecordHotkey() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.changeRecordHotkey(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadCurrentHotkeys()
            }
        }
    }

    private func changeInstructionHotkey() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.changeInstructionHotkey(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadCurrentHotkeys()
            }
        }
    }
    private func changeModalHotkey() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.changeModalHotkey(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadCurrentHotkeys()
            }
        }
    }
    private func changeScriptHotkey() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.changeScriptHotkey(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadCurrentHotkeys()
            }
        }
    }
}
