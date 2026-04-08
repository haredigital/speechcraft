import Cocoa
import SwiftUI
import Combine

/// Observable state driving the floating recording overlay.
/// SwiftUI redraws automatically when `mode` changes.
final class RecordingOverlayState: ObservableObject {
    enum Mode: Equatable {
        case recording
        case transcribing
    }
    @Published var mode: Mode = .recording
}

/// Pill-shaped SwiftUI view shown inside the overlay panel.
/// Dark translucent background with a pulsing status dot and label.
struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseScale)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        pulseScale = 0.55
                    }
                }
            Text(stateText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var stateColor: Color {
        switch state.mode {
        case .recording:
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .transcribing:
            return Color(red: 0.40, green: 0.65, blue: 1.00)
        }
    }

    private var stateText: String {
        switch state.mode {
        case .recording:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        }
    }
}

/// Borderless, non-activating floating panel that shows the current
/// dictation / transcription state. Never steals focus from the frontmost
/// app. Visible on every desktop space including fullscreen apps.
///
/// Why NSPanel (not NSWindow):
/// - `.nonactivatingPanel` style means interacting with it doesn't change
///   the frontmost app. Critical for a dictation indicator — if focusing
///   the overlay changed the frontmost app, Cmd+V would paste transcripts
///   into the wrong place.
///
/// Why `level = .statusBar`:
/// - Floats above the Dock, normal windows, and most floating windows.
///   Only system overlays (notifications, Control Center) sit above us.
///
/// Why `ignoresMouseEvents = true`:
/// - Clicks pass through to the underlying app. The overlay is purely
///   informational — the user should never need to interact with it.
///
/// Why `.fullScreenAuxiliary` collection behavior:
/// - Without this, the overlay disappears when the user enters fullscreen
///   mode in Safari, Xcode, etc. With it, the overlay is visible even in
///   fullscreen apps where dictation is most useful.
final class RecordingOverlayWindow: NSPanel {
    let overlayState = RecordingOverlayState()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        isMovable = false
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: RecordingOverlayView(state: overlayState))
        hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 44)
        contentView = hosting

        // Size the panel to the SwiftUI content's natural fitting size so the
        // pill hugs its text instead of leaving awkward padding.
        let fitting = hosting.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            setContentSize(fitting)
        }

        alphaValue = 0.0
        positionAtBottomCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Positions the overlay horizontally centered and ~30pt above the bottom
    /// of the visible screen area. Sits just above the Dock without floating
    /// awkwardly high in the middle of the screen's lower third.
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let w = frame.size.width
        let h = frame.size.height
        let x = visible.midX - (w / 2)
        let y = visible.minY + 30
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    /// Shows the overlay INSTANTLY (no fade-in animation) to minimize any
    /// perceived latency during dictation startup. Setting `alphaValue = 1.0`
    /// and calling `orderFrontRegardless()` puts the window on screen in the
    /// next render pass — typically 0-16ms depending on where in the refresh
    /// cycle we are. Safe to call while already visible.
    func show(mode: RecordingOverlayState.Mode) {
        overlayState.mode = mode
        if !isVisible {
            positionAtBottomCenter()
            alphaValue = 1.0
            orderFrontRegardless()
        } else {
            // Already visible — ensure alpha is 1 in case a previous hide
            // animation was interrupted.
            alphaValue = 1.0
        }
    }

    /// Updates the mode without affecting visibility. Use this during the
    /// recording → transcribing transition so the overlay smoothly changes
    /// color and label without re-animating in.
    func updateMode(_ mode: RecordingOverlayState.Mode) {
        overlayState.mode = mode
    }

    /// Hides the overlay with a quick fade-out.
    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}
