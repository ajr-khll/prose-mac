//  The app: exactly one window, its chrome, and the global keyboard shortcuts.

import ProseCore
import ProseHost
import SwiftUI

@main
struct ProseApp: App {
    @NSApplicationDelegateAdaptor(ProseAppDelegate.self) private var delegate
    @State private var workspace = Workspace(hosting: .enabled)

    var body: some Scene {
        // `Window` rather than `WindowGroup`: exactly one window, and the New
        // Window menu item disappears with it (spec §2, for free — plan §1).
        Window("Prose", id: "prose") {
            WorkspaceView()
                .environment(workspace)
                // SwiftUI keeps a safe area for the titlebar even with
                // `.hiddenTitleBar`. prose's own 40px header *is* that row —
                // it is what the traffic lights sit in — so the content has to
                // reach the top of the window.
                .ignoresSafeArea(.all)
        }
        // The titlebar is transparent and prose draws its own chrome under it,
        // so the content view has to run the full height of the window — the
        // 40px header row is prose's, and the traffic lights float over it.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: CGFloat(Pixels.windowWidth),
            height: CGFloat(Pixels.windowHeight)
        )
        .defaultPosition(.center)
        // spec §2: no window restoration, no persistence of any kind.
        .restorationBehavior(.disabled)
        .commands { ProseCommands(workspace: workspace) }
    }
}

/// Without a bundle a SwiftPM executable launches as an accessory process, so
/// it gets no dock icon and never becomes key. Nothing here is product
/// behaviour; it is what a `.app` wrapper would have declared in its Info.plist.
final class ProseAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        restoreKeyRepeat()
        releaseCloseShortcut()
        reportWebViewFrameChanges()
    }

    /// Holding a key down repeats it, rather than opening the accent palette.
    ///
    /// Press-and-hold is macOS's way of typing `é` from `e`, and AppKit turns it
    /// on for every `NSTextView`. The cost is that holding a key stops
    /// repeating: for a letter with accents the palette opens instead, and for
    /// everything else — backspace, an arrow, a bracket — the keystroke simply
    /// stops after the first, which reads as the field having frozen.
    ///
    /// A composer is for typing prose *to an agent*, where holding backspace to
    /// clear a line is worth more than the palette, so prose takes that trade
    /// the other way round — the same call every code editor on the platform
    /// makes. Registered rather than set, so it stays a default a user can still
    /// override, and scoped to prose rather than written to the global domain.
    private func restoreKeyRepeat() {
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    /// Prints how many times AppKit has resized a web view, once every two
    /// seconds, when `PROSE_FRAME=1` is set.
    ///
    /// plan §2 claims a `WKWebView` in AppKit does not need the re-framing
    /// gpui's plan required on every paint. That is the kind of claim that is
    /// easy to assert and easy to be wrong about, so it is counted: the number
    /// should move when the window or a divider moves, and be perfectly still
    /// otherwise.
    private func reportWebViewFrameChanges() {
        guard ProcessInfo.processInfo.environment["PROSE_FRAME"] == "1" else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                print("PROSE_WEBVIEW_FRAMES \(PaneWebView.frameChanges)")
                fflush(stdout)
            }
        }
    }

    /// spec §12 gives Cmd+W to "close the focused pane", but AppKit hands the
    /// same chord to a window's Close, which would shut the whole window — and
    /// prose has exactly one, so that is a quit. Such an item keeps its place
    /// in the menu; only its key equivalent is given up.
    ///
    /// Matched on the *action* rather than on the chord, which is the whole
    /// point: the first version of this swept every Cmd+W out of the menu bar
    /// and took prose's own "Close Pane" with it, so the chord reached no menu
    /// item at all and fell through to the window. Dumping the built menu at
    /// launch is what found it — `performClose:` is what a window's Close does
    /// and nothing of prose's does, so the selector separates them cleanly.
    @MainActor
    private func releaseCloseShortcut() {
        for menu in NSApp.mainMenu?.items ?? [] {
            for item in menu.submenu?.items ?? []
            where item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalent = ""
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// The second of plan §6.4's three parts: sweep the session table on the
    /// way out, so no agent outlives prose on the ordinary path.
    func applicationWillTerminate(_ notification: Notification) {
        AgentProcess.terminateAll()
        Workspace.directoryToClean.map { try? FileManager.default.removeItem(atPath: $0) }
    }
}

/// spec §12's global shortcuts — the ones that work from either side of the
/// divider.
///
/// These are menu commands rather than a key handler, which is the one place
/// the port is straightforwardly better than the original: gpui had a single
/// flat key-down match *deliberately*, because a keymap's context predicates
/// fought the inline rename field. A real responder chain means the rename
/// field and (later) the composer take plain arrows, Enter and Escape without
/// the window's own shortcuts intercepting them, because none of these claim an
/// unmodified key.
///
/// The pane shortcuts (Cmd+D, Cmd+Shift+D, Cmd+W, Cmd+T, Cmd+Alt+arrows) arrive
/// with the tiling in step 3.
private struct ProseCommands: Commands {
    let workspace: Workspace

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { workspace.zoom(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
            // Both spellings, since a keyboard may report either.
            Button("Zoom In") { workspace.zoom(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { workspace.zoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom Out") { workspace.zoom(by: -1) }
                .keyboardShortcut("_", modifiers: .command)
            Button("Actual Size") { workspace.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Toggle Sidebar") { workspace.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            Button("Split Right") {
                if let pane = workspace.focusedPane { workspace.splitPane(pane, .row) }
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split Down") {
                if let pane = workspace.focusedPane { workspace.splitPane(pane, .column) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            // Asks rather than closes: a pane is an agent session and its
            // transcript, so spec §12's Cmd+W is one keystroke away from
            // throwing both away. The alert lives in `WorkspaceView`.
            Button("Close Pane…") {
                if let pane = workspace.focusedPane { workspace.requestClosePane(pane) }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Turn Into Browser Pane") {
                if let pane = workspace.focusedPane { workspace.setPaneKind(pane, .browser) }
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            // A browser pane's own chords. Each one is a no-op unless the
            // focused pane is a browser, which is why they are written against
            // `workspace.browser(pane)` rather than being enabled and disabled:
            // a menu item that dims as focus moves is noise in a window where
            // focus moves constantly.
            Button("Reload Page") { workspace.focusedBrowser?.reloadOrStop() }
                .keyboardShortcut("r", modifiers: .command)

            // Cmd+L is the one chord that has to work when the pane is *empty*,
            // since a browser pane with no page is exactly when you want the URL
            // field — so it asks for focus rather than assuming it.
            Button("Open Location") { workspace.focusAddressBar() }
                .keyboardShortcut("l", modifiers: .command)

            Button("Back") { workspace.focusedBrowser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { workspace.focusedBrowser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)

            Divider()

            // Moving between panes needs a modifier of its own: from step 5 a
            // focused agent pane holds a caret and the plain arrows belong to
            // it, so the unmodified pair cannot be the only way here.
            Button("Focus Pane Left") { workspace.stepPaneFocus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Pane Right") { workspace.stepPaneFocus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Pane Up") { workspace.stepPaneFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Pane Down") { workspace.stepPaneFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            // From either side of the divider, so moving the tab selection
            // never depends on where focus happens to be.
            Button("Previous Tab") { workspace.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Tab") { workspace.step(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}
