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
        case tag(name: String)
    }

    @Published var sidebarSelection: SidebarSelection = .all
    @Published var searchText: String = ""
    @Published var sort: CaptureLibrarySort = .timeDesc
    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var appGroups: [CaptureLibraryAppGroup] = []
    @Published private(set) var tagGroups: [CaptureLibraryTagGroup] = []
    @Published var selectedItemID: UUID?
    @Published var isLoading: Bool = false

    private let pageSize = 240
    private var changeObserver: Any?
    private var reloadTask: Task<Void, Never>?
    private var requestedOCR = Set<UUID>()
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

        let query = queryForSelection()
        let effectiveSearch = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        async let groups = CaptureLibrary.shared.fetchAppGroups()
        async let tags = CaptureLibrary.shared.fetchTagGroups()
        async let fetched = CaptureLibrary.shared.fetchItems(query: query, limit: pageSize, offset: 0)

        appGroups = await groups
        tagGroups = await tags

        let fetchedItems = await fetched
        if AppSettings.shared.captureLibrarySemanticSearchEnabled,
           sort == .relevance,
           !effectiveSearch.isEmpty {
            items = await CaptureLibrarySemanticSearchService.shared.rerank(items: fetchedItems, queryText: effectiveSearch)
        } else {
            items = fetchedItems
        }

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
        if !item.isPinned {
            requestOCRIfNeeded(for: item)
        }
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

    func requestOCRIfNeeded(for item: CaptureItem) {
        let existing = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existing.isEmpty else { return }
        guard let url = previewURL(for: item) else { return }

        guard !requestedOCR.contains(item.id) else { return }

        let enqueued = CaptureLibrary.shared.requestOCR(
            for: item.id,
            imageURL: url,
            preferredLanguages: AppSettings.shared.ocrRecognitionLanguages
        )
        if enqueued {
            requestedOCR.insert(item.id)
        }
    }

    func updateTags(for itemID: UUID, input: String) {
        let tags = Self.normalizeTags(from: input)
        Task {
            await CaptureLibrary.shared.setTags(tags, for: itemID)
        }
    }

    func updateNote(for itemID: UUID, note: String?) {
        Task {
            await CaptureLibrary.shared.updateNote(note, for: itemID)
        }
    }

    private func queryForSelection() -> CaptureLibraryQuery {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        var query: CaptureLibraryQuery
        switch sidebarSelection {
        case .all:
            query = CaptureLibraryQuery.all
        case .pinned:
            query = CaptureLibraryQuery.pinned
        case .recent24h:
            query = CaptureLibraryQuery.all
            query.createdAfter = Date().addingTimeInterval(-24 * 60 * 60)
        case .app(let bundleID):
            query = CaptureLibraryQuery.all
            query.appBundleID = bundleID
        case .tag(let name):
            query = CaptureLibraryQuery.all
            query.tag = name
        }

        query.sort = sort
        if trimmedSearch.isEmpty {
            query.searchText = nil
            return query
        }

        query.searchText = applySearchSyntax(trimmedSearch, to: &query)
        return query
    }

    private func applySearchSyntax(_ raw: String, to query: inout CaptureLibraryQuery) -> String? {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
            .filter { !$0.isEmpty }

        var remaining: [String] = []
        remaining.reserveCapacity(tokens.count)

        let now = Date()
        let calendar = Calendar.current

        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if isPinnedToken(trimmed) {
                query.pinnedOnly = true
                continue
            }

            if let days = parseRelativeDaysToken(trimmed) {
                query.createdAfter = now.addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
                query.createdBefore = nil
                continue
            }

            if let dayRange = parseDayKeyword(trimmed, calendar: calendar, now: now) {
                query.createdAfter = dayRange.start
                query.createdBefore = dayRange.end
                continue
            }

            if let date = parseDateToken(trimmed, calendar: calendar, now: now) {
                let start = calendar.startOfDay(for: date)
                let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
                query.createdAfter = start
                query.createdBefore = end
                continue
            }

            if trimmed.hasPrefix("#") || trimmed.hasPrefix("＃") {
                let value = String(trimmed.dropFirst())
                if let tag = resolveTagName(from: value, requireExisting: false), !tag.isEmpty {
                    query.tag = tag
                    continue
                }
            }

            if let (key, value) = parseKeyValue(trimmed) {
                switch key.lowercased() {
                case "app", "应用":
                    if let resolved = resolveAppBundleID(from: value) {
                        query.appBundleID = resolved
                        continue
                    }
                case "tag", "标签":
                    if let resolved = resolveTagName(from: value, requireExisting: false), !resolved.isEmpty {
                        query.tag = resolved
                        continue
                    }
                case "type", "类型":
                    if let resolved = captureType(from: value) {
                        query.captureType = resolved
                        continue
                    }
                default:
                    break
                }
            }

            if query.appBundleID == nil, let bundleID = resolveAppBundleID(from: trimmed) {
                query.appBundleID = bundleID
                continue
            }

            if query.tag == nil, let tag = resolveTagName(from: trimmed, requireExisting: true), !tag.isEmpty {
                query.tag = tag
                continue
            }

            remaining.append(trimmed)
        }

        let cleaned = remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func parseKeyValue(_ token: String) -> (key: String, value: String)? {
        let separators: [Character] = [":", "："]
        guard let separator = separators.first(where: { token.contains($0) }) else { return nil }
        let parts = token.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = stripQuotes(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private func stripQuotes(_ value: String) -> String {
        var text = value
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private func resolveAppBundleID(from value: String) -> String? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(".") {
            return trimmed
        }

        let lowered = trimmed.lowercased()
        if let match = appGroups.first(where: { group in
            let name = group.appName.lowercased()
            return name == lowered || name.contains(lowered) || lowered.contains(name)
        }) {
            return match.bundleID
        }

        return nil
    }

    private func resolveTagName(from value: String, requireExisting: Bool) -> String? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if let match = tagGroups.first(where: { group in
            let name = group.name.lowercased()
            return name == lowered
        }) {
            return match.name
        }

        return requireExisting ? nil : trimmed
    }

    private func captureType(from value: String) -> CaptureItemCaptureType? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        switch trimmed {
        case "area", "selection", "region", "选区":
            return .area
        case "window", "窗口":
            return .window
        case "fullscreen", "full", "screen", "全屏":
            return .fullscreen
        default:
            return nil
        }
    }

    private func isPinnedToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered == "pinned" || lowered == "pin" || lowered == "置顶"
    }

    private func parseDayKeyword(_ token: String, calendar: Calendar, now: Date) -> (start: Date, end: Date)? {
        let lowered = token.lowercased()
        if lowered == "today" || lowered == "今天" {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? now
            return (start, end)
        }

        if lowered == "yesterday" || lowered == "昨天" {
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            let start = calendar.startOfDay(for: day)
            let end = calendar.startOfDay(for: now).addingTimeInterval(-0.001)
            return (start, end)
        }

        return nil
    }

    private func parseRelativeDaysToken(_ token: String) -> Int? {
        let lowered = token.lowercased()

        if lowered.hasPrefix("最近"), lowered.hasSuffix("天") {
            let number = lowered.dropFirst(2).dropLast()
            return Int(number)
        }

        if lowered.hasPrefix("近"), lowered.hasSuffix("天") {
            let number = lowered.dropFirst(1).dropLast()
            return Int(number)
        }

        if lowered.hasSuffix("d") {
            return Int(lowered.dropLast())
        }

        if lowered.hasSuffix("天") {
            return Int(lowered.dropLast())
        }

        return nil
    }

    private func parseDateToken(_ token: String, calendar: Calendar, now: Date) -> Date? {
        var cleaned = token
        cleaned = cleaned.replacingOccurrences(of: "年", with: "-")
        cleaned = cleaned.replacingOccurrences(of: "月", with: "-")
        cleaned = cleaned.replacingOccurrences(of: "日", with: "")

        let separators = CharacterSet(charactersIn: "/-.")
        let parts = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 2 || parts.count == 3 else { return nil }

        let year: Int
        let month: Int
        let day: Int

        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            year = y
            month = m
            day = d
        } else if parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) {
            year = calendar.component(.year, from: now)
            month = m
            day = d
        } else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func normalizeTags(from input: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",，;；"))
        let parts = input
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        var seen = Set<String>()
        for tag in parts where seen.insert(tag).inserted {
            unique.append(tag)
        }
        return Array(unique.prefix(20))
    }
}

