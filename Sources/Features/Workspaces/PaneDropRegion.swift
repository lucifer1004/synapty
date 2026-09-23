import AppKit
import Foundation
import UniformTypeIdentifiers

/// WHERE IN A PANE A DRAGGED PANE WAS RELEASED ([[WI-2026-08-17-028]]).
///
/// The gesture agreed with the human is five regions: four edge bands
/// that split the position they were dropped on, and a centre that joins
/// its stack. Which one a point falls in is the entire difference between
/// "beside this" and "behind this", so it is decided here — a pure
/// function of a point and a size — rather than inside the AppKit
/// destination, where it could only be checked by a person with a mouse.
///
/// COORDINATES ARE Y-DOWN, like the layout's own frames and SwiftUI's.
/// The one surface that reports otherwise is the terminal's NSView, which
/// is unflipped; `at(flippingY:in:)` is the single place that difference
/// is spelled out.
enum PaneDropRegion: Equatable {
    /// The centre: the dragged pane joins this position's stack.
    case stack
    case left, right, top, bottom

    /// How wide an edge band is, as a fraction of the pane. A quarter per
    /// side leaves the middle half of the pane meaning "stack".
    static let band: CGFloat = 0.25

    /// A NEAR-TIE IS A TIE. On the diagonal of a corner two edges are the
    /// same distance away, and in floating point they are that distance
    /// apart plus or minus a last bit — so an exact `<` hands the corner
    /// of one pane to the left and the identical corner of another to the
    /// bottom, by rounding. Anything closer than this is settled by the
    /// order the sides are tried in, which is fixed.
    private static let tie: CGFloat = 1e-9

    /// The region a point falls in. Points outside the pane are clamped
    /// rather than refused: AppKit reports them while a drag is leaving,
    /// and the region the human last saw highlighted is what a release
    /// there should still mean.
    static func at(_ point: CGPoint, in size: CGSize) -> PaneDropRegion {
        guard size.width > 0, size.height > 0 else { return .stack }
        let nx = clamp(point.x / size.width)
        let ny = clamp(point.y / size.height)

        // Distances in FRACTIONS of the pane, not points. A wide pane's
        // left band is wider than its top band is tall, so comparing
        // distances in points would give every corner to the short side.
        let sides: [(PaneDropRegion, CGFloat)] =
            [(.left, nx), (.right, 1 - nx), (.top, ny), (.bottom, 1 - ny)]
        var nearest = sides[0]
        for side in sides.dropFirst() where side.1 < nearest.1 - tie { nearest = side }

        return nearest.1 < band ? nearest.0 : .stack
    }

    /// The same question asked by a view whose origin is at the BOTTOM
    /// left — every NSView that does not override `isFlipped`, which
    /// includes the terminal surface. Flipping here, once and by name, is
    /// what keeps a drop under the tab bar from splitting downwards.
    static func at(flippingY point: CGPoint, in size: CGSize) -> PaneDropRegion {
        at(CGPoint(x: point.x, y: size.height - point.y), in: size)
    }

    private static func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    /// How the position is divided, or nil for the centre — which divides
    /// nothing.
    var direction: SplitNode.SplitDirection? {
        switch self {
        case .stack: return nil
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// Whether the arriving pane takes the near side of the split. A tree
    /// keeps its two children in order, so this is the difference between
    /// the left edge and the right one meaning the same thing.
    var placesMovedPaneFirst: Bool {
        self == .left || self == .top
    }
}

/// READING A PANE DRAG OFF THE BOARD APPKIT IS CARRYING.
///
/// The tab that started the drag is a SwiftUI view and puts a
/// `TabDragPayload` on the drag pasteboard; the pane it is released over
/// is an NSView, because a SwiftUI drop modifier is never asked behind the
/// terminal — AppKit finds its destination by walking the view tree
/// ([[WI-2026-08-17-028]]). So the two ends of one gesture speak through
/// different APIs, and this is the seam.
enum PaneDragBoard {
    static let type = NSPasteboard.PasteboardType(UTType.tabDragPayload.identifier)

    /// The pane being dragged, or nil when this drag is carrying something
    /// else — a file, most often, which the same destination also takes.
    static func paneID(on board: NSPasteboard) -> UUID? {
        guard let data = board.data(forType: type),
              let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data)
        else { return nil }
        return payload.paneID
    }

    /// Where the arriving pane will end up, in the destination's own
    /// coordinates — half the pane for an edge, all of it for the centre.
    /// Half is the honest preview: a split gives the new position half the
    /// space, and a highlight the width of the band would promise a
    /// quarter.
    ///
    /// `flipped` is for the terminal surface, whose origin is at the
    /// BOTTOM left like every NSView that does not say otherwise.
    static func highlight(_ region: PaneDropRegion, in bounds: CGRect,
                          flipped: Bool = false) -> CGRect {
        switch region {
        case .stack:
            return bounds
        case .left:
            return CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .right:
            return CGRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .top:
            return CGRect(x: bounds.minX, y: flipped ? bounds.midY : bounds.minY,
                          width: bounds.width, height: bounds.height / 2)
        case .bottom:
            return CGRect(x: bounds.minX, y: flipped ? bounds.minY : bounds.midY,
                          width: bounds.width, height: bounds.height / 2)
        }
    }
}
