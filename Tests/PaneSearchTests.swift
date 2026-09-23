import XCTest
@testable import Synapty

/// [[PaneSearch]] — the ranking behind "go to pane" in the ⌘K palette
/// ([[WI-2026-09-02-007]]).
final class PaneSearchTests: XCTestCase {

    private func c(_ label: String, title: String = "", host: String = "",
                   agent: String = "", workspace: String = "") -> PaneSearch.Candidate {
        .init(id: UUID(), label: label, title: title, host: host, agent: agent, workspace: workspace)
    }

    /// The empty palette lists hosts; panes only answer a typed query.
    func testAnEmptyQueryMatchesNoPane() {
        XCTAssertNil(PaneSearch.score("", against: c("build")))
        XCTAssertNil(PaneSearch.score("   ", against: c("build")))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(PaneSearch.score("BUILD", against: c("the build one")))
    }

    /// THE LABEL WINS: prefix over contains over the other fields.
    func testALabelPrefixOutranksAContainsOutranksTheOtherFields() {
        let prefix = c("deploy api")
        let contains = c("the deploy one")
        let byHost = c("zsh", host: "deploy-box")
        let byTitle = c("zsh", title: "vim deploy.yml")
        let byAgent = c("zsh", agent: "claude-deploy")
        let ranked = PaneSearch.rank("deploy", in: [byAgent, byTitle, byHost, contains, prefix])
        XCTAssertEqual(ranked.map(\.label).prefix(2), ["deploy api", "the deploy one"])
        XCTAssertEqual(Set(ranked.dropFirst(2).map(\.id)), Set([byAgent.id, byTitle.id, byHost.id]))
    }

    /// Ties keep the caller's order — the workspaces' own — so the list is
    /// stable while the human types.
    func testTiesKeepTheGivenOrder() {
        let a = c("api one"), b = c("api two"), d = c("api three")
        XCTAssertEqual(PaneSearch.rank("api", in: [a, b, d]).map(\.id), [a.id, b.id, d.id])
    }

    func testAPaneMatchingNowhereIsLeftOut() {
        let ranked = PaneSearch.rank("cargo", in: [c("zsh", host: "deskmac", workspace: "Local")])
        XCTAssertTrue(ranked.isEmpty)
    }

    /// The workspace's name is searchable too — "the one in Remotehost".
    func testTheWorkspaceNameCounts() {
        XCTAssertEqual(PaneSearch.score("remote", against: c("zsh", workspace: "remotehost")), 1)
    }
}
