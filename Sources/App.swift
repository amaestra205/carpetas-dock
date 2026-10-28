import AppKit
import SwiftUI
import ServiceManagement

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
                _ = NSApplication.shared
                let ok = IconRenderer.writeSample(to: URL(fileURLWithPath: args[i + 1]))
                exit(ok ? 0 : 1)
            }
            let app = NSApplication.shared
            app.delegate = AppDelegate.shared
            app.setActivationPolicy(.regular)
            app.mainMenu = AppDelegate.makeMainMenu()
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    var folder: FolderController?
    var manager: ManagerWindowController?
    private var pendingPaths: [String] = []
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        finished = true
        guard let id = Bundles.folderID else {
            showManager()
            return
        }
        let fc = FolderController(id: id)
        folder = fc
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if !pendingPaths.isEmpty {
            fc.add(paths: pendingPaths, before: nil)
            pendingPaths = []
        } else if CommandLine.arguments.contains("--silent") || launchedAsLoginItem() {
            NSApp.hide(nil)   // arranca en segundo plano, solo con su icono en el Dock
        } else {
            fc.open()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched(_:)),
                                                          name: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil)
    }

    private func launchedAsLoginItem() -> Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let oapp: AEEventID = 0x6F617070      // 'oapp'
        let prdt: AEKeyword = 0x70726474      // keyAEPropData
        let lgit: OSType = 0x6C676974         // keyAELaunchedAsLogInItem
        return ev.eventID == oapp && ev.paramDescriptor(forKeyword: prdt)?.enumCodeValue == lgit
    }

    /// Al reiniciarse el Dock (cambios en sus apps, renombrar otra carpeta…) olvida los iconos en vivo.
    @objc private func appLaunched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.dock" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.folder?.refreshDockIcon()
        }
    }

    @objc private func otherAppActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        DebugLog.log("activated \(app.bundleIdentifier ?? "?")")
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           app.bundleIdentifier != "com.apple.dock", folder?.dockDragActive != true {
            folder?.close(thenHide: false, reason: "otra app")
        }
    }

    /// Apps soltadas sobre el icono de la carpeta en el Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.compactMap(AppPaths.normalize)
        if let f = folder {
            f.add(paths: paths, before: nil)
        } else if !finished {
            pendingPaths += paths
        }
    }

    /// Clic en el icono del Dock con la app ya abierta.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLog.log("reopen")
        if let f = folder { f.toggle() } else { showManager() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { folder == nil }

    func applicationWillTerminate(_ notification: Notification) {
        if let id = Bundles.folderID, Store.load(id) == nil {
            try? SMAppService.mainApp.unregister()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        if folder != nil {
            m.addItem(withTitle: "Abrir carpeta", action: #selector(openFolder), keyEquivalent: "")
            m.addItem(withTitle: "Cambiar nombre…", action: #selector(renameFolder), keyEquivalent: "")
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Nueva carpeta", action: #selector(newFolder), keyEquivalent: "")
        m.addItem(withTitle: "Gestionar carpetas…", action: #selector(openManager), keyEquivalent: "")
        if folder != nil {
            m.addItem(.separator())
            m.addItem(withTitle: "Eliminar esta carpeta…", action: #selector(deleteThis), keyEquivalent: "")
        }
        for item in m.items { item.target = self }
        return m
    }

    @objc func openFolder() { folder?.open() }

    @objc func renameFolder() {
        guard let f = folder else { return }
        f.open()
        f.beginEditingTitle()
    }

    @objc func newFolder() { Bundles.createFolder(name: "Nueva carpeta") }

    @objc func openManager() { showManager() }

    @objc func deleteThis() {
        guard let f = folder else { return }
        f.close(thenHide: false, reason: "eliminar")
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "¿Eliminar la carpeta «\(f.config.name)»?"
        a.informativeText = "Las apps no se borran." + (Settings.moveFromDock ? " Las que vinieron del Dock volverán a él." : "")
        a.addButton(withTitle: "Eliminar")
        a.addButton(withTitle: "Cancelar")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? SMAppService.mainApp.unregister()
        Bundles.deleteFolder(id: f.id)
        NSApp.terminate(nil)
    }

    func showManager() {
        if manager == nil { manager = ManagerWindowController() }
        manager?.show()
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Gestionar carpetas…", action: #selector(AppDelegate.openManager), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}
