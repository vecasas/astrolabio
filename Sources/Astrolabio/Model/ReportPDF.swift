import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Dibuja un `ReportDocument` en un PDF A4 de varias páginas con Core Graphics y Core Text.
enum ReportPDF {
    static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4 en puntos
    private static let margin: CGFloat = 42
    private static let headerHeight: CGFloat = 64

    private static let blue = CGColor(red: 0.07, green: 0.20, blue: 0.45, alpha: 1)
    private static let lightBlue = CGColor(red: 0.32, green: 0.63, blue: 1.0, alpha: 1)
    private static let paleBlue = CGColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1)
    private static let textColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1)
    private static let mutedColor = NSColor(calibratedRed: 0.38, green: 0.43, blue: 0.52, alpha: 1)

    static func render(_ doc: ReportDocument) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [
                kCGPDFContextTitle: "\(doc.title) — \(doc.subtitle)",
                kCGPDFContextCreator: "\(AppInfo.name) \(AppInfo.version)",
                kCGPDFContextAuthor: AppInfo.name,
              ] as CFDictionary) else { return Data() }
        var w = Writer(ctx: ctx, doc: doc)
        w.run()
        ctx.closePDF()
        return data as Data
    }

    private struct Writer {
        let ctx: CGContext
        let doc: ReportDocument
        var y: CGFloat = 0          // distancia desde el borde superior
        var page = 0
        var width: CGFloat { pageSize.width - 2 * margin }

        mutating func run() {
            newPage()
            text(doc.title, font: .systemFont(ofSize: 22, weight: .bold), color: textColor)
            text(doc.subtitle, font: .systemFont(ofSize: 13), color: mutedColor)
            y += 8
            section(tr("Resumen"), rows: doc.summary)
            section(tr("Condiciones"), rows: doc.conditions)
            if !doc.objects.isEmpty {
                heading(tr("Objetos observados"))
                for o in doc.objects { object(o) }
            }
            if !doc.device.isEmpty { section(tr("Telescopio"), rows: doc.device) }
            heading(tr("Eventos y errores"))
            if doc.events.isEmpty {
                text(tr("No hay eventos registrados para esta sesión."), font: .systemFont(ofSize: 9.5), color: mutedColor)
            } else {
                for e in doc.events { text(e, font: .monospacedSystemFont(ofSize: 8, weight: .regular), color: textColor, spacing: 1.5) }
            }
            finishPage()
        }

        // MARK: Páginas

        mutating func newPage() {
            if page > 0 { finishPage() }
            page += 1
            ctx.beginPDFPage(nil)
            // Cabecera azul con el nombre y la versión de la app.
            ctx.setFillColor(blue)
            ctx.fill(CGRect(x: 0, y: pageSize.height - headerHeight, width: pageSize.width, height: headerHeight))
            ctx.setFillColor(lightBlue)
            ctx.fill(CGRect(x: 0, y: pageSize.height - headerHeight - 3, width: pageSize.width, height: 3))
            draw("✦ \(AppInfo.name)", at: CGPoint(x: margin, y: 22), width: 300,
                 font: .systemFont(ofSize: 18, weight: .bold), color: .white)
            draw(tr("Versión %@", AppInfo.version), at: CGPoint(x: margin, y: 43), width: 300,
                 font: .systemFont(ofSize: 9), color: NSColor(calibratedWhite: 1, alpha: 0.75))
            draw(doc.title, at: CGPoint(x: pageSize.width - margin - 220, y: 26), width: 220,
                 font: .systemFont(ofSize: 11, weight: .semibold), color: .white, alignment: .right)
            y = headerHeight + 26
        }

        mutating func finishPage() {
            let footer = "\(doc.footer)   ·   \(tr("Página %d", page))"
            draw(footer, at: CGPoint(x: margin, y: pageSize.height - 26), width: width,
                 font: .systemFont(ofSize: 8), color: mutedColor, alignment: .center)
            ctx.endPDFPage()
        }

        mutating func ensure(_ h: CGFloat) {
            if y + h > pageSize.height - margin - 14 { newPage() }
        }

        // MARK: Bloques

        mutating func heading(_ s: String) {
            ensure(46)
            y += 8
            ctx.setFillColor(lightBlue)
            ctx.fill(flip(CGRect(x: margin, y: y + 2, width: 3, height: 14)))
            draw(s, at: CGPoint(x: margin + 9, y: y), width: width - 9, font: .systemFont(ofSize: 13, weight: .semibold), color: textColor)
            y += 22
        }

        mutating func section(_ title: String, rows: [ReportDocument.Row]) {
            heading(title)
            table(rows, width: width)
            y += 4
        }

        mutating func table(_ rows: [ReportDocument.Row], x: CGFloat = margin, width: CGFloat) {
            let labelW = min(170, width * 0.42)
            let font = NSFont.systemFont(ofSize: 9.5)
            for (i, r) in rows.enumerated() {
                let h = max(measure(r.value, width: width - labelW - 12, font: font),
                            measure(r.label, width: labelW - 8, font: font)) + 6
                ensure(h)
                if i % 2 == 0 {
                    ctx.setFillColor(paleBlue)
                    ctx.fill(flip(CGRect(x: x, y: y, width: width, height: h)))
                }
                draw(r.label, at: CGPoint(x: x + 6, y: y + 3), width: labelW - 8, font: font, color: mutedColor)
                draw(r.value, at: CGPoint(x: x + labelW, y: y + 3), width: width - labelW - 8, font: font, color: textColor)
                y += h
            }
        }

        mutating func object(_ o: ReportDocument.ObjectBlock) {
            let imgW: CGFloat = o.image == nil ? 0 : 170
            let tableW = width - (imgW > 0 ? imgW + 14 : 0)
            let font = NSFont.systemFont(ofSize: 9.5)
            let rowsH = o.rows.reduce(CGFloat(0)) { $0 + measure($1.value, width: tableW * 0.58 - 12, font: font) + 6 }
            let imgH: CGFloat = o.image.map { imgW * CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? 0
            // Se intenta no partir el bloque de un objeto entre páginas.
            ensure(min(36 + max(rowsH, min(imgH, 240)), pageSize.height - headerHeight - 2 * margin - 20))
            draw(o.title, at: CGPoint(x: margin, y: y), width: width, font: .systemFont(ofSize: 12, weight: .bold), color: textColor)
            y += 17
            if !o.subtitle.isEmpty {
                draw(o.subtitle, at: CGPoint(x: margin, y: y), width: width, font: .systemFont(ofSize: 9), color: mutedColor)
                y += 13
            }
            let top = y
            if let img = o.image {
                let h = min(imgH, 240), w = h * CGFloat(img.width) / CGFloat(max(img.height, 1))
                let r = CGRect(x: margin + width - imgW + (imgW - w) / 2, y: top, width: w, height: h)
                ctx.draw(img, in: flip(r))
                ctx.setStrokeColor(lightBlue); ctx.setLineWidth(0.6)
                ctx.stroke(flip(r))
                table(o.rows, width: tableW)
                y = max(y, top + h)
            } else {
                table(o.rows, width: tableW)
            }
            y += 12
        }

        mutating func text(_ s: String, font: NSFont, color: NSColor, spacing: CGFloat = 3) {
            let h = measure(s, width: width, font: font)
            ensure(h)
            draw(s, at: CGPoint(x: margin, y: y), width: width, font: font, color: color)
            y += h + spacing
        }

        // MARK: Dibujo con Core Text (coordenadas desde arriba)

        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: pageSize.height - r.maxY, width: r.width, height: r.height)
        }

        func attributed(_ s: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
            let p = NSMutableParagraphStyle()
            p.alignment = alignment
            p.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        }

        func measure(_ s: String, width: CGFloat, font: NSFont) -> CGFloat {
            let fs = CTFramesetterCreateWithAttributedString(attributed(s, font: font, color: textColor))
            let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil,
                                                                    CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            return ceil(size.height)
        }

        func draw(_ s: String, at p: CGPoint, width: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
            let h = measure(s, width: width, font: font) + 2
            let fs = CTFramesetterCreateWithAttributedString(attributed(s, font: font, color: color, alignment: alignment))
            let path = CGPath(rect: flip(CGRect(x: p.x, y: p.y, width: width, height: h)), transform: nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(), path, nil)
            ctx.saveGState()
            ctx.textMatrix = .identity
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
    }
}
