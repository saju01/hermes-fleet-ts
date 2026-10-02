import SwiftUI
import FleetCore

/// Drives one Bot Desktop viewer: thumbnail polling for the browser card,
/// then the live RFB stream with Watch / Take control / Hand back.
///
/// All protocol decisions live in the pure `DisplayViewerMachine` and
/// `RFBClientSession` (FleetCore); this type only performs their effects.
@MainActor
@Observable
public final class DisplayViewerModel {
    public private(set) var machine = DisplayViewerMachine()
    public private(set) var thumbnail: CGImage?
    public private(set) var thumbnailSuppressed: String?
    public private(set) var frame: CGImage?
    public private(set) var frameSize: CGSize = .zero
    public private(set) var errorMessage: String?
    public private(set) var desktopStatus: DisplayStatusSnapshot?

    public var phase: DisplayViewerPhase { machine.phase }
    public var canSendInput: Bool { machine.canSendInput }

    private let display: any BotDisplayProviding
    private let profile: String?
    private var rfb = RFBClientSession()
    private var stream: (any DisplayByteStream)?
    private var receiveTask: Task<Void, Never>?
    private var pendingObservation: DisplayObservation?

    public init(display: any BotDisplayProviding, profile: String?) {
        self.display = display
        self.profile = profile
    }

    // MARK: Card thumbnail

    public func refreshThumbnail() async {
        do {
            let thumb = try await display.thumbnail(profile: profile)
            thumbnailSuppressed = thumb.suppressed
            if let data = thumb.imageData, let image = Self.decodeImage(data) {
                thumbnail = image
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: Viewer intents

    public func watch() { perform(machine.start(takeControl: false)) }
    public func startInControl() { perform(machine.start(takeControl: true)) }
    public func takeControl() { perform(machine.requestControl()) }
    public func handBack() { perform(machine.requestHandBack()) }
    public func close() { perform(machine.close()) }

    // MARK: Input (dropped unless this viewer holds the lease)

    public func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard canSendInput else { return }
        send(RFBClientSession.pointerEvent(x: x, y: y, buttons: buttons))
    }

    public func sendKeysym(_ keysym: UInt32) {
        guard canSendInput else { return }
        send(RFBClientSession.keyEvent(keysym: keysym, down: true) + RFBClientSession.keyEvent(keysym: keysym, down: false))
    }

    public func sendText(_ text: String) {
        for character in text {
            for keysym in RFBKeysym.forCharacter(character) { sendKeysym(keysym) }
        }
    }

    // MARK: Effects

    private func perform(_ effects: [DisplayViewerEffect]) {
        for effect in effects {
            switch effect {
            case .observe(let viewerID):
                Task { await self.runObserve(viewerID: viewerID) }
            case .openStream:
                Task { await self.runOpenStream() }
            case .acquire(let viewerID):
                Task { await self.runLease(acquire: true, viewerID: viewerID) }
            case .release(let viewerID):
                Task { await self.runLease(acquire: false, viewerID: viewerID) }
            case .closeStream:
                teardownStream()
            }
        }
    }

    private func runObserve(viewerID: String?) async {
        teardownStream()
        do {
            let observation = try await display.observe(profile: profile, viewerID: viewerID)
            desktopStatus = observation.status
            pendingObservation = observation
            errorMessage = nil
            perform(machine.observed(viewerID: observation.viewerID))
        } catch {
            errorMessage = Self.describe(error)
            perform(machine.failed(errorMessage ?? "observe failed"))
        }
    }

    private func runOpenStream() async {
        guard let observation = pendingObservation else { return }
        pendingObservation = nil
        do {
            let stream = try await display.openStream(observation)
            self.stream = stream
            rfb = RFBClientSession()
            receiveTask = Task { [weak self] in await self?.receiveLoop(stream) }
        } catch {
            perform(machine.streamClosed(code: Self.closeCode(error)))
        }
    }

    private func receiveLoop(_ stream: any DisplayByteStream) async {
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                guard !Task.isCancelled else { return }
                self.stream = nil
                perform(machine.streamClosed(code: Self.closeCode(error)))
                return
            }
            do {
                let (events, outbound) = try rfb.receive(chunk)
                if !outbound.isEmpty { try? await stream.send(outbound) }
                for event in events { handle(event) }
            } catch {
                errorMessage = "Desktop stream error: \(error)"
                perform(machine.failed(errorMessage ?? "stream error"))
                return
            }
        }
    }

    private func handle(_ event: RFBClientSession.Event) {
        switch event {
        case .ready(let width, let height, _):
            frameSize = CGSize(width: width, height: height)
            perform(machine.streamReady())
        case .resized(let width, let height):
            frameSize = CGSize(width: width, height: height)
        case .framebufferUpdated:
            frame = Self.makeImage(rfb.framebuffer)
        case .bell, .serverCutText:
            break
        }
    }

    private func runLease(acquire: Bool, viewerID: String) async {
        do {
            let lease = acquire
                ? try await display.acquireLease(profile: profile, viewerID: viewerID, reason: "Hermes Fleet takeover")
                : try await display.releaseLease(profile: profile, viewerID: viewerID)
            perform(machine.leaseResult(lease))
        } catch {
            errorMessage = Self.describe(error)
            perform(machine.leaseFailed())
        }
    }

    private func send(_ data: Data) {
        guard let stream else { return }
        Task { try? await stream.send(data) }
    }

    private func teardownStream() {
        receiveTask?.cancel()
        receiveTask = nil
        if let stream {
            self.stream = nil
            Task { await stream.close() }
        }
    }

    // MARK: Helpers

    static func closeCode(_ error: any Error) -> Int? {
        if case BotDisplayError.streamClosed(let code) = error { return code }
        return nil
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case BotDisplayError.notConnected: "Not connected to the gateway."
        case BotDisplayError.unavailable(let m), BotDisplayError.rpcFailed(let m): m
        case BotDisplayError.streamClosed(let code): "Desktop stream closed\(code.map { " (\($0))" } ?? "")."
        default: ConversationViewModel.nonSecret(error)
        }
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.cgImage
    }

    /// BGRX bytes → CGImage (32-bit little-endian, alpha skipped).
    static func makeImage(_ fb: RFBFramebuffer) -> CGImage? {
        guard fb.width > 0, fb.height > 0,
              let provider = CGDataProvider(data: Data(fb.pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: fb.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
