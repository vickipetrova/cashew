import AppKit
import Foundation
import Testing

@testable import CashewCore

/// The menu bar's working animation, in every style.
///
/// These assert on *rendered pixels*, not just on sizes, because the one defect this area has
/// already produced was invisible to a size check: a glyph rotated inside a canvas measured for its
/// unrotated self lost its spokes at the edges, so the frames changed shape rather than orientation.
///
/// `@MainActor` and `.serialized` are load-bearing, not tidiness. AppKit drawing is not thread-safe,
/// and swift-testing runs tests in parallel by default: with seven drawing tests in flight at once
/// the run deadlocked and never finished, with no failure to attribute it to. Every test that
/// rasterizes an image belongs in this suite for that reason.
@MainActor
@Suite(.serialized)
struct MenuBarAnimationTests {
    /// Ink pixels, and whether any of them sit in the outermost ring of the image, rendered at 4x.
    ///
    /// The bitmap is allocated by CoreGraphics (`data: nil`) rather than by handing it a Swift
    /// array's pointer, which does not outlive the call it is passed to.
    private func ink(_ image: NSImage, scale: Int = 4) -> (pixels: Int, touchesEdge: Bool) {
        let width = Int(image.size.width) * scale, height = Int(image.size.height) * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("could not create the bitmap context")
            return (0, false)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var pixels = 0, touchesEdge = false
        for y in 0..<height {
            for x in 0..<width where bytes[y * context.bytesPerRow + x * 4 + 3] > 0 {
                pixels += 1
                if x < scale || x >= width - scale || y < scale || y >= height - scale {
                    touchesEdge = true
                }
            }
        }
        return (pixels, touchesEdge)
    }

    private func image(_ style: MenuBarAnimation, frame: Int, mode: Settings.ColorMode = .alertsOnly,
                       working: Bool = true, attention: Bool = false,
                       reduceMotion: Bool = false) -> NSImage {
        style.image(mode: mode, frame: frame, working: working, attention: attention,
                    reduceMotion: reduceMotion)
    }

    /// The width must not depend on the frame: a title that changes width four times a second
    /// shuffles every menu bar item to its left.
    @Test(arguments: MenuBarAnimation.allCases)
    func everyFrameIsTheSameSize(_ style: MenuBarAnimation) {
        let sizes = Set((0..<style.cycleFrames).map { image(style, frame: $0).size })
        #expect(sizes.count == 1)
        // And resting matches working, so starting and stopping doesn't jump either.
        #expect(image(style, frame: 0, working: false).size == sizes.first)
    }

    /// The code-drawn styles share one square canvas, so switching between them doesn't move the
    /// numbers beside the image.
    @Test func theDrawnStylesShareOneCanvas() {
        let drawn = MenuBarAnimation.allCases.filter { $0 != .cashew }
        #expect(Set(drawn.map { image($0, frame: 0).size.width }).count == 1)
        #expect(Set(drawn.map { image($0, frame: 0).size.height }).count == 1)
    }

