# SpeechCraft (haredigital fork)

<p align="center">
  <img src="icon.png" alt="SpeechCraft Icon" width="128" height="128" />
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![Swift 5.5+](https://img.shields.io/badge/Swift-5.5%2B-orange.svg)](https://swift.org) [![Platform: macOS 12+](https://img.shields.io/badge/macOS-12%2B-lightgrey.svg)](https://www.apple.com/macos)

> A lightweight macOS menu‑bar utility that turns your voice into text and smart edits using the OpenAI API.

> **This is a security-hardened fork of [esawtooth/speechcraft](https://github.com/esawtooth/speechcraft).** See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the full audit of upstream v1.01 and the rationale for every change in this fork.

## Fork Changes (vs. upstream v1.01)

| Fix | Why |
|-----|-----|
| **AppleScript confirmation dialog** | Upstream executes LLM-generated AppleScript directly with no user approval — RCE risk via prompt injection. This fork shows the script and requires explicit "Run Script" click. |
| **Keychain credential storage** | Upstream stored OpenAI/Azure API keys in plain UserDefaults (`.plist`) — readable by any user-process. This fork stores them in macOS Keychain via `KeychainStore.swift` with one-time migration. |
| **Temp audio file cleanup** | Upstream wrote `.wav` files to `temporaryDirectory` and never deleted them, leaving voice recordings on disk forever. This fork uses `defer { removeItem }` after every upload. |
| **Default model: `gpt-4o-mini-transcribe`** | Upstream defaulted to the more expensive `gpt-4o-transcribe`. Mini variant is ~50% cheaper with WER very close to the full model. Switchable in Preferences. |
| **Removed unused camera entitlement** | Upstream declared `device.camera` but never used webcam APIs (uses `ScreenCaptureKit` instead). Eliminates an entire permission category. |

See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the full list of findings, including issues we have NOT yet fixed (sandbox disabled, unvalidated Azure endpoint, no auto-update protection).

## Trust Model

This fork follows a **build-from-source-only** trust model:

1. Clone this repository
2. Open in Xcode and build the app yourself
3. Sign with your own developer cert (or run unsigned)
4. **Do not use prebuilt releases** — they cannot be verified against the source you read

If you trust prebuilt binaries, you might as well use [SuperWhisper](https://superwhisper.com/) — it's a more mature commercial app that also supports `gpt-4o-transcribe` natively.

The whole point of forking and auditing is that **you control which version of the code runs on your Mac**.

## Table of Contents
1. [Features](#features)
2. [Requirements](#requirements)
3. [Getting the App](#getting-the-app)
4. [Installation](#installation)
5. [Configuration](#configuration)
6. [Usage](#usage)
7. [Development](#development)
8. [License](#license)

## Features
- 🔑 **Bring Your Own Key**: You can use your own keys for OpenAI or Azure OpenAI and configure them directly in the app.
- 🎤 **Push‑to‑Talk Transcription**: Start/stop recording with **Option+S**, auto‑paste the transcript.
- ✂️ **Smart Text Transformations**: Copy selection, speak an instruction with **Option+Shift+S**, and replace text via GPT‑4o.
- 📋 **Clipboard Integration**: Seamlessly saves and restores your clipboard.
- 🖼️ **Visual Context**: Optionally include a screenshot for richer prompts (macOS 13+).
  Configure via **Transcription → Include screenshots in GPT requests**.
- 📝 **Proofread Transcripts**: Automatically proofread and clean up your transcriptions with GPT-4o with image context. Yes, you can now dictate code!
- 🔐 **Flexible Deployment**: Supports App Store (sandboxed) or Developer ID (hardened runtime) builds.
- 🚀 **Minimal Footprint**: Runs in the menu bar, no Dock icon.
- 💬 **Modal Chat**: Press **Option+A** to record an audio instruction (optionally with selected text & screenshot), then view the AI’s response in a modal dialog with Copy/Close buttons.
- 🍎 **Script Automation**: Press **Option+D** to copy the current selection (if any) and include a screenshot, record an audio command, then have GPT‑4o generate and execute AppleScript to automate your Mac, with a preview of the script and its execution result.

## Requirements
- macOS 12.0 (Monterey) or later
- Xcode 14 or later (Swift 5.5+)
- An OpenAI or Azure OpenAI subscription

## Getting the App

If you just want to try SpeechCraft, download the latest DMG from the Releases page on GitHub and install it directly. No build tools are required:

https://github.com/esawtooth/SpeechCraft/releases

Developers who wish to build from source can follow the instructions below.

## Installation
1. Clone the repo:
   ```bash
   git clone https://github.com/yourorg/SpeechCraft.git
   cd SpeechCraft
   ```
2. Open the Xcode project:
   ```bash
   open speechcraft/speechcraft/SpeechCraft.xcodeproj
   ```
3. Select the **SpeechCraft** scheme, configure your Team under **Signing & Capabilities**, then **Build** & **Run**.

## Configuration
1. **Entitlements**
   - App Store: Enable **App Sandbox** (allow network, microphone).
   - Outside Store: Disable sandbox, enable **Hardened Runtime**.
2. **Info.plist**
   - `NSMicrophoneUsageDescription`: “Recording audio for transcription”
   - `NSCameraUsageDescription`: “Screen recording for rich context”
   - `LSUIElement`: `YES` (hides Dock icon)
3. **Permissions** (System Settings → Privacy & Security)
   - Grant **Accessibility** & **Microphone** access to SpeechCraft.
4. **Environment Variables** (Xcode Scheme → Run → Arguments → Env Vars)
   ```text
   AZURE_OPENAI_ENDPOINT            = https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_TRANSCRIBE_DEPLOYMENT/audio/transcriptions?api-version=2025-03-01-preview
   AZURE_OPENAI_CHAT_ENDPOINT       = https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_CHAT_DEPLOYMENT/chat/completions?api-version=2025-03-01-preview
   AZURE_OPENAI_KEY                 = <your_api_key>
   ```

## Usage
- **Option+S**: Start/stop voice recording → automatic transcription & paste.
- **Option+Shift+S**: Copy selection → record instruction → GPT‑4o applies changes → replaces text.
- **Option+A**: Start/stop audio instruction recording (captures optional selected text & screenshot) → sends to AI chat → displays the response in a modal dialog with Copy/Close options.
- **Option+D**: Copy selection (if any) & screenshot → record an audio command → GPT‑4o generates and executes AppleScript to automate your Mac tasks → shows the generated script and execution result.

🟢 Ready | 🔴 Recording | 🔵 Processing

## Development
1. Fork the repo and create a feature branch.
2. Open in Xcode, implement your changes.
3. If you have a custom icon (e.g. `icon.png`), you can embed it into your built `.app` by running:
   ```bash
   python3 apply_icon.py /path/to/SpeechCraft.app icon.png
   ```
4. Run & test locally.
5. Submit a pull request with clear commit messages.
6. Ensure SwiftLint and pre‑commit hooks pass.

## License
This project is released under the MIT License. See [LICENSE](LICENSE) for details.
