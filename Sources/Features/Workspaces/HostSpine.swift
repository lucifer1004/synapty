import SwiftUI

/// WHICH MACHINE A TAB IS ON, SAID ALONG ITS LEADING EDGE RATHER THAN AS A
/// DOT ([[HostTint]], [[WI-2026-09-17-001]]).
///
/// IT WAS A DOT, AND THE DOT WAS THE PROBLEM. [[WI-2026-09-07-003]] took
/// the identity colour off the workspace row for a reason it wrote down —
/// "`DS.danger` and `DS.warning` are the only saturated colours with a
/// meaning and they were competing with three hundred and sixty arbitrary
/// hues; a red dot among a rainbow is just another colour" — and exempted
/// the pane tab, on the argument that a tab "has no room for a name and is
/// on exactly one machine" ([[WorkspaceStatus]]).
///
/// THE EXEMPTION STOPPED HOLDING. That argument is about how many MACHINES
/// a tab has, and the thing that went wrong is how many DOTS it has: the
/// identity dot sat immediately left of the attention pulse, same 6pt, one
/// of them meaning something and one of them not. That is the row's own
/// disease — "three unlabelled dots is not three channels, it is one
/// channel used badly" — reaching the one place it had been allowed to
/// stay.
///
/// A DIFFERENT CHANNEL, NOT A QUIETER DOT. Dimming it would have left the
/// eye the same discrimination to make in the same place. Moved to the
/// edge, the dot channel carries only the two things that mean something
/// (amber pulse: this wants you; accent after the label: something is
/// running), and identity is read the way one reads a margin.
///
/// AND A STACK OF THEM READS AS A GROUP. Identical dots repeated down a
/// tab strip are noise, because a dot is a mark you are meant to inspect.
/// Identical spines are a bracket: four tabs on one machine look like four
/// tabs on one machine, which is the thing the colour was for.
///
/// NOT THE BOTTOM EDGE, which was the other candidate. [[ProgressHairline]]
/// already draws a 2pt horizontal bar under the label; a second horizontal
/// bar two points tall, differing only in where it sits, is the collision
/// this whole change is about.
enum HostSpine {

    /// Thin enough to be a margin, thick enough to carry a hue at
    /// `HostTint`'s deliberately low saturation. Two points read as an
    /// artefact of the border.
    static var width: CGFloat { DS.scaled(3) }

    /// FLUSH WITH THE TAB'S LEADING EDGE, and the whole of its height.
    ///
    /// INSET AND SHORT FIRST, WHICH LOOKED WRONG AND SAID WHY. Most tabs
    /// draw no background at all — only the active one wears the pill —
    /// so a short bar floating three points inside a transparent tab has
    /// no edge to be the margin OF. It read as a stray tick beside the
    /// title: a mark to inspect, which is the thing this change exists to
    /// stop it being. Full height against the boundary is the shape every
    /// gutter marker on this platform has, for the same reason.
    static var leading: CGFloat { 0 }

    /// The tab's own height ([[PaneTab]]); a capsule, so the ends round.
    static var height: CGFloat { DS.scaled(20) }

    /// HOW FAR INTO THE TAB IDENTITY IS ALLOWED TO REACH.
    ///
    /// A NUMBER SO A TEST CAN ASK IT. The claim this change makes is not
    /// "the spine is three points wide" — it is that the machine is said
    /// HERE AND NOWHERE ELSE on the tab. That is an invariance about where
    /// two tabs differing only in their host may differ, and it needs a
    /// boundary to be stated against.
    static var occupiedWidth: CGFloat { leading + width }
}

/// The spine itself.
struct HostSpineView: View {
    let hostLabel: String

    var body: some View {
        Capsule()
            .fill(HostTint.color(for: hostLabel))
            .frame(width: HostSpine.width, height: HostSpine.height)
            .padding(.leading, HostSpine.leading)
            // SPOKEN BY THE TAB, NOT BY THIS. The tab declares
            // `accessibilityElement(children: .ignore)` so that a pane is
            // one spoken element rather than a scatter of marks — which
            // silently dropped the label the identity dot used to carry
            // here. The machine is in the tab's own label and its tooltip
            // now, where it is reachable without hitting a 3pt target.
            .accessibilityHidden(true)
    }
}
