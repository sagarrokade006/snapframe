import AppKit
import SnapframeCore
import SwiftUI

enum HomeSection: String, CaseIterable {
    case home = "Home"
    case library = "Library"
    case pinned = "Pinned"

    var symbol: String {
        switch self {
        case .home: return "house"
        case .library: return "square.grid.2x2"
        case .pinned: return "pin"
        }
    }
}

struct HomeView: View {
    @ObservedObject private var library = CaptureLibrary.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updates = UpdateController.shared

    var onCapture: (ShortcutAction) -> Void
    var onSettings: () -> Void

    @State private var section = HomeSection.home
    @State private var kind: String?
    @State private var tag: String?
    @State private var query = ""

    private var matches: [CaptureItem] {
        library.index.filtered(kind: kind, tag: tag, query: query, pinnedOnly: section == .pinned)
    }

    private var visible: [CaptureItem] {
        section == .home ? Array(matches.prefix(6)) : matches
    }

    private var selected: CaptureItem? {
        matches.first { $0.id == library.selectedID } ?? matches.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            main
            CaptureInspector(item: selected)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color.snapGround)
        .snapWindowStyle()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                BrandMark()
                Text("Snapframe").font(.snapDisplay(18))
            }
            .padding(.horizontal, 8)
            .padding(.top, 44)
            .padding(.bottom, 18)

            ForEach(HomeSection.allCases, id: \.self) { item in
                navigationRow(
                    item.rawValue, item.symbol,
                    count: item == .home ? nil : count(for: item),
                    active: section == item
                ) {
                    section = item
                    tag = nil
                }
            }
            navigationRow("Annotate Image…", "pencil.tip.crop.circle", count: nil, active: false) { AnnotateController.shared.chooseFile() }
            navigationRow("Settings", "slider.horizontal.3", count: nil, active: false, action: onSettings)

            if !library.index.allTags.isEmpty {
                Text("TAGS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.snapMuted)
                    .padding(.horizontal, 10)
                    .padding(.top, 20)
                    .padding(.bottom, 6)

                ForEach(library.index.allTags.prefix(8), id: \.self) { name in
                    Button {
                        tag = tag == name ? nil : name
                        if section == .home { section = .library }
                    } label: {
                        HStack(spacing: 11) {
                            Circle().fill(CaptureFormatting.tagColor(name)).frame(width: 9, height: 9)
                            Text(name).lineLimit(1)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: tag == name ? .semibold : .regular))
                        .frame(height: 30)
                        .padding(.horizontal, 10)
                        .background(tag == name ? Color.snapRaised : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
            updateCard
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 224)
        .frame(maxHeight: .infinity)
        .background(Color.snapSidebar)
    }

    private func count(for section: HomeSection) -> Int {
        section == .pinned ? library.index.items.filter(\.isPinned).count : library.index.items.count
    }

    private func navigationRow(_ title: String, _ symbol: String, count: Int?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(Color.snapMuted) }
            }
            .frame(height: 38)
            .padding(.horizontal, 10)
            .background(active ? Color.snapRaised : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var updateCard: some View {
        Button {
            updates.checkForUpdates()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Version \(UpdateService.currentVersion.description)").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if updates.availableVersion != nil {
                        Text("Update").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.snapAccent)
                    } else if updates.phase == .upToDate {
                        Text("Up to date").font(.system(size: 12)).foregroundStyle(Color.snapTeal)
                    }
                }
                Text("Your captures stay on this Mac.").font(.system(size: 12)).foregroundStyle(Color.snapMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .snapCard(radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!updates.isConfigured)
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(section.rawValue).font(.snapDisplay(26))
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.snapMuted)
                    TextField("Search captures", text: $query).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(width: 240, height: 36)
                .snapCard(radius: 9)
            }
            .padding(.top, 14)

            if section == .home { captureTiles }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(listTitle).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    filter("All", value: nil)
                    filter("Area", value: "Area")
                    filter("Window", value: "Window")
                    filter("Fullscreen", value: "Fullscreen")
                }

                if visible.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(visible) { item in captureCard(item) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listTitle: String {
        if let tag { return tag }
        return section == .home ? "Recent captures" : "\(matches.count) captures"
    }

    private var captureTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            tile(.area, title: "Capture Area", primary: true)
            tile(.window, title: "Window")
            tile(.fullscreen, title: "Fullscreen")
            tile(.previousArea, title: "Previous Area")
            tile(.selfTimer, title: "Self-Timer")
            soonTile("Scrolling", "arrow.up.and.down.text.horizontal")
            soonTile("Capture Text", "text.viewfinder")
            soonTile("Record", "record.circle")
        }
    }

    private func tile(_ action: ShortcutAction, title: String, primary: Bool = false) -> some View {
        Button {
            onCapture(action)
        } label: {
            tileBody(
                symbol: action.symbol, title: title,
                badge: settings.shortcuts[action]?.displayString,
                foreground: primary ? .snapInk : .snapText,
                fill: primary ? .snapAccent : .snapCard,
                border: primary ? .snapAccent : .snapLine,
                badgeFill: primary ? Color.snapInk.opacity(0.16) : .snapRaised
            )
        }
        .buttonStyle(.plain)
    }

    private func soonTile(_ title: String, _ symbol: String) -> some View {
        tileBody(symbol: symbol, title: title, badge: "Soon", foreground: .snapMuted, fill: .snapCard, border: .snapLine, badgeFill: .snapRaised)
            .accessibilityElement(children: .combine)
    }

    private func tileBody(symbol: String, title: String, badge: String?, foreground: Color, fill: Color, border: Color, badgeFill: Color) -> some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            Spacer()
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(12)
        .frame(height: 84)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(border))
        .contentShape(Rectangle())
    }

    private func filter(_ title: String, value: String?) -> some View {
        Button {
            kind = value
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(kind == value ? Color.snapInk : Color.snapText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(kind == value ? Color.snapText : Color.snapCard, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func captureCard(_ item: CaptureItem) -> some View {
        Button {
            library.selectedID = item.id
        } label: {
            VStack(spacing: 0) {
                CaptureThumbnail(item: item).frame(height: 132).clipped()
                HStack(spacing: 8) {
                    if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.snapAccent) }
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(CaptureFormatting.when(item.createdAt)).font(.system(size: 12)).foregroundStyle(Color.snapMuted)
                }
                .padding(.horizontal, 11)
                .frame(height: 42)
            }
            .snapCard(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(item.id == selected?.id ? Color.snapAccent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: emptySymbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.snapMuted)
            Text(emptyTitle).font(.system(size: 16, weight: .semibold))
            if library.index.items.isEmpty, let shortcut = settings.shortcuts[.area] {
                HStack(spacing: 10) {
                    Text("Press").foregroundStyle(Color.snapMuted)
                    KeyCaps(parts: shortcut.keyParts)
                    Text("and drag across your screen").foregroundStyle(Color.snapMuted)
                }
                .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .snapCard()
    }

    private var emptySymbol: String { section == .pinned ? "pin" : "photo.on.rectangle.angled" }

    private var emptyTitle: String {
        if library.index.items.isEmpty { return "Your captures will appear here" }
        return section == .pinned && query.isEmpty && kind == nil ? "Nothing pinned yet" : "No captures match"
    }
}

struct CaptureInspector: View {
    let item: CaptureItem?

    @ObservedObject private var library = CaptureLibrary.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var addingTag = false
    @State private var newTag = ""

    var body: some View {
        Group {
            if let item {
                details(item)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right").font(.system(size: 26, weight: .light)).foregroundStyle(Color.snapMuted)
                    Text("Select a capture").foregroundStyle(Color.snapMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 296)
        .frame(maxHeight: .infinity)
        .background(Color.snapSidebar)
    }

    private func details(_ item: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CaptureThumbnail(item: item)
                .frame(height: 172)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                Text("\(CaptureFormatting.when(item.createdAt)) · \(item.kind)").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            }

            HStack(spacing: 6) {
                IconAction(title: "Copy", symbol: "doc.on.doc", primary: true) { library.copy(item) }
                IconAction(title: "Edit", symbol: "pencil.tip.crop.circle") { AnnotateController.shared.open(item) }
                IconAction(title: "Float", symbol: "pip") { PinController.shared.pin(item) }
                IconAction(title: "Share", symbol: "square.and.arrow.up") { ShareSheet.show(library.imageURL(id: item.id)) }
                IconAction(title: "Reveal", symbol: "folder") { library.reveal(item) }
            }

            VStack(spacing: 0) {
                meta("Size", "\(item.pixelWidth) × \(item.pixelHeight)")
                meta("Format", item.formatTitle)
                meta("File size", CaptureFormatting.bytes(item.byteCount))
                meta("Saved to", savedLocation(item), divider: false)
            }
            .padding(.horizontal, 12)
            .snapCard(radius: 10)

            FlowLayout {
                ForEach(item.tags, id: \.self) { tag in
                    Button {
                        library.removeTag(tag, from: item)
                    } label: {
                        Text(tag).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5).background(Color.snapRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove tag")
                }
                if addingTag {
                    TextField("Tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 80)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.snapRaised, in: Capsule())
                        .onSubmit {
                            library.addTag(newTag, to: item)
                            newTag = ""
                            addingTag = false
                        }
                } else {
                    Button("Add tag") { addingTag = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Capsule().stroke(Color(hex: 0x5A5D65), style: StrokeStyle(lineWidth: 1, dash: [3])))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("Auto-delete").font(.system(size: 13))
                Spacer()
                Text(retention(item)).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            }
            .padding(12)
            .snapCard(radius: 10)

            HStack(spacing: 8) {
                Button(item.isPinned ? "Unpin" : "Pin to Library") { library.togglePinned(item) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Delete") { library.delete(item) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func meta(_ key: String, _ value: String, divider: Bool = true) -> some View {
        HStack {
            Text(key).foregroundStyle(Color.snapMuted)
            Spacer()
            Text(value).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 13))
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color(hex: 0x2C2E33)).frame(height: 1) }
        }
    }

    private func savedLocation(_ item: CaptureItem) -> String {
        guard let path = item.savedPath else { return "Library only" }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    private func retention(_ item: CaptureItem) -> String {
        if item.isPinned { return "Off while pinned" }
        return settings.libraryRetentionDays == 0 ? "Never" : "After \(settings.libraryRetentionDays) days"
    }
}
