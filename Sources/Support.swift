import AppKit
import Foundation

// MARK: - Modelo de una carpeta

struct FolderConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Rutas a los .app, en el orden en que se muestran.
    var apps: [String]
    /// Apps que estaban en el Dock cuando se metieron en la carpeta (vuelven a él si se sacan).
    var fromDock: [String]? = nil
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CarpetasDock/folders", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let bundlesDir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Carpetas Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func config(_ id: String) -> URL { support.appendingPathComponent("\(id).json") }
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}

enum Store {
    static func load(_ id: String) -> FolderConfig? {
        guard let d = try? Data(contentsOf: Paths.config(id)) else { return nil }
        return try? JSONDecoder().decode(FolderConfig.self, from: d)
    }
    static func save(_ c: FolderConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(c) { try? d.write(to: Paths.config(c.id), options: .atomic) }
    }
    static func all() -> [FolderConfig] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.support, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url -> FolderConfig? in
                guard let d = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(FolderConfig.self, from: d)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: Paths.config(id)) }
}

enum Settings {
    static let defaults = UserDefaults(suiteName: "io.github.amaestra205.carpetasdock.ajustes") ?? .standard
    /// Como en iOS: meter una app en una carpeta la quita del Dock (y sacarla la devuelve).
    static var moveFromDock: Bool {
        get { (defaults.object(forKey: "moveFromDock") as? Bool) ?? true }
        set { defaults.set(newValue, forKey: "moveFromDock") }
    }
}

// MARK: - Apps

struct AppItem: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String {
        var n = FileManager.default.displayName(atPath: path)
        if n.lowercased().hasSuffix(".app") { n.removeLast(4) }
        return n
    }
    var icon: NSImage { IconCache.icon(path) }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func clear() { cache.removeAll() }
    static func icon(_ p: String) -> NSImage {
        if let i = cache[p] { return i }
        let i = NSWorkspace.shared.icon(forFile: p)
        i.size = NSSize(width: 256, height: 256)
        cache[p] = i
        return i
    }
}

enum AppPaths {
    /// Convierte lo que llega en un arrastre (URL, alias, referencia) en la ruta de un .app.
    static func normalize(_ url: URL) -> String? {
        var u = url
        if let fp = (url as NSURL).filePathURL { u = fp }
        u = u.standardizedFileURL
        if (try? u.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
           let r = try? URL(resolvingAliasFileAt: u) { u = r.standardizedFileURL }
        guard u.pathExtension.lowercased() == "app" else { return nil }
        var p = u.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func installedApps() -> [AppItem] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [AppItem] = []
        func scan(_ d: String, depth: Int) {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let p = (d as NSString).appendingPathComponent(n)
                if n.hasSuffix(".app") {
                    if seen.insert(n).inserted { out.append(AppItem(path: p)) }
                } else if depth > 0, !n.hasPrefix("."), n != "Carpetas Dock", n != "Utilities" {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { scan(p, depth: depth - 1) }
                }
            }
        }
        for d in dirs { scan(d, depth: d == "/Applications" ? 1 : 0) }
        return out
            .filter { Bundle(path: $0.path)?.object(forInfoDictionaryKey: "CDFolderID") == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@discardableResult
func run(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Preferencias del Dock

enum DockPrefs {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    static func persistentApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? [[String: Any]]) ?? []
    }

    private static func write(_ items: [[String: Any]]) {
        CFPreferencesSetAppValue(key, items as NSArray, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static func path(of item: [String: Any]) -> String? {
        guard let td = item["tile-data"] as? [String: Any],
              let fd = td["file-data"] as? [String: Any],
              let s = fd["_CFURLString"] as? String else { return nil }
        if let u = URL(string: s), u.isFileURL { return u.path }
        return s
    }

    static func bundleID(of item: [String: Any]) -> String? {
        (item["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    private static func canonical(_ p: String) -> String {
        var s = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func matches(_ item: [String: Any], _ appPath: String) -> Bool {
        if let p = path(of: item), canonical(p) == canonical(appPath) { return true }
        if let bid = bundleID(of: item), let other = Bundle(path: appPath)?.bundleIdentifier, bid == other { return true }
        return false
    }

    static func contains(_ appPath: String) -> Bool {
        persistentApps().contains { matches($0, appPath) }
    }

    static func tile(for appPath: String, label: String? = nil, bundleID: String? = nil) -> [String: Any] {
        let url = URL(fileURLWithPath: appPath, isDirectory: true)
        var data: [String: Any] = [
            "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15] as [String: Any],
            "file-label": label ?? AppItem(path: appPath).name,
            "file-type": 41,
        ]
        if let bid = bundleID ?? Bundle(path: appPath)?.bundleIdentifier { data["bundle-identifier"] = bid }
        return ["tile-type": "file-tile", "tile-data": data]
    }

    struct Replacement {
        let old: String
        let new: String
        let label: String
        let bundleID: String?
    }

    /// Aplica los cambios al Dock. Devuelve true si cambió algo.
    @discardableResult
    static func apply(remove: [String] = [], add: [String] = [], replace: [Replacement] = [], restart: Bool = true) -> Bool {
        var items = persistentApps()
        var changed = false
        let before = items.count
        items.removeAll { item in remove.contains { matches(item, $0) } }
        if items.count != before { changed = true }
        for r in replace {
            if let i = items.firstIndex(where: { matches($0, r.old) }) {
                items[i] = tile(for: r.new, label: r.label, bundleID: r.bundleID)
                changed = true
            }
        }
        for p in add where !items.contains(where: { matches($0, p) }) {
            items.append(tile(for: p))
            changed = true
        }
        if changed {
            write(items)
            if restart { restartDock() }
        }
        return changed
    }

    static func restartDock() { run("/usr/bin/killall", ["Dock"]) }
}

// MARK: - Registro de depuración
// Desactivado por defecto. Para activarlo:  mkdir -p ~/Library/Logs/CarpetasDock && touch ~/Library/Logs/CarpetasDock/debug.log
// y vuelve a abrir las carpetas. Para desactivarlo, borra el archivo.
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CarpetasDock/debug.log")
    static let enabled = FileManager.default.fileExists(atPath: url.path)
    static func log(_ s: @autoclosure () -> String) {
        guard enabled, let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "?"
        h.write("\(Date()) [\(name)] \(s())\n".data(using: .utf8)!)
        try? h.close()
    }
}
