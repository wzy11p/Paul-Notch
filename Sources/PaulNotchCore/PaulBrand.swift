import AppKit

/// Original P/notch mark. One scalable silhouette for both application and template icons.
enum PaulBrand {
    static func mark() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 24, y: 78))
        path.curve(to: NSPoint(x: 31, y: 85), controlPoint1: NSPoint(x: 24, y: 82), controlPoint2: NSPoint(x: 27, y: 85))
        path.line(to: NSPoint(x: 43, y: 85))
        path.curve(to: NSPoint(x: 59, y: 85), controlPoint1: NSPoint(x: 47, y: 77), controlPoint2: NSPoint(x: 55, y: 77))
        path.line(to: NSPoint(x: 63, y: 85))
        path.curve(to: NSPoint(x: 63, y: 42), controlPoint1: NSPoint(x: 92, y: 85), controlPoint2: NSPoint(x: 92, y: 42))
        path.line(to: NSPoint(x: 44, y: 42))
        path.curve(to: NSPoint(x: 39, y: 37), controlPoint1: NSPoint(x: 40, y: 42), controlPoint2: NSPoint(x: 39, y: 41))
        path.line(to: NSPoint(x: 39, y: 18))
        path.curve(to: NSPoint(x: 36, y: 15), controlPoint1: NSPoint(x: 39, y: 16), controlPoint2: NSPoint(x: 38, y: 15))
        path.line(to: NSPoint(x: 26, y: 15))
        path.curve(to: NSPoint(x: 23, y: 18), controlPoint1: NSPoint(x: 24, y: 15), controlPoint2: NSPoint(x: 23, y: 16))
        path.line(to: NSPoint(x: 23, y: 37))
        path.curve(to: NSPoint(x: 44, y: 58), controlPoint1: NSPoint(x: 23, y: 50), controlPoint2: NSPoint(x: 32, y: 58))
        path.line(to: NSPoint(x: 63, y: 58))
        path.curve(to: NSPoint(x: 63, y: 69), controlPoint1: NSPoint(x: 72, y: 58), controlPoint2: NSPoint(x: 72, y: 69))
        path.line(to: NSPoint(x: 32, y: 69))
        path.curve(to: NSPoint(x: 24, y: 78), controlPoint1: NSPoint(x: 27, y: 69), controlPoint2: NSPoint(x: 24, y: 72))
        path.close()
        return path
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = AffineTransform(scale: 0.22)
            (transform as NSAffineTransform).concat()
            let path = mark()
            let offset = AffineTransform(translationByX: -12, byY: -9)
            path.transform(using: offset)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Paul Notch"
        return image
    }
}
