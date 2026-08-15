import SwiftUI

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let shortcut: String?
    let perform: () -> Void

    init(_ title: String, systemImage: String, shortcut: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.perform = perform
    }
}

struct CommandPalette: View {
    let actions: [PaletteAction]
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var filtered: [PaletteAction] {
        guard !query.isEmpty else { return actions }
        let q = query.lowercased()
        return actions
            .filter { fuzzyMatches($0.title.lowercased(), q) }
            .sorted { a, b in
                let ap = a.title.lowercased().hasPrefix(q)
                let bp = b.title.lowercased().hasPrefix(q)
                if ap != bp { return ap }
                return a.title.count < b.title.count
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(CWT.font(15))
                .padding(14)
                .focused($focused)
                .onSubmit { runHighlighted() }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(0, filtered.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, action in
                            Button {
                                run(action)
                            } label: {
                                HStack {
                                    Image(systemName: action.systemImage)
                                        .frame(width: 22)
                                    Text(action.title)
                                        .font(CWT.font(12))
                                    Spacer()
                                    if let s = action.shortcut {
                                        Text(s)
                                            .font(CWT.caption)
                                            .foregroundStyle(idx == highlighted ? CWT.paper.opacity(0.7) : CWT.ink3)
                                    }
                                }
                                .foregroundStyle(idx == highlighted ? CWT.paper : CWT.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(idx == highlighted ? CWT.ink : .clear)
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) {
                    proxy.scrollTo(highlighted)
                }
            }
        }
        .frame(width: 480)
        .background(CWT.paper)
        .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
        .onAppear {
            focused = true
        }
        .onChange(of: query) { highlighted = 0 }
        #if os(macOS)
        .onExitCommand { isPresented = false }
        #else
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        #endif
    }

    private func runHighlighted() {
        guard filtered.indices.contains(highlighted) else { return }
        run(filtered[highlighted])
    }

    private func run(_ action: PaletteAction) {
        isPresented = false
        action.perform()
    }

    /// Subsequence fuzzy match: every char of q appears in order in s.
    private func fuzzyMatches(_ s: String, _ q: String) -> Bool {
        var it = s.makeIterator()
        outer: for ch in q {
            while let c = it.next() {
                if c == ch { continue outer }
            }
            return false
        }
        return true
    }
}
