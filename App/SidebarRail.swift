import SwiftUI
import MailCore

// MARK: - Rail items and their order

/// A built-in mailbox as it appears in the rail. The raw value is what gets
/// persisted in the saved order, so don't rename cases.
enum SidebarItem: String, CaseIterable, Identifiable {
    case unified, important, newsletters, updates, other
    case open, drafts, sent, archived, blocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: "Unified"
        case .important: "Important"
        case .newsletters: "Newsletters"
        case .updates: "Updates"
        case .other: "Other"
        case .open: "Open"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .archived: "Archived"
        case .blocked: "Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .unified: "tray.full"
        case .important: "star"
        case .newsletters: "newspaper"
        case .updates: "bell"
        case .other: "tray"
        case .open: "clock"
        case .drafts: "doc.badge.ellipsis"
        case .sent: "paperplane"
        case .archived: "archivebox"
        case .blocked: "hand.raised"
        }
    }

    var filter: MailboxFilter {
        switch self {
        case .unified: .unified
        case .important: .important
        case .newsletters: .newsletters
        case .updates: .updates
        case .other: .other
        case .open: .open
        case .drafts: .drafts
        case .sent: .sent
        case .archived: .archived
        case .blocked: .blocked
        }
    }
}

/// The order the rail is arranged in, persisted across launches.
///
/// Stored as a list of ids rather than positions, so it survives the item set
/// changing underneath it: an id that's no longer known is dropped, and
/// anything new — a mailbox added in an app update, an account just signed
/// in — falls to the end of its group instead of disappearing.
@MainActor
final class SidebarOrder: ObservableObject {
    @Published private(set) var items: [SidebarItem] = []
    @Published private(set) var accountIds: [String] = []
    /// Mailboxes kept off the board. Stored as the hidden set rather than the
    /// shown one so a mailbox added in a later app update shows up by default.
    @Published private(set) var hidden: Set<SidebarItem> = []
    /// Board column widths, keyed by `SidebarItem.rawValue`.
    @Published private(set) var widths: [String: Double] = [:]

    private let itemsKey = "sidebarItemOrder"
    private let accountsKey = "sidebarAccountOrder"
    private let hiddenKey = "boardHiddenItems"
    private let widthsKey = "boardColumnWidths"
    private let blockedHiddenKey = "boardHidBlockedOnce"
    private let defaults = UserDefaults.standard

    init() {
        let saved = defaults.stringArray(forKey: itemsKey) ?? []
        let known = saved.compactMap(SidebarItem.init(rawValue:))
        items = known + SidebarItem.allCases.filter { !known.contains($0) }
        accountIds = defaults.stringArray(forKey: accountsKey) ?? []
        hidden = Set((defaults.stringArray(forKey: hiddenKey) ?? [])
            .compactMap(SidebarItem.init(rawValue:)))
        // Blocked is the one mailbox you go looking for rather than watch, so
        // it starts off the board — once, so putting it back sticks.
        if !defaults.bool(forKey: blockedHiddenKey) {
            hidden.insert(.blocked)
            defaults.set(hidden.map(\.rawValue), forKey: hiddenKey)
            defaults.set(true, forKey: blockedHiddenKey)
        }
        widths = defaults.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
    }

    /// The columns the board draws, in rail order.
    var boardItems: [SidebarItem] { items.filter { !hidden.contains($0) } }

    func isOnBoard(_ item: SidebarItem) -> Bool { !hidden.contains(item) }

    func setOnBoard(_ item: SidebarItem, _ shown: Bool) {
        if shown { hidden.remove(item) } else { hidden.insert(item) }
        defaults.set(hidden.map(\.rawValue), forKey: hiddenKey)
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        defaults.set(items.map(\.rawValue), forKey: itemsKey)
    }

    /// Drop one item onto another's spot. The board drags whole columns rather
    /// than rows, so it has a dragged item and a target rather than the
    /// offsets `onMove` deals in — but both ends write the same saved order.
    func moveItem(_ item: SidebarItem, onto target: SidebarItem) {
        guard item != target,
              let from = items.firstIndex(of: item),
              let to = items.firstIndex(of: target) else { return }
        // Dragging rightward, `to` is the index the target vacates once the
        // dragged item is lifted out, so aim one past it.
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        defaults.set(items.map(\.rawValue), forKey: itemsKey)
    }

