import XCTest
@testable import Synapty

final class SplitTreeTests: XCTestCase {

    // MARK: - Leaf basics

    func testLeafHasUniqueID() {
        let a = SplitNode.LeafData()
        let b = SplitNode.LeafData()
        XCTAssertNotEqual(a.id, b.id)
    }

    func testLeafCommandStoredCorrectly() {
        let leaf = SplitNode.LeafData(command: "ssh user@host")
        XCTAssertEqual(leaf.command, "ssh user@host")
    }

    func testLeafCommandDefaultsToNil() {
        let leaf = SplitNode.LeafData()
        XCTAssertNil(leaf.command)
    }

    // MARK: - Single leaf tree

    func testSingleLeafIDMatchesLeafData() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.id, leaf.id)
    }

    func testSingleLeafHasOneLeafID() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.leafIDs, [leaf.id])
    }

    func testSingleLeafLeavesReturnsOne() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.leaves.count, 1)
        XCTAssertEqual(node.leaves.first?.id, leaf.id)
    }

    func testFindLeafOnSingleLeaf() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertNotNil(node.findLeaf(leaf.id))
        XCTAssertNil(node.findLeaf(UUID()))
    }

    // MARK: - Splitting

    func testSplitLeafProducesTwo() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        let (newRoot, newID) = node.splitLeaf(leaf.id, direction: .horizontal, newLeafCommand: nil)
        XCTAssertNotNil(newID)
        XCTAssertEqual(newRoot.leaves.count, 2)
    }

    func testSplitLeafOriginalIsFirstChild() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        let (newRoot, _) = node.splitLeaf(leaf.id, direction: .horizontal, newLeafCommand: nil)
        XCTAssertEqual(newRoot.leaves.first?.id, leaf.id)
    }

    func testSplitLeafNewIDIsSecondChild() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        let (newRoot, newID) = node.splitLeaf(leaf.id, direction: .horizontal, newLeafCommand: nil)
        XCTAssertEqual(newRoot.leaves.last?.id, newID)
    }

    func testSplitLeafPreservesCommand() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        let (newRoot, newID) = node.splitLeaf(leaf.id, direction: .vertical, newLeafCommand: "bash")
        let newLeaf = newRoot.findLeaf(newID!)
        XCTAssertEqual(newLeaf?.command, "bash")
    }

    func testSplitNonexistentLeafReturnsNil() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        let (_, newID) = node.splitLeaf(UUID(), direction: .horizontal, newLeafCommand: nil)
        XCTAssertNil(newID)
    }

    func testDoubleSplitProducesThreeLeaves() {
        let leaf = SplitNode.LeafData()
        var node = SplitNode.leaf(leaf)
        let (root1, id1) = node.splitLeaf(leaf.id, direction: .horizontal, newLeafCommand: nil)
        node = root1
        let (root2, _) = node.splitLeaf(id1!, direction: .vertical, newLeafCommand: nil)
        XCTAssertEqual(root2.leaves.count, 3)
    }

    // MARK: - Removing

    func testRemoveOnlyLeafReturnsNotFound() {
        // Single-leaf removal is the caller's job (close the pane) —
        // removeLeaf reports not-found for leaf nodes (WI-2026-08-08-033).
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.removeLeaf(leaf.id), .notFound)
    }

    func testRemoveFirstChildReturnsSibling() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        guard case .removed(let result) = node.removeLeaf(leafA.id) else {
            return XCTFail("expected removal")
        }
        XCTAssertEqual(result.leaves.count, 1)
        XCTAssertEqual(result.leaves.first?.id, leafB.id)
    }

    func testRemoveSecondChildReturnsSibling() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        guard case .removed(let result) = node.removeLeaf(leafB.id) else {
            return XCTFail("expected removal")
        }
        XCTAssertEqual(result.leaves.first?.id, leafA.id)
    }

    func testRemoveNonexistentLeafReturnsNotFound() {
        // The old API returned a structurally identical copy for a missing
        // leaf, so callers treated "not found" as "removed" and moved
        // focus anyway — the contract now distinguishes them
        // (WI-2026-08-08-033).
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.removeLeaf(UUID()), .notFound)
    }

    func testRemoveFromThreeLeavesCollapsesCorrectly() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let leafC = SplitNode.LeafData()
        // Structure: split(split(A, B), C)
        let inner = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .vertical,
            first: inner,
            second: .leaf(leafC)
        ))
        guard case .removed(let result) = root.removeLeaf(leafA.id) else {
            return XCTFail("expected removal")
        }
        XCTAssertEqual(result.leaves.count, 2)
        // B and C should remain
        let ids = result.leafIDs
        XCTAssertTrue(ids.contains(leafB.id))
        XCTAssertTrue(ids.contains(leafC.id))
    }

    // MARK: - Navigation

    func testNextLeafCycles() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        XCTAssertEqual(node.nextLeaf(after: leafA.id), leafB.id)
        XCTAssertEqual(node.nextLeaf(after: leafB.id), leafA.id) // wraps
    }

    func testPreviousLeafCycles() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        XCTAssertEqual(node.previousLeaf(before: leafB.id), leafA.id)
        XCTAssertEqual(node.previousLeaf(before: leafA.id), leafB.id) // wraps
    }

    func testNextLeafOnSingleLeafReturnsSelf() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertEqual(node.nextLeaf(after: leaf.id), leaf.id)
    }

    func testNextLeafWithUnknownIDReturnsNil() {
        let leaf = SplitNode.LeafData()
        let node = SplitNode.leaf(leaf)
        XCTAssertNil(node.nextLeaf(after: UUID()))
    }

    func testThreeLeafNavigation() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let leafC = SplitNode.LeafData()
        let inner = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB)
        ))
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .vertical,
            first: inner,
            second: .leaf(leafC)
        ))
        XCTAssertEqual(root.nextLeaf(after: leafA.id), leafB.id)
        XCTAssertEqual(root.nextLeaf(after: leafB.id), leafC.id)
        XCTAssertEqual(root.nextLeaf(after: leafC.id), leafA.id) // wraps
    }

    // MARK: - Ratio

    func testSetRatioClampsLow() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        var node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB),
            ratio: 0.5
        ))
        let splitID = node.id
        node.setRatio(splitID: splitID, ratio: 0.0)
        if case .split(let data) = node {
            XCTAssertEqual(data.ratio, 0.1, accuracy: 0.001)
        } else {
            XCTFail("Expected split node")
        }
    }

    func testSetRatioClampsHigh() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        var node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB),
            ratio: 0.5
        ))
        let splitID = node.id
        node.setRatio(splitID: splitID, ratio: 1.0)
        if case .split(let data) = node {
            XCTAssertEqual(data.ratio, 0.9, accuracy: 0.001)
        } else {
            XCTFail("Expected split node")
        }
    }

    func testSetRatioWithinRange() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        var node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB),
            ratio: 0.5
        ))
        let splitID = node.id
        node.setRatio(splitID: splitID, ratio: 0.3)
        if case .split(let data) = node {
            XCTAssertEqual(data.ratio, 0.3, accuracy: 0.001)
        } else {
            XCTFail("Expected split node")
        }
    }

    func testSetRatioOnNestedSplitFindsCorrectNode() {
        let leafA = SplitNode.LeafData()
        let leafB = SplitNode.LeafData()
        let leafC = SplitNode.LeafData()
        let inner = SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(leafA),
            second: .leaf(leafB),
            ratio: 0.5
        )
        var root = SplitNode.split(SplitNode.SplitData(
            direction: .vertical,
            first: .split(inner),
            second: .leaf(leafC),
            ratio: 0.5
        ))
        root.setRatio(splitID: inner.id, ratio: 0.7)
        // Verify the inner split was updated
        if case .split(let outerData) = root,
           case .split(let innerData) = outerData.first {
            XCTAssertEqual(innerData.ratio, 0.7, accuracy: 0.001)
            XCTAssertEqual(outerData.ratio, 0.5, accuracy: 0.001) // outer unchanged
        } else {
            XCTFail("Expected nested split structure")
        }
    }

    func testDefaultRatioIsFifty() {
        let data = SplitNode.SplitData(
            direction: .horizontal,
            first: .leaf(SplitNode.LeafData()),
            second: .leaf(SplitNode.LeafData())
        )
        XCTAssertEqual(data.ratio, 0.5, accuracy: 0.001)
    }
}
