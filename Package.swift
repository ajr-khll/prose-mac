// swift-tools-version: 6.0

import PackageDescription

/// prose, as a package rather than an app target.
///
/// `ProseCore` is deliberately a target of its own and deliberately depends on
/// nothing: plan §9 makes the point that this is what keeps the model's purity
/// honest, because a target with no dependency on SwiftUI *cannot* import it.
/// Everything in it — the split tree, the transcript reducer, the wire protocol,
/// the metrics — is testable without opening a window, which is the property
/// spec §14 identifies as the reason those parts are trustworthy.
let package = Package(
    name: "Prose",
    // plan §0 and §11.2. macOS 15 buys `.pointerStyle`, `ScrollPosition` and
    // `.restorationBehavior` for the app targets that come later; nothing in
    // ProseCore itself needs any of them.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProseCore", targets: ["ProseCore"]),
        .library(name: "ProseAutomation", targets: ["ProseAutomation"]),
        .library(name: "ProseIntegrations", targets: ["ProseIntegrations"]),
        .executable(name: "prose", targets: ["Prose"]),
        .library(name: "ProseHost", targets: ["ProseHost"]),
    ],
    targets: [
        .target(name: "ProseCore"),
        .testTarget(name: "ProseCoreTests", dependencies: ["ProseCore"]),
        // Durable automation stays out of `ProseCore`: recurrence and run
        // state are pure, but the store deliberately links SQLite. Keeping the
        // target separate preserves ProseCore's dependency-free guarantee.
        .target(
            name: "ProseAutomation",
            dependencies: ["ProseCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ProseAutomationTests",
            dependencies: ["ProseAutomation", "ProseCore"]
        ),
        // Third-party connectors. Separate from `ProseHost` because it links
        // `Security` and `Network` for the Keychain and the OAuth loopback,
        // and because the broker's refusals are worth testing without a
        // socket, a window or a provider.
        .target(name: "ProseIntegrations", dependencies: ["ProseCore"]),
        .testTarget(
            name: "ProseIntegrationsTests",
            dependencies: ["ProseIntegrations", "ProseCore"]
        ),
        // The app. SwiftUI for the shell, AppKit dropped in where it earns it
        // (plan §1) — here that is only the window chrome and the background
        // blur; the composer's NSTextView and the browser's WKWebView come in
        // later steps.
        // Processes and the socket. Foundation only — no UI framework, so the
        // handshake and the session table can be tested without a window.
        .target(name: "ProseHost", dependencies: ["ProseCore"]),
        .executableTarget(
            name: "Prose",
            dependencies: ["ProseCore", "ProseHost", "ProseAutomation",
                           "ProseIntegrations"]),
        // The shell's own decisions — which tab a close falls back to, when a
        // rename is abandoned, how a sidebar drag clamps — are logic, not
        // layout, so they are tested like anything else. Everything they rest
        // on (selection stepping, the zoom ladder, nearness, the header inset)
        // is already covered in ProseCoreTests.
        .testTarget(name: "ProseTests", dependencies: ["Prose"]),
        .testTarget(name: "ProseHostTests", dependencies: ["ProseHost"]),
    ]
)
