import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The pasteboard payload a dragged row carries.
///
/// A PLAIN PATH IS NOT ENOUGH: the drop has to know which MACHINE the file
/// is on to decide whether the gesture transfers or names it, and a path
/// alone silently reads as local. This travels under a private type; the
/// plain-text path rides along so a drop into any other application still
/// does something sensible.
struct DraggedFile: Codable, Equatable {
    var hostID: String?
    var path: String
    /// A tree. The receiver needs it: the copy recurses and the size is a
    /// walk rather than a stat.
    var isDirectory: Bool = false
    /// EVERYTHING ELSE IN THE SAME DRAG.
    ///
    /// One drag can carry a selection, and it is carried in ONE payload
    /// rather than as several pasteboard items: a receiver that reads the
    /// first item and acts is then correct for one file and silently wrong
    /// for the rest, which is the failure this shape makes impossible.
    var siblings: [DraggedFile] = []

    static let pasteboardType = "dev.synapty.file-endpoint"

    /// WHAT IS BEING DRAGGED RIGHT NOW, INSIDE THIS PROCESS.
    ///
    /// A pasteboard is how two PROCESSES describe a drag to each other. Our
    /// panel and our terminal are the same process, and going through the
    /// board cost us the feature entirely: SwiftUI's `.onDrag` hands AppKit
    /// an NSItemProvider, which makes every representation a PROMISE
    /// resolved asynchronously by the receiver — while `draggingEntered`
    /// has to answer synchronously, in the same call, whether it accepts.
    /// Measured, with our own type sitting in the board's list the whole
    /// time:
    ///
    ///   drag refused: endpoints=0 preview=set
    ///   board=[… Apple files promise …, dev.synapty.file-endpoint, …]
    ///
    /// Registering the data eagerly does not help: the provider is wrapped
    /// either way. So the payload travels in the process that owns both
    /// ends, and the pasteboard keeps doing the job it is actually for —
    /// the file promise that makes a drop into Finder produce a file.
    ///
    /// READ ONLY WHEN THE BOARD SAYS THE DRAG IS OURS, so a stale value can
    /// never be attached to somebody else's drag.
    @MainActor static var inFlight: DraggedFile?

    var endpoint: FileEndpoint {
        FileEndpoint(hostID: hostID.flatMap { UUID(uuidString: $0) },
                     path: path, isDirectory: isDirectory)
    }

    /// Every endpoint in the drag, this one first.
    var endpoints: [FileEndpoint] { [endpoint] + siblings.map(\.endpoint) }

    init(endpoint: FileEndpoint) {
        self.hostID = endpoint.hostID?.uuidString
        self.path = endpoint.path
        self.isDirectory = endpoint.isDirectory
    }

    init(endpoints: [FileEndpoint]) {
        self.init(endpoint: endpoints.first ?? FileEndpoint(hostID: nil, path: ""))
        self.siblings = endpoints.dropFirst().map { DraggedFile(endpoint: $0) }
    }

    static func from(_ data: Data) -> DraggedFile? {
        try? JSONDecoder().decode(DraggedFile.self, from: data)
    }

    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// The panel's file view: one host's directory, navigable, draggable.
struct RemoteFilesView: View {

    let host: HostEntry?
    let hostStore: HostStore
    let tunnelManager: TunnelManager
    let transfers: TransferService
    let artifacts: ArtifactService

    /// WHERE THIS PANE IS, WHAT IS ON ITS SCREEN, AND WHAT IS BEING TYPED
    /// INTO IT — one value, because they are not independent
    /// ([[FileBrowsing]] carries the reasoning and the four defects).
    @State private var browsing = FileBrowsing()

    /// WHERE THIS LEAF IS LOOKING, AND WHO REMEMBERS IT.
    ///
    /// The directory belongs to the LEAF ([[RFC-0015]] C-PERSIST: a file
    /// leaf's durable state is "the directory it is showing"), not to this
    /// view. It lived in `path` alone, which is `@State` — so switching
    /// tabs destroyed the view and the pane came back at `~`, undoing five
    /// clicks of navigation on a remote machine because the human looked
    /// at something else ([[WI-2026-08-19-002]]).
    ///
    /// The view still holds its own whereabouts as a working copy; these
    /// two carry the directory out to the leaf and back.
    var initialDirectory: String?
    var onDirectoryChange: (String) -> Void = { _ in }
    /// How this leaf is being looked at — where it has been, what it is
    /// filtered to, how it is sorted ([[WorkspaceManager.FileNavigation]]).
    /// Held by the leaf rather than here, because this view is destroyed
    /// every time the human looks at another tab.
    var navigation: WorkspaceManager.FileNavigation = .init()
    /// WHOSE OUTPUT OPENED THIS PANE, when text did rather than the human
    /// ([[RFC-0015]] C-DERIVED rule five). Nil for a pane they opened
    /// themselves, which owes nothing.
    var openedFrom: String?
    var onFilter: (String) -> Void = { _ in }
    var onListing: ([BrowsedFile], String) -> Void = { _, _ in }
    var onInvalidate: (String) -> Void = { _ in }
    var onSort: (WorkspaceManager.FileNavigation.Sort) -> Void = { _ in }
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    @FocusState private var filterFocused: Bool
    @FocusState private var pathFocused: Bool
    /// Files being fetched for opening — a remote one takes as long as it
    /// takes, and a row that shows nothing reads as a double click that
    /// missed.
    @State private var opening: Set<String> = []

