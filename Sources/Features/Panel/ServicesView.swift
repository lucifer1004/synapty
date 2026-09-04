import SwiftUI
import WebKit

/// WHAT AGENTS HAVE EXPOSED ON ONE MACHINE — a services leaf
/// ([[RFC-0015]] C-CONTENT).
///
/// NO ADDRESS BAR, deliberately. With one this becomes a browser living
/// inside a terminal application, and the rule that keeps this from
/// becoming a junk drawer — that it shows what agents offered — becomes a
/// fiction. What it offers instead is a list to pick from, not a field to
/// type into.
///
/// THIS MAC IS A MACHINE LIKE ANY OTHER. It read the local connection as
/// "no host chosen" and rendered "Pick a host. Choose one above." — above
/// was the panel's host picker, deleted when this became a pane, so the
/// most reachable instance of this leaf was a dead end pointing at a
/// control that no longer exists ([[WI-2026-08-19-001]]).
///
/// WHAT IT SHOWS LOCALLY IS AGENT EXPOSURES AND NOTHING ELSE.
/// [[RFC-0015]] C-CONTENT: what a machine merely LISTENS on is not an
/// offer — "it MUST NOT be enumerated for the local connection at all, and
/// on a remote connection it MUST require an explicit human act rather
/// than appearing of its own accord". A development machine answers on a
/// screenful of daemons that are nobody's work, and this Mac is the one
/// the human already has every other way of inspecting.
///
/// [[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-011]]
struct ServicesView: View {

    /// Whether this pane is in front. The view is no longer destroyed on a
    /// tab switch — a rebuilt WKWebView is a reload of whatever service
    /// this leaf was viewing — so it has to know when it is behind.
    var isVisible: Bool = true

    /// The machine this leaf is showing. `nil` is this Mac — a connection
    /// like any other, not the absence of a choice.
    let host: HostEntry?
    let forwards: PortForwardService
    let tunnelManager: TunnelManager
    /// WHAT THIS LEAF WAS SHOWING, AND WHO REMEMBERS IT.
    ///
    /// The leaf does, because this view is destroyed every time the human
    /// looks at another tab — held here alone, coming back put them at the
    /// list again with the page they were reading one click away and no
    /// sign that anything had been lost.
    var viewing: UUID?
    var onViewing: (UUID?) -> Void = { _ in }

    @State private var showing: PortForwardService.Exposure?
    @State private var discovered: [Int] = []
    @State private var scanning = false

    private var available: [PortForwardService.Exposure] {
        forwards.exposures.filter { $0.hostID == host?.id }
    }

    /// Whether this leaf may offer to look for unclaimed ports at all.
    /// Local: never ([[RFC-0015]] C-CONTENT).
    private var mayDiscover: Bool { host != nil }

    // Split into named branches: inlined, this one expression exceeded the
    // type-checker's budget.
    var body: some View {
        content
            .onChange(of: host?.id) { _, _ in show(nil); discovered = [] }
            .onChange(of: available.count) { _, _ in
                // AN OFFER THAT IS GONE IS NOT BEING SHOWN. An agent that
                // withdrew its view leaves the leaf at the list, and the
                // leaf's record has to go with it or coming back would
                // restore a page nobody is offering.
                if let showing, !available.contains(showing) { show(nil) }
                selectForScreenshot()
            }
            .onAppear {
                // RESUME WHAT THE LEAF WAS SHOWING, not the list.
                if showing == nil, let viewing {
                    showing = available.first { $0.id == viewing }
                }
                selectForScreenshot()
            }
    }

    /// Every change of what is on screen goes through here, so the leaf's
    /// record cannot drift from the view's.
    private func show(_ exposure: PortForwardService.Exposure?) {
        showing = exposure
        onViewing(exposure?.id)
    }

    /// Dev/test only: `--expose <port>` picks its own exposure so a
    /// screenshot can show the page.
    ///
    /// SELECTING IS THE HUMAN'S, and stays theirs — an exposure arriving
    /// while the human is looking at something else must not replace it
    /// ([[RFC-0013]] C-REQUEST-NOT-SEIZE). This exists because the only
    /// other way to reach the rendered state is a click, which left the one
    /// thing this view is for — putting a page on screen — verified by
    /// nothing at all.
    private func selectForScreenshot() {
        guard let port = DevLaunchArgs.expose, showing == nil else { return }
        showing = available.first { $0.remotePort == port }
    }

