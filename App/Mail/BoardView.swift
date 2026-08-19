import SwiftUI
import MailCore
#if os(macOS)
import AppKit
#endif

/// The whole mail canvas: every mailbox side by side, in the rail's order.
///
/// There is no separate "mailbox view" — conceptually you are always on the
/// board, and opening a mailbox just makes room. Focusing a column (clicking
/// one of its rows, its header, or its rail entry) slides that column to the
/// left edge: the columns before it are pushed off-screen left, and the
/// reader grows into the space after it, pushing the rest off-screen right.
/// Escape reverses the shove and the board is exactly where you left it,
/// scroll position included.
///
/// The board and the rail read the same `SidebarOrder`, so reordering either
/// one reorders both — drag a column header here, drag a row there, same
/// saved list.
struct BoardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var order: SidebarOrder
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding

    /// Where the horizontal scroll sits. Frozen while a column is focused
    /// (scrolling is disabled then), so the strip offset has a stable base
    /// and unfocusing lands back on the exact same scroll position.
    @State private var scrollX: CGFloat = 0

    private var focused: MailboxFilter? { model.mailbox }

    /// The board's columns — plus, when the focused mailbox isn't one of
    /// them (an account, or a box kept off the board like Spam), a stand-in
    /// column that slides in at the far left for the duration.
    private var slots: [BoardSlot] {
        var slots = order.boardItems.map(BoardSlot.init(item:))
        if let box = focused, !slots.contains(where: { $0.filter == box }) {
            slots.insert(standIn(for: box), at: 0)
        }
        return slots
    }

    private func standIn(for box: MailboxFilter) -> BoardSlot {
        if let item = SidebarItem.allCases.first(where: { $0.filter == box }) {
            return BoardSlot(item: item)
        }
        if case .account(let id) = box {
            let email = model.accountStore.accounts.first { $0.id == id }?.email ?? "Account"
            return BoardSlot(filter: box, title: email, systemImage: "person.circle",
                             item: nil, widthKey: "account-\(id)")
        }
        return BoardSlot(filter: box, title: box.title, systemImage: "tray",
                         item: nil, widthKey: "box-\(box.title)")
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(slots) { slot in
                        slotView(slot, in: geo)
                    }
                }
                .offset(x: stripOffset)
            }
            .scrollDisabled(focused != nil)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.x
            } action: { _, x in
                // Content resizes while focused (the reader claims width);
                // ignore anything the clamping does until we're back.
                if focused == nil { scrollX = x }
            }
        }
        .background(CWT.paper)
        .overlay {
            if order.boardItems.isEmpty, focused == nil {
                EmptyState(title: "No columns", systemImage: "rectangle.split.3x1",
                           detail: "Right-click a mailbox in the sidebar to show it here.")
            }
        }
        .navigationTitle(focused?.title ?? "All Mailboxes")
        .searchable(text: $searchText, prompt: "Search all mail")
        .searchFocused(searchFocused)
        .toolbar {
            ToolbarItem {
                Button {
                    model.compose()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Compose (C)")
            }
        }
        .onChange(of: searchText) {
            // Typing into the board's search field drops you into Unified —
            // the search runs across all mail anyway, and the results need a
            // focused column to live in.
            if focused == nil, !searchText.isEmpty { model.navigate(to: .unified) }
        }
    }

    /// One column, its resizer, and — while it's the focused one — the
    /// reader that opens up after it.
    @ViewBuilder private func slotView(_ slot: BoardSlot, in geo: GeometryProxy) -> some View {
        let isFocused = focused == slot.filter
        HStack(spacing: 0) {
            BoardColumn(slot: slot, order: order,
                        focused: isFocused,
                        searchQuery: isFocused && !searchText.isEmpty ? searchText : nil)
                .frame(width: order.width(key: slot.widthKey))
            ColumnResizer(slot: slot, order: order)
            if isFocused {
                ReaderPane()
                    .frame(width: readerWidth(for: slot, in: geo))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // A stand-in column has no home on the board to slide back to, so it
        // exits the way it came: off the left edge.
        .transition(slot.item.map { order.isOnBoard($0) } == true
                    ? .opacity
                    : .move(edge: .leading).combined(with: .opacity))
    }

    /// How far the strip shifts left so the focused column's leading edge
    /// lands on the viewport's: everything before it is pushed off-screen.
    /// `scrollX` cancels whatever scroll the board was already at.
    private var stripOffset: CGFloat {
        guard let box = focused else { return 0 }
        var left: CGFloat = 0
        for slot in slots {
            if slot.filter == box { break }
            left += order.width(key: slot.widthKey) + ColumnResizer.grabWidth
        }
        return scrollX - left
    }

    /// The reader takes everything right of the focused column, and shoves
    /// the remaining columns off-screen doing it.
    private func readerWidth(for slot: BoardSlot, in geo: GeometryProxy) -> CGFloat {
        max(320, geo.size.width - order.width(key: slot.widthKey) - ColumnResizer.grabWidth)
    }
}

/// A column on the canvas: one of the rail's board items, or a stand-in for
/// a focused mailbox that has no board column (`item == nil` for accounts).
struct BoardSlot: Identifiable, Equatable {
    let filter: MailboxFilter
    let title: String
    let systemImage: String
    let item: SidebarItem?
    let widthKey: String
    var id: MailboxFilter { filter }

    init(filter: MailboxFilter, title: String, systemImage: String,
         item: SidebarItem?, widthKey: String) {
        self.filter = filter
        self.title = title
        self.systemImage = systemImage
        self.item = item
        self.widthKey = widthKey
    }

    init(item: SidebarItem) {
        self.init(filter: item.filter, title: item.title, systemImage: item.systemImage,
                  item: item, widthKey: item.rawValue)
    }
}

/// The email itself, in the room the focused column made: a placeholder
/// until a row is chosen, then the thread slides in over it from the right.
private struct ReaderPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Text("Select a conversation")
                .font(CWT.caption)
                .foregroundStyle(CWT.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CWT.paper)
            if let thread = model.selectedThread {
                ThreadDetailView(thread: thread,
                                 nextThread: neighbor(of: thread, offset: 1),
                                 previousThread: neighbor(of: thread, offset: -1),
                                 onPullNext: { model.selectNext(in: model.activeList?.threads ?? []) },
                                 onPullPrevious: { model.selectPrevious(in: model.activeList?.threads ?? []) })
                    .background(CWT.paper)
                    .transition(.reader)
            }
        }
        .clipped()
    }

    /// What pulling past the bottom (+1) or top (-1) of the reader moves to,
    /// read from the focused column's live list.
    private func neighbor(of thread: MailThread, offset: Int) -> MailThread? {
        let threads = model.activeList?.threads ?? []
        guard let idx = threads.firstIndex(where: { $0.key == thread.key }),
              threads.indices.contains(idx + offset) else { return nil }
        return threads[idx + offset]
    }
}

