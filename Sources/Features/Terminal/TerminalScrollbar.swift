import AppKit

/// Where the viewport sits in the scrollback, drawn where every scroll
/// view on this platform draws it.
///
/// THE DATA WAS ALREADY ARRIVING. Ghostty reports scrollbar geometry to
/// its embedder — total rows, viewport offset, viewport length — on every
/// change (`GHOSTTY_ACTION_SCROLLBAR`), and this application dropped the
/// action on the floor. So a human deep in a build log had no way to know
/// there were ten thousand lines above them, or two hundred, or none:
/// the terminal was the one scrolling surface in the app with no scrollbar
/// and no sense of place.
///
/// AN OVERLAY IN THE MACOS GRAMMAR: invisible while the terminal follows
/// its output at the bottom — a terminal pinned to now needs no map —
/// and present the moment the human scrolls into history or hovers the
/// right edge. The thumb's size says how much history there is; its
/// position says how deep they are; dragging it goes there.
///
/// [[WI-2026-09-02-001]]
enum ScrollbarMath {

    /// The smallest thumb a finger or a pointer can be expected to hit.
    static let minThumb: CGFloat = 24

    struct Thumb: Equatable {
        var y: CGFloat
        var height: CGFloat
    }

    /// Nil when everything fits — a scrollbar for content with no
    /// overflow is noise pretending to be information.
    static func thumb(total: Int, offset: Int, len: Int, track: CGFloat) -> Thumb? {
        guard total > len, len > 0, track > 0 else { return nil }
        let height = max(minThumb, track * CGFloat(len) / CGFloat(total))
        // The thumb travels the track MINUS its own height, so the
        // fraction maps offset's full range onto the travel exactly:
        // offset 0 puts the thumb at the top, offset (total-len) puts its
        // bottom edge at the track's end — a clamped thumb would
        // otherwise never reach either extreme.
        let travel = track - height
        let fraction = CGFloat(offset) / CGFloat(total - len)
        return Thumb(y: travel * min(max(fraction, 0), 1), height: height)
    }

    /// The inverse: where a drag puts the viewport.
    ///
    /// THE DRAG MOVES THE THUMB'S TOP, so the same travel/fraction pair
    /// inverts — a mapping written any other way disagrees with the
    /// rendering above and the thumb jumps on grab.
    static func row(forThumbY y: CGFloat, total: Int, len: Int, track: CGFloat) -> Int {
        guard total > len, len > 0, track > 0 else { return 0 }
        let height = max(minThumb, track * CGFloat(len) / CGFloat(total))
        let travel = track - height
        guard travel > 0 else { return 0 }
        let fraction = min(max(y / travel, 0), 1)
        return Int((fraction * CGFloat(total - len)).rounded())
    }

    /// Following the output at the bottom is the resting state, and the
    /// resting state draws nothing.
    static func isAtBottom(total: Int, offset: Int, len: Int) -> Bool {
        offset + len >= total
    }
}

/// The AppKit overlay itself — a subview of the terminal's own NSView,
/// which is what lets it draw over the Metal layer (the drop hint proved
/// the route) and answer drags without SwiftUI in the loop.
final class TerminalScrollbarView: NSView {

    /// Asks the surface to scroll so this row is the viewport's first.
    var onScrollToRow: ((Int) -> Void)?

    private var total = 0
    private var offset = 0
    private var len = 0
    private var hovering = false
    private var dragging = false
    /// Thumb origin at mouseDown, so the drag is relative — an absolute
    /// mapping would snap the thumb's TOP to the pointer on grab.
    private var dragStart: (mouseY: CGFloat, thumbY: CGFloat)?

    private let thumbLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        thumbLayer.cornerRadius = 4
        layer?.addSublayer(thumbLayer)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func update(total: Int, offset: Int, len: Int) {
        guard (total, offset, len) != (self.total, self.offset, self.len) else { return }
        self.total = total
        self.offset = offset
        self.len = len
        refresh()
    }

    /// Visible while the human is IN history or pointing at the bar;
    /// invisible while the terminal follows its output. A bar that showed
    /// on every printed line would flicker for the length of a build.
    private var shouldShow: Bool {
        guard ScrollbarMath.thumb(total: total, offset: offset, len: len,
                                  track: bounds.height) != nil else { return false }
        return dragging || hovering
            || !ScrollbarMath.isAtBottom(total: total, offset: offset, len: len)
    }

    private func refresh() {
        guard let thumb = ScrollbarMath.thumb(total: total, offset: offset, len: len,
                                              track: bounds.height),
              shouldShow
        else {
            thumbLayer.isHidden = true
            return
        }
        thumbLayer.isHidden = false
        let width: CGFloat = (hovering || dragging) ? 9 : 5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit's y grows UP; the math speaks in "distance from the top".
        thumbLayer.frame = NSRect(x: bounds.width - width - 3,
                                  y: bounds.height - thumb.y - thumb.height,
                                  width: width, height: thumb.height)
        thumbLayer.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent((hovering || dragging) ? 0.55 : 0.35).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    /// ONLY THE BAR'S OWN STRIP TAKES EVENTS. The overlay spans the pane
    /// for layout convenience, but a terminal owns its clicks — this view
    /// exists at the right edge and nowhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inSuper = superview?.convert(point, to: self) ?? point
        guard !thumbLayer.isHidden, inSuper.x >= bounds.width - 14 else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let topY = bounds.height - point.y
        guard let thumb = ScrollbarMath.thumb(total: total, offset: offset, len: len,
                                              track: bounds.height) else { return }
        dragging = true
        if topY >= thumb.y && topY <= thumb.y + thumb.height {
            dragStart = (mouseY: topY, thumbY: thumb.y)
        } else {
            // A click on the track jumps there, centring the thumb on the
            // click — the platform's own behaviour with "jump to spot".
            let target = topY - thumb.height / 2
            dragStart = (mouseY: topY, thumbY: target)
            scroll(toThumbY: target)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let topY = bounds.height - point.y
        scroll(toThumbY: dragStart.thumbY + (topY - dragStart.mouseY))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        dragStart = nil
        refresh()
    }

    private func scroll(toThumbY y: CGFloat) {
        let row = ScrollbarMath.row(forThumbY: y, total: total, len: len,
                                    track: bounds.height)
        onScrollToRow?(row)
    }
}
