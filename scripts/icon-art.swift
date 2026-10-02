import SwiftUI
import Foundation

// Export YorozuMark geometry as flat SVG layers for Apple Icon Composer.
// Proportions match packages/shared-swift/Sources/YorozuShared/YorozuTheme.swift.
// Liquid Glass is supplied by Icon Composer/Xcode, never baked into these paths.
let dimension: CGFloat = 850
let rect = CGRect(x: 0, y: 0, width: dimension * 0.40, height: dimension * 0.86)
let outline = RoundedRectangle(cornerRadius: dimension * 0.22, style: .continuous)
    .path(in: rect).cgPath.copy(strokingWithWidth: dimension * 0.085,
                              lineCap: .butt, lineJoin: .miter, miterLimit: 10)
var commands: [String] = []
outline.applyWithBlock { pointer in
    let e = pointer.pointee
    func p(_ i: Int) -> String { "\(e.points[i].x) \(e.points[i].y)" }
    switch e.type {
    case .moveToPoint: commands.append("M\(p(0))")
    case .addLineToPoint: commands.append("L\(p(0))")
    case .addQuadCurveToPoint: commands.append("Q\(p(0)) \(p(1))")
    case .addCurveToPoint: commands.append("C\(p(0)) \(p(1)) \(p(2))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unknown path element")
    }
}
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
func write(_ name: String, _ content: String) throws {
    try ("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">" + content + "</svg>\n")
        .write(to: assets.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
}
for (appearance, ink, paper, center) in [
    ("light", "#4C5760", "#F1ECE4", "#BC2D1C"),
    ("dark", "#F1ECE4", "#4C5760", "#F06047"),
    ("tinted", "#FFFFFF", "#555555", "#DDDDDD")
] {
    for (name, angle) in [("loop-back", 45), ("loop-front", -45)] {
        try write("\(name)-\(appearance)", "<path fill=\"\(ink)\" d=\"\(commands.joined(separator: " "))\" transform=\"translate(512 512) rotate(\(angle)) translate(\(-rect.width / 2) \(-rect.height / 2))\"/>")
    }
    try write("center-ring-\(appearance)", "<circle cx=\"512\" cy=\"512\" r=\"\(dimension * 0.1225)\" fill=\"\(paper)\"/>")
    try write("center-\(appearance)", "<circle cx=\"512\" cy=\"512\" r=\"\(dimension * 0.0775)\" fill=\"\(center)\"/>")
}
