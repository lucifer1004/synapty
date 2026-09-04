import SwiftUI
import WebKit

/// A PAGE THE HUMAN ADDRESSED ([[RFC-0015]] C-CONTENT,
/// [[WI-2026-08-19-004]]).
///
/// THIS KIND HAS AN ADDRESS BAR AND THE SERVICES LEAF DOES NOT, which is
/// the whole difference between them. A services leaf shows what agents
/// offered on a named machine; this shows what a human asked for, and a
/// typed address names no machine — so the two could not be one pane
/// without that pane having to answer "over whose network?".
///
/// IT IS MARKED AS A RENDERED PAGE, POSITIVELY. A web page is the content
/// best able to imitate the window it is drawn in ([[ADR-0010]] rule d),
/// and "it does not look like our chrome" is not a mark a human can rely
/// on — a page can draw our chrome. So the pane carries a bar of its own
/// that a page cannot reach outside of, saying what is being shown and
/// where it came from.
///
/// AND IT DOES NOT WEAR THE AGENT FRAME. That frame means "an agent put
/// this here" ([[RFC-0013]] C-PRIMITIVES), and no agent asked for this —
/// the human typed it. Wearing it would attribute the human's own
/// browsing to whichever agent happened to be nearby.
struct BrowserView: View {

    /// Where this leaf is pointed, held by the LEAF — the one thing
    /// C-PERSIST writes for this kind, and what a restored workspace
    /// reopens on.
    var address: String?
    var onAddress: (String) -> Void = { _ in }
    /// Whether this pane is in front. The view is no longer destroyed on
    /// a tab switch — a rebuilt WKWebView is a reload, and the page,
    /// the scroll position and a half-filled form are not in the leaf —
    /// so it has to know when it is behind and take nothing.
    var isVisible: Bool = true

    @State private var draft = ""
    @State private var refusal: String?
    @FocusState private var addressFocused: Bool

    /// NON-PERSISTENT, AND NOT SHARED WITH THE SERVICES LEAF'S STORES.
    /// [[RFC-0015]] C-PERSIST bounds what a browser leaf writes to its
    /// address and excludes "the session, the history and anything a site
    /// left behind" — restoring an address is restoring where the human
    /// was, while restoring a session is re-entering it on their behalf.
    private static let store = WKWebsiteDataStore.nonPersistent()

    private var loaded: URL? {
        guard let address, case .success(let url) = BrowserAddress.parse(address) else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            DSHairline()
            if let loaded {
                BrowserSurface(url: loaded, store: Self.store, isVisible: isVisible)
                    .id(loaded)
            } else {
                DSEmptyState(
                    icon: "globe",
                    title: "Nothing addressed yet",
                    message: "Type a web address above. This pane opens "
                        + "\(BrowserAddress.allowedSchemes.joined(separator: " and ")) pages "
                        + "on this Mac — never on a host, and never a file.")
            }
        }
        .onAppear { draft = address ?? "" }
        .onChange(of: address) { _, moved in
            // The leaf can move without this view asking it to, and a
            // draft is about the place it was typed in.
            draft = moved ?? ""
            refusal = nil
        }
    }

    /// THE MARK, and it is the bar itself rather than a badge on it: a
    /// page cannot draw outside its own rectangle, so chrome the human can
    /// see above the content is the thing that cannot be imitated from
    /// inside it.
    private var bar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "globe")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textTertiary)
                Text("Web page")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize()

                TextField("Address", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.monoCaption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityIdentifier("browser-address")
                    .focused($addressFocused)
                    .onSubmit { go() }
                    .onExitCommand { draft = address ?? ""; refusal = nil }

                if let loaded {
                    // WHERE IT ACTUALLY CAME FROM, next to what was typed.
                    // A page that draws a convincing address bar of its own
                    // cannot change this one.
                    Text(loaded.host ?? "")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    DSIconButton(icon: "arrow.up.forward.app",
                                 help: "Open in Browser", size: 18) {
                        NSWorkspace.shared.open(loaded)
                    }
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)

            // A REFUSAL IS SHOWN WHERE THE HUMAN CAN SEE IT, and says what
            // this pane takes instead — a refusal nobody sees is a feature
            // that silently does nothing.
            if let refusal {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.danger)
                    Text(refusal)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.xs)
            }
        }
        .background(DS.chrome)
    }

    private func go() {
        switch BrowserAddress.parse(draft) {
        case .success(let url):
            refusal = nil
            addressFocused = false
            onAddress(url.absoluteString)
        case .failure(let why):
            // THE PANE DOES NOT MOVE. A refused address leaves the human
            // looking at what they were looking at, with the reason on
            // screen — the same rule a file pane's failed listing follows.
            refusal = why.message
        }
    }
}

/// The WKWebView itself, with the same confinement the services leaf's has.
private struct BrowserSurface: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    /// Whether this pane is the one in front. A web pane stays BUILT while
    /// hidden so its page survives a tab switch, which means a hidden one
    /// is a real AppKit view sitting in the overlapping stack — and
    /// WKWebView registers itself as a drag destination to accept files
    /// into a page. `isHidden` is what takes it out of hit-testing and out
    /// of that registration, the same one line TerminalSurface uses.
    let isVisible: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: config)
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
        /// THE ALLOW-LIST GOVERNS WHERE THE PAGE GOES, not only where the
        /// human sent it. A page that links to `file:///` — or is
        /// redirected there — would otherwise reach what the address bar
        /// refuses, which would make the refusal a formality.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let scheme = action.request.url?.scheme?.lowercased() else {
                return decisionHandler(.cancel)
            }
            decisionHandler(BrowserAddress.allowedSchemes.contains(scheme) ? .allow : .cancel)
        }

        /// A page opening a window would escape the bar that marks it as a
        /// page, so target=_blank loads here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               BrowserAddress.allowedSchemes.contains(scheme) {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
