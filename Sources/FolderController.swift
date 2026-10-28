import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Estado y lógica de una carpeta abierta en el Dock.
@MainActor
final class FolderController: ObservableObject {
    let id: String
    @Published var config: FolderConfig
    @Published var isOpen = false
    /// Punto (coordenadas de la ventana, origen arriba-izquierda) desde el que se despliega: el icono del Dock.
    @Published var origin: CGPoint = .zero
    @Published var showingPicker = false
    @Published var editingTitle = false
    @Published var titleDraft = ""
    /// App que se está arrastrando dentro de la carpeta.
    @Published var dragging: String?
    /// Posición del icono arrastrado (coordenadas de la página) y si está fuera del recuadro.
    @Published var dragPoint: CGPoint = .zero
    @Published var dragOutside = false
    /// Hay un arrastre desde fuera (Dock, Finder…) encima de la carpeta.
    @Published var externalTargeted = false
    /// Se está arrastrando un icono sacado del Dock por encima de la carpeta.
    @Published var dockDragTargeted = false

    // Vigilancia del Dock mientras la carpeta está abierta (el Dock no entrega sus iconos
    // como un arrastre normal: al soltarlos fuera simplemente los quita de sus preferencias).
    private var dockTimer: Timer?
    private var dockSnapshot = Set<String>()
    private var wasPressed = false
    private var pressFromDock = false
    private var releaseFromDock = false
    private var releasePoint: CGPoint = .zero
    private var releaseTime = Date.distantPast
    private var tick = 0
    /// Se ha soltado un icono del Dock dentro: esperamos a que el Dock lo quite (tarda unos segundos).
    private var pendingDockDrop = false

    private var window: OverlayWindow?
    private var pendingRemove = Set<String>()   // quitar del Dock al cerrar
    private var pendingAdd = Set<String>()      // devolver al Dock al cerrar
    private var renamePending = false
    private var closeTask: Task<Void, Never>?

    var visible: Bool { window?.isVisible == true }
    var items: [AppItem] { config.apps.map { AppItem(path: $0) } }

    init(id: String) {
        self.id = id
        let fallback = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Carpeta"
        var c = Store.load(id) ?? FolderConfig(id: id, name: fallback, apps: [])
        c.apps = c.apps.filter { FileManager.default.fileExists(atPath: $0) }
        config = c
        titleDraft = c.name
        refreshDockIcon()
    }

    func refreshDockIcon() {
        NSApp.applicationIconImage = IconRenderer.image(for: config.apps, size: 256)
        if window == nil { IconCache.clear() }   // con la carpeta abierta los iconos siguen haciendo falta
    }

    // MARK: Abrir / cerrar

    func toggle() {
        if visible && isOpen { close(reason: "toggle") } else { open() }
    }

