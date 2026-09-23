#!/usr/bin/env swift
// Inspect rendered UI, rather than source constants. Vision reports visible text and its
// pixel bounds for manual comparison of narrow/wide screenshots. OCR is evidence for review,
// not an accessibility audit or an assertion that a clipped label is semantically complete.
// Usage: swift scripts/inspect-native-screens.swift /tmp/yorozu-ui/*.png > /tmp/ui-text.json
import AppKit
import Foundation
import Vision

struct TextRegion: Encodable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Screen: Encodable {
    let file: String
    let width: Int
    let height: Int
    let text: [TextRegion]
}

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: swift scripts/inspect-native-screens.swift screenshot.png [...]\n", stderr)
    exit(1)
}

var screens: [Screen] = []
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let image = NSImage(contentsOf: url),
          let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { throw NSError(domain: "ScreenInspection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(path)"]) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: bitmap).perform([request])
    let regions = (request.results ?? []).compactMap { observation -> TextRegion? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return TextRegion(text: candidate.string, confidence: candidate.confidence,
                          x: box.minX * Double(bitmap.width),
                          y: (1 - box.maxY) * Double(bitmap.height),
                          width: box.width * Double(bitmap.width),
                          height: box.height * Double(bitmap.height))
    }
    screens.append(Screen(file: path, width: bitmap.width, height: bitmap.height, text: regions))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(screens))
FileHandle.standardOutput.write(Data("\n".utf8))
