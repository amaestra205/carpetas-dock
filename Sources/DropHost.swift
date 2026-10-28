import AppKit
import SwiftUI

/// Vista anfitriona de la carpeta abierta que recibe directamente los arrastres que vienen
/// de fuera (Dock, Finder, Launchpad…). Los arrastres internos (reordenar) los sigue gestionando SwiftUI.
final class DropHostingView<Content: View>: NSHostingView<Content> {
    weak var controller: FolderController?

    static var externalTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string,
         NSPasteboard.PasteboardType("NSFilenamesPboardType"),
         NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
         NSPasteboard.PasteboardType("public.url"),
         NSPasteboard.PasteboardType("com.apple.application-bundle")]
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + Self.externalTypes)))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    private func isExternal(_ s: NSDraggingInfo) -> Bool { s.draggingSource == nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isExternal(sender) else { return super.draggingEntered(sender) }
        DebugLog.log("drag entered types=\(sender.draggingPasteboard.types?.map(\.rawValue) ?? [])")
        controller?.externalTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isExternal(sender) else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let s = sender, !isExternal(s) { super.draggingExited(sender); return }
        controller?.externalTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isExternal(sender) else { return super.prepareForDragOperation(sender) }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isExternal(sender) else { return super.performDragOperation(sender) }
        controller?.externalTargeted = false
        let paths = Self.appPaths(from: sender.draggingPasteboard)
        DebugLog.log("drop -> \(paths)")
        guard !paths.isEmpty else { return false }
        controller?.add(paths: paths, before: nil)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let s = sender, !isExternal(s) { super.concludeDragOperation(sender) }
    }

    /// Saca rutas de .app de cualquier formato que traiga el arrastre.
    static func appPaths(from pb: NSPasteboard) -> [String] {
        var urls: [URL] = []
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] { urls += objs }
        if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls += list.map { URL(fileURLWithPath: $0) }
        }
        for item in pb.pasteboardItems ?? [] {
            for t in item.types {
                if let s = item.string(forType: t) {
                    DebugLog.log("  item \(t.rawValue) = \(s.prefix(200))")
                    urls += urlsFromString(s)
                } else if let d = item.data(forType: t),
                          let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) {
                    DebugLog.log("  item \(t.rawValue) plist = \(String(describing: plist).prefix(300))")
                    urls += urlsFromPlist(plist)
                }
            }
        }
        var seen = Set<String>()
        return urls.compactMap(AppPaths.normalize).filter { seen.insert($0).inserted }
    }

    private static func urlsFromString(_ raw: String) -> [URL] {
        var out: [URL] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("file://"), let u = URL(string: s) { out.append(u) }
            else if s.hasPrefix("/") { out.append(URL(fileURLWithPath: s)) }
            else if !s.contains(" "), !s.contains("/"), s.contains("."),
                    let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s) { out.append(u) }
        }
        return out
    }

    private static func urlsFromPlist(_ p: Any) -> [URL] {
        if let s = p as? String { return urlsFromString(s) }
        if let a = p as? [Any] { return a.flatMap(urlsFromPlist) }
        if let d = p as? [String: Any] { return d.values.flatMap(urlsFromPlist) }
        return []
    }
}
