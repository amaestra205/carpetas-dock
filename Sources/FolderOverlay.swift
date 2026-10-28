import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Desenfoque del escritorio detrás de la carpeta abierta (no captura clics).
final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> PassthroughEffectView {
        let v = PassthroughEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: PassthroughEffectView, context: Context) {}
}

/// La carpeta abierta: fondo difuminado, título editable y recuadro de Liquid Glass con las apps.
struct FolderOverlay: View {
    @ObservedObject var c: FolderController
    @FocusState private var titleFocused: Bool
    @State private var page: Int? = 0
    @State private var boxTargeted = false

    private let cols = 3
    private let rows = 3
    private let cellW: CGFloat = 104
    private let cellH: CGFloat = 112
    private let radius: CGFloat = 46
    private var boxW: CGFloat { CGFloat(cols) * cellW + 48 }
    private var gridH: CGFloat { CGFloat(rows) * cellH }
    private var boxH: CGFloat { gridH + 64 }

    private var pages: [[AppItem]] {
        let all = c.items
        let per = cols * rows
        if all.isEmpty { return [[]] }
        return stride(from: 0, to: all.count, by: per).map { Array(all[$0..<min($0 + per, all.count)]) }
    }

    var body: some View {
        GeometryReader { geo in
            let dx = c.origin.x - geo.size.width / 2
            let dy = c.origin.y - geo.size.height / 2
            ZStack {
                // Fondo: desenfoca el escritorio; un clic fuera cierra la carpeta.
                ZStack {
                    BlurView()
                    Color.black.opacity(0.10)
                }
                .opacity(c.isOpen ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    // Solo cierra si el clic cae fuera de la carpeta (título, recuadro y botón).
                    let w = boxW + 180, h = boxH + 46 + 40 + 40
                    let r = CGRect(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2, width: w, height: h)
                    if !r.contains(p) { c.userClose("clic fuera") }
                }
                .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { c.dropOutside($0) }

                VStack(spacing: 20) {
                    title
                        .frame(width: boxW + 180, height: 46)
                    box
                    addButton
                }
                .scaleEffect(c.isOpen ? 1 : 0.14)
                .offset(c.isOpen ? .zero : CGSize(width: dx, height: dy))
                .opacity(c.isOpen ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onExitCommand { c.userClose("exit") }
    }

    // MARK: Título

    @ViewBuilder private var title: some View {
        if c.editingTitle {
            TextField("Nombre", text: $c.titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .focused($titleFocused)
                .onSubmit { c.commitTitle() }
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        titleFocused = true
                    }
                }
                .onChange(of: titleFocused) { _, focused in
                    if !focused && c.editingTitle { c.commitTitle() }
                }
        } else {
            Text(c.config.name)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Rectangle())
                .onTapGesture { c.beginEditingTitle() }
                .help("Haz clic para cambiar el nombre")
        }
    }

    // MARK: Recuadro

    private var box: some View {
        ZStack {
            if c.showingPicker {
                AppPicker(c: c).transition(.opacity)
            } else {
                grid.transition(.opacity)
            }
        }
        .frame(width: boxW, height: boxH)
        .background(Color.white.opacity(0.001))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(boxTargeted || c.externalTargeted || c.dockDragTargeted ? 0.75 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .scaleEffect(boxTargeted || c.externalTargeted || c.dockDragTargeted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: boxTargeted || c.externalTargeted || c.dockDragTargeted)
        .onDrop(of: [.fileURL, .plainText], isTargeted: $boxTargeted) { c.dropInside($0, before: nil) }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<pages.count, id: \.self) { idx in
                        PageGrid(c: c, items: pages[idx], start: idx * cols * rows,
                                 cols: cols, rows: rows, cellW: cellW, cellH: cellH, boxW: boxW)
                            .frame(width: boxW, height: gridH, alignment: .top)
                            .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollClipDisabled(pages.count == 1)   // el icono arrastrado puede salir del recuadro
            .scrollPosition(id: $page)
            .frame(height: gridH)
            .onChange(of: pages.count) { _, n in
                if (page ?? 0) >= n { withAnimation { page = max(n - 1, 0) } }
            }

            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle()
                        .fill(Color.primary.opacity(i == (page ?? 0) ? 0.85 : 0.28))
                        .frame(width: 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { withAnimation(.easeInOut) { page = i } }
                }
            }
            .frame(height: 40)
            .opacity(pages.count > 1 ? 1 : 0)
        }
        .padding(.top, 24)
        .overlay {
            if c.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34, weight: .regular))
                    Text("Arrastra apps aquí")
                        .font(.headline)
                    Text("desde el Dock, o suéltalas sobre\nel icono de la carpeta")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
        }
    }

    private var addButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { c.showingPicker = true }
        } label: {
            Label("Añadir apps", systemImage: "plus")
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .opacity(c.showingPicker ? 0 : 1)
        .disabled(c.showingPicker)
    }
}

