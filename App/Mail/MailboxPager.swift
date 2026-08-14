#if !os(macOS)
import SwiftUI
import MailCore

/// The phone's main view. The Mac's board puts every mailbox side by side;
/// a phone has room for exactly one, so the columns become pages and the
/// column headers become the bar across the top.
///
/// The page swipe lives on that top bar and nowhere else. A `TabView(.page)`
/// over the whole screen reads horizontal drags with the same gesture a
/// `List` uses for its swipe actions, and the pager always wins — which cost
/// us swipe-to-archive. Keeping the two gestures in separate parts of the
/// screen is what makes both work.
///
/// Which page you're on *is* `model.mailbox`, so tapping a mailbox in the rail
/// and swiping the bar are the same action and stay in step.
struct MailboxPager: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var order: SidebarOrder

    @State private var searchText = ""
    @StateObject private var searchList = ThreadListModel()
    /// Which way the last move went, so the incoming page slides in from the
    /// side you swiped from.
    @State private var forward = true

    private var items: [SidebarItem] { order.boardItems }

    /// `model.mailbox` starts nil and the rail can point at a mailbox that's
    /// been hidden from the board, so fall back rather than showing nothing.
    private var current: SidebarItem {
        items.first { $0.filter == model.mailbox } ?? items.first ?? .unified
    }

    private var index: Int { items.firstIndex(of: current) ?? 0 }
    private var previousItem: SidebarItem? { index > 0 ? items[index - 1] : nil }
    private var nextItem: SidebarItem? { index + 1 < items.count ? items[index + 1] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if searchText.isEmpty {
                pagerBar
                Divider()
                page
            } else {
                ThreadPageList(list: searchList, emptyText: "No matches")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search all mail")
        .onChange(of: searchText) {
            guard !searchText.isEmpty else { return }
            searchList.observeSearch(db: model.db, query: searchText)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.compose()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .navigationDestination(for: MailThread.self) { thread in
            ThreadDetailView(thread: thread)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Mailboxes",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Long-press a mailbox in the sidebar to show it here.")
                )
            }
        }
    }

    // MARK: - Top bar

    /// Swipe it, or tap the mailbox either side of the current one.
    private var pagerBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                sideLabel(previousItem, alignment: .leading, chevron: "chevron.left")
                currentLabel
                sideLabel(nextItem, alignment: .trailing, chevron: "chevron.right")
            }
            .padding(.horizontal, 12)
            dots
        }
        .padding(.top, 6)
        .padding(.bottom, 7)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    // Ignore anything closer to vertical than horizontal —
                    // that's a scroll heading for the list below.
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 40 else { return }
                    move(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var currentLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: current.systemImage)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(current.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            if current == .open, model.openUnreadCount > 0 {
                Text("\(model.openUnreadCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
    }

    private func sideLabel(_ item: SidebarItem?, alignment: Alignment, chevron: String) -> some View {
        Group {
            if let item {
                Button {
                    move(to: item)
                } label: {
                    HStack(spacing: 2) {
                        if alignment == .leading {
                            Image(systemName: chevron).imageScale(.small)
                        }
                        Text(item.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if alignment == .trailing {
                            Image(systemName: chevron).imageScale(.small)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// Where you are in the run of mailboxes — the one thing a single-page
    /// view loses that the board gave you for free.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(items) { item in
                Circle()
                    .fill(item == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 5, height: 5)
            }
        }
    }

    // MARK: - Page

    private var page: some View {
        ZStack {
            MailboxPage(item: current)
                .id(current)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing)
                ))
        }
        .clipped()
    }

    // MARK: - Moving

    private func move(by offset: Int) {
        let target = index + offset
        guard items.indices.contains(target) else { return }
        move(to: items[target])
    }

    private func move(to item: SidebarItem) {
        guard item != current else { return }
        forward = (items.firstIndex(of: item) ?? 0) > index
        withAnimation(.easeInOut(duration: 0.22)) { model.mailbox = item.filter }
    }
}

/// One mailbox as a page, with its own live query.
private struct MailboxPage: View {
    let item: SidebarItem
    @EnvironmentObject var model: AppModel
    @StateObject private var list = ThreadListModel(pageSize: 50)

    var body: some View {
        ThreadPageList(list: list, emptyText: "Nothing here")
            .onAppear { list.observe(db: model.db, filter: item.filter) }
    }
}

/// The rows themselves, shared by the mailbox pages and the search results.
private struct ThreadPageList: View {
    @ObservedObject var list: ThreadListModel
    @EnvironmentObject var model: AppModel
    let emptyText: String

    var body: some View {
        List {
            ForEach(list.threads, id: \.key) { thread in
                NavigationLink(value: thread) {
                    ThreadRow(thread: thread, accountColor: model.accountColor(thread.accountId))
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        model.archive(thread)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        model.markRead(thread, read: thread.isUnread)
                    } label: {
                        Label(thread.isUnread ? "Read" : "Unread", systemImage: "envelope.badge")
                    }
                    .tint(.blue)
                    Button {
                        model.toggleOpen(thread)
                    } label: {
                        Label("Open", systemImage: "clock")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button(thread.isStarred ? "Unstar" : "Star") { model.toggleStar(thread) }
                    Button(thread.isOpen ? "Remove from Open" : "Mark Open") { model.toggleOpen(thread) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.syncAndWait() }
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 600
        } action: { _, nearBottom in
            if nearBottom { list.loadMore(db: model.db) }
        }
        .overlay {
            if list.threads.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
#endif