    /// Cashew's image is its art and nothing else — the proportions of the sheet, no padding. A
    /// status item scales an image to fit and pads it, so every point spent on margin is a point the
    /// character loses: inset inside a 22pt canvas it rendered *smaller* than it does at 20pt of
    /// pure art.
    @Test func theSpriteImageIsAllArt() throws {
        let image = image(.cashew, frame: 0)
        // Two statements, not one nested `#require`: nesting them is a recursive macro expansion
        // the compiler rejects.
        let data = try #require(Data(base64Encoded: cashewFramePNGs[0]))
        let sheet = try #require(NSImage(data: data))
        #expect(abs(image.size.width / image.size.height
                    - sheet.size.width / sheet.size.height) < 0.01)
        // Taller than `thickness` on purpose: that value under-reports what the bar draws, and the
        // art carries its own margin (roughly 4 of its 36 rows), so the ink still lands inside.
        // Checked by screenshot at this size, with space above the head and below the feet.
        #expect(image.size.height == NSStatusBar.system.thickness + 4)
        // Ink reaches the edge, which is what "no margin" means.
        #expect(ink(image).touchesEdge)
    }

    @Test(arguments: MenuBarAnimation.allCases)
    func everyFrameDrawsSomethingAndStaysInsideItsCanvas(_ style: MenuBarAnimation) {
        for frame in 0..<style.cycleFrames {
            let measured = ink(image(style, frame: frame))
            #expect(measured.pixels > 0, "\(style) frame \(frame) drew nothing")
            // The drawn styles live inside a canvas bigger than they are, so ink at its edge means
            // something was cut off. Cashew's image *is* its art, drawn to the edge on purpose —
            // insetting it only made the character smaller on screen.
            if style != .cashew {
                #expect(!measured.touchesEdge, "\(style) frame \(frame) is clipped at the canvas edge")
            }
        }
    }

    /// The character pauses on its resting pose between flips. Held in code rather than by repeating
    /// frame 0 in the sheet, so the sheets stay a description of the art and the pause stays one
    /// number.
    @Test func theRestingPoseIsHeldBetweenFlips() {
        let rest = MenuBarAnimation.cashewRestFrames
        let sheet = MenuBarAnimation.cashewFrameCount
        #expect(MenuBarAnimation.cashew.cycleFrames == sheet + rest)
        for tick in 0..<rest {
            #expect(MenuBarAnimation.cashewFrame(atTick: tick) == 0, "tick \(tick) left the rest")
        }
        #expect(MenuBarAnimation.cashewFrame(atTick: rest) == 1 - 1)          // first flip frame
        #expect(MenuBarAnimation.cashewFrame(atTick: rest + 5) == 5)
        // The last tick of the loop is the last frame of the flip, so the next tick rests again.
        #expect(MenuBarAnimation.cashewFrame(atTick: rest + sheet - 1) == sheet - 1)
        #expect(MenuBarAnimation.cashewFrame(atTick: rest + sheet) == 0)
        // Negative ticks can't happen from the counter, but the arithmetic must not trap if they do.
        #expect(MenuBarAnimation.cashewFrame(atTick: -1) == sheet - 1)
    }

    /// Turning a glyph preserves its area, so a spinning frame that loses ink is a frame being cut
    /// off — the failure that shipped once already, and the one a size check cannot see.
    ///
    /// Only the styles whose ink *should* be constant are held to that, and only loosely: a glyph
    /// drawn at 20° covers more partially-lit pixels than one at 0°, so anti-aliasing alone moves
    /// the count by a few per cent across a smooth turn. Clipping is caught by the edge check above;
    /// this catches a frame that loses a *limb*.
    @Test(arguments: MenuBarAnimation.allCases)
    func framesKeepTheirInk(_ style: MenuBarAnimation) {
        let counts = (0..<style.cycleFrames).map { ink(image(style, frame: $0)).pixels }
        let smallest = counts.min()!, largest = counts.max()!
        let tolerance: Double
        switch style {
        case .sparkSpin: tolerance = 0.15
        case .orbitingDot: tolerance = 0.15
        // The pulse's area goes with the square of its scale: 0.86² to 1.12² is a third of itself.
        case .sparkPulse: tolerance = 0.5
        // These two genuinely draw different amounts per frame — that is the animation.
        case .meterBars, .gaugeSweep: tolerance = 0.7
        // Drawn art whose whole animation is how much of it is filled in. The edge check above is
        // what holds its geometry; there is no constant ink to hold here.
        case .cashew: tolerance = 1
        }
        #expect(Double(largest - smallest) / Double(largest) <= tolerance,
                "\(style) ink varies \(counts)")
    }

    @Test(arguments: MenuBarAnimation.allCases)
    func animatedFramesActuallyDiffer(_ style: MenuBarAnimation) {
        // A quarter of the way through its own loop — at twelve frames a second, consecutive
        // frames are *meant* to be nearly identical; that is what smooth looks like.
        let first = image(style, frame: 0).tiffRepresentation
        // Past the resting hold for the sprite, whose loop opens with a deliberate pause.
        let moving = style == .cashew
            ? MenuBarAnimation.cashewRestFrames + style.cycleFrames / 4
            : style.cycleFrames / 4
        let later = image(style, frame: moving).tiffRepresentation
        #expect(first != later, "\(style) does not move within its cycle")
    }

    /// At rest the animation holds still: the resting frame is what a stopped timer leaves on
    /// screen, and every style's frame 0 is its resting shape.
    @Test(arguments: MenuBarAnimation.allCases)
    func reduceMotionAndRestAreStill(_ style: MenuBarAnimation) {
        let frames = (0..<style.cycleFrames).map {
            image(style, frame: $0, reduceMotion: true).tiffRepresentation
        }
        #expect(Set(frames).count == 1, "\(style) still animates under Reduce Motion")
        let resting = (0..<style.cycleFrames).map {
            image(style, frame: $0, working: false).tiffRepresentation
        }
        #expect(Set(resting).count == 1, "\(style) animates while no session is working")
    }

    /// System mode is monochrome by definition, so "waiting for you" can't be said in yellow there —
    /// it gets a dot, which is a *shape*. Alerts-only says it in colour and stays the same width.
    @Test(arguments: MenuBarAnimation.allCases)
    func attentionIsAShapeInSystemModeAndAColourInAlertsOnly(_ style: MenuBarAnimation) {
        let system = image(style, frame: 0, mode: .system, attention: true)
        #expect(system.isTemplate)
        #expect(system.size.width > image(style, frame: 0, mode: .system).size.width)

        let alerts = image(style, frame: 0, attention: true)
        #expect(!alerts.isTemplate)
        #expect(alerts.tiffRepresentation != image(style, frame: 0).tiffRepresentation)
        if style == .cashew {
            // Drawn art carries its own colours, so recolouring it yellow would just make a yellow
            // blob. It says "waiting" with the dot in both modes, and widens in both.
            #expect(alerts.size.width > image(style, frame: 0).size.width)
        } else {
            #expect(alerts.size == image(style, frame: 0).size)
        }
    }

    /// One counter drives every style, so where it wraps has to be a whole number of *each* style's
    /// loops. It used to wrap at the longest cycle (30) while the gauge looped every 24, which sent
    /// the gauge five frames backwards every two and a half seconds — a visible jump in the one
    /// style whose whole job is travelling smoothly.
    @Test(arguments: MenuBarAnimation.allCases)
    func theSharedCounterWrapsOnEveryStylesLoop(_ style: MenuBarAnimation) {
        #expect(MenuBarAnimation.globalCycleFrames % style.cycleFrames == 0)
        // The frame after the last is the first: same image, no jump.
        let afterWrap = image(style, frame: MenuBarAnimation.globalCycleFrames)
        #expect(afterWrap.tiffRepresentation == image(style, frame: 0).tiffRepresentation)
    }

    /// The sprite sheets are the one place a style's frames can go missing — a bad regeneration, a
    /// truncated base64 string — and a style that silently draws nothing would look like the app
    /// had frozen rather than like a bug.
    @Test func cashewSheetsAreCompleteAndMatched() {
        #expect(cashewFramePNGs.count == cashewTemplateFramePNGs.count)
        #expect(MenuBarAnimation.cashewFrameCount == cashewFramePNGs.count)
        #expect(MenuBarAnimation.cashewFrameCount >= 2)
        for (index, encoded) in zip(cashewFramePNGs, cashewTemplateFramePNGs).enumerated().map({ ($0.0, $0.1) }) {
            let colour = NSImage(data: Data(base64Encoded: encoded.0) ?? Data())
            let template = NSImage(data: Data(base64Encoded: encoded.1) ?? Data())
            #expect(colour != nil, "colour frame \(index) does not decode")
            #expect(template != nil, "template frame \(index) does not decode")
            #expect(colour?.size == template?.size, "frame \(index) differs in size between sheets")
        }
    }

    @Test func labelsAreDistinctAndShort() {
        let labels = MenuBarAnimation.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty && $0.count <= 20 })
    }
}