private struct CaptureLibraryRootView: View {
    @StateObject private var model = CaptureLibraryViewModel()
    @ObservedObject private var settings = AppSettings.shared
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

            if !model.tagGroups.isEmpty {
                Section(NSLocalizedString("library.section.tags", value: "标签", comment: "")) {
                    ForEach(model.tagGroups) { group in
                        HStack(spacing: 10) {
                            Label(group.name, systemImage: "tag")
                                .labelStyle(.titleOnly)
                                .lineLimit(1)

                            Spacer()

                            Text("\(group.itemCount)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(CaptureLibraryViewModel.SidebarSelection.tag(name: group.name))
                    }
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
                        isSelected: model.selectedItemID == item.id,
                        debugMode: settings.captureLibraryDebugMode,
                        ocrLangs: item.ocrLangs,
                        ocrUpdatedAt: item.ocrUpdatedAt,
                        ocrText: item.ocrText
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
                    debugMode: settings.captureLibraryDebugMode,
                    onCopyImage: { model.copyImage(item) },
                    onReveal: { model.reveal(item) },
                    onTogglePinned: { model.togglePinned(item) },
                    onDelete: { model.delete(item) },
                    onUpdateTags: { tagsText in
                        model.updateTags(for: item.id, input: tagsText)
                    },
                    onUpdateNote: { note in
                        model.updateNote(for: item.id, note: note)
                    },
                    onRequestOCR: {
                        model.requestOCRIfNeeded(for: item)
                    }
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
    let debugMode: Bool
    let ocrLangs: [String]
    let ocrUpdatedAt: Date?
    let ocrText: String?

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

            if debugMode {
                Text(debugOCRText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
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

    private var debugOCRText: String {
        let langsText = ocrLangs.isEmpty ? "(auto)" : ocrLangs.joined(separator: " ")

        let updatedText: String
        if let ocrUpdatedAt {
            updatedText = ocrUpdatedAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            updatedText = "-"
        }

        let trimmed = (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(6)
            .joined(separator: " ")
        let preview = collapsed.isEmpty ? "<empty>" : String(collapsed.prefix(120))

        return """
        OCR langs: \(langsText)
        OCR updated: \(updatedText)
        OCR: \(preview)
        """
    }
}

private struct CaptureLibraryInspectorView: View {
    let item: CaptureItem
    let previewURL: URL?
    let debugMode: Bool
    let onCopyImage: () -> Void
    let onReveal: () -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void
    let onUpdateTags: (String) -> Void
    let onUpdateNote: (String?) -> Void
    let onRequestOCR: () -> Void

    @State private var image: NSImage?
    @State private var tagsText: String = ""
    @State private var noteText: String = ""
    @State private var noteUpdateTask: Task<Void, Never>?

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

            if debugMode {
                ocrDebugCard
            }

            metadataEditor

            Divider()

            actions

            Spacer(minLength: 0)
        }
        .task(id: item.id) {
            tagsText = item.tagsCache
            noteText = item.note ?? ""
            onRequestOCR()
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

    private var ocrDebugCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(NSLocalizedString("library.debug.ocr_langs", value: "OCR 语言", comment: "")) {
                    Text(item.ocrLangs.isEmpty ? "(auto)" : item.ocrLangs.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                LabeledContent(NSLocalizedString("library.debug.ocr_updated_at", value: "OCR 更新时间", comment: "")) {
                    Text(item.ocrUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("library.debug.ocr_text", value: "OCR 文本", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (item.ocrText ?? "") : "<empty>")
                            .font(.caption2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .glassContainer(material: .thinMaterial, cornerRadius: 10, borderOpacity: 0.12, shadowOpacity: 0.0)
                }
            }
        }
    }

    private var metadataEditor: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("library.info.tags", value: "标签", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        NSLocalizedString("library.info.tags.placeholder", value: "用空格/逗号分隔，例如：发票 报销", comment: ""),
                        text: $tagsText
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onUpdateTags(tagsText)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("library.info.note", value: "备注", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $noteText)
                        .font(.system(.body, design: .default))
                        .frame(minHeight: 78)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .onChange(of: noteText) { _, newValue in
                            noteUpdateTask?.cancel()
                            noteUpdateTask = Task {
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                guard !Task.isCancelled else { return }
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                onUpdateNote(trimmed.isEmpty ? nil : trimmed)
                            }
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
