import AppKit
import SwiftUI

/// El icono de la carpeta para el Dock: un cuadrado redondeado de cristal con
/// las 9 primeras apps en miniatura, como las carpetas de iOS.
struct FolderIconArt: View {
    let icons: [NSImage]

    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            let box = s * 0.805
            let r = box * 0.225
            let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
            let cell = box * 0.235
            let gap = box * 0.05
            ZStack {
                shape
                    .fill(LinearGradient(colors: [Color(white: 0.34, opacity: 0.80), Color(white: 0.10, opacity: 0.88)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear],
                                                  startPoint: .top, endPoint: .center))
                    )
                    .overlay(
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.60), .white.opacity(0.06), .white.opacity(0.28)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing),
                                           lineWidth: max(1, s * 0.008))
                    )
                    .shadow(color: .black.opacity(0.35), radius: s * 0.02, y: s * 0.012)
                    .frame(width: box, height: box)
                VStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<3, id: \.self) { col in
                                let i = row * 3 + col
                                Group {
                                    if i < icons.count {
                                        Image(nsImage: icons[i]).resizable().interpolation(.high)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .frame(width: s, height: s)
        }
    }
}

@MainActor
enum IconRenderer {
    static func image(for paths: [String], size: CGFloat = 512) -> NSImage {
        let icons = paths.prefix(9).map { IconCache.icon($0) }
        let renderer = ImageRenderer(content: FolderIconArt(icons: Array(icons)).frame(width: size, height: size))
        renderer.scale = 1
        return renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
    }

    static func pngData(_ img: NSImage, px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Escribe un .icns (con iconutil) a partir de una imagen grande.
    @discardableResult
    static func writeICNS(_ img: NSImage, to dest: URL) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString).iconset")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let d = pngData(img, px: base * scale) else { return false }
                try? d.write(to: tmp.appendingPathComponent(name))
            }
        }
        return run("/usr/bin/iconutil", ["-c", "icns", tmp.path, "-o", dest.path]) == 0
    }

    /// Icono de la app principal (se genera al compilar).
    static func writeSample(to url: URL) -> Bool {
        let candidates = ["/System/Applications/Notes.app", "/System/Applications/Music.app",
                          "/System/Applications/Calendar.app", "/System/Applications/Photos.app",
                          "/System/Applications/Messages.app", "/System/Applications/Maps.app",
                          "/Applications/Safari.app", "/System/Applications/Mail.app",
                          "/System/Applications/Reminders.app", "/System/Applications/App Store.app"]
        let apps = Array(candidates.filter { FileManager.default.fileExists(atPath: $0) }.prefix(9))
        return writeICNS(image(for: apps, size: 1024), to: url)
    }
}
