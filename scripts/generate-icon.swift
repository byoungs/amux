#!/usr/bin/swift

import Cocoa

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: rounded rectangle (macOS icon shape)
let iconRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = size * 0.22
let bgPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).setFill()
bgPath.fill()

// Title bar
let titleBarHeight: CGFloat = size * 0.07
let titleBarRect = CGRect(x: size * 0.08, y: size - size * 0.08 - titleBarHeight,
                          width: size * 0.84, height: titleBarHeight)
NSColor(red: 0.15, green: 0.15, blue: 0.20, alpha: 1.0).setFill()
NSBezierPath(roundedRect: titleBarRect, xRadius: 8, yRadius: 8).fill()

// Traffic lights
let dotY = titleBarRect.midY
let dotRadius: CGFloat = size * 0.012
let dotSpacing: CGFloat = size * 0.026
let dotStartX: CGFloat = titleBarRect.origin.x + size * 0.025
for (i, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
    let dotX = dotStartX + CGFloat(i) * dotSpacing
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: dotX - dotRadius, y: dotY - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2)).fill()
}

// Pane grid area
let gridMargin: CGFloat = size * 0.08
let gridTop = titleBarRect.origin.y - size * 0.025
let gridRect = CGRect(x: gridMargin, y: gridMargin * 1.5,
                      width: size - gridMargin * 2,
                      height: gridTop - gridMargin * 1.5)

// 2x2 pane grid
let gap: CGFloat = size * 0.018
let paneW = (gridRect.width - gap) / 2
let paneH = (gridRect.height - gap) / 2
let paneRadius: CGFloat = size * 0.012

// Teal accent for active pane (top-left), dim for others
let activeBorder = NSColor(red: 0.27, green: 0.84, blue: 0.67, alpha: 0.8)  // teal (amux active color)
let inactiveBorder = NSColor(red: 0.25, green: 0.25, blue: 0.35, alpha: 0.5)
let alertBorder = NSColor(red: 0.84, green: 0.64, blue: 0.15, alpha: 0.8)   // amber (alert color)
let paneColor = NSColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1.0)

let paneConfigs: [(border: NSColor, textColor: NSColor, prompt: Bool)] = [
    (activeBorder, NSColor(red: 0.27, green: 0.84, blue: 0.67, alpha: 0.7), true),   // active
    (alertBorder, NSColor(red: 0.84, green: 0.64, blue: 0.15, alpha: 0.6), false),   // alert
    (inactiveBorder, NSColor(red: 0.4, green: 0.6, blue: 0.4, alpha: 0.4), false),   // working
    (inactiveBorder, NSColor(red: 0.4, green: 0.6, blue: 0.4, alpha: 0.4), false),   // working
]

for row in 0..<2 {
    for col in 0..<2 {
        let idx = row * 2 + col
        let config = paneConfigs[idx]
        let x = gridRect.origin.x + CGFloat(col) * (paneW + gap)
        let y = gridRect.origin.y + CGFloat(1 - row) * (paneH + gap)
        let paneRect = CGRect(x: x, y: y, width: paneW, height: paneH)

        // Pane background
        paneColor.setFill()
        let panePath = NSBezierPath(roundedRect: paneRect, xRadius: paneRadius, yRadius: paneRadius)
        panePath.fill()

        // Pane border
        config.border.setStroke()
        panePath.lineWidth = size * 0.004
        panePath.stroke()

        // Pane number label (top-left corner)
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size * 0.028, weight: .bold),
            .foregroundColor: config.border.withAlphaComponent(0.6)
        ]
        let numText = NSAttributedString(string: "\(idx + 1)", attributes: numAttrs)
        numText.draw(at: NSPoint(x: paneRect.origin.x + size * 0.015,
                                  y: paneRect.origin.y + paneRect.height - size * 0.04))

        // Terminal text lines
        config.textColor.setFill()
        let lineHeight: CGFloat = size * 0.010
        let lineGap: CGFloat = size * 0.016
        let lineMarginX: CGFloat = size * 0.015
        let lineStartY: CGFloat = paneRect.origin.y + paneRect.height - size * 0.06

        let widths: [CGFloat] = config.prompt
            ? [0.15, 0.65, 0.45, 0.8, 0.3, 0.55, 0.7]   // active: prompt + output
            : [0.7, 0.5, 0.85, 0.4, 0.6, 0.75, 0.35]     // working: streaming output

        for (line, widthFrac) in widths.enumerated() {
            let lx = paneRect.origin.x + lineMarginX
            let ly = lineStartY - CGFloat(line) * lineGap

            // Prompt symbol for active pane
            if config.prompt && line == 0 {
                let promptAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: size * 0.018, weight: .medium),
                    .foregroundColor: activeBorder.withAlphaComponent(0.8)
                ]
                NSAttributedString(string: "❯", attributes: promptAttrs)
                    .draw(at: NSPoint(x: lx, y: ly - lineHeight * 1.5))
                continue
            }

            let lw = (paneW - lineMarginX * 2) * widthFrac
            NSBezierPath(roundedRect: CGRect(x: lx, y: ly - lineHeight, width: lw, height: lineHeight),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

// Status bar at bottom
let statusBarHeight: CGFloat = size * 0.04
let statusRect = CGRect(x: gridMargin, y: gridMargin * 0.6,
                        width: size - gridMargin * 2, height: statusBarHeight)
NSColor(red: 0.15, green: 0.15, blue: 0.20, alpha: 1.0).setFill()
NSBezierPath(roundedRect: statusRect, xRadius: 4, yRadius: 4).fill()

// "amux" text in status bar
let statusAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: size * 0.022, weight: .bold),
    .foregroundColor: NSColor(red: 0.27, green: 0.84, blue: 0.67, alpha: 0.8)
]
NSAttributedString(string: "amux", attributes: statusAttrs)
    .draw(at: NSPoint(x: statusRect.origin.x + size * 0.015,
                      y: statusRect.origin.y + (statusBarHeight - size * 0.022) / 2))

// Alert dot in status bar
let dotR: CGFloat = size * 0.008
NSColor(red: 0.84, green: 0.64, blue: 0.15, alpha: 0.9).setFill()
NSBezierPath(ovalIn: CGRect(x: statusRect.maxX - size * 0.04, y: statusRect.midY - dotR,
                            width: dotR * 2, height: dotR * 2)).fill()

image.unlockFocus()

// Write PNG
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "amux_icon_1024.png"
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
