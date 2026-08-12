#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// Sparkle, wrapped just enough for SwiftUI to drive it.
///
/// The updater is configured entirely from the Info.plist keys the build script
/// writes — feed URL, public key, and automatic checking and installing — so
/// there is nothing to configure here. Updates therefore happen without asking:
/// that silence is the whole point of ADR 008 on the Mac, and it is the one
/// thing iOS cannot have.
///
/// `SPUStandardUpdaterController` must outlive the scene, so it is held by an
/// `@StateObject` on the App and never recreated.
@MainActor
final class Updater: ObservableObject {
    /// False while Sparkle is busy or has not finished starting, which is what
    /// the menu item's enabled state is bound to.
    @Published var canCheck = false

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init() {
        // `startingUpdater: true` schedules the background check. The feed is
        // only reachable on the LAN or the VPN, so a failed check is the normal
        // case on the move and Sparkle is left to stay quiet about it.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    /// Check now, showing progress and errors — the menu item, in other words.
    /// The automatic checks are silent; this one is not.
    func checkNow() {
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" item, in the application menu where it is expected.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkNow() }
            .disabled(!updater.canCheck)
    }
}
#endif