    func open() {
        DebugLog.log("open visible=\(visible) isOpen=\(isOpen)")
        closeTask?.cancel()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let w = window ?? makeWindow()
        w.setFrame(screen.frame, display: true)
        origin = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        if !visible { isOpen = false }
        showingPicker = false
        editingTitle = false
        dragging = nil
        titleDraft = config.name
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startWatchingDock()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self.isOpen = true }
            DebugLog.log("opened frame=\(w.frame) onscreen=\(w.isVisible) key=\(w.isKeyWindow) active=\(NSApp.isActive)")
        }
    }

    /// Hay un arrastre desde el Dock en curso (o acaba de terminar): no cerrar por clics o teclas sueltas.
    var dockDragActive: Bool {
        pressFromDock || pendingDockDrop || (releaseFromDock && Date().timeIntervalSince(releaseTime) < 1.5)
    }

    /// Cierre pedido por el usuario (clic fuera, Esc). Se ignora durante un arrastre desde el Dock.
    func userClose(_ reason: String) {
        if dockDragActive {
            DebugLog.log("ignorado cierre (\(reason)) durante arrastre del Dock")
            return
        }
        close(reason: reason)
    }

    func close(thenHide: Bool = true, reason: String = "?") {
        DebugLog.log("close[\(reason)] visible=\(visible) isOpen=\(isOpen) hide=\(thenHide)")
        guard visible, isOpen else { return }
        if editingTitle { commitTitle() }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
            isOpen = false
            showingPicker = false
        }
        closeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 330_000_000)
            guard !Task.isCancelled, !self.isOpen else { return }
            self.window?.orderOut(nil)
            self.stopWatchingDock()
            self.dragging = nil
            self.releaseWindow()
            if thenHide && NSApp.isActive { NSApp.hide(nil) }
            self.flushDock()
            if self.renamePending {
                self.renamePending = false
                try? await SMAppService.mainApp.unregister()
                Bundles.renameSelfAndRelaunch(to: self.config.name)
            }
        }
    }

    /// Libera la ventana, la vista SwiftUI y los iconos en memoria mientras la carpeta está cerrada.
    private func releaseWindow() {
        window?.contentView = nil
        window?.close()
        window = nil
        IconCache.clear()
    }

    private func makeWindow() -> OverlayWindow {
        let w = OverlayWindow(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // Justo por debajo del Dock: así el Dock sigue visible y se pueden arrastrar apps desde él.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.onCancel = { [weak self] in self?.userClose("esc") }
        let host = DropHostingView(rootView: FolderOverlay(c: self))
        host.controller = self
        host.sizingOptions = []
        w.contentView = host
        window = w
        return w
    }

    // MARK: Apps

    func launch(_ item: AppItem) {
        NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration())
        close(thenHide: false, reason: "launch")
    }

    private func markFromDock(_ p: String) {
        var fd = config.fromDock ?? []
        if !fd.contains(p) { fd.append(p) }
        config.fromDock = fd
    }

    func add(paths: [String], before target: String?, fromDock: Bool = false) {
        var apps = config.apps
        var added: [String] = []
        let me = Bundle.main.bundleURL.path
        for p in paths {
            guard !apps.contains(p), p != me, !p.hasPrefix(Paths.bundlesDir.path + "/"),
                  Bundle(path: p)?.object(forInfoDictionaryKey: "CDFolderID") == nil else { continue }
            if let t = target, let i = apps.firstIndex(of: t) { apps.insert(p, at: i) } else { apps.append(p) }
            added.append(p)
        }
        guard !added.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { config.apps = apps }
        if fromDock {
            for p in added { markFromDock(p) }
        } else if Settings.moveFromDock {
            for p in added {
                if pendingAdd.remove(p) != nil { markFromDock(p); continue }
                if DockPrefs.contains(p) {
                    pendingRemove.insert(p)
                    markFromDock(p)
                }
            }
        }
        persist()
        if !visible { flushDock() }
    }

    func remove(_ p: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { config.apps.removeAll { $0 == p } }
        if pendingRemove.remove(p) == nil, Settings.moveFromDock, config.fromDock?.contains(p) == true {
            pendingAdd.insert(p)
        }
        config.fromDock?.removeAll { $0 == p }
        persist()
        if !visible { flushDock() }
    }

    /// Mueve una app a una posición concreta (reordenación en vivo mientras se arrastra).
    func moveTo(_ p: String, index: Int) {
        guard let from = config.apps.firstIndex(of: p) else { return }
        var a = config.apps
        a.remove(at: from)
        a.insert(p, at: min(max(index, 0), a.count))
        if a != config.apps { config.apps = a }
    }

    func saveOrder() { persist() }

    private func persist() {
        Store.save(config)
        refreshDockIcon()
    }

    func flushDock() {
        guard !pendingRemove.isEmpty || !pendingAdd.isEmpty else { return }
        let r = Array(pendingRemove), a = Array(pendingAdd)
        pendingRemove.removeAll()
        pendingAdd.removeAll()
        DockPrefs.apply(remove: r, add: a)   // al reiniciarse el Dock, AppDelegate vuelve a poner el icono
    }

    // MARK: Arrastrar desde el Dock

    /// Rutas de las apps fijas en el Dock (sin tocar el disco: solo se lee la preferencia).
    private static func dockAppPaths() -> Set<String> {
        Set(DockPrefs.persistentApps().compactMap { item -> String? in
            guard var p = DockPrefs.path(of: item) else { return nil }
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        })
    }

    private var screenFrame: CGRect { window?.screen?.frame ?? window?.frame ?? NSScreen.main?.frame ?? .zero }

    /// Zona (en coordenadas de pantalla) donde soltar cuenta como «dentro de la carpeta».
    private var dropRect: CGRect {
        let f = screenFrame
        let w: CGFloat = 640, h: CGFloat = 620   // título + recuadro + botón, con margen
        return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
    }

    private func inDockArea(_ p: CGPoint) -> Bool {
        guard let screen = window?.screen ?? NSScreen.main else { return false }
        let f = screen.frame, v = screen.visibleFrame
        let bottom = max(v.minY - f.minY, 90)
        let left = max(v.minX - f.minX, 0), right = max(f.maxX - v.maxX, 0)
        if p.y < f.minY + bottom + 10 { return true }
        if left > 20 && p.x < f.minX + left + 10 { return true }
        if right > 20 && p.x > f.maxX - right - 10 { return true }
        return false
    }

    private func startWatchingDock() {
        dockTimer?.invalidate()
        dockSnapshot = []
        pendingDockDrop = false
        wasPressed = NSEvent.pressedMouseButtons & 1 != 0
        pressFromDock = false
        releaseFromDock = false
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDock() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        dockTimer = t
    }

    private func stopWatchingDock() {
        dockTimer?.invalidate()
        dockTimer = nil
        dockDragTargeted = false
        pendingDockDrop = false
    }

    private func pollDock() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let mouse = NSEvent.mouseLocation
        if pressed && !wasPressed {
            pressFromDock = inDockArea(mouse)
            // Foto del Dock justo al empezar a arrastrar desde él (antes de que quite nada).
            if pressFromDock && !pendingDockDrop { dockSnapshot = Self.dockAppPaths() }
            DebugLog.log("press \(mouse) dock=\(pressFromDock)")
        }
        if !pressed && wasPressed {
            DebugLog.log("release \(mouse) fromDock=\(pressFromDock) dentro=\(dropRect.contains(mouse))")
            releaseFromDock = pressFromDock
            releasePoint = mouse
            releaseTime = Date()
            if pressFromDock && dropRect.contains(mouse) {
                pendingDockDrop = true      // el Dock lo quitará en unos segundos
            }
            pressFromDock = false
        }
        wasPressed = pressed

        if pendingDockDrop && Date().timeIntervalSince(releaseTime) > 12 {
            DebugLog.log("el Dock no quitó ninguna app; se cancela")
            pendingDockDrop = false
        }
        let over = (pressed && pressFromDock && dropRect.contains(mouse)) || pendingDockDrop
        if over != dockDragTargeted { dockDragTargeted = over }

        // Solo se leen las preferencias del Dock mientras esperamos a que quite la app soltada.
        guard pendingDockDrop else { return }
        tick += 1
        guard tick % 2 == 0 else { return }     // 10 veces por segundo basta
        let removed = dockSnapshot.subtracting(Self.dockAppPaths())
        guard !removed.isEmpty else { return }
        DebugLog.log("quitadas del Dock: \(removed)")
        pendingDockDrop = false
        releaseFromDock = false
        dockDragTargeted = false
        let paths = removed.compactMap { AppPaths.normalize(URL(fileURLWithPath: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        add(paths: paths, before: nil, fromDock: true)
    }

    // MARK: Nombre

    func beginEditingTitle() {
        titleDraft = config.name
        editingTitle = true
    }

    func commitTitle() {
        editingTitle = false
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { titleDraft = config.name; return }
        guard t != config.name else { return }
        config.name = t
        titleDraft = t
        Store.save(config)
        renamePending = true
    }

    // MARK: Arrastrar y soltar

    private func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                DispatchQueue.main.async {
                    if let u = obj as? NSURL { urls.append(u as URL) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }

    func dropInside(_ providers: [NSItemProvider], before target: String?) -> Bool {
        if dragging != nil { dragging = nil; return true }
        loadURLs(providers) { urls in
            MainActor.assumeIsolated {
                self.add(paths: urls.compactMap(AppPaths.normalize), before: target)
            }
        }
        return true
    }

    /// Soltar fuera del recuadro: si viene de dentro, se saca de la carpeta (como en iOS).
    func dropOutside(_ providers: [NSItemProvider]) -> Bool {
        if let d = dragging {
            dragging = nil
            remove(d)
            return true
        }
        return dropInside(providers, before: nil)
    }
}
