//
//  CaptureLibraryView.swift
//  PastScreen
//
//  Lightweight capture library window (M1).
//

import SwiftUI
import AppKit
import Combine

final class CaptureLibraryWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureLibraryManager: NSObject, NSWindowDelegate {
    static let shared = CaptureLibraryManager()

    private var window: CaptureLibraryWindow?
    private var hostingController: NSHostingController<CaptureLibraryRootView>?

    func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            CaptureLibrary.shared.bootstrapIfNeeded()

            if let window = self.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let view = CaptureLibraryRootView { [weak self] in
                self?.dismiss()
            }

            let host = NSHostingController(rootView: view)
            self.hostingController = host

            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
            let width = min(1320, max(980, screenFrame.width * 0.82))
            let height = min(920, max(740, screenFrame.height * 0.82))

            let window = CaptureLibraryWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = NSLocalizedString("library.window.title", value: "素材库", comment: "")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 980, height: 720)
            window.setFrameAutosaveName("CaptureLibraryWindow")
            window.contentViewController = host
            window.center()
            window.delegate = self
            window.makeKeyAndOrderFront(nil)

            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.close()
            self.window = nil
            self.hostingController = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
    }
}

@MainActor
final class CaptureLibraryViewModel: ObservableObject {
    enum SidebarSelection: Hashable {
        case all
        case pinned
        case recent24h
        case app(bundleID: String?)
    }

    @Published var sidebarSelection: SidebarSelection = .all
    @Published var searchText: String = ""
    @Published var sort: CaptureLibrarySort = .timeDesc
    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var appGroups: [CaptureLibraryAppGroup] = []
    @Published var selectedItemID: UUID?
    @Published var isLoading: Bool = false

    private let pageSize = 240
    private var changeObserver: Any?
    private var reloadTask: Task<Void, Never>?
    private let rootURL: URL? = try? CaptureLibraryFileStore.defaultRootURL()

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .captureLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReload(debounce: true)
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        reloadTask?.cancel()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        async let groups = CaptureLibrary.shared.fetchAppGroups()
        async let fetched = CaptureLibrary.shared.fetchItems(query: queryForSelection(), limit: pageSize, offset: 0)

