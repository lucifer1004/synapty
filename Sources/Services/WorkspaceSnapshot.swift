import Foundation

// MARK: - Resume plan per [[RFC-0006:C-RESUME-PLAN]]

/// The recorded answer to "how do I bring THIS pane's agent back",
/// captured while the agent is alive. `incantation` nil = launch-fresh
/// (missing/invalid resume_ref or no template) — the UI must present
/// that honestly, never as continuity.
struct ResumePlan: Codable, Equatable {
    var tool: String
    var cwd: String?
    /// Host label; nil = local pane.
    var host: String?
    /// Validated resume_ref (allowlist, C-RESUME-PLAN). Stored only
    /// when valid.
    var resumeRef: String?
    /// Composed single-line resume incantation, or nil = launch-fresh —
    /// which means nothing is typed and the human starts the tool
    /// themselves, the way they start it anywhere else.
    var incantation: String?
}

/// C-RESUME-PLAN allowlist validation — agent-influenced bytes destined
/// for a typed-input channel are VALIDATED, never escaped: printable
/// ASCII, no whitespace, no control characters, bounded length.
enum ResumeRefValidator {
    static let maxLength = 128

    static func validate(_ ref: String) -> String? {
        guard !ref.isEmpty, ref.count <= maxLength else { return nil }
        for scalar in ref.unicodeScalars {
            guard scalar.value > 0x20, scalar.value < 0x7F else { return nil }
        }
        return ref
    }
}

// MARK: - Session snapshot (RFC-0006: layout + cwd + plans + armed bits)

struct WorkspaceSnapshot: Equatable {
    /// The shape this build writes and the only one it will read.
    ///
    /// ONE, AND IT STAYS ONE UNTIL SOMETHING IS RELEASED. A version number
    /// records a history of shapes that readers in the world might still
    /// hold; nothing in the world holds any of these
    /// ([[RFC-0015]] C-UNRELEASED), so counting them was recording a
    /// history nobody has. What the number is FOR here is the check below:
    /// a store written by any other shape is discarded rather than
    /// converted ([[RFC-0015]] C-PERSIST), and that works at any value.
    static let currentVersion = 1

    var version: Int = WorkspaceSnapshot.currentVersion
    var workspaces: [SessionEntry] = []

    struct SessionEntry: Codable, Equatable {
        /// THE IDENTITY, not a fresh one on every restore. This is what
        /// the workbench hands agents as `workspace_id` ([[RFC-0015]]
        /// C-WORKSPACE, C-IDENTIFY): an agent that wrote one into a task
        /// or a message recorded a value that resolved to nothing after
        /// the next relaunch, and nothing errored — the reference simply
        /// found no workspace.
        ///
        /// Optional to READ, because a snapshot written before this
        /// carries none and a workspace without a recorded identity is
        /// better restored under a new one than dropped.
        ///
        /// MACHINE-SCOPED, AND CLAIMING NOTHING MORE. It rides the
        /// machine-scoped snapshot beside the layout, and it is not
        /// portable: a workspace that exists on two of a human's machines
        /// has not been designed, and an identifier that travelled would
        /// be inventing that design by accident.
        var id: UUID?
        var label: String
        /// THE WORKSPACE'S ONE TREE ([[RFC-0015]] C-LAYOUT). This was a
        /// list of tabs each holding a tree of its own; there is one
        /// species now, and a tab is what a position with more than one
        /// pane shows.
        ///
        /// nil is an EMPTY workspace, which is a resting state and
        /// persists like any other ([[RFC-0015]] C-EMPTY) — a slot may
        /// not be empty, so there is no tree to write for one.
        var root: Node?
        /// Which POSITION the human was working in.
        var focusedSlotIndex: Int?
        /// The position shown alone, if the human left the workspace
        /// zoomed ([[WI-2026-09-02-006]]). Indexed like the focused one.
        var zoomedSlotIndex: Int?

        /// PUT AWAY, AND STILL HERE ([[RFC-0015]] C-ARCHIVE). An archived
        /// workspace persists its full arrangement — `root` above carries
        /// it, exactly as an open one's does — and comes back archived
        /// rather than dialling every host it names on the next launch.
        /// A workspace whose put-away state did not survive a restart
        /// would spend, on the next launch, precisely what putting it away
        /// was meant to reclaim.
        var isArchived: Bool = false
        /// Ordering and prominence only.
        var isPinned: Bool = false

        /// PANES CLOSED OUT OF THIS WORKSPACE WHOSE WORK IS STILL RUNNING
        /// ([[RFC-0015]] C-PANE-ARCHIVE). They are NOT in `root` — the tree
        /// holds what is on screen — which is why C-PERSIST names them
        /// separately: an enumeration that stops at the tree writes a
        /// store from which every one of them is missing, and what is
        /// missing is a live session nothing then names.
        var archivedPanes: [PaneEntry] = []

