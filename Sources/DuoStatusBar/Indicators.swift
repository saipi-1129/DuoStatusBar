import AppKit

func ethernetImage(color: NSColor = .white) -> NSImage {
    NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        color.setStroke()
        let port = NSBezierPath()
        port.move(to: NSPoint(x: 6, y: 18))
        port.line(to: NSPoint(x: 2, y: 12))
        port.line(to: NSPoint(x: 6, y: 6))
        port.move(to: NSPoint(x: 18, y: 18))
        port.line(to: NSPoint(x: 22, y: 12))
        port.line(to: NSPoint(x: 18, y: 6))
        port.lineWidth = 2
        port.lineCapStyle = .round
        port.lineJoinStyle = .round
        port.stroke()
        color.setFill()
        for x in [8.0, 12.0, 16.0] {
            NSBezierPath(ovalIn: NSRect(x: x - 1, y: 11, width: 2, height: 2)).fill()
        }
        return true
    }
}

// Start just right of the volume dots. As charge falls, the unfilled
// section grows from the bottom-right toward the right side and top.
enum BatteryOutline {
    static var segments: [[NSPoint]] {
        var points = [NSPoint(x: 58, y: 2), NSPoint(x: 21, y: 2)]
        for i in 1...180 {
            let angle = Double(270 - i) * .pi / 180
            points.append(NSPoint(x: 21 + 12 * cos(angle), y: 14 + 12 * sin(angle)))
        }
        points.append(NSPoint(x: 67, y: 26))
        for i in 1...180 {
            let angle = Double(90 - i) * .pi / 180
            points.append(NSPoint(x: 67 + 12 * cos(angle), y: 14 + 12 * sin(angle)))
        }
        points.append(points[0])
        return [points]
    }
    static func length(_ paths: [[NSPoint]]) -> CGFloat {
        paths.reduce(0) { sum, points in
            sum + zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }
    static func prefix(_ fraction: Double) -> [[NSPoint]] {
        var remaining = length(segments) * max(0, min(1, fraction))
        var output: [[NSPoint]] = []
        for points in segments {
            guard remaining > 0 else { break }
            var part = [points[0]]
            for (a, b) in zip(points, points.dropFirst()) {
                let distance = hypot(b.x - a.x, b.y - a.y)
                if remaining >= distance {
                    part.append(b)
                    remaining -= distance
                } else {
                    let t = remaining / distance
                    part.append(NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    remaining = 0
                    break
                }
            }
            output.append(part)
        }
        return output
    }
    static func draw(_ percent: Int?, color: NSColor, showsNumber: Bool = true) {
        func stroke(_ segments: [[NSPoint]], _ opacity: CGFloat) {
            let path = NSBezierPath()
            for points in segments {
                // Split before stroking so the reference's gaps have round ends.
                // Subdivide straight edges as well as curves to resolve each gap.
                var drawing = false
                for (a, b) in zip(points, points.dropFirst()) {
                    let steps = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / 0.2)))
                    for step in 0...steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        let p = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                        let hidden = (p.y < 4 && p.x > 28 && p.x < 60)
                            || (showsNumber && p.y > 20 && p.x > 57 && p.x < 75)
                        if hidden { drawing = false; continue }
                        if drawing { path.line(to: p) } else { path.move(to: p); drawing = true }
                    }
                }
            }
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.withAlphaComponent(color.alphaComponent * opacity).setStroke()
            path.stroke()
        }
        stroke(segments, 0.20)
        if let percent { stroke(prefix(Double(percent) / 100), 1) }
    }
}
