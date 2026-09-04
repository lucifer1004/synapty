import XCTest
@testable import Synapty

/// The four defects that reached the human, as assertions
/// ([[FileBrowsing]]).
///
/// Each was two pieces of view state disagreeing, and none of them was
/// reachable from a test while the disagreement lived in five `@State`
/// strings. Three of the four are unrepresentable now; these say so, and
/// say it about a value rather than about a window.
final class FileBrowsingTests: XCTestCase {

    private let rows = [BrowsedFile(name: "notes.md", size: 12, modified: nil, isDirectory: false),
                        BrowsedFile(name: "src", size: nil, modified: nil, isDirectory: true)]

    // MARK: - A row means a child of the directory the row came from

    /// THE REGRESSION. Walking back put the destination's cached rows on
    /// screen while the pane still named the origin, so clicking one asked
    /// for `<origin>/<name from destination>` — a path that does not exist.
    func testARowShownFromTheCacheResolvesAgainstTheDirectoryItCameFrom() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me/projects", files: []))

        browsing.navigate(to: "/home/me", cached: rows)

        XCTAssertEqual(browsing.here.showing.path, "/home/me",
                       "the rows came from the destination, so that is where they belong")
        XCTAssertEqual(browsing.here.showing.child("src"), "/home/me/src")
        XCTAssertNotEqual(browsing.here.showing.child("src"), "/home/me/projects/src",
                          "a row was resolved against a directory it did not come from")
    }

    /// The other half: with nothing cached, the pane goes on showing where
    /// it IS, and those rows still belong there.
    func testWithoutACacheTheRowsOnScreenStillBelongToTheOrigin() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me/projects", files: rows))

        browsing.navigate(to: "/home/me", cached: nil)

        XCTAssertEqual(browsing.here.showing.path, "/home/me/projects")
        XCTAssertEqual(browsing.here.showing.child("src"), "/home/me/projects/src")
    }

    /// A second click on a row still on screen means the same place as the
    /// first, at any speed — the older form of the same defect, which once
    /// asked for `~/projects/projects`.
    func testClickingOneRowTwiceMeansTheSamePlaceBothTimes() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "~", files: rows))

        let first = browsing.here.showing.child("src")
        browsing.navigate(to: first, cached: nil)
        let second = browsing.here.showing.child("src")

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, "~/src")
    }

    // MARK: - A draft ends at departure

    /// Ended on ARRIVAL, the draft outlived the whole round trip: the
    /// address bar went on showing an abandoned string for as long as the
    /// host took to answer.
    func testAnUnsubmittedPathIsGoneTheMomentThePaneLeaves() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me", files: rows))
        browsing.draft = "/etc/ap"

        browsing.navigate(to: "/home/me/src", cached: nil)

        XCTAssertNil(browsing.draft)
        XCTAssertEqual(browsing.address, "/home/me/src",
                       "the address bar named the destination, not the abandoned draft")
    }

    /// And it is gone at departure, not at arrival — the two-second gap.
    func testTheAddressBarNamesTheDestinationBeforeTheAnswerArrives() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me", files: rows))

        browsing.navigate(to: "/var/log", cached: nil)
        XCTAssertEqual(browsing.address, "/var/log")
        XCTAssertTrue(browsing.here.isLoading)

        browsing.here.arrive(at: "/var/log", files: rows)
        XCTAssertEqual(browsing.address, "/var/log")
        XCTAssertFalse(browsing.here.isLoading)
    }

    /// While the human is typing, the field is theirs.
    func testADraftOutranksWhereThePaneIs() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me", files: rows))
        browsing.draft = "/et"
        XCTAssertEqual(browsing.address, "/et")
    }

    // MARK: - A directory that cannot be read moves nobody

    func testAFailedListingLeavesThePaneWhereItWasWithNothingClickable() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me", files: rows))

        browsing.navigate(to: "/home/me/typo", cached: rows)
        XCTAssertEqual(browsing.here.showing.path, "/home/me/typo",
                       "the cache put the destination's rows up")

        browsing.here.fail()

        XCTAssertEqual(browsing.here.showing.path, "/home/me",
                       "a listing that failed relocated the human")
        XCTAssertTrue(browsing.here.showing.files.isEmpty,
                      "rows survived whose parent was never reached — and they are clickable")
        XCTAssertFalse(browsing.here.isLoading)
    }

    /// The canonical path is the host's answer, not what was asked for, and
    /// the rows belong to THAT.
    func testArrivalTakesTheHostsAnswerForWhereItLanded() {
        var browsing = FileBrowsing()
        browsing.navigate(to: "~/src", cached: nil)
        browsing.here.arrive(at: "/home/me/src", files: rows)

        XCTAssertEqual(browsing.here.showing.path, "/home/me/src")
        XCTAssertEqual(browsing.here.showing.child("notes.md"), "/home/me/src/notes.md")
    }

    /// WHAT A LOAD ASKS FOR: where we are going if we are going anywhere,
    /// and where we are otherwise. A reply about anywhere else is stale —
    /// this is the value that decides it.
    func testTheTargetIsTheDestinationWhileInFlightAndTheOriginOtherwise() {
        var browsing = FileBrowsing()
        browsing.here = .at(Listing(path: "/home/me", files: rows))
        XCTAssertEqual(browsing.here.target, "/home/me")

        browsing.navigate(to: "/var", cached: nil)
        XCTAssertEqual(browsing.here.target, "/var")

        // A second navigation while the first is in flight: the first
        // answer is now about somewhere the pane is neither in nor going
        // to.
        browsing.navigate(to: "/etc", cached: nil)
        XCTAssertEqual(browsing.here.target, "/etc")
        XCTAssertEqual(browsing.here.origin.path, "/home/me",
                       "the pane has still not arrived anywhere")
    }
}
