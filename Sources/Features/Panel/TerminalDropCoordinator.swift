import Foundation
import AppKit

/// What a file dropped on a terminal would do, and doing it.
///
/// THE RULE IS DECIDED BY MACHINE IDENTITY ALONE ([[RFC-0013]]
/// C-ADDRESSING): a file already on the destination host does not need to
/// be sent there, so the useful act is naming it; a file from anywhere else
/// has to move. Both are the same gesture, which is why the answer must be
/// shown BEFORE the drop rather than discovered after it.
///
/// [[WI-2026-08-15-009]]
@MainActor
struct TerminalDropCoordinator {

    let paneManager: WorkspaceManager
    let hostStore: HostStore
    let transfers: TransferService

    struct Destination {
        var endpoint: FileEndpoint
        /// False when the shell never reported a working directory, which
        /// is ordinary rather than exceptional: OSC 7 is emitted by the
        /// shell's own configuration, and a plain remote login usually does
        /// not. The fallback is the home directory and it MUST be named,
        /// because a file silently landing somewhere else is worse than a
        /// destination the human can see is approximate.
        var isPreciseDirectory: Bool
    }

    /// Where a drop on this leaf would land.
    ///
    /// ASKED OF THE LEAF ([[RFC-0015]] C-LEAF-BINDING). This found the
    /// session containing the leaf and took ITS host, which was right
    /// only while a container could hold one machine — and this is the
    /// call whose wrong answer puts a file on the wrong computer.
    func destination(forLeaf leafID: UUID) -> Destination? {
        guard paneManager.connectionID(ofLeaf: leafID) != nil else { return nil }
        let host = paneManager.host(ofLeaf: leafID)
        // THE SHELL'S DIRECTORY, DELIBERATELY ([[WI-2026-08-18-004]]).
        // `pwd` layers the shell's own word over a kernel read, and both
        // halves now answer for the SHELL rather than for whatever it is
        // running — the earlier reading, that a drop belongs wherever the
        // foreground process went, is right for an editor that `:cd`ed and
        // wrong for every build script that ever changed directory. A file
        // is written; the surprising case is the one that must not happen.
        if let pwd = paneManager.pwd(ofLeaf: leafID), !pwd.isEmpty {
            return Destination(
                endpoint: FileEndpoint(hostID: host?.id, path: pwd),
                isPreciseDirectory: true)
        }
        return Destination(
            endpoint: FileEndpoint(hostID: host?.id,
                                   path: host == nil
                                       ? FileManager.default.homeDirectoryForCurrentUser.path
                                       : "~"),
            isPreciseDirectory: false)
    }

    /// One line of drag feedback, or nil when nothing would happen.
    func preview(dragging source: FileEndpoint, ontoLeaf leafID: UUID,
                 count: Int = 1) -> String? {
        guard let destination = destination(forLeaf: leafID) else { return nil }
        // THE HUMAN JUST NAMED THE PANE THEY MEAN, which is the only moment
        // worth spending a round trip on. Asking every remote pane on a
        // timer would keep an answer current that nobody is reading; asking
        // here costs one query, caches it, and updates the hint in place
        // when it lands ([[RemotePwd]]).
        if !destination.isPreciseDirectory { paneManager.refreshRemotePwd(ofLeaf: leafID) }
        let subject = count > 1 ? " (\(count) items)" : ""
        switch DropRule.outcome(dragging: source, onto: destination.endpoint) {
        case .pastePath:
            return count > 1 ? "Insert \(count) paths" : "Insert path"
        case .transfer:
            let where_ = "\(hostLabel(destination.endpoint.hostID)):\(destination.endpoint.path)"
            return "Copy to \(where_)\(subject)\(note(destination, leafID))"
        }
    }

