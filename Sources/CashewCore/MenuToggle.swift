import AppKit

/// The metrics and colour rules behind `MenuToggleView`, kept separate so they can be checked
/// without a menu on screen.
enum MenuToggle {
    /// Close to the switch macOS draws in a Settings pane, scaled down to sit on a menu row without
    /// forcing the row taller than a line of menu text.
    static let size = NSSize(width: 33, height: 16)

    /// A capsule rather than a circle — a touch wider than tall, which is what modern macOS draws.
    static let knobSize = NSSize(width: size.height - 4 + 3, height: size.height - 4)

    /// How far the knob's edge sits from the track's, at rest at either end.
    private static let inset: CGFloat = 2

    static func knobCenter(isOn: Bool) -> CGPoint {
        let half = knobSize.width / 2
        return CGPoint(x: isOn ? size.width - half - inset : half + inset, y: size.height / 2)
    }

    /// The track fill.
    ///
    /// On is the user's accent colour, which carries its own light/dark behaviour — so it is
    /// deliberately not branched on `dark`. Picking an accent per appearance would be picking one
    /// for the user, and that is theirs to set.
    ///
    /// Off is where the care is needed, for two separate reasons. The system's own faint "off" grey
    /// is close to invisible on a light menu, and — the one that actually renders wrong rather than
    /// merely dim — a dynamic `NSColor` handed to CoreAnimation as `.cgColor` resolves against
    /// whatever appearance happens to be current at that instant, which during menu construction is
    /// not reliably the menu's. Latching the light variant onto a dark menu is survivable; latching
    /// the dark one onto a light menu is a white track on a white background. So the caller resolves
    /// the appearance it is actually drawing in and the colour is built from an explicit black or
    /// white, never from a catalogue entry that could resolve later.
    static func trackColor(isOn: Bool, dark: Bool, hovered: Bool) -> NSColor {
        guard !isOn else {
            let accent = NSColor.controlAccentColor
            guard hovered else { return accent }
            return accent.blended(withFraction: 0.10, of: .white) ?? accent
        }
        return NSColor(white: dark ? 1.0 : 0.0,
                       alpha: (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0))
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// A switch that works inside an `NSMenu`.
///
/// Adapted from `m1ckc3s/claude-status-bar` (MIT), which worked out the two things that make this
/// harder than dropping in a control:
///
/// **`NSSwitch` cannot be used here.** A menu is a vibrant, non-key window, and AppKit draws a
/// control's accent as the inactive grey in one — so a switch that is on looks identical to one that
/// is off. The track and knob are therefore `CALayer`s with the accent filled in explicitly.
///
/// **The animation has to be CoreAnimation, not a timer.** A menu runs its own modal tracking loop,
/// so timer-driven redraws stall for as long as the menu is up — which is the entire time anyone can
/// see this control. CA animations run in the render server and play regardless, which is what lets
/// the knob actually slide under the cursor that just clicked it.
///
/// Clicking it does *not* dismiss the menu, unlike every command in this app's dropdown. That is the
/// point of the control rather than a side effect: settings are things you change two or three of in
/// one visit, and a plain `NSMenuItem` closes the menu on each one.
final class MenuToggleView: NSView {
    private let track = CALayer()
    private let knob = CALayer()
    private var hovered = false

    /// Rejects a second click within a tenth of a second. Menu tracking can deliver a press that
    /// reads as two, and the visible result is a switch that flickers and lands back where it began.
    private var lastToggle = Date.distantPast

    var isOn: Bool { didSet { restyle(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: MenuToggle.size))

        // Layer-*hosted*, not layer-backed: this view draws nothing of its own, and hosting keeps
        // AppKit from redrawing over the sublayers mid-animation.
        layer = CALayer()
        wantsLayer = true

        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)

        knob.bounds = CGRect(origin: .zero, size: MenuToggle.knobSize)
        knob.cornerRadius = MenuToggle.knobSize.height / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)

        restyle(animated: false)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { MenuToggle.size }

    override func accessibilityValue() -> Any? { isOn }

    private func restyle(animated: Bool) {
        let color = MenuToggle.trackColor(
            isOn: isOn, dark: MenuToggle.isDark(effectiveAppearance), hovered: hovered
        ).cgColor
        let position = MenuToggle.knobCenter(isOn: isOn)

        CATransaction.begin()
        // Implicit animations are disabled and the explicit ones added by hand, so that a restyle
        // with no state change — a hover, an appearance switch — doesn't inherit the slide.
        CATransaction.setDisableActions(true)
        if animated {
            // Apple's own switch springs rather than eases. `presentation()` is the from-value so
            // that a click landing mid-slide continues from where the knob visibly is, instead of
            // jumping back to the end it was heading for.
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: position)
            spring.damping = 16
            spring.stiffness = 260
            spring.mass = 1
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")

            let fill = CABasicAnimation(keyPath: "backgroundColor")
            fill.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            fill.toValue = color
            fill.duration = 0.2
            track.add(fill, forKey: "backgroundColor")
        }
        knob.position = position
        track.backgroundColor = color
        CATransaction.commit()
    }

