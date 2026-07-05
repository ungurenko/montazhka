#!/usr/bin/env swift
// Рисует иконку Монтажки и собирает Resources/AppIcon.icns.
// Запуск: swift scripts/make-icon.swift

import AppKit

let size: CGFloat = 1024

func drawIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Подложка-«сквиркл» с отступом, как у системных иконок macOS
    let inset: CGFloat = size * 0.098
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Лёгкая тень
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.016
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    shadow.set()

    // Светлый градиент — фирменный стиль приложения
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.91, blue: 1.0, alpha: 1)
    ])
    gradient?.draw(in: squircle, angle: -90)

    // Волна звука: синие столбики по центру
    let accent = NSColor(calibratedRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)
    let heights: [CGFloat] = [0.18, 0.34, 0.52, 0.72, 0.44, 0.60, 0.28, 0.66, 0.50, 0.36, 0.20]
    let barWidth = rect.width * 0.045
    let gap = rect.width * 0.028
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - totalWidth / 2
    let maxBar = rect.height * 0.46

    for h in heights {
        let barHeight = maxBar * h
        let barRect = NSRect(x: x, y: rect.midY - barHeight / 2 + rect.height * 0.06,
                             width: barWidth, height: barHeight)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        accent.setFill()
        bar.fill()
        x += barWidth + gap
    }

    // Ножницы: разрез между столбиками — вертикальная «линия среза» и символ
    let cutX = rect.midX + (barWidth + gap) * 1.5 - gap / 2
    let cutLine = NSBezierPath()
    cutLine.move(to: NSPoint(x: cutX, y: rect.midY - maxBar * 0.62 + rect.height * 0.06))
    cutLine.line(to: NSPoint(x: cutX, y: rect.midY + maxBar * 0.62 + rect.height * 0.06))
    cutLine.lineWidth = size * 0.012
    let dash: [CGFloat] = [size * 0.030, size * 0.022]
    cutLine.setLineDash(dash, count: 2, phase: 0)
    NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).setStroke()
    cutLine.stroke()

    // Символ ножниц под волной
    if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.11, weight: .semibold)
        let symbol = scissors.withSymbolConfiguration(config)!
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let symbolSize = tinted.size
        tinted.draw(in: NSRect(x: cutX - symbolSize.width / 2,
                               y: rect.minY + rect.height * 0.10,
                               width: symbolSize.width, height: symbolSize.height))
    }

    image.unlockFocus()
    return image
}

// Сохраняем PNG всех размеров и собираем .icns
let icon = drawIcon()
let iconsetURL = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for entry in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(entry.px), pixelsHigh: Int(entry.px),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: entry.px, height: entry.px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: entry.px, height: entry.px),
              from: NSRect(x: 0, y: 0, width: size, height: size),
              operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconsetURL.appendingPathComponent("\(entry.name).png"))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", "Resources/AppIcon.iconset", "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)
print(task.terminationStatus == 0 ? "✓ Resources/AppIcon.icns готова" : "✗ iconutil failed")