        /// A FLAG THAT IS NOT IN THE FILE HAS NEVER BEEN SET.
        ///
        /// Swift's synthesised decoder does NOT fall back to a property's
        /// default when its key is absent — it THROWS, and one thrown key
        /// discards the whole snapshot. Adding `isArchived` and `isPinned`
        /// therefore made every session.json already on disk unreadable:
        /// the next launch would have found no workspaces and written a
        /// fresh empty one over the human's arrangement. Caught by seeding
        /// a file by hand and watching the app come up with one pane it
        /// had invented ([[RFC-0015]] C-PERSIST).
        ///
        /// This is not conversion code and nothing here reads an older
        /// shape ([[RFC-0015]] C-UNRELEASED): it says what absence MEANS,
        /// which for a flag is `false`. The next defaulted field added to
        /// this struct needs the same line, and the test below is what
        /// says so.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            root = try c.decodeIfPresent(Node.self, forKey: .root)
            focusedSlotIndex = try c.decodeIfPresent(Int.self, forKey: .focusedSlotIndex)
            zoomedSlotIndex = try c.decodeIfPresent(Int.self, forKey: .zoomedSlotIndex)
            isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
            isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            archivedPanes = try c.decodeIfPresent([PaneEntry].self, forKey: .archivedPanes) ?? []
        }

        init(id: UUID? = nil, label: String, root: Node? = nil,
             focusedSlotIndex: Int? = nil,
             isArchived: Bool = false, isPinned: Bool = false,
             archivedPanes: [PaneEntry] = []) {
            self.archivedPanes = archivedPanes
            self.id = id
            self.label = label
            self.root = root
            self.focusedSlotIndex = focusedSlotIndex
            self.isArchived = isArchived
            self.isPinned = isPinned
        }
    }

    /// A position and the stack of panes occupying it.
    struct SlotEntry: Codable, Equatable {
        var panes: [PaneEntry] = []
        /// Which of the stack was in front — the direct heir of the
        /// active-tab index, now asked per position.
        var activeIndex: Int = 0
    }

    struct PaneEntry: Codable, Equatable {
        /// The pane's own name. It used to belong to the tab containing
        /// it, which is not a thing any more.
        var label: String = "Shell"
        var userRenamed: Bool = false
        /// Last OSC 7-reported cwd.
        var pwd: String?
        /// RFC-0005 C-AUTHORITY: the armed bit is the human's standing
        /// choice for the pane — it rides the snapshot.
        var wakeArmed: Bool = false
        var resumePlan: ResumePlan?
        /// WHICH MACHINE THIS PANE WAS ON. The durable fact is the host,
        /// not the runtime connection — a connection does not survive a
        /// restart and a restore re-acquires one from this
        /// ([[RFC-0015]] C-PERSIST). nil = this machine.
        var hostID: UUID?
        /// THE NAME THIS PANE'S REMOTE WORK ANSWERS TO.
        ///
        /// A holder on the far side outlives the client, and `connect`
        /// reattaches to the one named for this id. Nothing carried it
        /// across a restart once, so every launch minted a fresh id and
        /// started a new session beside the surviving one — durability
        /// nothing could address. Found live on remotehost: 35 of them,
        /// the oldest four days old.
        ///
        /// PER PANE, because every pane runs its own child under its own
        /// id. It was persisted per SESSION, which reattached the first
        /// pane and orphaned the rest. nil for local panes, whose
        /// processes do not survive and which mint a fresh id.
        var agentID: String?
        /// WHAT THIS PANE WAS SHOWING ([[RFC-0015]] C-CONTENT).
        var content: SplitNode.PaneContent = .terminal(command: nil)
    }

    indirect enum Node: Equatable {
        case slot(SlotEntry)
        case split(direction: String, ratio: Double, first: Node, second: Node)

        /// Every position of this subtree, in order.
        var slotEntries: [SlotEntry] {
            switch self {
            case .slot(let entry): return [entry]
            case .split(_, _, let first, let second):
                return first.slotEntries + second.slotEntries
            }
        }

        /// Every pane of this subtree, in order — across all positions
        /// and all their stacks.
        var paneEntries: [PaneEntry] { slotEntries.flatMap(\.panes) }
    }
}