    @ViewBuilder
    private var content: some View {
        if let showing, available.contains(showing) {
            framed(showing)
        } else if available.isEmpty {
            nothingExposed
        } else {
            picker
        }
    }

    /// NOTHING OFFERED IS NOT NOTHING TO SAY. The leaf names its machine
    /// and says the one thing that would fill it — which on this Mac is
    /// the whole of the answer, because looking for unclaimed ports is not
    /// something this kind may offer here.
    private var nothingExposed: some View {
        // SCROLLING, LIKE THE PATH BESIDE IT. `picker` — the branch taken
        // once something IS exposed — has always wrapped everything
        // including `unclaimed` in a ScrollView. This branch, which is
        // where a human presses "Look for listening ports", did not, and
        // the discovery puts one row on it per listening port: on a
        // machine with many, the rows past the fold were drawn and could
        // not be reached (hub issue #3, [[WI-2026-09-03-013]]).
        ScrollView {
            VStack(spacing: DS.Space.md) {
                DSEmptyState(
                    icon: "square.dashed",
                    title: "Nothing exposed on \(hostLabel)",
                    message: "An agent shows you something here by running "
                        + "`synapty expose <port>`. What it exposes appears with its name on it.")
                if mayDiscover { unclaimed }
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Space.md)
        }
    }

