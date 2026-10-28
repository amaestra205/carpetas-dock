import AppKit

/// Cada carpeta es una copia de esta misma app con su propio identificador,
/// guardada en ~/Applications/Carpetas Dock/. Así cada una tiene su icono en el Dock.
@MainActor
enum Bundles {
    static let baseID = "io.github.amaestra205.carpetasdock"
    static var folderID: String? { Bundle.main.object(forInfoDictionaryKey: "CDFolderID") as? String }

    static func bundleURL(for id: String) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.bundlesDir, includingPropertiesForKeys: nil)) ?? []
        return items.first { u in
            guard u.pathExtension == "app",
                  let d = try? Data(contentsOf: u.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
            else { return false }
            return (info["CDFolderID"] as? String) == id
        }
    }

    static func safeFileName(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Carpeta" : n
    }

    static func uniqueURL(for name: String, excluding: URL? = nil) -> URL {
        let base = safeFileName(name)
        var url = Paths.bundlesDir.appendingPathComponent(base + ".app")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path),
              url.standardizedFileURL.path != excluding?.standardizedFileURL.path {
            url = Paths.bundlesDir.appendingPathComponent("\(base) \(i).app")
            i += 1
        }
        return url
    }

    static func editInfo(_ bundle: URL, _ changes: [String: Any]) {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let d = try? Data(contentsOf: plistURL),
              var dict = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return }
        for (k, v) in changes { dict[k] = v }
        if let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? out.write(to: plistURL)
        }
    }

    static func sign(_ bundle: URL) {
        run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        run(Paths.lsregister, ["-f", bundle.path])
    }

    /// Solo para paquetes que NO se están ejecutando.
    static func writeStaticIcon(bundle: URL, apps: [String]) {
        let dest = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
        IconRenderer.writeICNS(IconRenderer.image(for: apps, size: 1024), to: dest)
        editInfo(bundle, ["CFBundleIconFile": "AppIcon"])
    }

    /// App de la que se copian las carpetas nuevas: la app principal instalada si existe
    /// (así una carpeta creada desde el menú de otra carpeta no hereda nada de ella).
    static var templateURL: URL {
        if folderID != nil,
           let main = NSWorkspace.shared.urlForApplication(withBundleIdentifier: baseID),
           FileManager.default.fileExists(atPath: main.path) {
            return main
        }
        return Bundle.main.bundleURL
    }

    @discardableResult
    static func createFolder(name: String, open: Bool = true) -> URL? {
        let id = UUID().uuidString.lowercased()
        let short = String(id.replacingOccurrences(of: "-", with: "").prefix(10))
        let dest = uniqueURL(for: name)
        do {
            try FileManager.default.copyItem(at: templateURL, to: dest)
        } catch {
            NSLog("CarpetasDock: no se pudo copiar la plantilla: \(error)")
            return nil
        }
        editInfo(dest, ["CFBundleIdentifier": "\(baseID).f.\(short)",
                        "CFBundleName": name, "CFBundleDisplayName": name, "CDFolderID": id])
        Store.save(FolderConfig(id: id, name: name, apps: []))
        writeStaticIcon(bundle: dest, apps: [])
        sign(dest)
        DockPrefs.apply(add: [dest.path])
        if open {
            NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration())
        }
        return dest
    }

    /// Borra una carpeta (la app de la carpeta, no las apps que contiene).
    static func deleteFolder(id: String) {
        let cfg = Store.load(id)
        let isSelf = folderID == id
        let url = isSelf ? Bundle.main.bundleURL : bundleURL(for: id)
        if !isSelf, let url, let bid = Bundle(url: url)?.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).forEach { $0.terminate() }
        }
        Store.delete(id)
        let back = Settings.moveFromDock
            ? (cfg?.fromDock ?? []).filter { FileManager.default.fileExists(atPath: $0) } : []
        DockPrefs.apply(remove: url.map { [$0.path] } ?? [], add: back)
        if let url { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Cambia el nombre del paquete (lo que se ve al pasar el ratón por el Dock) y vuelve a abrir la carpeta.
    /// Los cambios de archivos se hacen desde un script cuando esta app ya se ha cerrado.
    static func renameSelfAndRelaunch(to name: String) {
        let old = Bundle.main.bundleURL
        let new = uniqueURL(for: name, excluding: old)
        editInfo(old, ["CFBundleName": name, "CFBundleDisplayName": name])
        DockPrefs.apply(replace: [.init(old: old.path, new: new.path, label: name,
                                        bundleID: Bundle.main.bundleIdentifier)], restart: false)
        let script = """
        sleep 0.8
        if [ "$1" != "$2" ]; then /bin/mv "$1" "$2" || exit 1; fi
        /usr/bin/codesign --force --sign - "$2"
        "\(Paths.lsregister)" -f "$2"
        /usr/bin/killall Dock
        sleep 1.2
        /usr/bin/open "$2" --args --silent
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", old.path, new.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