// Manual Codable for the tree: an indirect enum with associated values
// has no synthesis. Nothing here is a compatibility path.
extension WorkspaceSnapshot.Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, slot, direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "slot":
            self = .slot(try c.decode(WorkspaceSnapshot.SlotEntry.self, forKey: .slot))
        case "split":
            self = .split(
                direction: try c.decode(String.self, forKey: .direction),
                ratio: try c.decode(Double.self, forKey: .ratio),
                first: try c.decode(WorkspaceSnapshot.Node.self, forKey: .first),
                second: try c.decode(WorkspaceSnapshot.Node.self, forKey: .second))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown node kind"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .slot(let entry):
            try c.encode("slot", forKey: .kind)
            try c.encode(entry, forKey: .slot)
        case .split(let direction, let ratio, let first, let second):
            try c.encode("split", forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

// MARK: - Reading a store

/// NO CONVERSION PATH, DELIBERATELY. Synapty is unreleased and the only
/// arrangements on disk are the ones this development wrote — so a
/// version bump discards the store and the app opens fresh, which costs
/// nothing anybody wanted and saves carrying a converter, its tests and
/// its clause for every shape change still to come.
///
/// `version` is kept and written so the first shipped release has
/// something to migrate FROM. The moment real arrangements exist, this is
/// where the conversion goes.
extension WorkspaceSnapshot: Codable {}

// MARK: - Store

/// Snapshot persistence at ~/.config/synapty/machine/session.json.
///
/// THE FILE KEEPS ITS OLD NAME on purpose: renaming it would be a second
/// migration for a store the format version already converts, and a
/// launch that could not find its predecessor would silently lose the
/// human's arrangement. Same
/// location discipline as settings. Malformed/missing = no restore
/// (fresh start), never a crash.
enum WorkspaceStore {
    /// Test seam: redirect storage so tests never touch the real
    /// ~/.config, which holds the operator's own state.
    nonisolated(unsafe) static var storageOverride: URL?

    static var fileURL: URL {
        if let storageOverride { return storageOverride }
        // MACHINE-scoped (ConfigPaths): a window layout references THIS
        // machine's panes, agents and hosts. Replicating it produces
        // confident nonsense on another Mac.
        let dir = ConfigPaths.machine
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func save(_ snapshot: WorkspaceSnapshot) {
        // Same guard HostStore.save carries, and here for the same reason
        // rather than by analogy: this class had ONE test that installed an
        // override and reset it to nil afterwards, so every other test in
        // that file ran against the real machine-scoped session.json. None
        // of them happened to write. That is discipline holding, not a
        // mechanism, and discipline is what failed the two times this repo
        // clobbered real state.
        // A TEST HOST IS NOT A TEST WRITING. `fileURL` already resolves
        // through ConfigPaths, which redirects to TestHost.configRoot for
        // the whole process — so the hosted app's own autosave is isolated
        // whether or not any test remembered a seam, which is exactly what
        // TestHost was built for.
        //
        // Without that distinction this assert killed the hosted app
        // mid-suite: ContentView schedules a snapshot save, the save fires
        // during a test run, and the entire run failed with "the test
        // runner crashed" — intermittently, because it depended on when
        // the debounce landed. Two hours went into blaming DerivedData.
        assert(
            storageOverride != nil || TestHost.isActive
                || NSClassFromString("XCTestCase") == nil,
            "WorkspaceStore.storageOverride must be set in tests"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // `error` by the AppLog policy: nothing retries, nobody is
            // told, and the consequence lands a relaunch later as "my
            // windows came back wrong" with no trace of a cause.
            AppLog.sessionStore.error(
                "session layout not saved: \(error.localizedDescription, privacy: .public) — the window layout will not survive a relaunch")
        }
    }

    /// A store this version does not recognise is DISCARDED, and the app
    /// opens fresh. There is nothing on disk but development's own
    /// arrangements, so converting one would be work for a loss nobody
    /// would feel.
    static func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              snapshot.version == WorkspaceSnapshot.currentVersion
        else { return nil }
        return snapshot
    }
}

// MARK: - Persisting what a pane is showing ([[RFC-0015]] C-CONTENT)

/// THE COMMAND IS NOT PERSISTED WITH THE KIND. A restored terminal gets a
/// FRESH run-wrapper command and agent id — the stored one names a
/// wrapper invocation from a previous launch, and RFC-0006 makes
/// registration the agent's own act rather than something a restore
/// replays. Only which KIND of pane it was is durable.
extension SplitNode.PaneContent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, directory, address }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        // THE DIRECTORY IS DURABLE AND THE COMMAND IS NOT, which looks
        // inconsistent until you ask what each one NAMES. A command names
        // a wrapper invocation from a previous launch and is meaningless
        // in this one; a directory names a place on a machine, and a file
        // leaf that came back somewhere else has not been restored
        // ([[RFC-0015]] C-PERSIST, C-CONTENT).
        case "files": self = .files(directory: try c.decodeIfPresent(String.self, forKey: .directory))
        case "services": self = .services
        // THE ADDRESS AND NOTHING ELSE ([[RFC-0015]] C-PERSIST). Restoring
        // an address is restoring where the human was; restoring a session
        // would be re-entering it on their behalf — so no history, no
        // cookies, nothing a site left behind.
        case "browser": self = .browser(address: try c.decodeIfPresent(String.self, forKey: .address))
        default: self = .terminal(command: nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal: try c.encode("terminal", forKey: .kind)
        case .files(let directory):
            try c.encode("files", forKey: .kind)
            try c.encodeIfPresent(directory, forKey: .directory)
        case .services: try c.encode("services", forKey: .kind)
        case .browser(let address):
            try c.encode("browser", forKey: .kind)
            try c.encodeIfPresent(address, forKey: .address)
        }
    }
}
