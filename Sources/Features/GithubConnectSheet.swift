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
            DSSheetHeader(
                title: "Connect GitHub",
                icon: "link.badge.plus",
                help: "The login device holds a fine-grained PAT (Issues: Read/Write on the hub repo). Agents route task tools through this device — the credential stays in your Keychain.",
                isPresented: isPresented
            )
            .disabled(isRunning)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                TextField("Owner (GitHub username or org)", text: $owner)
                    .dsField()
                TextField("Repository name", text: $repo)
                    .dsField()
                SecureField("Fine-grained PAT (Issues Read/Write)", text: $token)
                    .dsField()
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
                // Cancel + primary pair — same footer as every other form
                // (WI-2026-08-08-090).
                Button("Cancel") {
                    isPresented.wrappedValue = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || owner.trimmingCharacters(in: .whitespaces).isEmpty
                    || repo.trimmingCharacters(in: .whitespaces).isEmpty
                    || token.isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.scaled(420))
    }

    /// WHETHER THE LOGIN TOOK — AND IT IS THE EXIT STATUS THAT SAYS SO.
    ///
    /// This asked STDOUT for "error:", and `synapty github login` writes
    /// all four of its refusals — owner, repo and token missing, and
    /// token verification failed — to STDERR before exiting 1
    /// (`src/cli/commands.zig` `runGithubLogin`), leaving stdout empty.
    /// So an under-scoped or expired PAT took the SUCCESS branch: the
    /// sheet closed, `onConnected()` fired, and NOTHING had been written
    /// to the Keychain or the config, because the CLI exits before
    /// either. The token was cleared from the field on the way out, so
    /// trying again meant minting a new one on GitHub. The error branch —
    /// which reads stderr correctly — could only be reached by a timeout
    /// or a binary that would not launch.
    ///
    /// The same launch-check-for-a-status confusion as
    /// [[WI-2026-09-10-001]], at a site that fix did not reach.
    static func loginSucceeded(_ output: SubprocessRunner.Output) -> Bool {
        output.error == nil && !output.timedOut && (output.exitCode ?? 1) == 0
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
                if Self.loginSucceeded(output) {
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
