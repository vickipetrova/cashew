import AppKit

/// What the menu bar draws while a Claude Code session is working.
///
/// Most styles are drawn here in code rather than shipped as artwork: Headroom is going to track
/// more than one tool, so a mascot belonging to any single vendor would date the app the week a
/// second provider lands, and drawing means one square canvas, one set of rules about colour, and
/// one test that measures the rendered pixels of all of them.
///
/// `cashew` is the exception, and the shape of it is the rule for any future sprite style: it is
/// Headroom's own character, drawn by the author, shipped as two sheets of frames — full colour,
/// and an alpha-only template for System mode — that go through the same canvas, the same resting
/// frame and the same pixel tests as everything drawn in code.
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
    /// A drawn character, animated from sprite frames rather than by code.
    case cashew

    /// Frames per second. Twelve, not the four this started at: at four, a turning glyph and a
    /// breathing one were barely perceptible — the eye reads slow discrete steps as a still image
    /// that occasionally jumps — while the orbiting dot, whose movement *was* visible, looked like
    /// it was teleporting between four corners rather than travelling. The tick only runs while a
    /// session is working, and a frame is one small image redrawn, not a re-layout of the title.
    static let framesPerSecond = 12
    static let tickInterval = 1.0 / Double(framesPerSecond)

    /// How many frames one loop of this style takes, which is what sets its speed. Each is tuned
    /// separately: the spark's eight-fold symmetry means a 45° turn is a whole cycle, while the dot
    /// has a full circle to cross and needs longer or it reads as frantic.
    var cycleFrames: Int {
        switch self {
        case .sparkSpin: return 18     // 45° in 1.5s
        case .sparkPulse: return 24    // one breath every 2s
        case .gaugeSweep: return 24    // one lap every 2s
        case .orbitingDot: return 30   // one lap every 2.5s — the slowest, it travels furthest
        case .meterBars: return 18
        // One pass through the sprite sheet, which is a whole backflip and so meets its own start.
        // At 12 fps that is a 1.3s loop.
        case .cashew: return Self.cashewFrameCount
        }
    }

    /// Where the shared frame counter wraps.
    ///
    /// A *common multiple* of every style's cycle, not the longest one. Wrapping at the longest (30)
    /// while the gauge looped every 24 sent it from frame 29 to frame 0 — five frames backwards,
    /// once every two and a half seconds — which is exactly the jump the smooth-motion work was
    /// supposed to remove. Every style now meets the wrap at the start of its own loop.
    static let globalCycleFrames: Int = allCases.reduce(1) { total, style in
        let a = total, b = style.cycleFrames
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }   // gcd
        return a / x * b                       // lcm
    }

    var label: String {
        switch self {
        case .sparkSpin: return "Spark spin"
        case .sparkPulse: return "Spark pulse"
        case .gaugeSweep: return "Gauge sweep"
        case .orbitingDot: return "Orbiting dot"
        case .meterBars: return "Meter bars"
        case .cashew: return "Cashew"
        }
    }

    // MARK: - Drawing

    private static let glyph = "✻" as NSString
    /// 15pt, not the 13pt of menu bar *text*: the spark is a glyph standing in for an icon, and at
    /// text size it read as small and timid beside neighbouring apps' icons. The canvas below is
    /// sized from it, and `MenuBarAnimationTests` holds the whole thing inside its bounds.
    private static let font = NSFont.systemFont(ofSize: 15)

    /// The square every style draws into, and the one number that keeps the styles interchangeable:
    /// switching style in Settings must not move the percentages beside the image.
    ///
    /// Margin included, because two styles need room the glyph's own box doesn't have: the pulse
    /// grows to 1.12 of resting size, and the dot orbits outside the spark. Without it they would
    /// be clipped exactly the way the rotating spark once was.
    private static var side: CGFloat {
        let size = glyph.size(withAttributes: [.font: font])
        return ceil(max(size.width, size.height) * 1.14)
    }

    private static let dotDiameter: CGFloat = 6
    private static let dotGap: CGFloat = 2

    /// The canvas this style draws into.
    ///
    /// Square for everything drawn in code, and wider than it is tall for Cashew, whose frames are
    /// 37×36 with ink out to every edge — no transparent margin to grow into. Squeezing that into
    /// the square left the character 18.4pt tall inside a menu bar that is 22pt, which is why it
    /// looked small. Its canvas is now as tall as the others and wide enough for the character at
    /// 20pt, keeping a clear point on every edge.
    private var canvas: NSSize {
        let side = Self.side
        guard self == .cashew, let sprite = Self.cashewColourFrames.first,
              sprite.size.width > 0, sprite.size.height > 0 else {
            return NSSize(width: side, height: side)
        }
        let height = side - 2
        return NSSize(width: ceil(height * sprite.size.width / sprite.size.height) + 2, height: side)
    }

    /// `working` is what stops the animation when every session is idle; `reduceMotion` freezes it
    /// for someone who asked the system for less movement. Both resolve to the resting frame, which
    /// is frame 0 of each style — the shape the style looks like when nothing is happening.
    func image(mode: Settings.ColorMode, frame: Int, working: Bool, attention: Bool,
               reduceMotion: Bool) -> NSImage {
        let side = Self.side
        let canvas = self.canvas
        // System mode can't use colour, so waiting is drawn as an extra shape and the image widens.
        // Cashew is drawn art rather than a glyph: its colours are its own and tinting it yellow
        // would just make a yellow blob, so it takes the dot in both modes.
        let needsDot = attention && (mode == .system || self == .cashew)
        let width = canvas.width + (needsDot ? Self.dotGap + Self.dotDiameter : 0)
        let moving = working && !reduceMotion
        // Where this frame sits in the style's own loop, 0..<1. Styles are written against the
        // phase rather than a frame index so their speeds can differ without their drawing knowing.
        let phase = moving
            ? Double(((frame % cycleFrames) + cycleFrames) % cycleFrames) / Double(cycleFrames)
            : 0
        let ink: NSColor = mode == .system ? .black : (attention ? .systemYellow : Fmt.spark)

        // `NSImage(size:flipped:drawingHandler:)` rather than lockFocus: the handler re-runs per
        // destination scale, so the image stays sharp on a second display with a different backing
        // scale instead of being rasterized once at whatever the main screen happened to be.
        let image = NSImage(size: NSSize(width: width, height: canvas.height), flipped: false) { _ in
            switch self {
            case .sparkSpin:
                // 45°, not 360: ✻ has eight spokes, so a 45° turn *is* a full revolution to the eye.
                Self.drawSpark(side: side, ink: ink, rotation: CGFloat(phase) * 45)
            case .sparkPulse:
                // A cosine, so it eases at both ends instead of stepping, and it grows past resting
                // size rather than only shrinking — at 4 frames between 1.0 and 0.84 the breath was
                // invisible.
                let eased = (1 - cos(phase * 2 * .pi)) / 2
                Self.drawSpark(side: side, ink: ink, scale: CGFloat(0.76 + 0.36 * eased))
            case .gaugeSweep: Self.drawGauge(side: side, ink: ink, phase: phase, working: moving)
            case .orbitingDot: Self.drawOrbit(side: side, ink: ink, phase: phase, working: moving)
            case .meterBars: Self.drawBars(side: side, ink: ink, phase: phase, working: moving)
            case .cashew:
                Self.drawCashew(canvas: canvas,
                                frame: moving ? Int(phase * Double(Self.cashewFrameCount)) : 0,
                                template: mode == .system)
            }
            if needsDot {
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: canvas.width + Self.dotGap,
                                            y: (canvas.height - Self.dotDiameter) / 2,
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
    private static func drawGauge(side: CGFloat, ink: NSColor, phase: Double, working: Bool) {
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
        // The arc's length breathes as it travels — it stretches as it leaves the top and gathers
        // back in, the way a real gauge needle's trail would, which is what stops a constant-length
        // arc going round at constant speed from looking mechanical.
        let start = 90 - CGFloat(phase) * 360
        let sweep = CGFloat(70 + 50 * (1 - cos(phase * 4 * .pi)) / 2)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius, startAngle: start,
                      endAngle: start - sweep, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
    }

    /// A smaller spark with a dot going round it. At rest it is just the spark, at full size, so
    /// stopping doesn't leave a stray dot parked somewhere.
    private static func drawOrbit(side: CGFloat, ink: NSColor, phase: Double, working: Bool) {
        guard working else { return drawSpark(side: side, ink: ink) }
        drawSpark(side: side, ink: ink, scale: 0.62)
        // Smaller and slower than the first version: a big dot jumping a quarter-circle per frame
        // read as a blinking light in the corner of the eye, which is the one thing a menu bar
        // animation must not do. It now travels continuously and takes 2.5s to come round.
        let diameter: CGFloat = 2.8
        let radius = side / 2 - diameter / 2 - 1
        let angle = (90 - phase * 360) * .pi / 180
        let centre = NSPoint(x: side / 2 + CGFloat(cos(angle)) * radius,
                             y: side / 2 + CGFloat(sin(angle)) * radius)
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    /// How many frames the Cashew sheet holds, taken from the sheet itself rather than written down
    /// twice — regenerating it with a different count should change the speed, not break the loop.
    static let cashewFrameCount = min(cashewFramePNGs.count, cashewTemplateFramePNGs.count)

    /// Decoded once, not per frame: at twelve frames a second, base64-decoding and re-parsing a PNG
    /// every tick would be real work to produce a picture that never changes.
    private static let cashewColourFrames = decode(cashewFramePNGs)
    private static let cashewTemplateFrames = decode(cashewTemplateFramePNGs)

    private static func decode(_ encoded: [String]) -> [NSImage] {
        encoded.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    /// One sprite frame, scaled to sit inside the shared square with the same margin the drawn
    /// styles keep. The template sheet is purpose-drawn as alpha-only ink, so it is used as-is in
    /// System mode rather than being derived from the colour art.
    private static func drawCashew(canvas: NSSize, frame: Int, template: Bool) {
        let frames = template ? cashewTemplateFrames : cashewColourFrames
        guard !frames.isEmpty else { return }
        let sprite = frames[((frame % frames.count) + frames.count) % frames.count]
        guard sprite.size.width > 0, sprite.size.height > 0 else { return }
        // A point clear of every edge — the margin `everyFrameDrawsSomethingAndStaysInsideItsCanvas`
        // checks, and all there is room for in a 22pt menu bar.
        let scale = min((canvas.width - 2) / sprite.size.width, (canvas.height - 2) / sprite.size.height)
        let size = NSSize(width: sprite.size.width * scale, height: sprite.size.height * scale)
        sprite.draw(in: NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                               width: size.width, height: size.height))
    }

    /// Three bars. At rest they sit low and level, so the style still says "nothing is happening".
    private static func drawBars(side: CGFloat, ink: NSColor, phase: Double, working: Bool) {
        let barWidth: CGFloat = 2.4, gap: CGFloat = 1.8
        let total = barWidth * 3 + gap * 2
        let left = (side - total) / 2
        let floorY = (side - (side - 4)) / 2
        let tallest = side - 4
        // A sine per column, each a third of a cycle behind the last: the row reads as one wave
        // passing through three bars rather than three lights blinking in turn.
        ink.setFill()
        for bar in 0..<3 {
            let wave = (1 - cos((phase + Double(bar) / 3) * 2 * .pi)) / 2
            let fraction = CGFloat(working ? 0.3 + 0.7 * wave : 0.3)
            let height = tallest * fraction
            let rect = NSRect(x: left + CGFloat(bar) * (barWidth + gap), y: floorY,
                              width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
