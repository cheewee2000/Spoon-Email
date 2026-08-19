import SwiftUI
import UniformTypeIdentifiers
import MailCore

struct ComposeDraft: Identifiable {
    let id = UUID()
    var accountId: String
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""            // plain-text version of what was typed
    var bodyHTML: String = ""        // rich version, sent as the text/html part
    var attachments: [ComposeAttachment] = []  // inline images the body cites by cid
    var quotedText: String = ""      // plain-text fallback of the quoted trail
    var quotedHTML: String?          // original HTML, sent as-is below the new text
    var threadId: String?
    var inReplyTo: String = ""
    var references: String = ""
    var draftMessageId: String = ""  // Gmail draft being edited ("" if new)
    var gmailDraftId: String = ""    // stable draft id, learned on first save this session
}

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    /// Set when the composer runs in its own window, where `dismiss` has
    /// nothing to dismiss.
    private let onClose: (() -> Void)?
    @State private var showCcBcc = false
    @State private var suggestions: [(name: String, email: String)] = []
    @State private var showQuoted = false
    @State private var richBody: NSAttributedString
    @State private var showLinkPrompt = false
    @State private var linkURL = ""
    @State private var isDropTargeted = false
    @State private var dropError: String?
    /// Fingerprint of the content most recently written to Gmail; autosave
    /// only fires when the composer has drifted from it. Starts as the
    /// opening content so an untouched draft never saves.
    @State private var savedFingerprint = ""
    /// Set once the message is sent or explicitly saved/closed — the exit
    /// flush must not double-save behind it.
    @State private var closing = false
    /// Files dropped on the window, sent as regular (non-inline) attachments.
    @State private var files: [ComposeAttachment] = []
    @StateObject private var rich = RichTextController()
    @FocusState private var focus: Field?

    enum Field { case to, cc, bcc, subject, body }

    /// Pins the header label column so the fields, not the labels, take up
    /// the slack when the window is widened.
    private static let labelWidth: CGFloat = 62

    init(draft: ComposeDraft, onClose: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onClose = onClose
        _richBody = State(initialValue: RichHTML.attributed(fromHTML: draft.bodyHTML,
                                                            plainFallback: draft.body,
                                                            inlineImages: draft.attachments))
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    SectionLabel(text: "From")
                        .frame(width: Self.labelWidth, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    if isBoundToAccount {
                        // A reply, or a stored draft, belongs to a Gmail thread
                        // that only its own account can add to — so it answers
                        // from the address it arrived at, and that's not a choice.
                        Text(model.accountEmail(draft.accountId))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Replies are sent from the account that received the message.")
                    } else {
                        Picker("", selection: $draft.accountId) {
                            ForEach(model.accountStore.accounts) { account in
                                Text(account.email).tag(account.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
                recipientRows("To", text: $draft.to, field: .to)
                if showCcBcc {
                    recipientRows("Cc", text: $draft.cc, field: .cc)
                    recipientRows("Bcc", text: $draft.bcc, field: .bcc)
                } else {
                    GridRow {
                        Color.clear.frame(width: Self.labelWidth, height: 0)
                        Button("+ Cc/Bcc") { showCcBcc = true }
                            .buttonStyle(.textAction(CWT.ink3))
                    }
                }
                GridRow {
                    SectionLabel(text: "Subject")
                        .frame(width: Self.labelWidth, alignment: .trailing)
                    TextField("", text: $draft.subject)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focused($focus, equals: .subject)
                }
            }
            .padding(12)
            .background(CWT.paperWarm)
            Hairline()
            formatBar
            Hairline()
            RichTextEditor(text: $richBody, controller: rich)
                .focused($focus, equals: .body)
            if draft.quotedHTML != nil || !draft.quotedText.isEmpty {
                Hairline()
                DisclosureGroup(isExpanded: $showQuoted) {
                    Group {
                        if let html = draft.quotedHTML {
                            MessageWebView(html: quotedPreviewDoc(html))
                        } else {
                            ScrollView {
                                Text(draft.quotedText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(CWT.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                        }
                    }
                    .frame(height: 180)
                } label: {
                    Text("Quoted message — included below your reply")
                        .font(CWT.caption)
                        .foregroundStyle(CWT.ink2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Hairline()
            if !files.isEmpty {
                attachmentStrip
                Hairline()
            }
            if let dropError {
                Text(dropError)
                    .font(CWT.caption)
                    .foregroundStyle(CWT.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button("Close") {
                    // Not a discard: progress survives as a draft, same as
                    // closing the window. Deleting the draft discards it.
                    autosaveIfDirty()
                    closing = true
                    close()
                }
                    .buttonStyle(.textAction(CWT.ink2))
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close — keeps your progress as a draft (Esc)")
                Button("Save draft") {
                    closing = true
                    captureBody()
                    model.saveDraft(draft)
                    close()
                }
                .buttonStyle(.textAction(CWT.ink2))
                .padding(.leading, 8)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save Draft (⌘S)")
                Spacer()
                Menu {
                    Button("In 1 Hour") { sendAt(Date().addingTimeInterval(3600)) }
                    Button("Tonight 8 PM") { sendAt(next(hour: 20)) }
                    Button("Tomorrow 9 AM") { sendAt(next(hour: 9, forceTomorrow: true)) }
                } label: {
                    Text("Send later ↓")
                        .font(CWT.font(12))
                        .foregroundStyle(CWT.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Schedule the send")
                Button("Send →") { sendAt(nil) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.squarePrimary)
                    .disabled(draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Send (⌘Return)")
            }
            .padding(12)
            .background(CWT.paperWarm)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
        .onDrop(of: [.image, .fileURL, .data], isTargeted: $isDropTargeted) { providers in
            receive(providers)
        }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(CWT.ink, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .background(CWT.ink.opacity(0.04))
                    .overlay(
                        Text("Drop images to insert, files to attach")
                            .font(CWT.caption)
                            .foregroundStyle(CWT.paper)
                            .padding(6)
                            .background(CWT.ink)
                    )
                    .allowsHitTesting(false)
                    .padding(4)
            }
        }
        .onAppear {
            rich.onFileDrop = receiveFileURLs
            files = draft.attachments.filter { !$0.isInline }
            if !draft.cc.isEmpty || !draft.bcc.isEmpty { showCcBcc = true }
            focus = draft.to.isEmpty ? .to : .body
            savedFingerprint = fingerprint()
            #if os(macOS)
            ComposeWindowHost.shared.willClose = { autosaveIfDirty() }
            #endif
        }
        .onDisappear { autosaveIfDirty() }
        .task {
            // Periodic autosave, torn down with the view.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                autosaveIfDirty()
            }
        }
    }

    // MARK: - Autosave

    /// What the draft would be saved as right now. `captureBody()` first.
    private func fingerprint() -> String {
        captureBody()
        return [draft.to, draft.cc, draft.bcc, draft.subject, draft.bodyHTML,
                draft.attachments.map(\.id).joined(separator: ",")]
            .joined(separator: "\u{1}")
    }

    /// Saves silently when the content has changed since the last write —
    /// covers the 30 s tick, the red close button, and the sheet dismissing.
    private func autosaveIfDirty() {
        guard !closing else { return }
        let fp = fingerprint()
        guard fp != savedFingerprint else { return }
        savedFingerprint = fp
        let snapshot = draft
        Task {
            if let ids = await model.persistDraft(snapshot, quiet: true) {
                // Feed the ids back so the next tick updates in place; the
                // message id is new after every update.
                draft.gmailDraftId = ids.draftId
                draft.draftMessageId = ids.messageId
            } else {
                savedFingerprint = ""  // failed — retry on the next tick
            }
        }
    }

    /// True when the message is tied to a Gmail thread or draft that lives in
    /// one account, which fixes the sending address.
    private var isBoundToAccount: Bool {
        draft.threadId != nil || !draft.draftMessageId.isEmpty
    }

    /// One address line plus, while it has focus, the contact matches for
    /// whatever is being typed after the last comma. Same lookup for To, Cc
    /// and Bcc — the list follows the caret.
    @ViewBuilder
    private func recipientRows(_ label: String, text: Binding<String>, field: Field) -> some View {
        GridRow {
            SectionLabel(text: label)
                .frame(width: Self.labelWidth, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focus, equals: field)
                .onChange(of: text.wrappedValue) { updateSuggestions(for: field) }
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
        }
        if !suggestions.isEmpty && focus == field {
            GridRow {
                Color.clear.frame(width: Self.labelWidth, height: 0)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.email) { s in
                        Button {
                            applySuggestion(s, to: field)
                        } label: {
                            Text("\(s.name) <\(s.email)>")
                                .font(CWT.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.textAction(CWT.ink2))
                    }
                }
            }
        }
    }

    /// Dropped files, each with its size and an × to pull it back out.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 10))
                        Text(file.filename).lineLimit(1).truncationMode(.middle)
                        Text(Self.byteFormatter.string(fromByteCount: Int64(file.data.count)))
                            .foregroundStyle(CWT.ink3)
                        Button {
                            files.removeAll { $0.id == file.id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .font(CWT.caption)
                    .foregroundStyle(CWT.ink2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Rich-text formatting for the body. The editor also takes the standard
    /// system shortcuts, so these are the discoverable version.
    private var formatBar: some View {
        HStack(spacing: 4) {
            Button { rich.toggleBold() } label: { Image(systemName: "bold") }
                .keyboardShortcut("b", modifiers: .command)
                .help("Bold (⌘B)")
            Button { rich.toggleItalic() } label: { Image(systemName: "italic") }
                .keyboardShortcut("i", modifiers: .command)
                .help("Italic (⌘I)")
            Button { rich.toggleUnderline() } label: { Image(systemName: "underline") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Underline (⌘U)")
            Button { rich.toggleStrikethrough() } label: { Image(systemName: "strikethrough") }
                .help("Strikethrough")
            Hairline(axis: .vertical).frame(height: 14)
            Button { linkURL = ""; showLinkPrompt = true } label: { Image(systemName: "link") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .help("Add Link (⇧⌘K)")
            Button { rich.clearFormatting() } label: { Image(systemName: "eraser") }
                .help("Clear formatting from the selection")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .popover(isPresented: $showLinkPrompt) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Link URL")
                TextField("https://", text: $linkURL)
                    .textFieldStyle(.plain)
                    .font(CWT.font(12))
                    .padding(6)
                    .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
                    .frame(width: 260)
                    .onSubmit { applyLink() }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { showLinkPrompt = false }
                        .buttonStyle(.square)
                    Button("Add") { applyLink() }
                        .buttonStyle(.squarePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .cwtChrome()
        }
    }

    /// Closes the composer, whichever way it was put on screen.
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func applyLink() {
        rich.applyLink(linkURL)
        showLinkPrompt = false
    }

    // MARK: - Dropped images

    /// Accepts dropped images and drops them into the body at the caret.
    /// Returns false when nothing in the drag was an image, so the drag
    /// bounces back instead of silently vanishing.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let images = providers.filter(InlineImageLoader.supported)
        let others = providers.filter { !InlineImageLoader.supported($0) && FileAttachmentLoader.supported($0) }
        guard !images.isEmpty || !others.isEmpty else { return false }
        Task {
            dropError = nil
            if !images.isEmpty {
                let loaded = await InlineImageLoader.load(images)
                if loaded.isEmpty { dropError = "Couldn't read that image." }
                for (payload, image) in loaded {
                    guard fits(payload) else { break }
                    rich.insert(image: InlineImageAttachment(payload: payload, image: image))
                }
            }
            if !others.isEmpty {
                let loaded = await FileAttachmentLoader.load(others)
                if loaded.isEmpty { dropError = "Couldn't read that file." }
                for file in loaded {
                    guard fits(file) else { break }
                    files.append(file)
                }
            }
        }
        return true
    }

    /// Files dropped directly on the body text view, which reads its own drag
    /// pasteboard — same routing as `receive`: images inline, the rest attached.
    private func receiveFileURLs(_ urls: [URL]) -> Bool {
        dropError = nil
        for url in urls {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                dropError = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let name = url.lastPathComponent
            if let (payload, image) = InlineImageLoader.prepare(data: data, filename: name) {
                guard fits(payload) else { break }
                rich.insert(image: InlineImageAttachment(payload: payload, image: image))
            } else {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                let file = ComposeAttachment(filename: name, mimeType: mime,
                                             data: data, isInline: false)
                guard fits(file) else { break }
                files.append(file)
            }
        }
        return true
    }

    /// Guards the message against outgrowing what Gmail will take. Counts what
    /// is already in the body, since images arrive one drop at a time.
    private func fits(_ candidate: ComposeAttachment) -> Bool {
        let used = (RichHTML.attachments(in: richBody) + files).reduce(0) { $0 + $1.data.count }
        guard used + candidate.data.count <= ComposeAttachment.totalByteLimit else {
            dropError = "\(candidate.filename) would push the message past "
                + "\(ComposeAttachment.totalByteLimit / 1_000_000) MB — it wasn't added."
            return false
        }
        return true
    }

    /// Snapshots the editor into the draft right before it leaves the sheet.
    private func captureBody() {
        draft.body = RichHTML.plainText(from: richBody)
        draft.bodyHTML = RichHTML.html(from: richBody)
        draft.attachments = RichHTML.attachments(in: richBody) + files
    }

    private func quotedPreviewDoc(_ html: String) -> String {
        """
        <!doctype html><html><head><meta name="color-scheme" content="light dark"><style>
          body { margin: 8px; font: 12px -apple-system, sans-serif; }
          img { max-width: 100% !important; height: auto !important; }
        </style></head><body>\(html)</body></html>
        """
    }

    private func sendAt(_ date: Date?) {
        closing = true
        captureBody()
        model.send(draft: draft, at: date)
        close()
    }

    private func next(hour: Int, forceTomorrow: Bool = false) -> Date {
        let cal = Calendar.current
        var date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        if forceTomorrow || date <= Date() {
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        return date
    }

    private func recipientText(_ field: Field) -> String {
        switch field {
        case .cc: return draft.cc
        case .bcc: return draft.bcc
        default: return draft.to
        }
    }

    private func setRecipientText(_ field: Field, _ value: String) {
        switch field {
        case .cc: draft.cc = value
        case .bcc: draft.bcc = value
        default: draft.to = value
        }
    }

    private func updateSuggestions(for field: Field) {
        let query = recipientText(field).components(separatedBy: ",").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard query.count >= 2 else {
            suggestions = []
            return
        }
        Task {
            let hits = await model.suggestContacts(query)
            // Keystrokes can finish out of order — only the lookup that
            // still matches what's typed gets to set the list.
            let current = recipientText(field).components(separatedBy: ",").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if current == query { suggestions = hits }
        }
    }

    private func applySuggestion(_ s: (name: String, email: String), to field: Field) {
        var parts = recipientText(field).components(separatedBy: ",")
        parts[parts.count - 1] = " \(s.name) <\(s.email)>"
        setRecipientText(field, parts.joined(separator: ",").trimmingCharacters(in: .whitespaces))
        suggestions = []
    }
}