    /// The off grey depends on the appearance this view is drawn on, and `effectiveAppearance` only
    /// resolves to the menu's once the view has been installed in it — not at `init`, where the
    /// answer is whatever the app's appearance happens to be.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`, because the app is an accessory and is never the active one while its own
        // menu is open — `.activeInActiveApp` would mean no hover feedback at all.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        restyle(animated: false)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        restyle(animated: false)
    }

    override func mouseDown(with event: NSEvent) { flip() }

    /// Also called by the row around it, so the whole width is the target rather than 33 points of
    /// it. Debounced because both can see one press — and because menu tracking has been observed
    /// delivering a single click as two, which shows up as a switch that flickers and lands back
    /// where it started.
    func flip() {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

/// The Settings submenu's rows.
///
/// Here rather than in `MenuController` for the reason that file's header gives: it renders
/// `[LimitWindow]` and knows nothing about where usage comes from, and it had grown to 738 lines by
/// also owning every item builder in the app.
enum SettingsRow {
    private static let height: CGFloat = 24
    /// Measured rather than guessed: at 38 the caption of one row sat 7 points off the title of the
    /// next, so two stacked toggles read as one four-line block. 40 puts 10 points between rows and
    /// ~1 between a title and its own caption, which is the ratio that makes the pairing obvious.
    private static let twoLineHeight: CGFloat = 40
    private static let inset = PanelMetrics.horizontalPadding
    /// Room for the switch plus a gap the eye reads as a gutter rather than a squeeze.
    private static let trailingGap: CGFloat = 12

    /// What VoiceOver and AppleScript report for a toggle row.
    ///
    /// A view-backed item draws no title at all, but `title` is still what the accessibility API
    /// reads and what `get name of every menu item` returns — the `osascript` recipe in CLAUDE.md
    /// that is this project's standing way to read the menu without screenshots. A plain item would
    /// have carried its state in `NSMenuItem.state`, which both can reach; a switch carries it in a
    /// layer's fill, which neither can. So the name has to say it.
    static func spokenTitle(_ title: String, isOn: Bool) -> String {
        "\(title) (\(isOn ? "on" : "off"))"
    }

    /// Section headings, for the Settings submenus only. The main panel's headings are drawn by
    /// `UsageRowView`; inside a submenu a dimmed heading is the conventional macOS look, and it
    /// labels a group rather than being a thing you can pick.
    static func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// A dim line of status under the row it belongs to — what the hooks are doing, whether the
    /// statusline feed is live. Disabled, which is what dims it: this is a report, not a command.
    static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = noteTitle(text)
        item.isEnabled = false
        return item
    }

    /// Separate from `note` so a caller holding the item can rewrite it while the menu is open —
    /// which a switch now makes possible, since flipping one no longer dismisses the menu.
    /// `attributedTitle`, not `title`: on a plain item the attributed one silently wins, so setting
    /// `title` here would look right and change nothing.
    static func noteTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize - 2),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// A labelled switch, optionally with a line of explanation under it.
    ///
    /// The subtitle is part of this one view rather than a second item, so that the pair can't be
    /// separated by menu layout, arrow-keys don't stop on a fragment, and the explanation can't be
    /// mistaken for something selectable.
    /// `settled` is for the settings that macOS, not Cashew, has the final say over: it is read back
    /// after `onToggle` has run, and the switch is put where the answer says rather than where the
    /// click asked. Launch-at-login is the one that needs it — registration legitimately fails from
    /// a quarantined or temporary location, and a switch that slides over anyway is a lie about
    /// something the system just refused. Omitted where Cashew owns the value outright.
    static func toggle(_ title: String, subtitle: String? = nil, isOn: Bool,
                       settled: (() -> Bool)? = nil,
                       onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let titleFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = titleFont
        label.textColor = .labelColor
        label.sizeToFit()

        let caption = subtitle.map { text -> NSTextField in
            let field = NSTextField(labelWithString: text)
            field.font = NSFont.menuFont(ofSize: titleFont.pointSize - 2)
            field.textColor = .secondaryLabelColor
            field.sizeToFit()
            return field
        }

        let switchView = MenuToggleView(isOn: isOn)
        let rowHeight = caption == nil ? height : twoLineHeight
        // A floor, not a target — the menu sizes itself to its widest item and stretches every row
        // to match, exactly as `HostedRow` documents. This only has to be wide enough that the
        // switch doesn't sit on top of the label in a submenu with nothing else in it.
        let natural = inset + max(label.frame.width, caption?.frame.width ?? 0)
            + trailingGap + MenuToggle.size.width + inset
        let row = SettingsToggleRow(toggle: switchView,
                                    frame: NSRect(x: 0, y: 0, width: natural, height: rowHeight))
        row.autoresizingMask = [.width]

        // Laid out from the top down, because a two-line row has to put its title on the first line
        // whatever the row's height turns out to be. AppKit's y origin is at the bottom.
        let titleY = rowHeight - label.frame.height - (caption == nil ? (rowHeight - label.frame.height) / 2 : 4)
        label.setFrameOrigin(NSPoint(x: inset, y: titleY))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        if let caption {
            caption.setFrameOrigin(NSPoint(x: inset, y: titleY - caption.frame.height))
            caption.autoresizingMask = [.maxXMargin]
            row.addSubview(caption)
        }

        // Pinned to the trailing edge and kept there as the menu stretches the row. Vertically
        // centred on the *title*, not on the row, so it reads as belonging to the label it switches
        // rather than floating between the two lines.
        switchView.setFrameOrigin(
            NSPoint(x: natural - MenuToggle.size.width - inset,
                    y: titleY + (label.frame.height - MenuToggle.size.height) / 2))
        switchView.autoresizingMask = [.minXMargin]
        row.addSubview(switchView)

        let item = NSMenuItem()
        item.view = row
        item.title = spokenTitle(title, isOn: isOn)
        // Disabled for the reason `HostedRow` gives: an enabled view-backed item is *selected* when
        // the mouse is released over it, which dismisses the whole menu. That is the one thing this
        // control exists to avoid — you change two or three settings in a visit, not one.
        item.isEnabled = false
        switchView.onToggle = { [weak item, weak switchView] isOn in
            onToggle(isOn)
            // Animated, so a refusal reads as the switch springing back rather than as a click that
            // never registered.
            let actual = settled?() ?? isOn
            if let switchView, switchView.isOn != actual { switchView.isOn = actual }
            item?.title = spokenTitle(title, isOn: actual)
        }
        return item
    }
}

/// Carries the click from anywhere on the row to the switch at the end of it.
///
/// Without this, only the 33 points of the switch itself are the target, and a click on the label —
/// which is what people aim at — does nothing at all.
private final class SettingsToggleRow: NSView {
    private let toggle: MenuToggleView

    init(toggle: MenuToggleView, frame: NSRect) {
        self.toggle = toggle
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Only reached for clicks *outside* the switch: a subview gets the event first, and
    // `MenuToggleView` handles its own. The shared debounce covers the overlap either way.
    override func mouseDown(with event: NSEvent) { toggle.flip() }
}
