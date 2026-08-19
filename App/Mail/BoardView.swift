import SwiftUI
import MailCore
#if os(macOS)
import AppKit
#endif

/// The main view: every mailbox side by side, in the rail's order.
///
/// The board and the rail read the same `SidebarOrder`, so reordering either
/// one reorders both — drag a column header here, drag a row there, same saved
/// list. Clicking a thread drills into that column full-width; Escape comes
/// back.
struct BoardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var order: SidebarOrder

    var body: some View {
        ScrollView(.horizontal) {
            // Not lazy: a column that hasn't been built isn't observing its
            // mailbox, and the whole point is seeing them all at once — the
            // ones off the right edge included, the moment you scroll there.
            HStack(spacing: 0) {
                ForEach(order.boardItems) { item in
                    BoardColumn(item: item, order: order)
                        .frame(width: order.width(item))
                    ColumnResizer(item: item, order: order)
                }
            }
        }
        .overlay {
            if order.boardItems.isEmpty {
                EmptyState(title: "No columns", systemImage: "rectangle.split.3x1",
                           detail: "Right-click a mailbox in the sidebar to show it here.")
            }
        }
        .navigationTitle("All Mailboxes")
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
    }
}

/// The rule between two columns, dragged to resize the one on its left.
///
/// On iOS it stays a plain divider — the grab strip is a pointer-sized target,
/// and there's no cursor to tell you it's live.
private struct ColumnResizer: View {
    let item: SidebarItem
    @ObservedObject var order: SidebarOrder

    /// Width when the drag began. `DragGesture` reports translation from the
    /// start of the drag, not since the last event, so accumulating it per
    /// change would compound into a runaway column.
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    /// Invisible margin either side of the 1pt rule, so the drag doesn't need
    /// pixel-perfect aim.
    private static let grabWidth: CGFloat = 9

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
                withAnimation(.easeInOut(duration: 0.15)) { order.resetWidth(item) }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? order.width(item)
                        if startWidth == nil { startWidth = start }
                        order.setWidth(start + value.translation.width, for: item)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize \(item.title) — double-click to reset")
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
private struct BoardColumn: View {
    let item: SidebarItem
    @ObservedObject var order: SidebarOrder
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
        .onAppear { list.observe(db: model.db, filter: item.filter) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .imageScale(.small)
                .foregroundStyle(CWT.ink2)
            Text(item.title)
                .font(CWT.font(12, bold: true))
            Spacer(minLength: 4)
            if item == .open, model.openUnreadCount > 0 {
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
        // The header is the column's own title bar: click it to open this
        // mailbox full-width, drag it to move the column.
        .onTapGesture { model.mailbox = item.filter }
        .help("Open \(item.title) — drag to reorder")
        .draggable(item.rawValue) {
            Label(item.title, systemImage: item.systemImage)
                .font(CWT.font(12))
                .padding(6)
                .background(CWT.paper)
        }
        .dropDestination(for: String.self) { ids, _ in
            // Anything but one of our own headers — a stray text drag from
            // another app — leaves the order alone.
            guard let dragged = ids.first.flatMap(SidebarItem.init(rawValue:)) else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                order.moveItem(dragged, onto: item)
            }
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    private var threads: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list.threads, id: \.key) { thread in
                    Button {
                        model.open(thread, in: item.filter)
                    } label: {
                        ThreadRow(thread: thread,
                                  accountColor: model.accountColor(thread.accountId))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ThreadContextMenu(thread: thread) }
                    .hotkeyHoverTarget(thread, model: model)
                    .collapsed(list.collapsing.contains(thread.key))
                    if !list.collapsing.contains(thread.key) { Hairline() }
                }
            }
        }
        // Same trick the full-width list uses: row .onAppear can't be trusted
        // to fire, so page from the scroll position instead.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 400
        } action: { _, nearBottom in
            if nearBottom { list.loadMore(db: model.db) }
        }
        .overlay {
            if list.threads.isEmpty {
                Text("Nothing here")
                    .font(CWT.caption)
                    .foregroundStyle(CWT.ink3)
            }
        }
    }
}
