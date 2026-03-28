import Foundation

/// Binary tree representing the split layout within a single pane/tab.
/// Leaves are terminal surfaces; internal nodes are horizontal or vertical splits.
indirect enum SplitNode: Identifiable {
    case leaf(LeafData)
    case split(SplitData)

    struct LeafData: Identifiable {
        let id: UUID
        let command: String?

        init(command: String? = nil) {
            self.id = UUID()
            self.command = command
        }
    }

    struct SplitData: Identifiable {
        let id: UUID
        let direction: SplitDirection
        /// Split ratio (0.0–1.0). First child gets `ratio` of the space.
        var ratio: CGFloat
        var first: SplitNode
        var second: SplitNode

        init(direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat = 0.5) {
            self.id = UUID()
            self.direction = direction
            self.ratio = ratio
            self.first = first
            self.second = second
        }
    }

    enum SplitDirection {
        case horizontal // side by side (split right/left)
        case vertical   // stacked (split down/up)
    }

    var id: UUID {
        switch self {
        case .leaf(let data): return data.id
        case .split(let data): return data.id
        }
    }

    /// All leaf IDs in this subtree (for surface rendering).
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let data):
            return [data.id]
        case .split(let data):
            return data.first.leafIDs + data.second.leafIDs
        }
    }

    /// All leaves in this subtree.
    var leaves: [LeafData] {
        switch self {
        case .leaf(let data):
            return [data]
        case .split(let data):
            return data.first.leaves + data.second.leaves
        }
    }

    /// Find the leaf with the given ID.
    func findLeaf(_ id: UUID) -> LeafData? {
        switch self {
        case .leaf(let data):
            return data.id == id ? data : nil
        case .split(let data):
            return data.first.findLeaf(id) ?? data.second.findLeaf(id)
        }
    }

    /// Split the leaf with the given ID into two, returning (updated tree, new leaf ID).
    /// The original leaf becomes the first child; the new leaf is the second child.
    func splitLeaf(_ leafID: UUID, direction: SplitDirection, newLeafCommand: String?) -> (SplitNode, UUID?) {
        switch self {
        case .leaf(let data):
            if data.id == leafID {
                let newLeaf = LeafData(command: newLeafCommand)
                let node = SplitNode.split(SplitData(
                    direction: direction,
                    first: self,
                    second: .leaf(newLeaf)
                ))
                return (node, newLeaf.id)
            }
            return (self, nil)

        case .split(var data):
            let (newFirst, id1) = data.first.splitLeaf(leafID, direction: direction, newLeafCommand: newLeafCommand)
            data.first = newFirst
            if let id1 { return (.split(data), id1) }

            let (newSecond, id2) = data.second.splitLeaf(leafID, direction: direction, newLeafCommand: newLeafCommand)
            data.second = newSecond
            return (.split(data), id2)
        }
    }

    /// Remove a leaf and return the sibling (collapsing the parent split).
    /// Returns nil if this node IS the leaf being removed (caller handles).
    func removeLeaf(_ leafID: UUID) -> SplitNode? {
        switch self {
        case .leaf(let data):
            return data.id == leafID ? nil : self

        case .split(let data):
            // Check if either direct child is the leaf to remove
            if case .leaf(let firstLeaf) = data.first, firstLeaf.id == leafID {
                return data.second // Collapse: return sibling
            }
            if case .leaf(let secondLeaf) = data.second, secondLeaf.id == leafID {
                return data.first // Collapse: return sibling
            }
            // Recurse into children
            var newData = data
            if let newFirst = data.first.removeLeaf(leafID) {
                newData.first = newFirst
            }
            if let newSecond = data.second.removeLeaf(leafID) {
                newData.second = newSecond
            }
            return .split(newData)
        }
    }

    /// Update the split ratio for a split node by ID. Clamps to [0.1, 0.9].
    mutating func setRatio(splitID: UUID, ratio: CGFloat) {
        switch self {
        case .leaf:
            break
        case .split(var data):
            if data.id == splitID {
                data.ratio = min(max(ratio, 0.1), 0.9)
                self = .split(data)
            } else {
                data.first.setRatio(splitID: splitID, ratio: ratio)
                data.second.setRatio(splitID: splitID, ratio: ratio)
                self = .split(data)
            }
        }
    }

    /// Get the next leaf ID after the given one (for focus navigation).
    func nextLeaf(after leafID: UUID) -> UUID? {
        let all = leaves
        guard let idx = all.firstIndex(where: { $0.id == leafID }) else { return nil }
        let nextIdx = (idx + 1) % all.count
        return all[nextIdx].id
    }

    /// Get the previous leaf ID before the given one.
    func previousLeaf(before leafID: UUID) -> UUID? {
        let all = leaves
        guard let idx = all.firstIndex(where: { $0.id == leafID }) else { return nil }
        let prevIdx = idx == 0 ? all.count - 1 : idx - 1
        return all[prevIdx].id
    }
}
