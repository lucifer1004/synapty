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
                }

                // Draw draggable dividers for the active pane's split tree
                if let activePane {
                    let dividers = SplitLayout.computeDividers(
                        node: activePane.splitRoot,
                        in: CGRect(origin: .zero, size: geo.size)
                    )
                    ForEach(dividers) { info in
                        DraggableDivider(info: info) { newRatio in
                            paneManager.resizeSplit(splitID: info.id, ratio: newRatio)
                        }
                    }

                    // Focus indicator
                    if activePane.splitRoot.leaves.count > 1,
                       let focusedID = activePane.focusedLeafID,
                       let focusFrame = activeFrames[focusedID] {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: focusFrame.width, height: focusFrame.height)
                            .offset(x: focusFrame.minX, y: focusFrame.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

// MARK: - Layout computation (pure functions)

enum SplitLayout {
    /// Divider info for rendering and interaction.
    struct DividerInfo: Identifiable {
        let id: UUID // matches SplitData.id
        let rect: CGRect
        let direction: SplitNode.SplitDirection
        /// The full extent of the parent split (for ratio calculation during drag).
        let parentRect: CGRect
    }

    static func computeFrames(node: SplitNode, in rect: CGRect) -> [UUID: CGRect] {
        switch node {
        case .leaf(let data):
            return [data.id: rect]

        case .split(let data):
            let dividerSize: CGFloat = 4 // slightly wider for easier grab
            let (firstRect, secondRect) = splitRects(rect, direction: data.direction, ratio: data.ratio, dividerSize: dividerSize)
            let first = computeFrames(node: data.first, in: firstRect)
            let second = computeFrames(node: data.second, in: secondRect)
            return first.merging(second) { _, b in b }
        }
    }

    static func computeDividers(node: SplitNode, in rect: CGRect) -> [DividerInfo] {
        switch node {
        case .leaf:
            return []
        case .split(let data):
            let dividerSize: CGFloat = 4
            var dividers: [DividerInfo] = []

            let (firstRect, secondRect) = splitRects(rect, direction: data.direction, ratio: data.ratio, dividerSize: dividerSize)

            // This split's divider
            let dividerRect: CGRect
            switch data.direction {
            case .horizontal:
                dividerRect = CGRect(x: firstRect.maxX, y: rect.minY, width: dividerSize, height: rect.height)
            case .vertical:
                dividerRect = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: dividerSize)
            }
            dividers.append(DividerInfo(id: data.id, rect: dividerRect, direction: data.direction, parentRect: rect))

            // Recurse
            dividers += computeDividers(node: data.first, in: firstRect)
            dividers += computeDividers(node: data.second, in: secondRect)
            return dividers
        }
    }

    private static func splitRects(_ rect: CGRect, direction: SplitNode.SplitDirection, ratio: CGFloat, dividerSize: CGFloat) -> (CGRect, CGRect) {
        switch direction {
        case .horizontal:
            let firstWidth = (rect.width - dividerSize) * ratio
            let secondWidth = rect.width - dividerSize - firstWidth
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(x: rect.minX + firstWidth + dividerSize, y: rect.minY, width: secondWidth, height: rect.height)
            )
        case .vertical:
            let firstHeight = (rect.height - dividerSize) * ratio
            let secondHeight = rect.height - dividerSize - firstHeight
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                CGRect(x: rect.minX, y: rect.minY + firstHeight + dividerSize, width: rect.width, height: secondHeight)
            )
        }
    }
}

// MARK: - Draggable Divider

struct DraggableDivider: View {
    let info: SplitLayout.DividerInfo
    let onResize: (CGFloat) -> Void
    @State private var isHovered = false

    var body: some View {
        let isHorizontal = info.direction == .horizontal
        // Visible divider (thin line)
        Rectangle()
            .fill(isHovered ? Color.accentColor : Color(NSColor.separatorColor))
            .frame(width: info.rect.width, height: info.rect.height)
            .offset(x: info.rect.minX, y: info.rect.minY)
            // Wider hit area for easier grabbing
            .contentShape(Rectangle().inset(by: isHorizontal ? -4 : -4))
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newRatio: CGFloat
                        if isHorizontal {
                            // Horizontal split: drag left/right
                            let pos = value.location.x + info.rect.minX
                            newRatio = (pos - info.parentRect.minX) / info.parentRect.width
                        } else {
                            // Vertical split: drag up/down
                            let pos = value.location.y + info.rect.minY
                            newRatio = (pos - info.parentRect.minY) / info.parentRect.height
                        }
                        onResize(newRatio)
                    }
            )
            .onHover { hovering in
                if hovering {
                    if isHorizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}
