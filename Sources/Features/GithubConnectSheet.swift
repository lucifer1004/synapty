import SwiftUI

/// Connect / re-bind the GitHub hub-repo bridge from the GUI
/// (WI-2026-08-08-043): owner/repo + a fine-grained PAT, pasted into a
/// secure field. The token is fed to `synapty github login` via STDIN —
/// it never appears in argv (ps) or in any log.
struct GithubConnectSheet: View {
    let isPresented: Binding<Bool>
    /// Called after a successful login (dismiss + refresh the binding UI).
    var onConnected: () -> Void

    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""
    @State private var isRunning = false
    @State private var errorText: String?

    private static let patCreationURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSheetHeader(title: "Connect GitHub", icon: "link.badge.plus", isPresented: isPresented)
                .disabled(isRunning)

            Text("The login device holds a fine-grained PAT (Issues: Read/Write on the hub repo). Agents route task tools through this device — the credential stays in your Keychain.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                TextField("Owner (GitHub username or org)", text: $owner)
                    .textFieldStyle(.roundedBorder)
                TextField("Repository name", text: $repo)
                    .textFieldStyle(.roundedBorder)
                SecureField("Fine-grained PAT (Issues Read/Write)", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Create a fine-grained PAT on GitHub…") {
                    NSWorkspace.shared.open(Self.patCreationURL)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let errorText {
                Text(errorText)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || owner.trimmingCharacters(in: .whitespaces).isEmpty
                    || repo.trimmingCharacters(in: .whitespaces).isEmpty
                    || token.isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 420)
    }

    private func connect() {
        guard let binary = SynaptyBinary.resolve() else {
            errorText = "synapty binary not found"
            return
        }
        isRunning = true
        errorText = nil
        let trimmedOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let output = SubprocessRunner.run(
                executable: binary,
                arguments: ["github", "login", "--owner", trimmedOwner, "--repo", trimmedRepo],
                timeout: 30,
                input: token
            )
            DispatchQueue.main.async {
                isRunning = false
                if output.error == nil && !output.timedOut && !output.stdout.contains("error:") {
                    isPresented.wrappedValue = false
                    token = ""
                    onConnected()
                } else {
                    let msg = output.stderr.split(separator: "\n").last
                        ?? output.stdout.split(separator: "\n").last
                        ?? "Connection failed"
                    errorText = String(msg).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
}