        appGroups = await groups
        items = await fetched

        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = items.first?.id
        } else if selectedItemID == nil {
            self.selectedItemID = items.first?.id
        }
    }

    func scheduleReload(debounce: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    var selectedItem: CaptureItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    func thumbURL(for item: CaptureItem) -> URL? {
        guard let rootURL else { return nil }
        return rootURL.appendingPathComponent(item.internalThumbPath, isDirectory: false)
    }

    func previewURL(for item: CaptureItem) -> URL? {
        if let path = item.internalOriginalPath {
            return rootURL?.appendingPathComponent(path, isDirectory: false)
        }
        if let path = item.internalPreviewPath {
            return rootURL?.appendingPathComponent(path, isDirectory: false)
        }
        if let external = item.externalFileURL {
            return external
        }
        return thumbURL(for: item)
    }

    func icon(for group: CaptureLibraryAppGroup) -> NSImage {
        guard let bundleID = group.bundleID else {
            return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    func title(for item: CaptureItem) -> String {
        if let path = item.externalFilePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let appName = item.appName, !appName.isEmpty {
            return appName
        }
        return NSLocalizedString("library.item.untitled", value: "截图", comment: "")
    }

    func togglePinned(_ item: CaptureItem) {
        Task {
            await CaptureLibrary.shared.setPinned(!item.isPinned, for: item.id)
        }
    }

    func delete(_ item: CaptureItem) {
        Task {
            await CaptureLibrary.shared.deleteItems(ids: [item.id])
        }
    }

    func copyImage(_ item: CaptureItem) {
        CaptureLibrary.shared.copyImageToClipboard(item: item)
    }

    func copyPath(_ item: CaptureItem) {
        CaptureLibrary.shared.copyPathToClipboard(item: item)
    }

    func reveal(_ item: CaptureItem) {
        CaptureLibrary.shared.revealInFinder(item: item)
    }

    private func queryForSelection() -> CaptureLibraryQuery {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch sidebarSelection {
        case .all:
            var query = CaptureLibraryQuery.all
            query.searchText = trimmedSearch.isEmpty ? nil : trimmedSearch
            query.sort = sort
            return query
        case .pinned:
            var query = CaptureLibraryQuery.pinned
            query.searchText = trimmedSearch.isEmpty ? nil : trimmedSearch
            query.sort = sort
            return query
        case .recent24h:
            var query = CaptureLibraryQuery.all
            query.createdAfter = Date().addingTimeInterval(-24 * 60 * 60)
            query.searchText = trimmedSearch.isEmpty ? nil : trimmedSearch
            query.sort = sort
            return query
        case .app(let bundleID):
            var query = CaptureLibraryQuery.all
            query.appBundleID = bundleID
            query.searchText = trimmedSearch.isEmpty ? nil : trimmedSearch
            query.sort = sort
            return query
        }
    }
}

private struct CaptureLibraryRootView: View {
    @StateObject private var model = CaptureLibraryViewModel()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            grid
        } detail: {
            inspector
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: Text(NSLocalizedString("library.search.prompt", value: "搜索", comment: ""))
        )
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help(NSLocalizedString("library.close", value: "关闭", comment: ""))
            }

            ToolbarItemGroup {
                Button {
                    model.scheduleReload(debounce: false)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(NSLocalizedString("library.refresh", value: "刷新", comment: ""))

                Picker("", selection: $model.sort) {
                    Text(NSLocalizedString("library.sort.time", value: "时间", comment: "")).tag(CaptureLibrarySort.timeDesc)
                    Text(NSLocalizedString("library.sort.relevance", value: "相关度", comment: "")).tag(CaptureLibrarySort.relevance)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            model.scheduleReload(debounce: false)
        }
        .onChange(of: model.sidebarSelection) { _, _ in
            model.scheduleReload(debounce: false)
        }
        .onChange(of: model.searchText) { _, _ in
            model.scheduleReload(debounce: true)
        }
        .onChange(of: model.sort) { _, _ in
            model.scheduleReload(debounce: false)
        }
    }

    private var sidebar: some View {
        List(selection: Binding<CaptureLibraryViewModel.SidebarSelection?>(
            get: { model.sidebarSelection },
            set: { newValue in
                if let newValue {
                    model.sidebarSelection = newValue
                }
            }
        )) {
            Section {
                Label(NSLocalizedString("library.filter.all", value: "全部", comment: ""), systemImage: "photo.on.rectangle.angled")
                    .tag(CaptureLibraryViewModel.SidebarSelection.all)
                Label(NSLocalizedString("library.filter.pinned", value: "置顶", comment: ""), systemImage: "pin.fill")
                    .tag(CaptureLibraryViewModel.SidebarSelection.pinned)
                Label(NSLocalizedString("library.filter.recent24h", value: "最近 24 小时", comment: ""), systemImage: "clock")
                    .tag(CaptureLibraryViewModel.SidebarSelection.recent24h)
            }

            Section(NSLocalizedString("library.section.apps", value: "应用", comment: "")) {
                ForEach(model.appGroups) { group in
                    HStack(spacing: 10) {
                        Image(nsImage: model.icon(for: group))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .cornerRadius(4)

                        Text(group.appName)
                            .lineLimit(1)

                        Spacer()

                        Text("\(group.itemCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(CaptureLibraryViewModel.SidebarSelection.app(bundleID: group.bundleID))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(model.items) { item in
                    CaptureLibraryGridItemView(
                        title: model.title(for: item),
                        url: model.thumbURL(for: item),
                        isPinned: item.isPinned,
                        isSelected: model.selectedItemID == item.id
                    )
                    .onTapGesture {
                        model.selectedItemID = item.id
                    }
                    .contextMenu {
                        Button {
                            model.copyImage(item)
                        } label: {
                            Label(NSLocalizedString("library.action.copy_image", value: "复制图片", comment: ""), systemImage: "doc.on.doc")
                        }

                        Button {
                            model.copyPath(item)
                        } label: {
                            Label(NSLocalizedString("library.action.copy_path", value: "复制路径", comment: ""), systemImage: "link")
                        }

                        Button {
                            model.reveal(item)
                        } label: {
                            Label(NSLocalizedString("library.action.reveal", value: "在 Finder 显示", comment: ""), systemImage: "folder")
                        }

                        Divider()

                        Button {
                            model.togglePinned(item)
                        } label: {
                            Label(
                                item.isPinned
                                    ? NSLocalizedString("library.action.unpin", value: "取消置顶", comment: "")
                                    : NSLocalizedString("library.action.pin", value: "置顶", comment: ""),
                                systemImage: item.isPinned ? "pin.slash" : "pin"
                            )
                        }

                        Divider()

                        Button(role: .destructive) {
                            model.delete(item)
                        } label: {
                            Label(NSLocalizedString("library.action.delete", value: "删除", comment: ""), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var inspector: some View {
        Group {
            if let item = model.selectedItem {
                CaptureLibraryInspectorView(
                    item: item,
                    previewURL: model.previewURL(for: item),
                    onCopyImage: { model.copyImage(item) },
                    onReveal: { model.reveal(item) },
                    onTogglePinned: { model.togglePinned(item) },
                    onDelete: { model.delete(item) }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("library.empty_selection", value: "选择一条截图查看详情", comment: ""))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}

private struct CaptureLibraryGridItemView: View {
    let title: String
    let url: URL?
    let isPinned: Bool
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 110)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }

            Text(title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassContainer(material: .regularMaterial, cornerRadius: 12, borderOpacity: isSelected ? 0.35 : 0.12, shadowOpacity: 0.06)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await Task.detached(priority: .utility) {
                NSImage(contentsOfFile: url.path)
            }.value
        }
    }
}

private struct CaptureLibraryInspectorView: View {
    let item: CaptureItem
    let previewURL: URL?
    let onCopyImage: () -> Void
    let onReveal: () -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .task(id: previewURL) {
                guard let previewURL else {
                    image = nil
                    return
                }
                image = await Task.detached(priority: .utility) {
                    NSImage(contentsOfFile: previewURL.path)
                }.value
            }

            info

            Divider()

            actions

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.appName ?? NSLocalizedString("library.app.unknown", value: "未知应用", comment: ""))
                    .font(.headline)
                    .lineLimit(1)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if item.isPinned {
                Label(NSLocalizedString("library.pinned", value: "置顶", comment: ""), systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var info: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(NSLocalizedString("library.info.type", value: "类型", comment: "")) {
                    Text(typeText(item.captureType))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(NSLocalizedString("library.info.trigger", value: "触发", comment: "")) {
                    Text(triggerText(item.trigger))
                        .foregroundStyle(.secondary)
                }
                if let external = item.externalFileURL {
                    LabeledContent(NSLocalizedString("library.info.external", value: "外部文件", comment: "")) {
                        Text(external.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    LabeledContent(NSLocalizedString("library.info.external", value: "外部文件", comment: "")) {
                        Text(NSLocalizedString("library.info.none", value: "未落盘", comment: ""))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onCopyImage) {
                Label(NSLocalizedString("library.action.copy_image", value: "复制图片", comment: ""), systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onReveal) {
                Label(NSLocalizedString("library.action.reveal", value: "在 Finder 显示", comment: ""), systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: onTogglePinned) {
                Label(
                    item.isPinned
                        ? NSLocalizedString("library.action.unpin", value: "取消置顶", comment: "")
                        : NSLocalizedString("library.action.pin", value: "置顶", comment: ""),
                    systemImage: item.isPinned ? "pin.slash" : "pin"
                )
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label(NSLocalizedString("library.action.delete", value: "删除", comment: ""), systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private func typeText(_ type: CaptureItemCaptureType) -> String {
        switch type {
        case .area:
            return NSLocalizedString("library.type.area", value: "选区", comment: "")
        case .window:
            return NSLocalizedString("library.type.window", value: "窗口", comment: "")
        case .fullscreen:
            return NSLocalizedString("library.type.fullscreen", value: "全屏", comment: "")
        }
    }

    private func triggerText(_ trigger: CaptureItemTrigger) -> String {
        switch trigger {
        case .menuBar:
            return NSLocalizedString("library.trigger.menubar", value: "菜单栏", comment: "")
        case .hotkey:
            return NSLocalizedString("library.trigger.hotkey", value: "快捷键", comment: "")
        case .appIntent:
            return NSLocalizedString("library.trigger.appintent", value: "快捷指令", comment: "")
        case .automation:
            return NSLocalizedString("library.trigger.automation", value: "自动化", comment: "")
        }
    }
}
