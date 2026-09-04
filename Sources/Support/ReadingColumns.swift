import SwiftUI

/// SECTIONS FLOW INTO COLUMNS WHEN THERE IS ROOM FOR THEM.
///
/// A settings pane is a stack of self-contained cards, and a card has a
/// width past which it stops being readable — a label at the far left and
/// a switch at the far right with a hand's width of nothing between them.
/// So the column is capped. On a wide display that left the right half of
/// every settings page empty, which is the complaint this answers: the cap
/// stays and the PAGE gets more of them.
///
/// A LAYOUT AND NOT A GRID, because the cards are different heights and a
/// grid would align their tops row by row, leaving ragged gaps under the
/// short ones. This places each card in whichever column is currently
/// shortest, which is what keeps two columns level without anyone
/// declaring where the split goes.
///
/// READING ORDER IS THE COST, and it is real: down the left column, then
/// down the right. It is the order a newspaper has, and the sections of a
/// settings pane are independent of one another — nothing here is a
/// sequence the human must follow.
struct ReadingColumns: Layout {
    /// The widest a card may be before its contents stop belonging
    /// together.
    var maxColumnWidth: CGFloat = 700
    var spacing: CGFloat = 24

    struct Cache {
        var columns: Int = 1
        var columnWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func plan(width: CGFloat, count: Int) -> (columns: Int, columnWidth: CGFloat) {
        guard width > 0, count > 0 else { return (1, max(width, 0)) }
        // As many capped columns as fit, and never more columns than
        // cards — two columns holding one card each with the second empty
        // is worse than one.
        let fitting = max(1, Int((width + spacing) / (maxColumnWidth + spacing)))
        let columns = min(fitting, count)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (columns, min(columnWidth, maxColumnWidth))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? maxColumnWidth
        let (columns, columnWidth) = plan(width: width, count: subviews.count)
        cache.columns = columns
        cache.columnWidth = columnWidth

        var heights = [CGFloat](repeating: 0, count: columns)
        for subview in subviews {
            let target = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            let size = subview.sizeThatFits(.init(width: columnWidth, height: nil))
            heights[target] += size.height + spacing
        }
        let tallest = (heights.max() ?? 0) - spacing
        return CGSize(width: width, height: max(tallest, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        let (columns, columnWidth) = plan(width: bounds.width, count: subviews.count)
        var heights = [CGFloat](repeating: 0, count: columns)
        for subview in subviews {
            let target = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            let size = subview.sizeThatFits(.init(width: columnWidth, height: nil))
            let x = bounds.minX + CGFloat(target) * (columnWidth + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY + heights[target]),
                          proposal: .init(width: columnWidth, height: size.height))
            heights[target] += size.height + spacing
        }
    }
}
