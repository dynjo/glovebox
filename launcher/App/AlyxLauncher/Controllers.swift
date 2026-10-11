import SwiftUI
import UIKit
import GameController
import ARKit

/// The PS VR2 Sense controllers. The game can't be played without them, so Play waits until both
/// are on and the app may track them, and the page says what's missing in a line.
struct ControllerState: Equatable {
    enum Access: Equatable { case notAsked, allowed, denied }
    /// Sense controllers connected right now (the game needs both).
    var connected = 0
    /// A game controller (DualSense, Xbox, ...) is connected. It supplies buttons and sticks; the
    /// hands, tracked by the headset, supply the poses.
    var gamepad = false
    var access = Access.notAsked
}

/// What stands between the player and Play.
enum ControllerIssue: Equatable {
    case trackingDenied
    case notConnected(Int)
}

extension LauncherModel {
    /// A host with no controllers to check can turn this off. Before visionOS 26 there is no Sense
    /// support, so nothing is checked there either.
    static var requiresControllers = true

    /// Other tracking permissions to ask for together with the controllers' at Play, so every
    /// system dialog appears over the launcher rather than as the game starts (e.g. `.handTracking`
    /// while the game still tracks hands).
    static var alsoAsk: [ARKitSession.AuthorizationType] = []

    private static let arSession = ARKitSession()

    var controllerIssue: ControllerIssue? {
        guard Self.requiresControllers, #available(visionOS 26.0, *) else { return nil }
        // A game controller stands in for the Sense pair, so accessory tracking doesn't matter then.
        if controllers.gamepad && controllers.connected < 2 { return nil }
        if controllers.access == .denied { return .trackingDenied }
        if controllers.connected < 2 { return .notConnected(controllers.connected) }
        return nil
    }

    /// Counts the Sense controllers now and whenever one connects or drops, so Play unlocks by
    /// itself the moment the second one turns on.
    func watchControllers() {
        guard #available(visionOS 26.0, *) else { return }
        countControllers()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let model = self
                MainActor.assumeIsolated { model?.countControllers() }
            }
        }
        refreshControllerAccess()
    }

    @available(visionOS 26.0, *)
    private func countControllers() {
        let all = GCController.controllers()
        controllers.connected = all
            .filter { $0.productCategory == GCProductCategorySpatialController }.count
        controllers.gamepad = all.contains {
            $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil
        }
        NSLog("[launcher] Sense controllers connected: \(controllers.connected), game controller: \(controllers.gamepad)")
    }

    /// The permission as it stands, without asking: at start, and on coming back from Settings.
    func refreshControllerAccess() {
        guard DemoState.current == nil, #available(visionOS 26.0, *) else { return }
        Task {
            let status = await Self.arSession.queryAuthorization(for: [.accessoryTracking])
            controllers.access = .init(status[.accessoryTracking])
        }
    }

    /// Asks for controller tracking if nobody has yet, so the system's dialog appears here, after
    /// Play, rather than as the game starts. False if it's turned off.
    func allowControllerTracking() async -> Bool {
        guard Self.requiresControllers, DemoState.current == nil, #available(visionOS 26.0, *) else { return true }
        // With a game controller the hands supply the poses, so ask for hand tracking instead.
        if controllers.gamepad && controllers.connected < 2 {
            let status = await Self.arSession.requestAuthorization(for: [.handTracking] + Self.alsoAsk)
            return status[.handTracking] != .denied
        }
        let status = await Self.arSession.requestAuthorization(for: [.accessoryTracking] + Self.alsoAsk)
        controllers.access = .init(status[.accessoryTracking])
        return controllers.access != .denied
    }
}

private extension ControllerState.Access {
    init(_ status: ARKitSession.AuthorizationStatus?) {
        switch status {
        case .allowed?: self = .allowed
        case .denied?: self = .denied
        default: self = .notAsked
        }
    }
}

/// In place of the saves line while Play waits: the two controllers (lit when on) and what to do.
struct ControllerStatus: View {
    let issue: ControllerIssue
    let connected: Int

    var body: some View {
        HStack(spacing: 20) {
            SenseControllers(on: connected, waiting: issue != .trackingDenied)
                .overlay(alignment: .bottomTrailing) {
                    if issue == .trackingDenied {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.bold))
                            .padding(6)
                            .background(.orange, in: .circle)
                            .offset(x: 6, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                switch issue {
                case .notConnected(let n):
                    Text(n == 1 ? "Turn on the other controller" : "Turn on both controllers")
                        .font(.title3.weight(.semibold))
                    Text(n == 1 ? "Press its PS button." : "Press the PS button on each.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("First time? Pair them in Settings › Bluetooth. No Sense controllers? A game controller works too, with your hands for aiming.")
                        .font(.callout).foregroundStyle(.tertiary)
                case .trackingDenied:
                    Text("Controller tracking is off")
                        .font(.title3.weight(.semibold))
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: connected)
    }
}

/// Two PS VR2 Sense controllers, drawn: lit when connected, softly pulsing while they're awaited.
struct SenseControllers: View {
    /// How many are on: the left one lights first.
    var on: Int
    var waiting = true
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            SenseController(left: true).foregroundStyle(.white.opacity(level(lit: on >= 1)))
            SenseController(left: false).foregroundStyle(.white.opacity(level(lit: on >= 2)))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever()) { pulse = true }
        }
    }

    private func level(lit: Bool) -> Double {
        if lit { return 1 }
        return waiting && pulse ? 0.5 : 0.2
    }
}

/// One controller: the ring that wraps the back of the hand, over a grip that leans outward.
private struct SenseController: View {
    var left: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Circle()
                .trim(from: 0.14, to: 0.86)
                .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 30, height: 30)
            Capsule()
                .frame(width: 10, height: 26)
                .offset(y: 25)
        }
        .rotationEffect(.degrees(left ? -14 : 14))
        .frame(width: 34, height: 56)
    }
}
