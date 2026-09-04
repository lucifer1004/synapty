import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// THE MARK A RECEIVER DRAWS WHILE A DRAG IS OVER IT
/// ([[WI-2026-08-17-028]]).
///
/// TWO SHAPES, BECAUSE THERE ARE TWO OPERATIONS. An ordered insertion — a
/// tab between tabs, a workspace between workspaces — draws a CARET in the
/// gap the thing will land in, because what the human is choosing is a
/// position, and the gap is where that position is.
/// Joining a container fills it, because what they are choosing is the
/// container: a pane over another pane fills the region it will take, and
/// a pane over a workspace row makes that row wear the selected treatment
/// outright — the same answer Finder gives a folder.
///
/// AND IT SPEAKS THE GRAMMAR THIS VIEW ALREADY HAS, which the first
/// version of it did not. Three things were already decided here and were
/// each re-invented a little worse:
///
///   - `DS.selectionAccentSoft` exists, and its own note says "tinted fill
///     for a selected or TARGETED region". This drew a hand-rolled 28%
///     instead — over twice the weight, enough to tint the terminal text
///     underneath rather than sit behind it.
///   - A pane overlay in this application is `cornerRadius: 2` with a 2pt
///     stroke: that is the focus ring and the attention ring. This drew a
///     radius-6 box, so one pane could wear two different corner radii at
///     once — and a split pane has SQUARE corners, so the preview was not
///     the shape of the result it was promising.
///   - Stroke means STATE here (focused, wants attention) and fill means
///     selection. This drew both at once, doubling the visual weight and
///     saying nothing extra.
///
/// So: fill only, soft, radius 2. A drop mark is not a state and must not
/// look like one.
enum DropMark {
    /// Matching the focus and attention rings this sits beside. A split
    /// pane's corners are square; 2 is as close to that as a rounded
    /// rectangle gets without claiming to be a card.
    static let cornerRadius: CGFloat = 2

    /// Line weight for an insertion mark. Rings are 2pt because they
    /// enclose; a caret is thinner because it separates.
    static let lineThickness: CGFloat = 2

    /// GEOMETRY MOVES, IT DOES NOT TELEPORT. Crossing from a pane's left
    /// band to its centre changes what the mark IS, and a rectangle that
    /// jumps between the two reads as a debug overlay — the single
    /// largest reason the first version looked unfinished. A spring
    /// rather than a curve because the mark is chasing a pointer.
    static let motion = Animation.spring(response: 0.22, dampingFraction: 0.86)

    /// Appearing and disappearing is a fade; only movement springs.
    static let fade = Animation.easeOut(duration: 0.12)
}

extension View {
    /// A CARET IN THE GAP THE ARRIVING THING WILL LAND IN.
    ///
    /// `gap` is the space between this receiver and its neighbour: the
    /// caret is centred IN it rather than drawn on this view's edge,
    /// because the gap is what the human is aiming at. Drawn on the edge
    /// it reads as "this one is selected", which is a different sentence.
    ///
    /// It is also inset from the ends. A rule the full height of its
    /// neighbour is a divider or a scrollbar; a caret is shorter than
    /// what it sits between, which is how a text cursor is shorter than
    /// its line.
    func dropCaret(_ shown: Bool, on edge: Alignment, gap: CGFloat, inset: CGFloat) -> some View {
        let horizontal = edge == .leading || edge == .trailing
        return overlay(alignment: edge) {
            Capsule()
                .fill(DS.selectionAccent)
                .frame(width: horizontal ? DropMark.lineThickness : nil,
                       height: horizontal ? nil : DropMark.lineThickness)
                .padding(horizontal ? .vertical : .horizontal, inset)
                .offset(x: horizontal ? -gap / 2 : 0,
                        y: horizontal ? 0 : -gap / 2)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(DropMark.fade, value: shown)
    }
}

/// A PANE THAT IS NOT A TERMINAL, RECEIVING ANOTHER PANE
/// ([[WI-2026-08-17-028]]).
///
/// A DELEGATE RATHER THAN `.dropDestination`, and for one reason: the
/// mark this draws has to follow the pointer. Which of the five regions
/// it is over IS the answer, and `isTargeted` is a Bool — `dropUpdated`
/// is the only SwiftUI drop callback carrying a location.
///
/// THE PAYLOAD IS READ OFF THE DRAG PASTEBOARD, not out of an item
/// provider. It is the same seam the terminal surface reads, proven by
/// every drop that already works; reading an identifier back out of a
/// provider is what WI-2026-08-17-023 measured never delivering a value.
struct PaneBodyDrop: DropDelegate {
    /// The receiving pane's own size — `DropInfo.location` is reported in
    /// its coordinates, y down.
    let size: CGSize
    /// The region under the pointer, or nil when the drag left.
    let onRegion: (PaneDropRegion?) -> Void
    let onDrop: (UUID, PaneDropRegion) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.tabDragPayload])
    }

    func dropEntered(info: DropInfo) {
        onRegion(PaneDropRegion.at(info.location, in: size))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onRegion(PaneDropRegion.at(info.location, in: size))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { onRegion(nil) }

    func performDrop(info: DropInfo) -> Bool {
        onRegion(nil)
        guard let paneID = PaneDragBoard.paneID(on: NSPasteboard(name: .drag)) else { return false }
        onDrop(paneID, PaneDropRegion.at(info.location, in: size))
        return true
    }
}

/// Which pane a drag is over and where in it. One value, because a
/// pointer is in one place.
struct PaneBodyDropTarget: Equatable {
    let paneID: UUID
    let region: PaneDropRegion
}
