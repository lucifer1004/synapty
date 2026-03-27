import SwiftUI

/// Renders ALL terminal surfaces across ALL panes in a single flat ZStack.
/// Only the active pane's leaves are visible; inactive panes' leaves are hidden
/// but alive (preserving ghostty surface state across tab switches).
struct AllPanesSplitView: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let ghosttyApp: GhosttyApp

    var body: some View {
        GeometryReader { geo in
            let activePane = paneManager.activePane
            let activeLeafIDs: Set<UUID> = activePane.map { Set($0.splitRoot.leafIDs) } ?? []
            let activeFrames: [UUID: CGRect] = activePane.map {
                SplitLayout.computeFrames(node: $0.splitRoot, in: CGRect(origin: .zero, size: geo.size))
            } ?? [:]

            ZStack(alignment: .topLeading) {
                // All leaves from all panes — flat ForEach for stable identity
                ForEach(paneManager.allLeaves, id: \.id) { leaf in
                    let isActive = activeLeafIDs.contains(leaf.id)
                    let frame = activeFrames[leaf.id] ?? CGRect(origin: .zero, size: geo.size)

                    TerminalView(ghosttyApp: ghosttyApp, command: leaf.command, leafID: leaf.id)
                        .frame(width: isActive ? frame.width : geo.size.width,
                               height: isActive ? frame.height : geo.size.height)
                        .offset(x: isActive ? frame.minX : 0,
                                y: isActive ? frame.minY : 0)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .overlay(
                            Group {
                                if isActive, let activePane, activePane.splitRoot.leaves.count > 1 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            activePane.focusedLeafID == leaf.id ? Color.accentColor : Color.clear,
                                            lineWidth: 2
                                        )
                                }
                            }
                        )
                }

                // Draw dividers for the active pane's split tree
                if let activePane {
                    let dividers = SplitLayout.computeDividers(
                        node: activePane.splitRoot,
                        in: CGRect(origin: .zero, size: geo.size)
                    )
                    ForEach(dividers, id: \.self) { divider in
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(width: divider.width, height: divider.height)
                            .offset(x: divider.minX, y: divider.minY)
                    }
                }
            }
        }
    }
}

// MARK: - Layout computation (pure functions)

enum SplitLayout {
    /// Compute the frame for each leaf by recursively subdividing the available rect.
    static func computeFrames(node: SplitNode, in rect: CGRect) -> [UUID: CGRect] {
        switch node {
        case .leaf(let data):
            return [data.id: rect]

        case .split(let data):
            let dividerSize: CGFloat = 1
            switch data.direction {
            case .horizontal:
                let halfWidth = (rect.width - dividerSize) / 2
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: halfWidth, height: rect.height)
                let secondRect = CGRect(x: rect.minX + halfWidth + dividerSize, y: rect.minY, width: halfWidth, height: rect.height)
                let first = computeFrames(node: data.first, in: firstRect)
                let second = computeFrames(node: data.second, in: secondRect)
                return first.merging(second) { _, b in b }

            case .vertical:
                let halfHeight = (rect.height - dividerSize) / 2
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)
                let secondRect = CGRect(x: rect.minX, y: rect.minY + halfHeight + dividerSize, width: rect.width, height: halfHeight)
                let first = computeFrames(node: data.first, in: firstRect)
                let second = computeFrames(node: data.second, in: secondRect)
                return first.merging(second) { _, b in b }
            }
        }
    }

    /// Compute divider rects for each split node.
    static func computeDividers(node: SplitNode, in rect: CGRect) -> [CGRect] {
        switch node {
        case .leaf:
            return []
        case .split(let data):
            let dividerSize: CGFloat = 1
            var dividers: [CGRect] = []

            switch data.direction {
            case .horizontal:
                let halfWidth = (rect.width - dividerSize) / 2
                dividers.append(CGRect(x: rect.minX + halfWidth, y: rect.minY, width: dividerSize, height: rect.height))
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: halfWidth, height: rect.height)
                let secondRect = CGRect(x: rect.minX + halfWidth + dividerSize, y: rect.minY, width: halfWidth, height: rect.height)
                dividers += computeDividers(node: data.first, in: firstRect)
                dividers += computeDividers(node: data.second, in: secondRect)

            case .vertical:
                let halfHeight = (rect.height - dividerSize) / 2
                dividers.append(CGRect(x: rect.minX, y: rect.minY + halfHeight, width: rect.width, height: dividerSize))
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)
                let secondRect = CGRect(x: rect.minX, y: rect.minY + halfHeight + dividerSize, width: rect.width, height: halfHeight)
                dividers += computeDividers(node: data.first, in: firstRect)
                dividers += computeDividers(node: data.second, in: secondRect)
            }
            return dividers
        }
    }
}
