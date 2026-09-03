//  CartridgeLabel.swift
//  Desenha a etiqueta do cartucho no padrão americano: fundo preto, arte da
//  capa no centro e a faixa vertical à direita. Sem capa, um bloco de cor
//  derivado do título com o nome do jogo por cima.

import AppKit

enum CartridgeLabel {
    /// Proporção do rebaixo do rótulo na malha (3,23 × 1,52).
    static let size = NSSize(width: 1400, height: 660)

    static func render(title: String, cover: NSImage?) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(white: 0.06, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let art = NSRect(x: 120, y: 30, width: 1010, height: size.height - 60)
        if let cover {
            drawCover(cover, in: art)
        } else {
            drawPlaceholder(title: title, in: art)
        }
        NSColor(white: 0.35, alpha: 1).setStroke()
        let frame = NSBezierPath(rect: art)
        frame.lineWidth = 3
        frame.stroke()

        // Coluna esquerda: licença e o selo dourado.
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
        ]
        ("LICENSED BY" as NSString).draw(at: NSPoint(x: 28, y: size.height - 70), withAttributes: small)
        ("NINTENDO" as NSString).draw(at: NSPoint(x: 28, y: size.height - 100), withAttributes: small)
        NSColor(calibratedRed: 0.85, green: 0.72, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 40, y: 250, width: 80, height: 80)).fill()

        // Faixa direita: os quatro pontos e "SUPER NINTENDO" na vertical.
        let stripe = NSRect(x: 1150, y: 30, width: 230, height: size.height - 60)
        NSColor(white: 0.12, alpha: 1).setFill()
        stripe.fill()
        let dots: [NSColor] = [.systemRed, .systemBlue, .systemYellow, .systemGreen]
        for (i, color) in dots.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1190 + CGFloat(i % 2) * 48, y: 480 + CGFloat(i / 2) * 48,
                                        width: 40, height: 40)).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 1250, yBy: 420)
        transform.rotate(byDegrees: -90)
        transform.concat()
        ("SUPER NINTENDO" as NSString).draw(at: NSPoint(x: 0, y: -22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .black), .foregroundColor: NSColor.white,
        ])
        ("ENTERTAINMENT SYSTEM" as NSString).draw(at: NSPoint(x: 0, y: -50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor(white: 0.7, alpha: 1),
        ])
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    /// Capa preenchendo a área da arte, cortada pelo centro se a proporção diferir.
    private static func drawCover(_ cover: NSImage, in rect: NSRect) {
        let coverSize = cover.size
        guard coverSize.width > 0, coverSize.height > 0 else { return }
        let scale = max(rect.width / coverSize.width, rect.height / coverSize.height)
        let drawn = NSSize(width: coverSize.width * scale, height: coverSize.height * scale)
        let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        cover.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPlaceholder(title: String, in rect: NSRect) {
        let (start, end) = placeholderColors(for: title)
        NSGradient(starting: start, ending: end)?.draw(in: rect, angle: -35)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: title.count > 18 ? 78 : 104, weight: .heavy),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow,
        ]
        let text = title as NSString
        let bounds = text.boundingRect(with: NSSize(width: rect.width - 80, height: rect.height),
                                       options: [.usesLineFragmentOrigin], attributes: attributes)
        text.draw(in: NSRect(x: rect.minX + 40, y: rect.midY - bounds.height / 2,
                             width: rect.width - 80, height: bounds.height), withAttributes: attributes)
    }

    /// Duas cores estáveis por título, para cada jogo sem capa ter a sua.
    private static func placeholderColors(for title: String) -> (NSColor, NSColor) {
        var hash: UInt32 = 2166136261
        for byte in title.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = CGFloat(hash % 360) / 360
        return (NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.62, alpha: 1),
                NSColor(calibratedHue: hue, saturation: 0.7, brightness: 0.18, alpha: 1))
    }
}
