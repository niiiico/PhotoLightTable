#if !os(macOS)
import SwiftUI
import UIKit

/// The iOS half of ADR 008: notice a new build, offer to install it.
///
/// iOS has no API for an app to update itself, so this is as transparent as it
/// gets — the app finds the build and opens the install link, and the user
/// taps once. `itms-services` hands the manifest to the system, which replaces
/// the app in place; data survives because the bundle identifier and signing
/// team are unchanged.
///
/// macOS gets Sparkle and needs none of this.

/// A build newer than the one running.
struct AvailableUpdate: Identifiable, Equatable {
    let version: String
    let build: Int
    let installURL: URL

    var id: Int { build }
}

@MainActor
final class UpdateCheck: ObservableObject {
    @Published var available: AvailableUpdate?

    /// Matches Sparkle's interval on the Mac, so both platforms notice a
    /// release in about the same time.
    private static let interval: TimeInterval = 3600
    private var lastChecked: Date?

    /// Check unless one succeeded recently. Called on launch and on every
    /// return to the foreground, which would otherwise be far too often.
    func checkIfDue() async {
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.interval { return }
        await check()
    }

    /// Ask the service what the latest build is.
    ///
    /// Every failure is silent. The service is reachable on the LAN and the VPN
    /// only, so being unable to reach it is the ordinary case on cellular — not
    /// something worth interrupting a photo session for.
    func check() async {
        guard let feed = AppBuild.string("LTUpdateCheckURL").flatMap(URL.init(string:)) else { return }

        var request = URLRequest(url: feed)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }

        lastChecked = Date()

        guard payload.build > AppBuild.number,
              let url = URL(string: payload.installURL)
        else {
            available = nil
            return
        }
        available = AvailableUpdate(version: payload.version, build: payload.build, installURL: url)
    }

    /// What `latest.json` carries. Deliberately a subset — the service sends
    /// more, and anything this does not name is something it cannot come to
    /// depend on.
    private struct Payload: Decodable {
        let version: String
        let build: Int
        let installURL: String

        enum CodingKeys: String, CodingKey {
            case version, build
            case installURL = "install_url"
        }
    }
}

private struct UpdateCheckModifier: ViewModifier {
    @StateObject private var check = UpdateCheck()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await check.checkIfDue() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await check.checkIfDue() }
            }
            .alert(item: $check.available) { update in
                Alert(
                    title: Text("LightTable \(update.version) is available"),
                    message: Text("You have \(AppBuild.version) (\(AppBuild.label))."),
                    primaryButton: .default(Text("Install")) {
                        UIApplication.shared.open(update.installURL)
                    },
                    secondaryButton: .cancel(Text("Later"))
                )
            }
    }
}

extension View {
    /// Watch for newer builds and offer to install them.
    func updateCheck() -> some View { modifier(UpdateCheckModifier()) }
}
#endif
