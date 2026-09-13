//  The three things about this window that SwiftUI has no API for, plus the
//  blur behind everything.
//
//  plan §1: the shell is SwiftUI and AppKit is dropped in only where it earns
//  it. `standardWindowButton(_:)` positioning and `collectionBehavior` have no
//  declarative equivalent, so they are reached through a representable that
//  does nothing but find the window.

import AppKit
import ProseCore
import SwiftUI

/// Applies spec §2's window chrome once the view is in a window.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class ChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        configure(window)

        // macOS re-lays the titlebar out on its own schedule — a resize, a
        // change of key state — and puts the buttons back where it wants them.
        // Re-applying on both is cheaper than fighting the layout pass, and it
        // is the only part of this that is not a one-shot setting.
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { positionTrafficLights(in: window) }
            }
        }
    }

    private func configure(_ window: NSWindow) {
        // The titlebar is transparent and prose draws its own chrome under it,
        // so the traffic lights float over the app's own header row.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // macOS blurs what is behind the window (the NSVisualEffectView below)
        // and prose paints one translucent wash over that, so the window itself
        // must not paint an opaque ground underneath both.
        window.isOpaque = false
        window.backgroundColor = .clear

        window.minSize = NSSize(
            width: CGFloat(Pixels.windowMinWidth),
            height: CGFloat(Pixels.windowMinHeight)
        )

        // The green button is forced back to Zoom — fill the screen, keep the
        // menu bar — rather than Enter Full Screen. This also disables the
        // Window-menu item and its shortcut, which is the point: prose is one
        // window and full screen would hide the traffic lights its whole header
        // row is aligned to.
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenNone)

        positionTrafficLights(in: window)
        reportFrame(of: window)
    }
}

/// Puts the close button's top-left at spec §2's (17, 13), in real pixels.
///
/// The three buttons keep the system's own spacing: only the group is moved, so
/// prose is choosing where the lights sit, not how far apart they are.
@MainActor
private func positionTrafficLights(in window: NSWindow) {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
    guard let container = buttons.first?.superview else { return }

    let leftmost = buttons.map(\.frame.minX).min() ?? 0
    for button in buttons {
        let offset = button.frame.minX - leftmost
        button.setFrameOrigin(
            NSPoint(
                x: CGFloat(Pixels.trafficLights.x) + offset,
                // AppKit's origin is bottom-left and spec §2 measures from the
                // top, so the y is subtracted from the titlebar's own height.
                y: container.bounds.height - CGFloat(Pixels.trafficLights.y) - button.frame.height
            )
        )
    }
}

/// Prints the window's frame in screen pixels, top-left origin, when
/// `PROSE_FRAME=1` is set.
///
/// Purely a measurement affordance: spec §5's acceptance table has to be
/// re-measured with `screencapture` after any layout change, and an agent
/// cannot click this window into a known position. Printing the frame lets a
/// capture be cropped to exactly the window. It does nothing without the
/// variable and is not product behaviour.
@MainActor
private func reportFrame(of window: NSWindow) {
    guard ProcessInfo.processInfo.environment["PROSE_FRAME"] == "1" else { return }
    guard let primary = NSScreen.screens.first else { return }

    let frame = window.frame
    let top = primary.frame.height - frame.maxY
    print("PROSE_FRAME \(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height))")
    print("PROSE_WINDOW \(window.windowNumber)")
    print("PROSE_STATE visible=\(window.isVisible) key=\(window.isKeyWindow) alpha=\(window.alphaValue) screen=\(window.screen?.frame.origin.debugDescription ?? "nil")")
    fflush(stdout)
}

/// The system blur behind the whole window.
///
/// Replaces the hand-painted translucent wash: macOS blurs whatever is behind
/// the window and prose paints one `windowBG` wash over the result (spec §4).
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BlurredView()
        // A *colourless* semantic material. The obvious choice,
        // `.underWindowBackground`, is one of AppKit's opinionated frosted
        // grounds: it carries its own heavy tint, and stacking `windowBG` on
        // top of it buries the desktop instead of veiling it. `.selection`
        // adds the least colour of any material, which is why gpui picked it
        // too — prose wants the blur and nothing else, because the one wash
        // over it is the whole design (spec §4).
        view.material = .selection
        view.blendingMode = .behindWindow
        // `.followsWindowActiveState` would drop the blur when the window is
        // not key, and prose's whole surface is built on it being there.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// An `NSVisualEffectView` with AppKit's decoration stripped out of its layers.
///
/// Even a colourless material arrives dressed: AppKit tints the blur towards
/// the desktop behind it and boosts its saturation, both of which fight a
/// single flat wash — the desktop tint makes the window's colour drift as it
/// moves across the screen, and the saturation boost makes whatever is behind
/// it bleed through more strongly than `windowBG`'s alpha says it should.
///
/// Undoing them is layer surgery rather than API, so this is a direct port of
/// what gpui does (`platform/mac/window.rs`, `remove_layer_background`) and the
/// reason prose's translucency looked the way it did. The work has to happen in
/// `updateLayer` because AppKit rebuilds these layers — on appearance changes,
/// on display changes — and would otherwise quietly dress them again.
private final class BlurredView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        if let layer { Self.strip(layer) }
    }

    private static func strip(_ layer: CALayer) {
        layer.backgroundColor = nil

        // The desktop tinting effect: a layer that samples the wallpaper and
        // washes the blur with it.
        if layer.className == "CAChameleonLayer" {
            layer.isHidden = true
            return
        }

        // The increased saturation. A filter's effect is determined by its
        // name, and its `description` reflects that name — currently a
        // `CAFilter` called "colorSaturate". Matching on "Saturat" keeps
        // working if AppKit switches to a `CIFilter`, whose description
        // carries "inputSaturation" instead.
        if let filters = layer.filters {
            layer.filters = filters.filter { filter in
                !String(describing: filter).contains("Saturat")
            }
        }

        layer.sublayers?.forEach(strip)
    }
}
