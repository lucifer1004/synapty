import XCTest
import AppKit
@testable import Synapty

/// [[WI-2026-08-15-009]]. The drag, from the bytes a row puts on the
/// pasteboard to the transfer that comes out — everything except AppKit's
/// own delivery of the drop, which needs a pointer.
///
/// WHAT THIS DELIBERATELY COVERS is the part most likely to be wrong: the
/// payload has to survive a real NSPasteboard round trip under a private
/// type, and the rule has to be applied against the destination leaf's
/// actual session. What is left unverified is whether AppKit hands the
/// pasteboard to `performDragOperation`, which is the part least likely to
/// be wrong and the only part a test cannot reach.
@MainActor
final class TerminalDropTests: XCTestCase {

    private var tmp: URL!
    private var hostStore: HostStore!
    private var paneManager: WorkspaceManager!
    private var transfers: TransferService!
    private var builder: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        hostStore = HostStore()
        paneManager = WorkspaceManager()
        transfers = TransferService()
        transfers.hostStore = hostStore
        builder = HostEntry(label: "builder", address: "builder.example", username: "someone")
        hostStore.hosts.append(builder)
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    private func coordinator() -> TerminalDropCoordinator {
        TerminalDropCoordinator(paneManager: paneManager, hostStore: hostStore, transfers: transfers)
    }

    /// A session with one leaf, and optionally a reported working directory.
    @discardableResult
    private func leaf(on host: HostEntry?, pwd: String? = nil) -> UUID {
        let connectionID = host.map { paneManager.connections.acquire(host: $0).id }
            ?? paneManager.connections.localID
        let session = WorkspaceManager.Workspace(
            label: host?.label ?? "Local", initialCommand: "/bin/zsh",
            connectionID: connectionID)
        paneManager.workspaces.append(session)
        let id = session.panes[0].id
        if let pwd { paneManager.leafDidUpdatePwd(id, pwd: pwd) }
        return id
    }