// MARK: - Página de iconos con reordenación al estilo iOS

/// Coloca los iconos de una página en su hueco y permite arrastrarlos:
/// el icono sigue al ratón, los demás se apartan en vivo y, si lo sueltas fuera del recuadro, sale de la carpeta.
struct PageGrid: View {
    @ObservedObject var c: FolderController
    let items: [AppItem]
    let start: Int
    let cols: Int
    let rows: Int
    let cellW: CGFloat
    let cellH: CGFloat
    let boxW: CGFloat

    private var side: CGFloat { (boxW - CGFloat(cols) * cellW) / 2 }

    private func slotCenter(_ i: Int) -> CGPoint {
        CGPoint(x: side + CGFloat(i % cols) * cellW + cellW / 2,
                y: CGFloat(i / cols) * cellH + cellH / 2)
    }

    private func slot(at p: CGPoint) -> Int {
        let col = min(max(Int((p.x - side) / cellW), 0), cols - 1)
        let row = min(max(Int(p.y / cellH), 0), rows - 1)
        return min(row * cols + col, items.count - 1)
    }

    /// Fuera del recuadro de cristal (con un pequeño margen hacia fuera).
    private func isOutside(_ p: CGPoint) -> Bool {
        p.x < -10 || p.x > boxW + 10 || p.y < -34 || p.y > CGFloat(rows) * cellH + 50
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let isDragged = c.dragging == item.path
                AppCell(item: item, c: c, w: cellW, h: cellH, lifted: isDragged,
                        outside: isDragged && c.dragOutside)
                    .position(isDragged ? c.dragPoint : slotCenter(i))
                    .zIndex(isDragged ? 10 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("pagina"))
                            .onChanged { v in
                                if c.dragging == nil {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                        c.dragging = item.path
                                    }
                                }
                                c.dragPoint = v.location
                                let out = isOutside(v.location)
                                if out != c.dragOutside {
                                    withAnimation(.easeOut(duration: 0.15)) { c.dragOutside = out }
                                }
                                guard !out, let cur = items.firstIndex(where: { $0.path == item.path }) else { return }
                                let target = slot(at: v.location)
                                if target != cur {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                        c.moveTo(item.path, index: start + target)
                                    }
                                }
                            }
                            .onEnded { v in
                                let out = isOutside(v.location)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if out { c.remove(item.path) }
                                    c.dragging = nil
                                    c.dragOutside = false
                                }
                                c.saveOrder()
                            }
                    )
            }
        }
        .frame(width: boxW, height: CGFloat(rows) * cellH, alignment: .topLeading)
        .coordinateSpace(name: "pagina")
    }
}

// MARK: - Icono de una app dentro de la carpeta

struct AppCell: View {
    let item: AppItem
    @ObservedObject var c: FolderController
    let w: CGFloat
    let h: CGFloat
    var lifted = false
    var outside = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(lifted ? 0.35 : 0.18), radius: lifted ? 12 : 4, y: lifted ? 8 : 2)
                .scaleEffect(lifted ? 1.18 : (hover && c.dragging == nil ? 1.06 : 1))
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: w - 14)
                .opacity(lifted ? 0 : 1)
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .opacity(outside ? 0.6 : 1)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hover = inside } }
        .onTapGesture { c.launch(item) }
        .contextMenu {
            Button("Abrir") { c.launch(item) }
            Button("Mostrar en el Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Quitar de la carpeta", role: .destructive) { c.remove(item.path) }
        }
    }
}

// MARK: - Selector de apps

struct AppPicker: View {
    @ObservedObject var c: FolderController
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var all: [AppItem] = []

    private var filtered: [AppItem] {
        query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar apps", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { item in
                        row(item)
                    }
                }
            }
            .scrollIndicators(.never)

            HStack {
                Button("Cancelar") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { c.showingPicker = false }
                }
                .buttonStyle(.glass)
                Spacer()
                Button(selected.isEmpty ? "Añadir" : "Añadir (\(selected.count))") {
                    let paths = all.map(\.path).filter { selected.contains($0) }
                    c.add(paths: paths, before: nil)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { c.showingPicker = false }
                }
                .buttonStyle(.glassProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(18)
        .task {
            if all.isEmpty { all = await Task.detached(priority: .userInitiated) { AppPaths.installedApps() }.value }
        }
    }

    private func row(_ item: AppItem) -> some View {
        let inFolder = c.config.apps.contains(item.path)
        let isSel = selected.contains(item.path)
        return HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
            Text(item.name).lineLimit(1)
            Spacer()
            Image(systemName: inFolder || isSel ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSel ? Color.accentColor : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSel ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .opacity(inFolder ? 0.45 : 1)
        .onTapGesture {
            guard !inFolder else { return }
            if isSel { selected.remove(item.path) } else { selected.insert(item.path) }
        }
    }
}
