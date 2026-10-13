import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    @Published var mode = "Starting"
    @Published var detail = ""
    @Published var transcript = ""
    @Published var held = false
    @Published var muted = false
    @Published var enrolled = false
    /// Text for the user to read aloud, shown in an expanded panel.
    @Published var prompt = ""
    var onQuit: (() -> Void)?
    var onLearnVoice: (() -> Void)?
    var onToggleMute: (() -> Void)?
}

/// A floating status panel that never takes keyboard focus. Its buttons accept clicks without
/// activating Keyless, so the app being dictated into keeps focus.
@MainActor
final class OverlayPanel {
    let model = OverlayModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
        // orderFrontRegardless shows the panel without activating Keyless or moving focus.
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        let height: CGFloat = expanded ? 190 : 64
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.mode).font(.system(size: 13, weight: .semibold))
                if !model.detail.isEmpty {
                    Text(model.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !model.enrolled {
                    Button { model.onLearnVoice?() } label: { Image(systemName: "person.wave.2") }
                        .buttonStyle(.borderless)
                        .help("Learn my voice, so only I can give commands")
                }
                Button { model.onToggleMute?() } label: {
                    Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.borderless)
                .help(model.muted ? "Unmute microphone" : "Mute microphone (turns off voice wake)")
                Button { model.onQuit?() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Quit Keyless")
            }
            if !model.prompt.isEmpty {
                Text(model.prompt)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.system(size: 12))
                    .foregroundStyle(model.held ? .orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
