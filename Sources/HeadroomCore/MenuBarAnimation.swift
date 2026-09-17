import AppKit

/// What the menu bar draws while a Claude Code session is working.
///
/// Every style is drawn here rather than shipped as artwork, for two reasons. Headroom is going to
/// track more than one tool, so a mascot belonging to any single vendor would date the app the week
/// a second provider lands — and drawing means one square canvas, one set of rules about colour, and
/// one test that measures the rendered pixels of all of them.
///
/// **Colour.** In `.system` the image is a *template*: macOS draws it the way it draws a built-in
/// menu bar control, so it inverts when highlighted and follows light and dark. A template's shape
/// is its alpha channel and its colour is thrown away — which is why every style is drawn in opaque
/// black there (`labelColor` is 0.847 alpha and renders visibly lighter than its neighbours), and
/// why "a session is waiting for you" cannot be said in yellow in that mode. It gets a dot instead.
/// In `.alertsOnly` the brand orange is baked in, and waiting turns the whole glyph yellow.
///
/// **Geometry.** Every style shares one square canvas, sized from the spark glyph, at every frame
/// and whether or not anything is working. Two things depend on that: a frame that changed size
/// would shuffle every menu bar item to its left four times a second, and a canvas measured for an
/// unrotated glyph clips the spokes the moment it turns — measured at 4x, the rotated frames each
/// had ink in the outermost column while the unrotated one didn't, and the ink total drifted down
/// as the corners fell outside the box. `MenuBarAnimationTests` renders the pixels to hold both.
enum MenuBarAnimation: String, CaseIterable {
    /// The ✻ spark, turning. What Headroom shipped first, and the default.
    case sparkSpin
    /// The spark, breathing in and out rather than turning.
    case sparkPulse
    /// An arc travelling around a ring, echoing the gauge tracks in the app icon.
    case gaugeSweep
    /// A dot circling the spark.
    case orbitingDot
    /// Three bars rising and falling, like a level meter.
    case meterBars

    /// Four frames at the 0.25 s tick: one full cycle a second, which reads as motion without
    /// asking the eye to track anything.
    static let frameCount = 4

    var label: String {
        switch self {
        case .sparkSpin: return "Spark spin"
        case .sparkPulse: return "Spark pulse"
        case .gaugeSweep: return "Gauge sweep"
        case .orbitingDot: return "Orbiting dot"
        case .meterBars: return "Meter bars"
        }
    }

    // MARK: - Drawing

    private static let glyph = "✻" as NSString
    private static let font = NSFont.systemFont(ofSize: 13)

    /// The square every style draws into, and the one number that keeps the styles interchangeable:
    /// switching style in Settings must not move the percentages beside the image.
    private static var side: CGFloat {
        let size = glyph.size(withAttributes: [.font: font])
        return ceil(max(size.width, size.height))
    }

    private static let dotDiameter: CGFloat = 6
    private static let dotGap: CGFloat = 2

    /// `working` is what stops the animation when every session is idle; `reduceMotion` freezes it
    /// for someone who asked the system for less movement. Both resolve to the resting frame, which
    /// is frame 0 of each style — the shape the style looks like when nothing is happening.
    func image(mode: Settings.ColorMode, frame: Int, working: Bool, attention: Bool,
               reduceMotion: Bool) -> NSImage {
        let side = Self.side
        // System mode can't use colour, so waiting is drawn as an extra shape and the image widens.
        let needsDot = attention && mode == .system
        let width = side + (needsDot ? Self.dotGap + Self.dotDiameter : 0)
        let step = working && !reduceMotion ? ((frame % Self.frameCount) + Self.frameCount) % Self.frameCount : 0
        let ink: NSColor = mode == .system ? .black : (attention ? .systemYellow : Fmt.spark)

        // `NSImage(size:flipped:drawingHandler:)` rather than lockFocus: the handler re-runs per
        // destination scale, so the image stays sharp on a second display with a different backing
        // scale instead of being rasterized once at whatever the main screen happened to be.
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            switch self {
            case .sparkSpin: Self.drawSpark(side: side, ink: ink, rotation: CGFloat(step) * 11.25)
            case .sparkPulse:
                Self.drawSpark(side: side, ink: ink, scale: [1, 0.92, 0.84, 0.92][step])
            case .gaugeSweep: Self.drawGauge(side: side, ink: ink, step: step, working: working && !reduceMotion)
            case .orbitingDot: Self.drawOrbit(side: side, ink: ink, step: step, working: working && !reduceMotion)
            case .meterBars: Self.drawBars(side: side, ink: ink, step: step, working: working && !reduceMotion)
            }
            if needsDot {
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: side + Self.dotGap, y: (side - Self.dotDiameter) / 2,
                                            width: Self.dotDiameter, height: Self.dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = mode == .system
        return image
    }

    /// The spark, turned and scaled about the centre of its square.
    private static func drawSpark(side: CGFloat, ink: NSColor, rotation: CGFloat = 0,
                                  scale: CGFloat = 1) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = glyph.size(withAttributes: attributes)
        let origin = NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: side / 2, y: side / 2)
        context.rotate(by: -rotation * .pi / 180)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -side / 2, y: -side / 2)
        glyph.draw(at: origin, withAttributes: attributes)
        context.restoreGState()
    }

    /// A ring with a brighter arc running around it. At rest the ring is whole, which is what the
    /// gauges in the app icon look like when they aren't moving.
    private static func drawGauge(side: CGFloat, ink: NSColor, step: Int, working: Bool) {
        let lineWidth: CGFloat = 1.8
        // The inset keeps the stroke — which straddles the path — a clear pixel inside the canvas.
        let radius = side / 2 - lineWidth / 2 - 1
        let centre = NSPoint(x: side / 2, y: side / 2)

        let ring = NSBezierPath()
        ring.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        ring.lineWidth = lineWidth
        ink.withAlphaComponent(working ? 0.3 : 1).setStroke()
        ring.stroke()

        guard working else { return }
        let start = 90 - CGFloat(step) * 90
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius, startAngle: start,
                      endAngle: start - 100, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
    }

    /// A smaller spark with a dot going round it. At rest it is just the spark, at full size, so
    /// stopping doesn't leave a stray dot parked somewhere.
    private static func drawOrbit(side: CGFloat, ink: NSColor, step: Int, working: Bool) {
        guard working else { return drawSpark(side: side, ink: ink) }
        drawSpark(side: side, ink: ink, scale: 0.62)
        let diameter: CGFloat = 3.4
        let radius = side / 2 - diameter / 2 - 1
        let angle = CGFloat(90 - step * 90) * .pi / 180
        let centre = NSPoint(x: side / 2 + cos(angle) * radius, y: side / 2 + sin(angle) * radius)
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    /// Three bars. At rest they sit low and level, so the style still says "nothing is happening".
    private static func drawBars(side: CGFloat, ink: NSColor, step: Int, working: Bool) {
        let barWidth: CGFloat = 2.4, gap: CGFloat = 1.8
        let total = barWidth * 3 + gap * 2
        let left = (side - total) / 2
        let floorY = (side - (side - 4)) / 2
        let tallest = side - 4
        // Each column runs through the same heights a step apart, which is what makes the row look
        // like one moving thing rather than three blinking ones.
        let heights: [CGFloat] = [0.35, 0.65, 1.0, 0.65]
        ink.setFill()
        for bar in 0..<3 {
            let fraction = working ? heights[(step + bar) % heights.count] : 0.35
            let height = tallest * fraction
            let rect = NSRect(x: left + CGFloat(bar) * (barWidth + gap), y: floorY,
                              width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
