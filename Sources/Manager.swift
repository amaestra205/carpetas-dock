import AppKit
import SwiftUI

/// Ventana para crear y borrar carpetas.
@MainActor
final class ManagerWindowController {
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ManagerView())
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct ManagerView: View {
    @State private var folders: [FolderConfig] = Store.all()
    @State private var newName = ""
    @State private var moveFromDock = Settings.moveFromDock

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Carpetas Dock").font(.title2.bold())
                    Text("Agrupa las apps del Dock en carpetas, como en el iPhone.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 10) {
                TextField("Nombre de la carpeta nueva", text: $newName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .onSubmit(create)
                Button("Crear carpeta", action: create)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(trimmed.isEmpty)
            }

            if folders.isEmpty {
                Text("Aún no tienes carpetas. Crea la primera y aparecerá en tu Dock.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(folders) { f in row(f) }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Al meter una app en una carpeta, quitarla del Dock (como en iOS)", isOn: $moveFromDock)
                .onChange(of: moveFromDock) { _, v in Settings.moveFromDock = v }

            Text("Haz clic en el icono de una carpeta del Dock para abrirla. Arrastra apps dentro desde el Dock, suéltalas sobre su icono o usa «Añadir apps». Haz clic en el título para cambiarle el nombre y arrastra una app fuera del recuadro para sacarla.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 540)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            folders = Store.all()
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        Bundles.createFolder(name: trimmed)
        newName = ""
        folders = Store.all()
    }

    private func row(_ f: FolderConfig) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconRenderer.image(for: f.apps, size: 128))
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.headline)
                Text(f.apps.count == 1 ? "1 app" : "\(f.apps.count) apps")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let u = Bundles.bundleURL(for: f.id) {
                    NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
                }
            } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.glass)
                .help("Abrir la carpeta")
            Button { confirmDelete(f) } label: { Image(systemName: "trash") }
                .buttonStyle(.glass)
                .help("Eliminar la carpeta")
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func confirmDelete(_ f: FolderConfig) {
        let a = NSAlert()
        a.messageText = "¿Eliminar la carpeta «\(f.name)»?"
        a.informativeText = "Las apps no se borran." + (Settings.moveFromDock ? " Las que vinieron del Dock volverán a él." : "")
        a.addButton(withTitle: "Eliminar")
        a.addButton(withTitle: "Cancelar")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Bundles.deleteFolder(id: f.id)
        folders = Store.all()
    }
}