/// The rule between two columns (or the focused column and the reader),
/// dragged to resize the column on its left.
///
/// On iOS it stays a plain divider — the grab strip is a pointer-sized target,
/// and there's no cursor to tell you it's live.
private struct ColumnResizer: View {
    let slot: BoardSlot
    @ObservedObject var order: SidebarOrder

    /// Width when the drag began. `DragGesture` reports translation from the
    /// start of the drag, not since the last event, so accumulating it per
    /// change would compound into a runaway column.
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    /// Invisible margin either side of the 1pt rule, so the drag doesn't need
    /// pixel-perfect aim.
    static let grabWidth: CGFloat = 9

    private var active: Bool { hovering || startWidth != nil }

    var body: some View {
        #if os(macOS)
        rule
            .frame(width: Self.grabWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // Ahead of the drag so a double-click, which never moves far
            // enough to start one, resets instead of nudging the width.
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.15)) { order.resetWidth(key: slot.widthKey) }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? order.width(key: slot.widthKey)
                        if startWidth == nil { startWidth = start }
                        order.setWidth(start + value.translation.width, key: slot.widthKey)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize \(slot.title) — double-click to reset")
        #else
        rule
        #endif
    }

    private var rule: some View {
        Rectangle()
            .fill(active ? CWT.ink : CWT.hairline)
            .frame(width: active ? 2 : 1)
    }
}

