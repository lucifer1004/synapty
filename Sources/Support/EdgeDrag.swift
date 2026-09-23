import Foundation

/// A DIVIDER DRAG IN PROGRESS: where it began, and where it has reached.
///
/// TWO OPTIONALS FOR ONE DRAG. The anchor and the live width were separate
/// `@State`, set together in one closure and cleared together in another —
/// correct, but able to hold an anchor with no width or a width with no
/// anchor, neither of which is a drag. Together they are one value that is
/// either happening or not.
///
/// THE ANCHOR IS HELD RATHER THAN ACCUMULATED. `DSDragDivider` reports the
/// translation from the START of the gesture on every frame, so adding each
/// report to the current width would apply the whole gesture again on every
/// tick and the divider would run away from the pointer.
struct EdgeDrag: Equatable {

    /// The width the drag started from.
    let anchor: Double

    /// Where it has got to. The committed width is `@AppStorage`, written
    /// once when the drag ends: writing UserDefaults per frame is a
    /// synchronous store plus a defaults-change notification per frame,
    /// which the resize then has to keep up with.
    private(set) var width: Double

    init(from width: Double) {
        self.anchor = width
        self.width = width
    }

    mutating func slide(by offset: Double, within limits: ClosedRange<Double>) {
        width = min(max(anchor + offset, limits.lowerBound), limits.upperBound)
    }
}
