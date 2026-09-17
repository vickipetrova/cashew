import AppKit
import Foundation
import Testing

@testable import HeadroomCore

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
        let sizes = Set((0..<MenuBarAnimation.frameCount).map { image(style, frame: $0).size })
        #expect(sizes.count == 1)
        // And resting matches working, so starting and stopping doesn't jump either.
        #expect(image(style, frame: 0, working: false).size == sizes.first)
    }

    /// Every style is the same width as every other, so switching style in Settings doesn't move
    /// the numbers beside it.
    @Test func stylesAgreeOnWidth() {
        let widths = Set(MenuBarAnimation.allCases.map { image($0, frame: 0).size.width })
        #expect(widths.count == 1)
    }

    @Test(arguments: MenuBarAnimation.allCases)
    func everyFrameDrawsSomethingAndStaysInsideItsCanvas(_ style: MenuBarAnimation) {
        for frame in 0..<MenuBarAnimation.frameCount {
            let measured = ink(image(style, frame: frame))
            #expect(measured.pixels > 0, "\(style) frame \(frame) drew nothing")
            #expect(!measured.touchesEdge, "\(style) frame \(frame) is clipped at the canvas edge")
        }
    }

    /// Turning a glyph preserves its area, so a spinning frame that loses ink is a frame being cut
    /// off — the failure that shipped once already, and the one a size check cannot see.
    ///
    /// Only the styles whose ink *should* be constant are held to that: the pulse scales (area goes
    /// with the square of the scale, so ~25% at 0.84), the bars and the gauge arc draw deliberately
    /// different amounts per frame. Clipping in those is caught by the edge check above instead.
    @Test(arguments: MenuBarAnimation.allCases)
    func framesKeepTheirInk(_ style: MenuBarAnimation) {
        let counts = (0..<MenuBarAnimation.frameCount).map { ink(image(style, frame: $0)).pixels }
        let smallest = counts.min()!, largest = counts.max()!
        let tolerance: Double
        switch style {
        case .sparkSpin: tolerance = 0.05
        case .orbitingDot: tolerance = 0.1
        case .sparkPulse: tolerance = 0.35
        case .meterBars, .gaugeSweep: tolerance = 0.6
        }
        #expect(Double(largest - smallest) / Double(largest) <= tolerance,
                "\(style) ink varies \(counts)")
    }

    @Test(arguments: MenuBarAnimation.allCases)
    func animatedFramesActuallyDiffer(_ style: MenuBarAnimation) {
        let first = image(style, frame: 0).tiffRepresentation
        let later = image(style, frame: 1).tiffRepresentation
        #expect(first != later, "\(style) frame 1 is identical to frame 0")
    }

    /// At rest the animation holds still: the resting frame is what a stopped timer leaves on
    /// screen, and every style's frame 0 is its resting shape.
    @Test(arguments: MenuBarAnimation.allCases)
    func reduceMotionAndRestAreStill(_ style: MenuBarAnimation) {
        let frames = (0..<MenuBarAnimation.frameCount).map {
            image(style, frame: $0, reduceMotion: true).tiffRepresentation
        }
        #expect(Set(frames).count == 1, "\(style) still animates under Reduce Motion")
        let resting = (0..<MenuBarAnimation.frameCount).map {
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
        #expect(alerts.size == image(style, frame: 0).size)
        #expect(alerts.tiffRepresentation != image(style, frame: 0).tiffRepresentation)
    }

    @Test func labelsAreDistinctAndShort() {
        let labels = MenuBarAnimation.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty && $0.count <= 20 })
    }
}