/// One mailbox as a column: a draggable header over its own live thread list.
///
/// The column persists across focus changes — the same list you were looking
/// at on the board is the one beside the reader, mid-scroll and all, which is
/// what makes the shove feel like furniture moving rather than a screen swap.
private struct BoardColumn: View {
    let slot: BoardSlot
    @ObservedObject var order: SidebarOrder
    let focused: Bool
    /// Non-nil only while this column is focused and the search field has
    /// text: the column's list shows matches across all mail instead.
    let searchQuery: String?
    @EnvironmentObject var model: AppModel
    // Columns page in small bites — nine lists share the window, and only a
    // dozen rows of any one of them are on screen.
    @StateObject private var list = ThreadListModel(pageSize: 50)
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            threads
        }
        .background(CWT.paper)
        .onAppear {
            observe()
            if focused { model.activeList = list }
        }
        .onChange(of: focused) {
            if focused { model.activeList = list }
            observe()
        }
        .onChange(of: searchQuery) { observe() }
    }

    private func observe() {
        if let query = searchQuery {
            list.observeSearch(db: model.db, query: query)
        } else {
            list.observe(db: model.db, filter: slot.filter)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: slot.systemImage)
                .imageScale(.small)
                .foregroundStyle(CWT.ink2)
            Text(slot.title)
                .font(CWT.font(12, bold: true))
                .lineLimit(1)
            Spacer(minLength: 4)
            if slot.item == .open, model.openUnreadCount > 0 {
                Tag(text: "\(model.openUnreadCount)")
            }
            Text("\(list.threads.count)")
                .font(CWT.font(11))
                .foregroundStyle(CWT.ink3)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(isDropTarget ? CWT.selection : CWT.paperWarm)
        .contentShape(Rectangle())
        // The header is the column's own title bar: click it to focus this
        // mailbox (making room for the reader), drag it to move the column.
        .onTapGesture { model.navigate(to: slot.filter) }
        .help(focused ? slot.title : "Open \(slot.title) — drag to reorder")
        .draggable(slot.item?.rawValue ?? "") {
            Label(slot.title, systemImage: slot.systemImage)
                .font(CWT.font(12))
                .padding(6)
                .background(CWT.paper)
        }
        .dropDestination(for: String.self) { ids, _ in
            // Anything but one of our own headers — a stray text drag from
            // another app — leaves the order alone. Stand-in columns aren't
            // reorder targets either; they have no place in the saved order.
            guard let target = slot.item,
                  let dragged = ids.first.flatMap(SidebarItem.init(rawValue:)) else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                order.moveItem(dragged, onto: target)
            }
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    private var threads: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list.threads, id: \.key) { thread in
                        Button {
                            if focused {
                                model.select(thread)
                            } else {
                                model.open(thread, in: slot.filter)
                            }
                        } label: {
                            ThreadRow(thread: thread,
                                      accountColor: model.accountColor(thread.accountId))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(focused && model.selectedThread?.key == thread.key
                                    ? CWT.selection : Color.clear)
                        .contextMenu { ThreadContextMenu(thread: thread) }
                        .hotkeyHoverTarget(thread, model: model)
                        .collapsed(list.collapsing.contains(thread.key))
                        if !list.collapsing.contains(thread.key) { Hairline() }
                    }
                }
            }
            // j/k move the selection from the keyboard; keep it in view.
            .onChange(of: model.selectedThread?.key) {
                guard focused, let key = model.selectedThread?.key else { return }
                proxy.scrollTo(key)
            }
        }
        // Same trick the full-width list used: row .onAppear can't be trusted
        // to fire, so page from the scroll position instead.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 400
        } action: { _, nearBottom in
            if nearBottom { list.loadMore(db: model.db) }
        }
        .overlay {
            if list.threads.isEmpty {
                Text(searchQuery == nil ? "Nothing here" : "No results")
                    .font(CWT.caption)
                    .foregroundStyle(CWT.ink3)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Local search exhausted? Gmail has more history than this Mac.
            if focused, let query = searchQuery {
                Button {
                    model.serverSearch(query)
                } label: {
                    Label("Search Gmail for older mail", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.square)
                .padding(6)
            }
        }
    }
}
