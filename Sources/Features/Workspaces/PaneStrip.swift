import SwiftUI

/// THE ROOM A PANE GIVES UP TO THE NOTICES DRAWN ABOVE IT.
///
/// A NOTICE THE HUMAN DID NOT ASK FOR MUST NOT HIDE WHAT IT IS REPORTING
/// ON. [[RejoinNoticeView]] paid for that lesson: floated over the grid, its
/// strip sat exactly on the shell's first row, so the pane photographed
/// BLANK with the prompt underneath it. The terminal is inset instead,
/// which is what a browser's infobar does and why both are shaped like one.
///
/// AND THERE CAN BE TWO. A pane that came back restarted and then lost its
/// link has something to say about each ([[RFC-0015]] C-HONESTY and
/// C-FAILURE are different obligations), and two strips that each inset the
/// pane by their own height would both draw at the top — the second on the
/// first, the terminal under whichever won. One owner for the height and
/// for where each strip sits is what makes that unrepresentable.
///
/// [[WI-2026-09-07-004]]
enum PaneStrip {
    /// FIXED, because the layout subtracts it from the pane. A strip that
    /// sized itself would leave the terminal a gap that is nearly right.
    static var height: CGFloat { DS.scaled(22) }

    /// What the terminal gets: its own rect, less the strips above it.
    ///
    /// A PANE IS NEVER INSET OUT OF EXISTENCE. A short pane and three
    /// notices would otherwise be a negative height, which is a crash in
    /// some layouts and a silently invisible terminal in the rest.
    static func paneRect(_ rect: CGRect, strips: Int) -> CGRect {
        let taken = min(height * CGFloat(max(strips, 0)), rect.height)
        return CGRect(x: rect.minX, y: rect.minY + taken,
                      width: rect.width, height: max(0, rect.height - taken))
    }

    /// Where the strip at `index` sits, counting from the pane's top edge.
    static func offsetY(_ rect: CGRect, index: Int) -> CGFloat {
        rect.minY + height * CGFloat(max(index, 0))
    }

    // MARK: - Who is above whom

    /// HOW MANY NOTICES A PANE IS CARRYING, and which row each takes.
    ///
    /// HERE RATHER THAN IN THE VIEW, because this is where the overlap the
    /// whole of [[PaneStrip]] exists to prevent actually lives. The
    /// geometry above was tested and the CALLER was not: nothing said the
    /// pane is inset by TWO when both notices show, or that the rejoin
    /// notice takes the lower row. Both were private to a `View` and so
    /// unreachable, and the defect they hide is a terminal drawn under a
    /// notice — the failure `RejoinNoticeView` already paid for once, when
    /// a pane photographed blank with its prompt underneath.
    ///
    /// NEWEST FACT ON TOP. The link notice leads because it is the
    /// condition that is true NOW; the hole reports something that
    /// happened during this session; the rejoin notice reports how the
    /// pane came back, which is the oldest of the three. Ordering by
    /// anything else would put "started a new shell" above "the link is
    /// down", which reads as a history rather than a status.
    static func count(link isLive: Bool, hole: Bool, rejoining: Bool) -> Int {
        (isLive ? 0 : 1) + (hole ? 1 : 0) + (rejoining ? 1 : 0)
    }

    /// The row the hole notice takes: below the link notice where there
    /// is one, and the top row where there is not.
    static func holeIndex(link isLive: Bool) -> Int { isLive ? 0 : 1 }

    /// The row the rejoin notice takes, below whichever of the two above
    /// it are showing.
    static func rejoinIndex(link isLive: Bool, hole: Bool) -> Int {
        holeIndex(link: isLive) + (hole ? 1 : 0)
    }
}