    /// A SECOND LAYER, REACHED BY AN EXPLICIT ACT — which is what
    /// [[RFC-0015]] C-CONTENT requires of it, and it is drawn as one
    /// rather than as a fallback the leaf slipped into. What a machine
    /// merely listens on is not an offer: an agent's exposure arrives with
    /// a name and this can only report a number, so it sits under its own
    /// heading, below, behind a button.
    ///
    /// NEVER ON THIS MAC. The guard is at the two call sites and stated
    /// here as well, because a rule that lives only in an `if` at the
    /// caller is one the next caller does not know about.
    @ViewBuilder
    private var unclaimed: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSSectionLabel(text: "Not offered by an agent",
                           count: offerable.isEmpty ? nil : offerable.count)
            Text("Anything \(hostLabel) happens to be listening on. Nobody has put "
                 + "their name to these.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.sm) {
                Button(scanning ? "Looking…" : "Look for listening ports") { scan() }
                    .disabled(scanning || !mayDiscover)
                if scanning { ProgressView().controlSize(.small) }
            }
            ForEach(offerable, id: \.self) { port in
                Button {
                    // ATTRIBUTED TO THE HUMAN, because they chose it. The
                    // frame still goes round it — the page is a remote one
                    // this application does not vouch for either way — but
                    // it must not claim an agent asked.
                    Task { @MainActor in
                        if case .ok(let exposure) = await forwards.expose(
                            hostID: host?.id, remotePort: port,
                            agent: "you", title: "port \(port)") {
                            show(exposure)
                        }
                    }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textTertiary)
                        Text(portText(port))
                            .font(DS.Typography.body)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.lg)
    }

    /// A PORT IS AN IDENTIFIER, NOT A QUANTITY. `Text("port \(anInt)")`
    /// resolves to the LocalizedStringKey initialiser, which formats the
    /// number for the locale — so port 9090 rendered as "9,090", a string
    /// that will not connect to anything and that a human reading it back
    /// has to mentally strip. Interpolating a String picks the verbatim
    /// initialiser instead.
    private func portText(_ port: Int) -> String { "port \(port)" }

    private var offerable: [Int] {
        PortDiscovery.offerable(discovered, alreadyExposed: Set(available.map(\.remotePort)))
    }

    private func scan() {
        // C-CONTENT forbids enumerating the local machine's ports, and the
        // guard is here rather than only on the button: a control that is
        // hidden is not a rule.
        guard mayDiscover, let host else { return }
        scanning = true
        discovered = []
        let connection = tunnelManager.connection(for: host)
        Task.detached(priority: .userInitiated) {
            let out = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: connection.sshOptions + [connection.userAtHost, PortDiscovery.command],
                timeout: 15)
            let ports = PortDiscovery.parse(out.stdout)
            await MainActor.run {
                discovered = ports
                scanning = false
            }
        }
    }

    /// AGENT CONTENT, IN THE FRAME. Never rendered bare: the frame is what
    /// says an agent put this here, and a web page is exactly the content
    /// that could otherwise imitate this application ([[ADR-0010]] rule d).
    private func framed(_ exposure: PortForwardService.Exposure) -> some View {
        DSAgentFrame(agent: exposure.agent, title: exposure.title,
                     onDismiss: { show(nil) }) {
            VStack(spacing: 0) {
                WebSurface(url: exposure.url, store: Self.store(for: exposure.hostID),
                           isVisible: isVisible)
                    .id(exposure.id)
                DSHairline()
                handoff(exposure)
            }
        }
    }

    /// THIS VIEW IS A GLANCE; THE BROWSER IS FOR WORKING.
    ///
    /// The alternative was our own window, and it fails on its own terms:
    /// this view has no address bar precisely so the panel does not become
    /// a browser living inside a terminal application, and a second window
    /// would have been that browser, reassembled one control at a time and
    /// worse than the one already installed. Handing off keeps the rule and
    /// gives the human devtools, zoom, find, a password manager and a
    /// window they can put on another screen.
    ///
    /// THE ADDRESS IS SHOWN, not because it is dangerous but because a
    /// button should say what it does. Where it goes is the only thing this
    /// button decides.
    private func handoff(_ exposure: PortForwardService.Exposure) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(exposure.display)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: DS.Space.sm)
            Button {
                NSWorkspace.shared.open(exposure.url)
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.forward.app")
                    .font(DS.Typography.caption)
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
    }


    /// THE LEAF SAYS WHICH MACHINE IT IS SHOWING. A human with two of
    /// these open otherwise reads two identical panes.
    private var hostLabel: String {
        guard let host else { return "this Mac" }
        return host.label.isEmpty ? host.address : host.label
    }

    /// What is on offer. The agent's own title is the label, because it is
    /// the only description of the thing that exists.
    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DSSectionLabel(text: "Exposed by agents on \(hostLabel)",
                               count: available.count)
                ForEach(available) { exposure in
                    Button {
                        show(exposure)
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "cpu")
                                .font(DS.Typography.body)
                                .foregroundStyle(DS.textTertiary)
                                .frame(width: DS.scaled(16))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exposure.title ?? "port \(exposure.remotePort)")
                                    .font(DS.Typography.body)
                                    .lineLimit(1)
                                // String(_:), not the Int — see `portText`.
                                Text("\(exposure.agent) · remote \(String(exposure.remotePort))")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, DS.Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // REACHABLE FROM HERE TOO, and still second. A leaf that
                // offers the deeper layer only while it is empty hides it
                // exactly where it is most likely to be wanted — on a
                // machine already running something.
                if mayDiscover {
                    Spacer(minLength: DS.Space.md)
                    unclaimed
                }
            }
            .padding(DS.Space.lg)
        }
    }

    // MARK: - Storage

    /// ONE DATA STORE PER HOST, and never a shared one.
    ///
    /// The port allocator already refuses to hand one host's port to
    /// another, which is what keeps two hosts from becoming one web origin.
    /// This is the second wall: if that rule were ever misapplied, a shared
    /// store would mean cookies, localStorage and service workers crossing
    /// with it and nothing behind to stop them.
    ///
    /// NON-PERSISTENT, so nothing reaches disk. A dev server's session
    /// therefore lasts as long as the application runs and no longer, which
    /// is the right trade for content this application does not vouch for —
    /// the alternative is a credential store, on disk, for pages an agent
    /// chose.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// This Mac's own, kept apart from every host's for the same reason
    /// the hosts are kept apart from each other.
    private static let localStore = WKWebsiteDataStore.nonPersistent()

    @MainActor
    static func store(for hostID: UUID?) -> WKWebsiteDataStore {
        guard let hostID else { return localStore }
        if let existing = stores[hostID] { return existing }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[hostID] = store
        return store
    }
}

/// The WKWebView itself.
private struct WebSurface: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    /// Whether this pane is in front. A services pane stays BUILT while
    /// hidden so the service it is viewing does not reload, which means a
    /// hidden one is a real AppKit view in the overlapping stack — and
    /// WKWebView registers itself as a drag destination. `isHidden` is
    /// what takes it out of hit-testing and out of that registration.
    let isVisible: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: config)
        // A remote page must not be able to open windows outside the frame
        // that marks it as an agent's, so navigation stays in this view.
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.isHidden == isVisible { view.isHidden = !isVisible }
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// A page opening a new window would escape the attribution frame,
        /// so target=_blank loads here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}