    // MARK: - Writes ([[RFC-0015]] C-PANE-WRITES)

    /// What the human has been asked and has not yet answered. One at a
    /// time: a second question stacked on the first is one nobody reads.
    @State private var pendingDeletion: [BrowsedFile]?
    @State private var renaming: BrowsedFile?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    /// A collision the human must answer before the write proceeds.
    @State private var pendingReplacement: (name: String, proceed: () -> Void)?
    /// A DIRECTORY THAT CANNOT BE READ AND A WRITE THAT FAILED ARE TWO
    /// DIFFERENT ANSWERS, and they shared one variable.
    ///
    /// The listing's error is drawn INSTEAD of the listing, so a rename
    /// that failed replaced the whole pane with "Cannot read this folder"
    /// — untrue, and a way to lose the directory the human was working in.
    /// The first of these empties the pane; the second is reported over
    /// the rows it failed on.
    @State private var listingFailure: String?
    @State private var notice: String?
    /// A home directory is mostly dotfiles — sixty of them ahead of
    /// anything the human put there. Hidden by default, like every other
    /// file browser on this platform, with a way back to them.
    @AppStorage("synapty.panelShowHidden") private var showHidden = false
    @State private var hovered: String?
    /// What is selected, by name. Cleared on navigation, because a
    /// selection that outlived the directory it was made in would send
    /// files from somewhere the human is no longer looking at.
    @State private var selected: Set<String> = []
    /// The anchor for a shift-click range.
    @State private var anchor: String?
    /// Bumped to force a reload; a host change and a path change both mean
    /// "list again", and a single trigger keeps them from racing.
    @State private var reloadToken = 0

    /// THE ROWS ON SCREEN AND THE DIRECTORY THEY CAME FROM. Everything a
    /// row does resolves against this: opening it, dragging it, renaming
    /// it, deleting it, and dropping something beside it.
    private var shown: Listing { browsing.here.showing }
    private var files: [BrowsedFile] { shown.files }

    var body: some View {
        VStack(spacing: 0) {
            // HANDED OVER, above what was browsed to. An artifact an agent
            // pushed is not something the human navigated to, and mixing it
            // into the directory listing would make it look like a file
            // that was always there ([[RFC-0013]] C-PRIMITIVES).
            if !artifacts.artifacts.isEmpty { presented }
            originStrip
            breadcrumb
            noticeStrip
            DSHairline()
            listing
        }
        .onChange(of: host?.id) { _, _ in
            // A new host starts at its own home; carrying the previous
            // host's path over would ask for a directory that is unlikely
            // to exist and would open on an error.
            navigate(to: "~")
        }
        .onChange(of: reloadToken) { _, _ in load() }
        // THE QUESTION NAMES THE MACHINE AND SAYS WHAT CANNOT BE UNDONE
        // ([[RFC-0015]] C-PANE-WRITES). Both sentences come from
        // [[PaneWrites]] rather than from here: a dialog is exactly where
        // those obligations get quietly dropped, and a rule kept in one
        // has no test that can ask it anything.
        .confirmationDialog(
            pendingDeletion.map { PaneWrites.deletionQuestion(count: $0.count, machine: hostLabel) } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(PaneWrites.deleteAnswer, role: .destructive) {
                if let files = pendingDeletion { performDelete(files) }
                pendingDeletion = nil
            }
            Button(PaneWrites.safeAnswer, role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(PaneWrites.deletionDetail(machine: hostLabel))
        }
        // A COLLISION IS NOT RESOLVED SILENTLY, and the safe outcome is
        // the default — the cancel role, which is also what Escape and
        // Return reach.
        .confirmationDialog(
            pendingReplacement.map { PaneWrites.replacementQuestion(name: $0.name, machine: hostLabel) } ?? "",
            isPresented: Binding(get: { pendingReplacement != nil },
                                 set: { if !$0 { pendingReplacement = nil } }),
            titleVisibility: .visible
        ) {
            Button(PaneWrites.destructiveAnswer, role: .destructive) {
                pendingReplacement?.proceed()
                pendingReplacement = nil
            }
            Button(PaneWrites.safeAnswer, role: .cancel) { pendingReplacement = nil }
        } message: {
            Text(PaneWrites.replacementDetail(disposal: disposal, machine: hostLabel))
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil },
                                              set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let file = renaming { requestRename(file, to: renameText) }
                renaming = nil
            }
            Button(PaneWrites.safeAnswer, role: .cancel) { renaming = nil }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { performCreateFolder(newFolderName) }
            Button(PaneWrites.safeAnswer, role: .cancel) {}
        }
        .onAppear {
            // RESUME WHERE THE LEAF WAS, not at home. A view that starts
            // at `~` every time it is created is what made switching tabs
            // undo the human's navigation ([[WI-2026-08-19-002]]).
            let start = initialDirectory ?? shown.path
            // AND SHOW WHAT IT LAST SAW WHILE IT CHECKS. The listing is
            // fetched every time regardless — a directory is a claim about
            // a machine and this pane does not get to stop checking — but
            // an empty pane with a spinner, on a leaf the human has
            // already been in, reads as having lost their place a second
            // time.
            browsing.here = .at(Listing(path: start, files: navigation.cached[start] ?? []))
            load()
        }
        // THE LEAF CAN MOVE WITHOUT THIS VIEW ASKING IT TO. Back and
        // forward are the manager's — they walk a history this view does
        // not hold — so the directory changes underneath and the pane has
        // to follow it. Read only at `onAppear`, the buttons updated the
        // model and moved nothing on screen.
        //
        // The guard is what keeps it from chasing its own tail: a
        // navigation that succeeds tells the leaf where it landed, which
        // comes back here as a change, which is already where we are.
        .onChange(of: initialDirectory) { _, moved in
            guard let moved, moved != browsing.here.origin.path,
                  moved != browsing.here.destination else { return }
            navigate(to: moved)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            acceptFromFinder(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyToggleHiddenFiles)) { _ in
            showHidden.toggle()
        }
    }

