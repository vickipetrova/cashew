import AppKit
import Foundation
import Testing

@testable import CashewCore

/// The Settings switch, in the parts that can be checked without a menu on screen.
///
/// `MenuToggleView` itself is a layer-hosted `NSView` whose behaviour — sliding on a spring while a
/// menu is tracking, not dismissing the menu when clicked — is only observable with a real menu up.
/// What *is* checkable is the arithmetic and the colour rule underneath it, and those are where the
/// two known defects live: a knob measured against the wrong edge overhangs its track, and a track
/// colour taken from a dynamic `NSColor` renders white on white.
@Suite struct MenuToggleTests {
    /// A knob wider than tall, travelling between two insets, is easy to get wrong by exactly the
    /// knob's own radius — which puts half of it outside the track at one end.
    @Test(arguments: [false, true])
    func theKnobStaysInsideTheTrack(_ isOn: Bool) {
        let center = MenuToggle.knobCenter(isOn: isOn)
        let half = MenuToggle.knobSize.width / 2
        #expect(center.x - half >= 0)
        #expect(center.x + half <= MenuToggle.size.width)
        #expect(center.y == MenuToggle.size.height / 2)
    }

    @Test func theKnobTravelsRightWhenTurnedOn() {
        #expect(MenuToggle.knobCenter(isOn: true).x > MenuToggle.knobCenter(isOn: false).x)
    }

    /// The defect this exists for: the off track is drawn from an explicit black-or-white, chosen
    /// from the appearance the view has *landed in*, because a dynamic `NSColor`'s `.cgColor` can
    /// latch the wrong one and hand CoreAnimation a white track on a white menu. If these two ever
    /// come back equal, that resolution has been dropped.
    @Test func theOffTrackIsPickedForTheAppearanceItIsDrawnOn() {
        #expect(MenuToggle.trackColor(isOn: false, dark: false, hovered: false)
            != MenuToggle.trackColor(isOn: false, dark: true, hovered: false))
    }

    /// The on track is the user's accent and carries its own light/dark behaviour, so unlike the off
    /// track it must *not* be branched on our flag — branching it would mean picking an accent for
    /// the user, which is theirs to set.
    @Test func theOnTrackIsTheAccentRegardlessOfAppearance() {
        #expect(MenuToggle.trackColor(isOn: true, dark: false, hovered: false)
            == MenuToggle.trackColor(isOn: true, dark: true, hovered: false))
    }

    /// Hover has to read in both states. It is the only feedback the control gives before you commit
    /// to the click, since a menu row's own highlight doesn't extend to a custom view.
    @Test(arguments: [false, true])
    func hoverIsVisibleWhicheverWayItIsSet(_ isOn: Bool) {
        #expect(MenuToggle.trackColor(isOn: isOn, dark: false, hovered: true)
            != MenuToggle.trackColor(isOn: isOn, dark: false, hovered: false))
    }

    // MARK: - What the row is called

    /// A view-backed row draws no title, but `title` is still what VoiceOver and AppleScript report
    /// — including the `osascript` recipe in CLAUDE.md that is this project's standing way to read
    /// the menu without screenshots. A switch's state lives in a layer's fill, where neither can
    /// reach it, so the row's name has to carry it or the recipe silently stops saying anything
    /// useful about settings.
    @Test func aToggleRowSaysWhichWayItIsSet() {
        #expect(SettingsRow.spokenTitle("Open at Login", isOn: true) == "Open at Login (on)")
        #expect(SettingsRow.spokenTitle("Open at Login", isOn: false) == "Open at Login (off)")
    }
}