    /// Accounts in saved order, with any not yet ranked appended.
    func sorted(_ accounts: [Account]) -> [Account] {
        let rank = Dictionary(uniqueKeysWithValues: accountIds.enumerated().map { ($1, $0) })
        return accounts.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    func moveAccounts(_ accounts: [Account], from source: IndexSet, to destination: Int) {
        var ids = sorted(accounts).map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        accountIds = ids
        defaults.set(ids, forKey: accountsKey)
    }

    // MARK: - Board column widths

    /// Wide enough for the two-line row the thread list uses, narrow enough
    /// that four or five fit on a laptop screen.
    static let defaultColumnWidth: CGFloat = 320
    /// Below this the sender/subject lines stop being readable; above it a
    /// single column swallows the board.
    static let minColumnWidth: CGFloat = 200
    static let maxColumnWidth: CGFloat = 800

    /// Only the columns the user has actually resized are stored, so a
    /// mailbox that has never been touched follows the default if it changes.
    func width(_ item: SidebarItem) -> CGFloat {
        widths[item.rawValue].map { CGFloat($0) } ?? Self.defaultColumnWidth
    }

    func setWidth(_ width: CGFloat, for item: SidebarItem) {
        widths[item.rawValue] = Double(min(max(width, Self.minColumnWidth), Self.maxColumnWidth))
        defaults.set(widths, forKey: widthsKey)
    }

    func resetWidth(_ item: SidebarItem) {
        widths[item.rawValue] = nil
        defaults.set(widths, forKey: widthsKey)
    }
}

// MARK: - Expanded state

private struct RailExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the sidebar is showing names next to its icons. Read by every
    /// rail row, so widening the column and labeling the rows stay one switch.
    var railExpanded: Bool {
        get { self[RailExpandedKey.self] }
        set { self[RailExpandedKey.self] = newValue }
    }
}

/// How wide the sidebar sits in each state.
enum RailWidth {
    static let collapsed: CGFloat = 64
    static let expanded: CGFloat = 200
}

// MARK: - Hover labels

/// Which rail item the pointer is over, and where it sits. Carried up as a
/// preference so the label can be drawn outside the rail — see
/// `railHoverLabel`.
struct RailHoverTarget: Equatable {
    let title: String
    let anchor: Anchor<CGRect>
}

struct RailHoverKey: PreferenceKey {
    static let defaultValue: RailHoverTarget? = nil
    static func reduce(value: inout RailHoverTarget?, nextValue: () -> RailHoverTarget?) {
        // Exactly one row is hovered at a time; keep whichever one spoke up.
        value = nextValue() ?? value
    }
}

extension View {
    /// Names an otherwise unlabeled control: revealed the instant the pointer
    /// enters, and read out to VoiceOver, which has no pointer to hover with.
    func railTitle(_ title: String) -> some View {
        modifier(RailTitle(title: title))
    }
}

private struct RailTitle: ViewModifier {
    let title: String
    @Environment(\.railExpanded) private var expanded
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.primary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .anchorPreference(key: RailHoverKey.self, value: .bounds) { anchor in
                // Expanded, the name is already on the row — a floating copy of
                // it next to the pointer would just be in the way.
                hovering && !expanded ? RailHoverTarget(title: title, anchor: anchor) : nil
            }
            .accessibilityLabel(title)
    }
}

extension View {
    /// Draws the hovered rail item's name. Belongs on whatever contains the
    /// sidebar, not on the sidebar itself: at 64pt the rail would clip the
    /// very labels that make it readable.
    func railHoverLabel() -> some View {
        overlayPreferenceValue(RailHoverKey.self) { target in
            GeometryReader { proxy in
                if let target {
                    let rect = proxy[target.anchor]
                    Text(target.title)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary)
                        }
                        .shadow(radius: 6, y: 2)
                        .fixedSize()
                        .offset(x: rect.maxX + 8, y: rect.midY - 14)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Rail row

/// One destination in the rail: icon only and named on hover when collapsed,
/// icon beside its name when expanded.
struct RailIcon: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var badge: Int = 0
    /// Small marker trailing the row — the pencil that flags the account new
    /// mail is composed from.
    var trailingSymbol: String?
    @Environment(\.railExpanded) private var expanded

    init(_ title: String, systemImage: String, tint: Color? = nil, badge: Int = 0,
         trailingSymbol: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.badge = badge
        self.trailingSymbol = trailingSymbol
    }

    var body: some View {
        Group {
            if expanded { labeled } else { iconOnly }
        }
        .railTitle(title)
    }

    private var labeled: some View {
        HStack(spacing: 8) {
            icon.imageScale(.large).frame(width: 22)
            // Addresses are the long ones, and their tail — the domain — is
            // what tells two accounts apart, so trim from the middle.
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailingSymbol { marker(trailingSymbol) }
            if badge > 0 { badgeLabel }
        }
        .frame(minHeight: 22)
    }

    private var iconOnly: some View {
        icon
            .imageScale(.large)
            .frame(maxWidth: .infinity, minHeight: 22)
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    badgeLabel.offset(x: 4, y: -5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let trailingSymbol {
                    marker(trailingSymbol).offset(x: 4, y: 3)
                }
            }
    }

    private func marker(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var badgeLabel: some View {
        Text("\(badge)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.red, in: Capsule())
    }

    // Only accounts carry a tint; everything else lets the list color its own
    // symbol, so a selected row still flips to white on the highlight.
    @ViewBuilder private var icon: some View {
        if let tint {
            Image(systemName: systemImage).foregroundStyle(tint)
        } else {
            Image(systemName: systemImage)
        }
    }
}