    /// Each in its own frame, because each was put there by an agent.
    private var presented: some View {
        VStack(spacing: DS.Space.xs) {
            ForEach(artifacts.artifacts) { artifact in
                DSAgentFrame(agent: artifact.agent, title: artifact.title,
                             onDismiss: { artifacts.dismiss(artifact.id) }) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: artifact.isReady ? "doc" : "arrow.down.circle")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artifact.fileName)
                                .font(DS.Typography.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(artifact.isReady
                                 ? (artifact.size.map {
                                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                                    } ?? "ready")
                                 : "arriving…")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                        Spacer(minLength: DS.Space.sm)
                        // OPENED DELIBERATELY, never rendered in place.
                        // Showing arbitrary agent-supplied content inline is
                        // what the frame exists to make safe; a card that
                        // has to be clicked is the smaller promise.
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: artifact.localPath)])
                        }
                        .controlSize(.small)
                        .disabled(!artifact.isReady)
                    }
                    .padding(DS.Space.sm)
                }
            }
        }
        .padding(.top, DS.Space.xs)
    }

    // MARK: - Chrome

    private var breadcrumb: some View {
        HStack(spacing: DS.Space.xs) {
            // BACK AND FORWARD BEFORE UP, in that order, because that is
            // the order every browser and every file manager puts them in
            // and the muscle memory is not ours to redirect.
            DSIconButton(icon: "chevron.left", help: "Back", size: 20) { onBack?() }
                .disabled(onBack == nil || navigation.back.isEmpty)
            DSIconButton(icon: "chevron.right", help: "Forward", size: 20) { onForward?() }
                .disabled(onForward == nil || navigation.forward.isEmpty)
            DSIconButton(icon: "chevron.up", help: "Enclosing folder", size: 20) {
                let parent = (shown.path as NSString).deletingLastPathComponent
                navigate(to: parent.isEmpty ? "/" : parent)
            }
            .disabled(shown.path == "/")

            // A PATH THAT CAN BE TYPED. Reaching ~/work/proj/src on a
            // remote machine was five clicks, and one mistake was five
            // more. Submitting navigates; a path that does not exist
            // fails where every other failed listing does — in the pane,
            // saying so — rather than navigating somewhere else.
            TextField("", text: Binding(
                get: { browsing.address },
                set: { browsing.draft = $0 }))
                .textFieldStyle(.plain)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(browsing.here.isLoading ? DS.textTertiary : DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(browsing.address)
                // NAMED, so a test can ask what this pane says it is
                // showing. It is the one surface that answers "did the
                // view follow the model", which is the class of defect no
                // unit test can see.
                .accessibilityIdentifier("file-pane-path")
                .focused($pathFocused)
                .onSubmit {
                    if let typed = browsing.draft?.trimmingCharacters(in: .whitespaces),
                       !typed.isEmpty {
                        navigate(to: typed)
                    }
                    browsing.draft = nil
                }
                // A path half-typed and abandoned is not where the human
                // is; the field goes back to saying where they are.
                .onExitCommand { browsing.draft = nil }
                .onChange(of: pathFocused) { _, focused in
                    if !focused { browsing.draft = nil }
                }

            Spacer(minLength: 0)

            // FILTERING HAPPENS ON WHAT IS ALREADY FETCHED, so it needs no
            // round trip and stays instant even on a slow link.
            DSIconButton(icon: "line.3.horizontal.decrease", help: "Filter", size: 20) {
                filterFocused = true
            }
            TextField("Filter", text: Binding(
                get: { navigation.filter },
                set: { onFilter($0) }))
                .textFieldStyle(.plain)
                .font(DS.Typography.monoCaption)
                .frame(width: DS.scaled(110))
                .focused($filterFocused)

            Menu {
                ForEach(WorkspaceManager.FileNavigation.Sort.allCases, id: \.self) { sort in
                    Button {
                        onSort(sort)
                    } label: {
                        // The tick says which column, the arrow which way —
                        // a sort that shows one without the other is half
                        // an answer.
                        if navigation.sort == sort {
                            Label(sort.rawValue.capitalized,
                                  systemImage: navigation.ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(sort.rawValue.capitalized)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by \(navigation.sort.rawValue)")

            // Filtering happens on what was already fetched, so this needs
            // no reload and stays instant.
            DSIconButton(
                icon: showHidden ? "eye" : "eye.slash",
                help: CommandHint.help(showHidden ? "Hide hidden files" : "Show hidden files",
                                       for: "files.show-hidden"),
                size: 20
            ) {
                showHidden.toggle()
            }

            DSIconButton(icon: "folder.badge.plus", help: "New folder", size: 20) {
                newFolderName = ""
                creatingFolder = true
            }

            if browsing.here.isLoading {
                ProgressView().controlSize(.small)
            } else {
                DSIconButton(icon: "arrow.clockwise", help: "Reload", size: 20) {
                    reloadToken += 1
                }
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
    }

    @ViewBuilder
    private var listing: some View {
        if let listingFailure {
            DSEmptyState(
                icon: "exclamationmark.triangle",
                title: PaneWrites.listingFailureTitle(machine: host == nil ? nil : hostLabel),
                message: listingFailure)
        } else if visibleFiles.isEmpty && !browsing.here.isLoading {
            // A FOLDER THAT IS EMPTY AND ONE THAT IS FILTERED EMPTY ARE
            // DIFFERENT ANSWERS. Showing "nothing here" over hidden content
            // sends the human looking for a file that is right there.
            DSEmptyState(
                icon: files.isEmpty ? "folder" : "eye.slash",
                title: files.isEmpty ? "Nothing here" : "Only hidden files",
                message: files.isEmpty
                    ? (host == nil ? "This folder is empty." : "This folder is empty on \(hostLabel).")
                    : "\(files.count) hidden \(files.count == 1 ? "item" : "items"). "
                        + "Press \(CommandHint.reach("files.show-hidden")) to show them.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleFiles) { file in
                        row(file)
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
        }
    }

    /// A PANE THE HUMAN DID NOT NAVIGATE TO SAYS SO, ABOVE EVERYTHING.
    ///
    /// Nothing else on a file leaf distinguishes one that arrived because
    /// an agent printed a path from one the human opened. Above the
    /// breadcrumb rather than below it, because the breadcrumb is the
    /// first thing read and this is the frame around it.
    @ViewBuilder
    private var originStrip: some View {
        if let openedFrom {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(DS.textTertiary)
                Text(openedFrom)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .background(DS.surfaceRaised)
            DSHairline()
        }
    }

    /// A FAILED WRITE IS REPORTED OVER THE ROWS IT FAILED ON, never
    /// instead of them.
    @ViewBuilder
    private var noticeStrip: some View {
        if let notice {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.danger)
                Text(notice)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: DS.Space.sm)
                DSIconButton(icon: "xmark", help: "Dismiss", size: 16) {
                    self.notice = nil
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.xs)
            .background(DS.danger.opacity(0.10))
        }
    }

    private func row(_ file: BrowsedFile) -> some View {
        HStack(spacing: DS.Space.sm) {
            FileRowIcon(file: file)

            Text(file.name)
                .font(DS.Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DS.Space.sm)

            if let size = file.size, !file.isDirectory {
                Text(Self.byteFormatter.string(fromByteCount: size))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.xs + 1)
        // NO RULE PER ROW. A separator under every line turns a short list
        // into a ledger; the hover highlight already says which row the
        // pointer is on, which is the only thing the rule was doing.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(selected.contains(file.id) ? DS.selectionAccentSoft
                      : (hovered == file.id ? DS.hover : .clear))
                .padding(.horizontal, DS.Space.sm))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? file.id : (hovered == file.id ? nil : hovered) }
        .contextMenu {
            Button("Rename…") { renaming = file; renameText = file.name }
            Button(host == nil ? "Move to Trash" : "Delete…", role: .destructive) {
                requestDelete(selected.contains(file.id) ? selectedFiles : [file])
            }
        }
        .modifier(RowClick(
            onClick: { modifiers in select(file, modifiers: modifiers) },
            onDoubleClick: {
                // A DIRECTORY OPENS ON DOUBLE CLICK, not single, now that a
                // single click means "select". One gesture cannot both
                // choose a thing and leave the place it is in.
                if file.isDirectory {
                    navigate(to: endpoint(for: file).path)
                } else {
                    open(file)
                }
            }))
        // Directories are not draggable: a recursive copy is a different
        // operation with a different cost, and offering the same gesture
        // for both would make the cheap one look expensive and the
        // expensive one look free.
        .ifDraggable(true, fetch: fetchForDrag) {
            // DRAG THE SELECTION, not the row under the pointer — unless
            // that row is outside it, which is the one case where the
            // pointer is the more recent statement of intent.
            let names = selected.contains(file.id) ? selected : [file.id]
            let chosen = visibleFiles.filter { names.contains($0.id) }
            return DraggedFile(endpoints: chosen.map { endpoint(for: $0) })
        }
        .help(file.isDirectory
              ? "Double-click to open · drag to send the whole folder"
              : "Drag onto a terminal to send it there")
    }

    // MARK: - Loading

    /// Filtered here rather than at fetch time, so toggling is instant and
    /// the empty state can still tell "empty" from "all hidden".
    private var visibleFiles: [BrowsedFile] {
        var shown = showHidden ? files : files.filter { !$0.name.hasPrefix(".") }

        // ON WHAT IS ALREADY FETCHED — no round trip, so it stays instant
        // on a link where a listing takes a second ([[WI-2026-08-19-002]]).
        let needle = navigation.filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            shown = shown.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }

        // DIRECTORIES FIRST, WHATEVER THE COLUMN. Sorting a listing by
        // size with the folders scattered through it — all of them zero —
        // is a sort that has technically obeyed and practically lost the
        // shape of the directory.
        return shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let ordered: Bool
            switch navigation.sort {
            case .name:
                ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                ordered = (a.size ?? 0) < (b.size ?? 0)
            case .modified:
                ordered = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
            return navigation.ascending ? ordered : !ordered
        }
    }

    private var hostLabel: String {
        guard let host else { return "this Mac" }
        return host.label.isEmpty ? host.address : host.label
    }

    /// Bring a remote file here so a receiver outside this application can
    /// have it. Local files are already where they need to be.
    private func fetchForDrag(
        _ source: FileEndpoint, to staged: URL, completion: @escaping (Error?) -> Void
    ) {
        guard !source.isLocal else {
            do {
                try FileManager.default.copyItem(atPath: source.path, toPath: staged.path)
                completion(nil)
            } catch { completion(error) }
            return
        }
        let id = transfers.enqueue(
            from: source,
            to: FileEndpoint(hostID: nil, path: staged.deletingLastPathComponent().path))
        // The receiver is holding the drag open, so this waits on the same
        // queue everything else uses rather than opening a second path.
        transfers.whenFinished(id) { state in
            switch state {
            case .done: completion(nil)
            case .failed(let why):
                completion(NSError(domain: "dev.synapty.transfer", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: why]))
            default:
                completion(NSError(domain: "dev.synapty.transfer", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
            }
        }
    }

    /// GIVE THE FILE TO THE SYSTEM, do not render it here
    /// ([[WI-2026-08-19-002]]).
    ///
    /// This workbench is not a viewer for every file type on a machine,
    /// and a viewer reassembled one format at a time is worse than the
    /// one already installed — the same reasoning the services pane
    /// follows when it hands a page to the real browser. A remote file
    /// comes here first, through the transfer queue everything else
    /// uses, and then goes to whatever the human's Mac opens it with.
    ///
    /// INTO A CACHE THAT SAYS WHERE IT CAME FROM. A file opened from a
    /// remote machine is a COPY, and one dropped in a temporary directory
    /// with a bare name is a copy the human cannot tell from the original
    /// they were editing.
    private func open(_ file: BrowsedFile) {
        let source = endpoint(for: file)
        guard !source.isLocal else {
            NSWorkspace.shared.open(URL(fileURLWithPath: source.path))
            return
        }
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synapty-opened")
            .appendingPathComponent(hostLabel)
        let staged = cache.appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
        } catch {
            notice = "could not prepare a place for \(file.name): \(error.localizedDescription)"
            return
        }
        opening.insert(file.id)
        fetchForDrag(source, to: staged) { error in
            Task { @MainActor in
                opening.remove(file.id)
                if let error {
                    // THE SAME PLACE EVERY OTHER FAILURE IS REPORTED. A
                    // fetch that failed silently leaves the human waiting
                    // for an application that is never going to open.
                    notice = "could not open \(file.name): \(error.localizedDescription)"
                } else {
                    NSWorkspace.shared.open(staged)
                }
            }
        }
    }

    /// THE SELECTION, WHERE THE POINTER IS INSIDE IT — the same rule the
    /// drag follows, so a right-click on one of five selected rows means
    /// the five and not the one.
    private var selectedFiles: [BrowsedFile] {
        visibleFiles.filter { selected.contains($0.id) }
    }

    /// WHERE THE DELETION GOES DECIDES WHETHER IT IS ASKED
    /// ([[RFC-0015]] C-PANE-WRITES). Local goes to the Trash and is not
    /// confirmed; everything else is confirmed and says so.
    private var disposal: PaneWrites.Disposal {
        PaneWrites.disposal(isLocal: host == nil)
    }

    private func requestDelete(_ files: [BrowsedFile]) {
        guard !files.isEmpty else { return }
        if PaneWrites.confirms(disposal) {
            pendingDeletion = files
        } else {
            performDelete(files)
        }
    }

    private func performDelete(_ files: [BrowsedFile]) {
        for file in files {
            let target = endpoint(for: file)
            let record = TransferService.PaneWrite(
                id: UUID(), verb: .deleted(disposal), machine: hostLabel,
                path: target.path, at: Date())
            transfers.record(record)

            if host == nil {
                // THE PLATFORM'S TRASH, not an unlink — this is the whole
                // of what makes the local path recoverable and therefore
                // unconfirmed.
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: target.path), resultingItemURL: nil)
                } catch {
                    fail(record.id, "could not delete \(file.name): \(error.localizedDescription)")
                }
            } else {
                remoteWrite(.delete(target.path, isDirectory: file.isDirectory), record: record.id,
                            failing: "could not delete \(file.name)")
            }
        }
        selected = []
        onInvalidate(shown.path)
        reloadToken += 1
    }

    private func requestRename(_ file: BrowsedFile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        // A RENAME ONTO AN EXISTING NAME DESTROYS WHAT WAS THERE, and a
        // collision may not be resolved silently.
        if visibleFiles.contains(where: { $0.name == trimmed })
            || files.contains(where: { $0.name == trimmed }) {
            pendingReplacement = (trimmed, { performRename(file, to: trimmed, replacing: true) })
            return
        }
        performRename(file, to: trimmed)
    }

    /// `replacing` IS THE ANSWER THE HUMAN GAVE, and it has to reach the
    /// write. Neither `moveItem` nor an SFTP v3 rename can go over
    /// something that is there — both are errors — so without this the
    /// sheet asked "Replace it?", was told yes, described what would
    /// happen to the existing file, and then failed with it still there
    /// ([[WI-2026-08-28-008]]).
    private func performRename(_ file: BrowsedFile, to newName: String,
                               replacing: Bool = false) {
        let from = endpoint(for: file).path
        let to = shown.child(newName)
        let record = TransferService.PaneWrite(
            id: UUID(), verb: .renamed(to: newName), machine: hostLabel,
            path: from, at: Date())
        transfers.record(record)

        if host == nil {
            do {
                // THE DISPOSAL THE SHEET PROMISED: "The existing copy moves
                // to the Trash" is only true if something moves it there.
                for step in PaneWrites.renameSteps(from: from, to: to, replacing: replacing) {
                    switch step {
                    case .trash(let path):
                        try FileManager.default.trashItem(
                            at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    case .move(let source, let target):
                        try FileManager.default.moveItem(atPath: source, toPath: target)
                    }
                }
            } catch {
                fail(record.id, "could not rename \(file.name): \(error.localizedDescription)")
            }
            onInvalidate(shown.path)
            reloadToken += 1
        } else {
            let write: RemoteFS.Write = replacing
                ? .replace(from: from, to: to,
                           destinationIsDirectory: isDirectory(named: newName))
                : .rename(from: from, to: to)
            remoteWrite(write, record: record.id,
                        failing: "could not rename \(file.name)")
        }
    }

    /// What is standing at `name` in the listing — a directory needs a
    /// different disposal packet than a file, and sending the wrong one
    /// fails in a way that reads as a permission problem.
    private func isDirectory(named name: String) -> Bool {
        (visibleFiles.first { $0.name == name } ?? files.first { $0.name == name })?
            .isDirectory ?? false
    }

    private func performCreateFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let target = shown.child(trimmed)
        let record = TransferService.PaneWrite(
            id: UUID(), verb: .createdFolder, machine: hostLabel,
            path: target, at: Date())
        transfers.record(record)

        if host == nil {
            do {
                try FileManager.default.createDirectory(
                    atPath: target, withIntermediateDirectories: false)
            } catch {
                fail(record.id, "could not create \(trimmed): \(error.localizedDescription)")
            }
            onInvalidate(shown.path)
            reloadToken += 1
        } else {
            remoteWrite(.makeDirectory(target), record: record.id,
                        failing: "could not create \(trimmed)")
        }
    }

    /// A FAILED WRITE IS REPORTED AS A FAILURE, and the listing is
    /// RELOADED either way — the pane's contents are a claim about a
    /// machine, and a claim that survives its operation failing is worse
    /// than an error.
    private func remoteWrite(_ write: RemoteFS.Write, record: UUID, failing: String) {
        guard let host else {
            fail(record, "\(failing): no connection to \(hostLabel)")
            return
        }
        // The interactive lane, for the reason a listing uses it: a human
        // pressed something and is waiting ([[RFC-0013]] C-BROKER).
        let connection = tunnelManager.connection(for: host)
        Task.detached(priority: .userInitiated) {
            let result = RemoteFS.perform(write, over: connection)
            await MainActor.run {
                if case .failure(let error) = result {
                    fail(record, "\(failing): \(error.message)")
                }
                onInvalidate(shown.path)
                reloadToken += 1
            }
        }
    }

    private func fail(_ record: UUID, _ why: String) {
        notice = why
        transfers.noteFailure(record, why)
    }

    private func endpoint(for file: BrowsedFile) -> FileEndpoint {
        FileEndpoint(hostID: host?.id,
                     path: shown.child(file.name),
                     isDirectory: file.isDirectory)
    }

    /// Finder's rules, because they are the ones a Mac user already has:
    /// plain click replaces, command toggles, shift extends from the
    /// anchor.
    private func select(_ file: BrowsedFile, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
            anchor = file.id
        } else if modifiers.contains(.shift), let anchor,
                  let start = visibleFiles.firstIndex(where: { $0.id == anchor }),
                  let end = visibleFiles.firstIndex(where: { $0.id == file.id }) {
            let range = start <= end ? start...end : end...start
            selected.formUnion(visibleFiles[range].map(\.id))
        } else {
            selected = [file.id]
            anchor = file.id
        }
    }

    /// Every path change goes through here, so "where are we going" is one
    /// piece of state rather than a mutation scattered across the callers.
    private func navigate(to target: String) {
        guard target != browsing.here.destination else { return }
        // THE KEYBOARD GOES BACK TO THE LIST. A human who navigates by
        // clicking is not typing a path, and a field that keeps first
        // responder keeps a caret blinking in a box they have finished
        // with.
        pathFocused = false
        // SHOW WHAT WE HAVE OF WHERE WE ARE GOING, immediately. The fetch
        // still happens; what this removes is the empty pane in front of
        // a human who is walking back through directories they were in
        // seconds ago ([[WorkspaceManager.FileNavigation]]). The rows and
        // the directory they came from travel together, so a click on one
        // of them still means a child of where it came from.
        browsing.navigate(to: target, cached: navigation.cached[target])
        // A SELECTION BELONGS TO A DIRECTORY. Carrying it across would send
        // files from a place the human has stopped looking at.
        selected = []
        anchor = nil
        // AND SO DOES A FAILED WRITE. "could not rename x" is about a file
        // in a directory the human has left.
        notice = nil
        reloadToken += 1
    }

    private func load() {
        listingFailure = nil
        // A RELOAD IS A JOURNEY TO WHERE WE ALREADY ARE. Written that way,
        // the spinner is a property of being in flight rather than a second
        // flag meaning the same thing — and two flags meaning one thing is
        // the shape of every defect this pane has had.
        if !browsing.here.isLoading {
            browsing.here.depart(for: browsing.here.origin.path, cached: nil)
        }
        let requested = browsing.here.target

        guard let host else {
            let expanded = (requested as NSString).expandingTildeInPath
            let listed = Self.listLocal(expanded)
            if let why = listed.1 {
                browsing.here.fail()
                listingFailure = why
            } else {
                browsing.here.arrive(at: expanded, files: listed.0)
                // TOLD TO THE LEAF ONLY ONCE IT IS SETTLED — where we ARE,
                // not where we were asked to go. A directory that failed to
                // list is not a place to come back to.
                onDirectoryChange(expanded)
                onListing(listed.0, expanded)
            }
            return
        }

        // THE INTERACTIVE LANE, even though a listing's payload can look
        // like bulk: a human clicked a folder and is waiting, so this is
        // latency-bound ([[RFC-0013]] C-BROKER).
        let connection = tunnelManager.connection(for: host)
        Task.detached(priority: .userInitiated) {
            let result = RemoteFS.list(requested, over: connection)
            await MainActor.run {
                // AN ANSWER ABOUT SOMEWHERE ELSE IS NOT AN ANSWER. A newer
                // navigation started while this was in flight, so this
                // reply describes a directory the pane is neither in nor
                // going to — and applying it would move the human back.
                guard requested == browsing.here.target else { return }
                switch result {
                case .success(let listing):
                    // The canonical path comes back from the host, so the
                    // breadcrumb shows where we actually are, and so does
                    // what the leaf remembers — rather than what was asked
                    // for.
                    let entries = listing.entries.map {
                        BrowsedFile(name: $0.name,
                                    size: $0.attributes.size,
                                    modified: $0.attributes.modified,
                                    isDirectory: $0.attributes.isDirectory,
                                    isSymlink: $0.attributes.isSymlink,
                                    // NOTHING ANSWERED FOR THE TARGET. The
                                    // listing asked and the host did not
                                    // say, which is what a link with
                                    // nothing on the end of it looks like.
                                    isBrokenLink: $0.attributes.isSymlink
                                        && $0.attributes.resolvedIsDirectory == nil)
                    }
                    browsing.here.arrive(at: listing.canonicalPath, files: entries)
                    onDirectoryChange(listing.canonicalPath)
                    onListing(entries, listing.canonicalPath)
                case .failure(let error):
                    // A MISTYPED PATH FAILS WHERE IT WAS TYPED and moves
                    // nobody ([[WI-2026-08-19-002]]).
                    browsing.here.fail()
                    listingFailure = error.message
                }
            }
        }
    }

    private static func listLocal(_ path: String) -> ([BrowsedFile], String?) {
        let fm = FileManager.default
        do {
            let names = try fm.contentsOfDirectory(atPath: path)
            let entries: [BrowsedFile] = names.compactMap { name in
                let full = (path as NSString).appendingPathComponent(name)
                // A LINK IS TYPED BY WHAT IT POINTS AT, and `fileExists`
                // follows one — so a symlink to a directory is enterable
                // here, as it now is on a remote host too
                // ([[WI-2026-08-29-002]]).
                var isDir: ObjCBool = false
                let resolves = fm.fileExists(atPath: full, isDirectory: &isDir)
                // A BROKEN LINK IS STILL AN ENTRY. `fileExists` answers for
                // the TARGET, so a link whose target is gone answered no
                // and the row vanished — the one file in the directory a
                // human most needs to see was the one it hid.
                // `attributesOfItem` does NOT follow a link, so this
                // answers for the entry itself — which is what makes it
                // the right question to ask about a broken one.
                let attrs = try? fm.attributesOfItem(atPath: full)
                guard resolves || attrs != nil else { return nil }
                let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
                return BrowsedFile(
                    name: name,
                    size: (attrs?[.size] as? NSNumber)?.int64Value,
                    modified: attrs?[.modificationDate] as? Date,
                    isDirectory: isDir.boolValue,
                    isSymlink: isLink,
                    // `fileExists` answered about the TARGET, and said no.
                    isBrokenLink: isLink && !resolves)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return (entries, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    // MARK: - Dropping into the panel

    /// Finder onto the panel uploads. The same service, entered from the
    /// other side.
    private func acceptFromFinder(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    transfers.enqueue(
                        from: FileEndpoint(hostID: nil, path: url.path),
                        to: FileEndpoint(hostID: host?.id, path: shown.path))
                }
            }
        }
        return accepted
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

private extension View {
    /// `.draggable` with a condition, because a modifier applied to only
    /// some rows must not change the view's identity between them.
    @ViewBuilder
    func ifDraggable(_ enabled: Bool,
                     fetch: @escaping (FileEndpoint, URL, @escaping (Error?) -> Void) -> Void,
                     _ payload: @escaping () -> DraggedFile) -> some View {
        if enabled {
            self.onDrag {
                let dragged = payload()
                // EAGER, NOT PROMISED. `registerDataRepresentation` takes a
                // completion, so the type is ADVERTISED on the pasteboard
                // while the bytes are produced only when something asks for
                // them. `draggingEntered` asks synchronously, gets nil, and
                // refuses the drop — measured, with our own type sitting
                // right there in the board's type list:
                //
                //   drag refused: endpoints=0 preview=set
                //   board=[… Apple files promise …, dev.synapty.file-endpoint, …]
                //
                // The payload is a few dozen bytes that already exist. There
                // was never anything to defer.
                DraggedFile.inFlight = dragged
                let provider = NSItemProvider(
                    item: dragged.encoded as NSData,
                    typeIdentifier: DraggedFile.pasteboardType)
                provider.suggestedName = (dragged.path as NSString).lastPathComponent

                // A FILE PROMISE, so a drop into Finder produces the FILE.
                //
                // A remote file has no local URL to hand over, so the only
                // honest offer is "ask me and I will fetch it". The handler
                // runs when the receiver actually wants it — dropping into
                // Finder, into Mail, anywhere — and not before, which is
                // what keeps a drag that was started and abandoned from
                // costing a transfer.
                let type = UTType(filenameExtension: (dragged.path as NSString).pathExtension)
                    ?? .data
                provider.registerFileRepresentation(
                    forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
                ) { completion in
                    let staged = FileManager.default.temporaryDirectory
                        .appendingPathComponent("synapty-drag-\(UUID().uuidString)")
                        .appendingPathComponent((dragged.path as NSString).lastPathComponent)
                    try? FileManager.default.createDirectory(
                        at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                    fetch(dragged.endpoint, staged) { error in
                        // `false`: the receiver copies it and this temp
                        // stays ours to clean up, rather than being moved
                        // out from under us mid-drag.
                        completion(error == nil ? staged : nil, false, error)
                    }
                    return nil
                }

                // The path as text, so a drop somewhere that wants neither
                // still lands something a person can use.
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all
                ) { completion in
                    completion(Data(dragged.path.utf8), nil)
                    return nil
                }
                return provider
            }
        } else {
            self
        }
    }
}
