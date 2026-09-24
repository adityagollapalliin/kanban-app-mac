#!/usr/bin/env swift
//
// Draws the app icon and writes the .appiconset.
//
// The icon is generated rather than checked in as art nobody can edit: the
// shape is a few lines of geometry here, so changing it is changing code
// instead of opening a drawing program. Run it after editing:
//
//   swift Scripts/make-icon.swift
//
// It writes every size macOS asks for, plus the Contents.json listing them.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

/// Draws the board: three columns, with cards sitting in them.
func drawIcon(size: CGFloat, into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons are inset inside their canvas rather than filling it.
    let inset = size * 0.085
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237   // the usual macOS squircle proportion

    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(platePath)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.29, 0.36, 0.86, 1])!,
            CGColor(colorSpace: space, components: [0.18, 0.55, 0.90, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // The three columns.
    let boardInset = plate.width * 0.13
    let board = plate.insetBy(dx: boardInset, dy: boardInset)
    let gap = board.width * 0.07
    let columnWidth = (board.width - gap * 2) / 3

    // How many cards each column holds, and how tall each card is as a
    // fraction of the column. A board that is not uniform reads as a board in
    // use rather than a diagram of one.
    let columns: [[CGFloat]] = [[0.30, 0.22, 0.18], [0.26, 0.20], [0.24]]

    for (index, cards) in columns.enumerated() {
        let x = board.minX + (columnWidth + gap) * CGFloat(index)
        let columnRect = CGRect(x: x, y: board.minY, width: columnWidth, height: board.height)

        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.addPath(CGPath(
            roundedRect: columnRect,
            cornerWidth: columnWidth * 0.14,
            cornerHeight: columnWidth * 0.14,
            transform: nil
        ))
        context.fillPath()

        // Cards stack from the top of the column downwards.
        var cursor = columnRect.maxY - columnWidth * 0.16
        for height in cards {
            let cardHeight = board.height * height
            let card = CGRect(
                x: columnRect.minX + columnWidth * 0.14,
                y: cursor - cardHeight,
                width: columnWidth - columnWidth * 0.28,
                height: cardHeight
            )

            context.setFillColor(CGColor(gray: 1, alpha: 0.93))
            context.addPath(CGPath(
                roundedRect: card,
                cornerWidth: card.width * 0.16,
                cornerHeight: card.width * 0.16,
                transform: nil
            ))
            context.fillPath()

            cursor = card.minY - columnWidth * 0.12
        }
    }
}

func writePNG(size: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no context at \(size)px"])
    }

    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not encode \(size)px"])
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not write \(url.lastPathComponent)"])
    }
}

// The sizes macOS asks for, as (points, scale).
let wanted: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var entries: [String] = []
for (points, scale) in wanted {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try writePNG(size: points * scale, to: iconset.appendingPathComponent(name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
    print("  \(name)  (\(points * scale)px)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "Scripts/make-icon.swift",
    "version" : 1
  }
}

"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(iconset.path)")
