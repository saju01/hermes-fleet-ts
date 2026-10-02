import SwiftUI
import UIKit
import FleetCore

/// Full-screen Bot Desktop viewer: live RFB frame, Watch / Take control /
/// Hand back, touch → pointer events and an iOS keyboard → key events.
/// Input is only sent while this viewer holds the lease (the gateway's
/// rfb_filter drops it otherwise anyway).
public struct DisplayTakeoverView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: DisplayViewerModel
    @State private var keyboardActive = false
    @State private var dragButtons: UInt8 = 0

    public init(model: DisplayViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let frame = model.frame {
                        let fitted = fittedRect(container: geo.size)
                        Image(frame, scale: 1, label: Text("Bot desktop screen"))
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                            .accessibilityLabel("Bot desktop screen")
                            .accessibilityIdentifier("simple.takeover.frame")
                    } else {
                        stateOverlay
                    }
                    if model.canSendInput {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(FleetTheme.statusNeedsIntervention, lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(pointerGesture(container: geo.size))
            }
            KeyboardCapture(active: $keyboardActive,
                            onText: { model.sendText($0) },
                            onBackspace: { model.sendKeysym(RFBKeysym.backspace) })
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: model.canSendInput) { _, canSend in
            if !canSend { keyboardActive = false }
        }
    }

    private var header: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Button("Done") {
                model.close()
                dismiss()
            }
            .accessibilityIdentifier("simple.takeover.done")
            Spacer()
            Text(statusText)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(model.canSendInput ? FleetTheme.statusNeedsIntervention : theme.textSecondary)
                .accessibilityIdentifier("simple.takeover.status")
            Spacer()
            if model.canSendInput {
                Button {
                    keyboardActive.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Keyboard")
                .accessibilityIdentifier("simple.takeover.keyboard")
                Button("Hand back") { model.handBack() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("simple.takeover.handback")
            } else {
                Button("Take control") { model.takeControl() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .watching)
                    .accessibilityIdentifier("simple.takeover.takecontrol")
            }
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .background(theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.takeover")
    }

    private var statusText: String {
        switch model.phase {
        case .idle, .observing, .connecting: "Connecting…"
        case .watching: "Watching"
        case .acquiring: "Taking control…"
        case .controlling: "You're in control"
        case .releasing: "Handing back…"
        case .ended(let reason):
            switch reason {
            case .closedByUser: "Closed"
            case .desktopGone: "Desktop stopped"
            case .notAllowed: "Not allowed"
            case .ticketRejected: "Session expired"
            case .failed(let m): m
            }
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        if case .ended = model.phase {
            VStack(spacing: FleetTheme.spacingSm) {
                Text(statusText).foregroundStyle(.white)
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
                Button("Reconnect") { model.watch() }
                    .accessibilityIdentifier("simple.takeover.reconnect")
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    /// Aspect-fit rect of the framebuffer inside the container.
    private func fittedRect(container: CGSize) -> CGRect {
        let fb = model.frameSize
        guard fb.width > 0, fb.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / fb.width, container.height / fb.height)
        let size = CGSize(width: fb.width * scale, height: fb.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func framebufferPoint(_ p: CGPoint, container: CGSize) -> (Int, Int)? {
        let rect = fittedRect(container: container)
        guard rect.contains(p), model.frameSize.width > 0 else { return nil }
        let x = (p.x - rect.minX) / rect.width * model.frameSize.width
        let y = (p.y - rect.minY) / rect.height * model.frameSize.height
        return (Int(x), Int(y))
    }

    /// Tap = left click; drag = press-move-release with button 1.
    private func pointerGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.canSendInput, let (x, y) = framebufferPoint(value.location, container: container) else { return }
                dragButtons = 1
                model.sendPointer(x: x, y: y, buttons: 1)
            }
            .onEnded { value in
                guard model.canSendInput, let (x, y) = framebufferPoint(value.location, container: container) else {
                    dragButtons = 0
                    return
                }
                dragButtons = 0
                model.sendPointer(x: x, y: y, buttons: 0)
            }
    }
}

/// A first-responder `UIKeyInput` view so the system keyboard drives RFB
/// key events (characters → keysyms, backspace → BackSpace).
struct KeyboardCapture: UIViewRepresentable {
    @Binding var active: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = onText
        view.onBackspace = onBackspace
        view.accessibilityIdentifier = "simple.takeover.keyinput"
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onBackspace = onBackspace
        if active, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !active, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    final class KeyInputView: UIView, UIKeyInput {
        var onText: ((String) -> Void)?
        var onBackspace: (() -> Void)?
        var hasText: Bool { true }
        override var canBecomeFirstResponder: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        func insertText(_ text: String) { onText?(text) }
        func deleteBackward() { onBackspace?() }
    }
}
