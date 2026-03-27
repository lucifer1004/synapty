import SwiftUI

/// Renders all terminal surfaces in a flat ZStack, positioned according to the split tree.
/// Surfaces are never destroyed by tree restructuring — only by explicit close.
struct SplitContentView: View {
    let node: SplitNode
    let ghosttyApp: GhosttyApp
    let focusedLeafID: UUID?
    var onFocusLeaf: ((UUID) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let frames = computeFrames(node: node, in: CGRect(origin: .zero, size: geo.size))

            ZStack(alignment: .topLeading) {
                ForEach(node.leaves, id: \.id) { leaf in
                    if let frame = frames[leaf.id] {
                        TerminalView(ghosttyApp: ghosttyApp, command: leaf.command, leafID: leaf.id)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(focusedLeafID == leaf.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY),
                                alignment: .topLeading
                            )
                    }
                }

                // Draw dividers between splits
                ForEach(computeDividers(node: node, in: CGRect(origin: .zero, size: geo.size)), id: \.self) { divider in
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: divider.width, height: divider.height)
                        .offset(x: divider.minX, y: divider.minY)
                }
            }
        }
    }

    /// Compute the frame for each leaf by recursively subdividing the available rect.
    private func computeFrames(node: SplitNode, in rect: CGRect) -> [UUID: CGRect] {
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
    private func computeDividers(node: SplitNode, in rect: CGRect) -> [CGRect] {
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