    /// WAITING IS NOT THE SAME AS NOT KNOWING, and saying so mattered:
    /// every remote pane opened by announcing "working directory unknown"
    /// for as long as the round trip took, which reads as a limitation
    /// rather than as a moment. The path shown is the one a drop would use
    /// RIGHT NOW, so the note qualifies it without contradicting it.
    private func note(_ destination: Destination, _ leafID: UUID) -> String {
        if destination.isPreciseDirectory { return "" }
        return paneManager.isAskingPwd(ofLeaf: leafID)
            ? "  (checking\u{2026})"
            : "  (working directory unknown)"
    }

    /// Do it. Returns what happened, or nil when the leaf has no session.
    @discardableResult
    func perform(dragging source: FileEndpoint, ontoLeaf leafID: UUID) -> DropOutcome? {
        perform(dragging: [source], ontoLeaf: leafID)
    }

    /// A DROP IS A SET, and every member takes the same route. The rule is
    /// evaluated per source because a selection can in principle span
    /// machines — and answering it once for the first one would be right
    /// for that file and silently wrong for the rest.
    @discardableResult
    func perform(dragging sources: [FileEndpoint], ontoLeaf leafID: UUID) -> DropOutcome? {
        guard let destination = destination(forLeaf: leafID), !sources.isEmpty else { return nil }
        var pasted: [String] = []
        for source in sources {
            switch DropRule.outcome(dragging: source, onto: destination.endpoint) {
            case .pastePath:
                // Quoted, because the human's file name reaches a shell that
                // is about to word-split it.
                pasted.append(Shell.quote(source.path))
            case .transfer:
                transfers.enqueue(from: source, to: destination.endpoint)
            }
        }
        if !pasted.isEmpty {
            typeIntoLeaf(leafID, text: pasted.joined(separator: " ") + " ")
        }
        // The outcome reported is the FIRST source's, which is what the
        // preview showed while dragging.
        return DropRule.outcome(dragging: sources[0], onto: destination.endpoint)
    }

    private func typeIntoLeaf(_ leafID: UUID, text: String) {
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { return }
        WakeInjector.type(text, into: surface)
    }

    private func hostLabel(_ hostID: UUID?) -> String {
        guard let hostID, let host = hostStore.hosts.first(where: { $0.id == hostID })
        else { return "this Mac" }
        return host.label.isEmpty ? host.address : host.label
    }
}

/// Reads a dragged file off a pasteboard.
///
/// TWO SOURCES, ONE ANSWER. A row in the panel carries its machine with it;
/// Finder carries a file URL, which is this Mac by definition. Both have to
/// arrive as the same thing or the drop rule cannot be applied uniformly.
enum DraggedFileReader {
    static func read(from pasteboard: NSPasteboard) -> FileEndpoint? {
        readAll(from: pasteboard).first
    }

    /// EVERYTHING IN THE DRAG. A reader that took only the first would be
    /// right for one file and silently wrong for a selection — which looks
    /// like a transfer that half worked.
    static func readAll(from pasteboard: NSPasteboard) -> [FileEndpoint] {
        let ours = NSPasteboard.PasteboardType(DraggedFile.pasteboardType)
        if let data = pasteboard.data(forType: ours), let dragged = DraggedFile.from(data) {
            return dragged.endpoints
        }
        // OUR OWN DRAG, FROM OUR OWN PROCESS. The board advertises the
        // type while the bytes stay behind a promise the receiver would
        // have to resolve asynchronously — which a drag-entered handler
        // cannot do. Gated on the board actually advertising our type, so
        // this can never attach a stale payload to somebody else's drag.
        if pasteboard.types?.contains(ours) == true,
           let dragged = MainActor.assumeIsolated({ DraggedFile.inFlight }) {
            return dragged.endpoints
        }
        // The board-level read misses a payload that lives on an ITEM,
        // which is where a provider-backed drag puts it. Cheap, and the
        // alternative is a drop refused for a payload that is present.
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: ours), let dragged = DraggedFile.from(data) {
                return dragged.endpoints
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls.filter(\.isFileURL).map {
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                return FileEndpoint(hostID: nil, path: $0.path, isDirectory: isDir.boolValue)
            }
        }
        return []
    }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(DraggedFile.pasteboardType), .fileURL]
    }
}
