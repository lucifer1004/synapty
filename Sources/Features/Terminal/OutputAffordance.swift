import AppKit

/// WHAT IS UNDER THE POINTER, IN CELLS AND IN CHARACTERS.
///
/// GHOSTTY MATCHES AND MARKS; THIS APPLICATION DECIDES AND ACTS. Its
/// default matcher is not a url matcher — its own header calls it a
/// "URL/path regex" and it has three branches: scheme urls, rooted and
/// dot-relative paths, and bare relative paths. It handles a path with a
/// space in it, a trailing parenthesis, and a url wrapped across lines,
/// none of which a single-row reader can. Marking on top of it drew two
/// underlines on the same characters, which is how this was found.
///
/// WHAT IT MUST NOT OWN IS THE ANSWER. `resolvePathForOpening` resolves a
/// relative path against `terminal.getPwd()` — OSC 7, a directory the
/// CHILD announced, and the one source [[RFC-0015]] C-DERIVED forbids
/// resolving untrusted text against, because a file leaf persists the
/// directory it is showing. So the target is recomputed here, from the
/// characters on the screen and a base the child cannot choose.
///
/// SEPARATE FROM [[AgentDetector]] ON PURPOSE. That one classifies a
/// pane's status and MUST read the ACTIVE screen, so scrolling cannot
/// change a verdict. This reads the VIEWPORT, because what it answers is
/// about the text the human is looking at.
@MainActor
enum OutputAffordance {

    /// THE CHARACTERS UNDER THE POINTER, recognised or not.
    ///
    /// What the human is reading, which is what a declared link target
    /// has to be compared against ([[RFC-0015]] C-DERIVED rule two).
    /// Not a detection: a hyperlink's display text is usually a name
    /// rather than anything this recognises.
    static func token(
        surface: ghostty_surface_t, row: Int, column: Int, columns: Int
    ) -> String? {
        guard let line = readViewportRow(surface: surface, row: row, columns: columns)
        else { return nil }
        return OutputDetector.token(in: line, atCell: column)
    }

    // MARK: - Grid geometry

    /// The surface's cell grid, in the view's own coordinates.
    struct Metrics {
        let columns: Int
        let rows: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let height: CGFloat

        init(columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat, height: CGFloat) {
            self.columns = columns
            self.rows = rows
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.height = height
        }

        init?(surface: ghostty_surface_t, bounds: CGRect) {
            let size = ghostty_surface_size(surface)
            guard size.columns > 0, size.rows > 0, size.width_px > 0, size.height_px > 0,
                  bounds.width > 0, bounds.height > 0
            else { return nil }
            // POINTS FROM PIXELS BY MEASUREMENT, not by assuming a backing
            // scale: the surface reports pixels and the view is laid out
            // in points, and the ratio is the only thing that knows which
            // display this is.
            self.init(
                columns: Int(size.columns), rows: Int(size.rows),
                cellWidth: CGFloat(size.cell_width_px) * bounds.width / CGFloat(size.width_px),
                cellHeight: CGFloat(size.cell_height_px) * bounds.height / CGFloat(size.height_px),
                height: bounds.height)
        }

        /// The cell under a point given in the view's coordinates, whose
        /// origin is at the BOTTOM left while the grid counts from the top.
        func cell(at point: CGPoint) -> (column: Int, row: Int)? {
            guard cellWidth > 0, cellHeight > 0 else { return nil }
            // FLOOR AND NOT TRUNCATION. `Int(-0.1)` is 0, so a pointer one
            // point off the left edge — or above the top — would land on
            // the first cell and pass the bounds check below.
            let column = Int(floor(point.x / cellWidth))
            let row = Int(floor((height - point.y) / cellHeight))
            guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
            return (column, row)
        }

        /// Where a span of cells on one row sits in the view.
        func rect(row: Int, cells: Range<Int>) -> CGRect {
            CGRect(
                x: CGFloat(cells.lowerBound) * cellWidth,
                y: height - CGFloat(row + 1) * cellHeight,
                width: CGFloat(cells.count) * cellWidth,
                height: cellHeight)
        }
    }

    /// One row of WHAT THE HUMAN IS LOOKING AT.
    ///
    /// Viewport rather than active screen: the offer is about text on the
    /// screen, including text scrolled back to, which C-DERIVED authorises
    /// this clause's reader — and only this one — to read.
    static func readViewportRow(
        surface: ghostty_surface_t, row: Int, columns: Int
    ) -> String? {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { withUnsafeMutablePointer(to: &text) { ghostty_surface_free_text(surface, $0) } }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len))
        // One row, so a trailing newline is the row ending rather than a
        // second line.
        return String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }
}
