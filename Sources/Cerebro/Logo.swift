import AppKit
import SwiftUI

/// The Cerebro logo, read from its SVG so it stays sharp at any size and takes any colour.
/// It has two parts: the pixel-brain mark and the "cerebro" wordmark.
enum Logo {
    enum Part {
        case mark, wordmark, full
    }

    /// Where to read the logo from; the app bundle by default.
    static var source = Bundle.main.url(forResource: "Logo", withExtension: "svg")

    /// One outline of the logo, in the SVG's own coordinates.
    struct Piece {
        let path: Path
        /// The mark is exported with the even-odd fill rule (its holes are cut that way); the letters are not.
        let isMark: Bool
    }

    /// Empty if the logo can't be read.
    static let pieces: [Piece] = {
        guard let source, let svg = try? String(contentsOf: source, encoding: .utf8) else { return [] }
        // Every outline is a <path>; the background is a <rect>, so it is left out.
        let pattern = try! NSRegularExpression(pattern: "<path d=\"([^\"]+)\"([^>]*)>")
        return pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap { match in
            guard let data = Range(match.range(at: 1), in: svg), let attributes = Range(match.range(at: 2), in: svg) else { return nil }
            return Piece(path: path(from: String(svg[data])), isMark: svg[attributes].contains("fill-rule=\"evenodd\""))
        }
    }()

    static func pieces(of part: Part) -> [Piece] {
        switch part {
        case .mark: return pieces.filter(\.isMark)
        case .wordmark: return pieces.filter { !$0.isMark }
        case .full: return pieces
        }
    }

    static func bounds(of part: Part) -> CGRect {
        pieces(of: part).reduce(CGRect.null) { $0.union($1.path.boundingRect) }
    }

    /// The mark as a menu bar image that macOS tints itself. Nil if the logo has no mark.
    static func markImage(height: CGFloat) -> NSImage? {
        let bounds = bounds(of: .mark)
        guard !bounds.isNull, bounds.height > 0 else { return nil }
        let size = NSSize(width: (height * bounds.width / bounds.height).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(LogoShape(drawing: .mark, fitting: .mark).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Parses the subset of SVG path syntax that design tools export: absolute M, L, H, V, C and Z.
    private static func path(from data: String) -> Path {
        var path = Path()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        var current = CGPoint.zero

        // Draws whatever the numbers collected since the last command letter describe.
        func flush() {
            switch command {
            case "M", "L":
                for index in stride(from: 0, to: numbers.count - 1, by: 2) {
                    current = CGPoint(x: numbers[index], y: numbers[index + 1])
                    // Extra coordinate pairs after a move are lines.
                    if command == "M", index == 0 { path.move(to: current) } else { path.addLine(to: current) }
                }
            case "H":
                for x in numbers {
                    current.x = x
                    path.addLine(to: current)
                }
            case "V":
                for y in numbers {
                    current.y = y
                    path.addLine(to: current)
                }
            case "C":
                for index in stride(from: 0, to: numbers.count - 5, by: 6) {
                    current = CGPoint(x: numbers[index + 4], y: numbers[index + 5])
                    path.addCurve(to: current,
                                  control1: CGPoint(x: numbers[index], y: numbers[index + 1]),
                                  control2: CGPoint(x: numbers[index + 2], y: numbers[index + 3]))
                }
            default:
                break
            }
            numbers.removeAll()
        }

        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        while !scanner.isAtEnd {
            if let number = scanner.scanDouble() {
                numbers.append(number)
            } else if let letter = scanner.scanCharacter() {
                flush()
                command = letter
                if letter == "Z" { path.closeSubpath() }
            }
        }
        flush()
        return path
    }
}

/// One part of the logo, scaled to fit its frame while keeping its proportions.
struct LogoShape: Shape {
    /// The part to draw.
    let drawing: Logo.Part
    /// The part whose outline is fitted to the frame. Drawing the mark while fitting the full logo
    /// puts the mark where it sits in the lockup, so the two parts can be layered.
    let fitting: Logo.Part

    func path(in rect: CGRect) -> Path {
        let bounds = Logo.bounds(of: fitting)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return Path() }

        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let fit = CGAffineTransform(translationX: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            .scaledBy(x: scale, y: scale)
        var path = Path()
        for piece in Logo.pieces(of: drawing) { path.addPath(piece.path, transform: fit) }
        return path
    }
}

/// The logo, or one part of it, at a given height. Falls back to plain text if the logo file is missing.
struct LogoView: View {
    let height: CGFloat
    var part = Logo.Part.full
    var color = Cosmic.brand

    var body: some View {
        let bounds = Logo.bounds(of: part)
        if bounds.isNull {
            Text("cerebro")
                .font(.system(size: height * 1.2, weight: .heavy))
                .foregroundStyle(color)
        } else {
            ZStack {
                if part != .mark { LogoShape(drawing: .wordmark, fitting: part).fill(color) }
                if part != .wordmark { LogoShape(drawing: .mark, fitting: part).fill(color, style: FillStyle(eoFill: true)) }
            }
            .frame(width: height * bounds.width / bounds.height, height: height)
        }
    }
}