    /// A real pasteboard carrying what a dragged row writes.
    private func pasteboard(for endpoint: FileEndpoint) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.synapty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.setData(DraggedFile(endpoint: endpoint).encoded,
                      forType: NSPasteboard.PasteboardType(DraggedFile.pasteboardType))
        return board
    }

    // MARK: - The payload survives the pasteboard

    /// A PATH ALONE IS NOT ENOUGH, and this is why the row carries a private
    /// type rather than a plain string: the drop has to know which MACHINE
    /// the file is on to decide whether the gesture transfers or names it,
    /// and a bare path silently reads as local.
    func testTheDraggedFileKeepsItsMachineAcrossAPasteboard() throws {
        let origin = FileEndpoint(hostID: builder.id, path: "/home/z/out.tar")
        let read = try XCTUnwrap(DraggedFileReader.read(from: pasteboard(for: origin)))
        XCTAssertEqual(read, origin)
    }

    /// Finder puts a file URL on the board and no machine, which is exactly
    /// right: a URL is this Mac by definition. Both sources have to arrive
    /// as the same thing or the rule cannot be applied uniformly.
    func testAFileUrlFromFinderArrivesAsALocalEndpoint() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.synapty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/report.pdf") as NSURL])

        let read = try XCTUnwrap(DraggedFileReader.read(from: board))
        XCTAssertNil(read.hostID, "a file URL is this Mac")
        XCTAssertEqual(read.path, "/tmp/report.pdf")
    }

    /// Something that is not a file at all is declined, not guessed at.
    func testAPasteboardWithNoFileIsDeclined() {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.synapty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.setString("just some text", forType: .string)
        XCTAssertNil(DraggedFileReader.read(from: board))
    }

    // MARK: - What the drop does

    /// ACROSS MACHINES, THE BYTES MOVE — into the directory the destination
    /// shell reported.
    func testDroppingAFileFromAnotherHostQueuesATransferIntoTheReportedDirectory() throws {
        let target = leaf(on: nil, pwd: "/Users/someone/work")
        let dragged = try XCTUnwrap(
            DraggedFileReader.read(from: pasteboard(for: FileEndpoint(hostID: builder.id, path: "/home/z/out.tar"))))

        XCTAssertEqual(coordinator().perform(dragging: dragged, ontoLeaf: target), .transfer)
        XCTAssertEqual(transfers.transfers.count, 1)
        XCTAssertEqual(transfers.transfers.first?.source.hostID, builder.id)
        XCTAssertNil(transfers.transfers.first?.destination.hostID)
        XCTAssertEqual(transfers.transfers.first?.destination.path, "/Users/someone/work")
        XCTAssertEqual(transfers.transfers.first?.initiator, .human)
    }

    /// WITHIN ONE MACHINE, NOTHING MOVES. The file is already where it would
    /// be sent, so the useful act is naming it — and no transfer is queued.
    func testDroppingAFileOntoItsOwnMachineQueuesNothing() throws {
        let target = leaf(on: builder, pwd: "/home/z")
        let dragged = try XCTUnwrap(
            DraggedFileReader.read(from: pasteboard(for: FileEndpoint(hostID: builder.id, path: "/home/z/out.tar"))))

        XCTAssertEqual(coordinator().perform(dragging: dragged, ontoLeaf: target), .pastePath)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    // MARK: - What the human is told before letting go

    /// THE ANSWER IS SHOWN BEFORE THE DROP COMMITS, because one gesture does
    /// two different things and the destination may be a fallback.
    func testThePreviewNamesTheDestinationBeforeTheDropCommits() {
        let target = leaf(on: builder, pwd: "/home/z/incoming")
        let preview = coordinator().preview(
            dragging: FileEndpoint(hostID: nil, path: "/tmp/out.tar"), ontoLeaf: target)

        XCTAssertEqual(preview, "Copy to builder:/home/z/incoming")
    }

    /// AN UNKNOWN WORKING DIRECTORY IS NAMED AS ONE. OSC 7 is the shell's own
    /// configuration and a plain remote login usually does not emit it, so
    /// this is the ordinary case rather than the exceptional one — and a file
    /// landing silently in the wrong directory is worse than a destination
    /// the human can see is approximate.
    func testAnUnknownWorkingDirectoryIsSaidToBeUnknown() {
        let target = leaf(on: builder, pwd: nil)
        let preview = try? XCTUnwrap(
            coordinator().preview(dragging: FileEndpoint(hostID: nil, path: "/tmp/out.tar"),
                                  ontoLeaf: target))
        XCTAssertEqual(preview, "Copy to builder:~  (working directory unknown)")
    }

    /// Within one machine the preview says so too, so the two outcomes are
    /// distinguishable while dragging rather than only afterwards.
    func testThePreviewDistinguishesTheTwoOutcomes() {
        let sameMachine = leaf(on: builder, pwd: "/home/z")
        XCTAssertEqual(
            coordinator().preview(dragging: FileEndpoint(hostID: builder.id, path: "/home/z/a"),
                                  ontoLeaf: sameMachine),
            "Insert path")
    }

    /// A leaf that belongs to no session takes nothing, rather than
    /// defaulting to somewhere.
    func testADropOnALeafWithNoSessionDoesNothing() {
        XCTAssertNil(coordinator().preview(
            dragging: FileEndpoint(hostID: builder.id, path: "/home/z/a"), ontoLeaf: UUID()))
        XCTAssertNil(coordinator().perform(
            dragging: FileEndpoint(hostID: builder.id, path: "/home/z/a"), ontoLeaf: UUID()))
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    // MARK: - A drag can carry more than one thing

    /// EVERY FILE IN THE DRAG ARRIVES. Reading only the first is right for
    /// one file and silently wrong for a selection, which looks like a
    /// transfer that half worked — and half-worked is the hardest kind to
    /// notice.
    func testASelectionSurvivesThePasteboardWhole() throws {
        let three = [
            FileEndpoint(hostID: builder.id, path: "/home/z/a.tar"),
            FileEndpoint(hostID: builder.id, path: "/home/z/b.tar"),
            FileEndpoint(hostID: builder.id, path: "/home/z/logs", isDirectory: true),
        ]
        let board = NSPasteboard(name: NSPasteboard.Name("dev.synapty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.setData(DraggedFile(endpoints: three).encoded,
                      forType: NSPasteboard.PasteboardType(DraggedFile.pasteboardType))

        XCTAssertEqual(DraggedFileReader.readAll(from: board), three)
    }

    /// AND EVERY ONE IS ACTED ON. A drop of three queues three.
    func testDroppingThreeFilesQueuesThree() throws {
        let target = leaf(on: nil, pwd: "/Users/someone/work")
        let three = (0..<3).map {
            FileEndpoint(hostID: builder.id, path: "/home/z/file\($0).tar")
        }
        XCTAssertEqual(coordinator().perform(dragging: three, ontoLeaf: target), .transfer)
        XCTAssertEqual(transfers.transfers.count, 3)
    }

    /// Within one machine, several paths are inserted as ONE line — three
    /// separate insertions would interleave with whatever the shell echoes
    /// back between them.
    func testSeveralPathsOnOneMachineAreInsertedTogether() {
        let target = leaf(on: builder, pwd: "/home/z")
        let two = [
            FileEndpoint(hostID: builder.id, path: "/home/z/a.tar"),
            FileEndpoint(hostID: builder.id, path: "/home/z/b.tar"),
        ]
        XCTAssertEqual(coordinator().perform(dragging: two, ontoLeaf: target), .pastePath)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    /// A DIRECTORY IS DRAGGABLE NOW, and carries the fact — the copy has to
    /// recurse and the size has to be a walk.
    func testADirectoryKeepsBeingADirectoryAcrossThePasteboard() throws {
        let tree = FileEndpoint(hostID: builder.id, path: "/home/z/build", isDirectory: true)
        let board = NSPasteboard(name: NSPasteboard.Name("dev.synapty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.setData(DraggedFile(endpoint: tree).encoded,
                      forType: NSPasteboard.PasteboardType(DraggedFile.pasteboardType))

        let read = try XCTUnwrap(DraggedFileReader.read(from: board))
        XCTAssertTrue(read.isDirectory)
    }

    /// The preview counts, so the human sees how many are about to move.
    func testThePreviewSaysHowMany() {
        let target = leaf(on: nil, pwd: "/tmp")
        let preview = coordinator().preview(
            dragging: FileEndpoint(hostID: builder.id, path: "/home/z/a.tar"),
            ontoLeaf: target, count: 3)
        XCTAssertTrue(preview?.contains("3 items") ?? false, preview ?? "nil")
    }
}
