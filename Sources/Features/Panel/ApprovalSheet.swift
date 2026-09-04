import SwiftUI

/// What agents are waiting on a human to allow.
///
/// A BADGE AND A SHEET, never an interruption. The request arrives while
/// someone is typing; putting it in front of them would make an agent able
/// to seize the screen by asking, which is the thing the whole plane is
/// built not to allow ([[RFC-0013]] C-REQUEST-NOT-SEIZE). It waits in a
/// count until they go and look.
///
/// [[WI-2026-08-15-012]]
struct ApprovalSheet: View {

    let authority: TransferAuthority
    let questions: QuestionService
    let transfers: TransferService
    let hostStore: HostStore
    /// WHERE THE ASKER IS. A question is the surface that exists to make
    /// a human act, and "which machine" is part of knowing what they are
    /// acting on — the more so now that a remote agent's question reaches
    /// here at all ([[ADR-0008]] 3b: an agent talks to the hub on its own
    /// host, and cross-machine traffic rides the peer link).
    var agentMonitor: AgentMonitor? = nil
    var onClose: () -> Void

    @State private var isPresented = true

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(
                title: "Waiting on you",
                icon: "shield.lefthalf.filled",
                isPresented: $isPresented)

            DSHairline()

            // ONE PLACE FOR EVERYTHING BLOCKED ON A HUMAN. Two badges and
            // two sheets would make "is anything waiting on me" a question
            // with two answers.
            if authority.pending.isEmpty && questions.unanswered.isEmpty
                && transfers.awaitingChoice.isEmpty {
                DSEmptyState(
                    icon: "checkmark.shield",
                    title: "Nothing waiting",
                    message: "Agents ask before moving files between your machines, "
                        + "and when a decision is yours to make.")
                    .frame(height: DS.scaled(160))
            } else {
                list.frame(maxHeight: DS.scaled(340))
            }

            DSHairline()
            footer
        }
        .frame(width: DS.scaled(460))
        .onChange(of: isPresented) { _, shown in if !shown { onClose() } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                // A NAME COLLISION IS A DECISION, so it belongs here
                // rather than in a dialog of its own. Replace is the only
                // way anything is ever destroyed, and it exists only
                // because a person asked for it in front of the file it
                // applies to.
                ForEach(transfers.awaitingChoice) { transfer in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("\(transfer.fileName) is already there")
                            .font(DS.Typography.titleLarge)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(transfers.machineName(of: transfer.destination)) already has a "
                             + "file with this name.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                        HStack(spacing: DS.Space.sm) {
                            // FINDER'S WORDS AND FINDER'S ORDER, because
                            // the human already has them — and the safe
                            // one reads first.
                            Button("Keep Both") { transfers.resolveConflict(transfer.id, .rename) }
                            Button("Replace") { transfers.resolveConflict(transfer.id, .replace) }
                            Button("Cancel") { transfers.cancel(transfer.id) }
                                .buttonStyle(.plain)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .font(DS.Typography.detail)
                    }
                    .padding(DS.Space.md)
                    .background(DS.hover, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                }
                ForEach(questions.unanswered) { question in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(question.text)
                            .font(DS.Typography.titleLarge)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(waitingLine(question.agent))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                        HStack(spacing: DS.Space.sm) {
                            Spacer(minLength: 0)
                            // ONLY WHAT THE AGENT OFFERED. It will act on
                            // the answer, so a choice it has no branch for
                            // is worse than none.
                            ForEach(question.options, id: \.self) { option in
                                Button(option) { questions.answer(question.id, with: option) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(DS.Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.surface))
                }
                ForEach(authority.pending) { request in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        // THE ROUTE IS THE QUESTION, not the file. A human
                        // answering about one file would be answering the
                        // wrong question: what they are granting is the
                        // ability to send along this route for the session.
                        Text("\(name(request.pair.from)) → \(name(request.pair.to))")
                            .font(DS.Typography.titleLarge)
                        Text("\(request.agent) wants to send \(request.fileName), and anything else "
                             + "along this route until you quit.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Space.sm) {
                            Spacer(minLength: 0)
                            Button("Deny") { authority.deny(request.id) }
                                .controlSize(.small)
                            Button("Allow for this session") { authority.grant(request.pair) }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(DS.Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.surface))
                }
            }
            .padding(DS.Space.lg)
        }
    }

    /// The mechanism sentence sits beside the buttons, where a human decides
    /// — the two facts that make the answer safe to give are that it expires
    /// and that it is one direction.
    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            Text("Permission lasts until you quit Synapty, and covers one direction only.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.md)
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.lg)
    }

    private func name(_ hostID: UUID?) -> String { hostStore.displayName(of: hostID) }

    /// THE NAME WITHOUT ITS ROUTING QUALIFIER, AND THE MACHINE SAID
    /// PLAINLY. `local-1a2b@deskmac-2630` is an encoding, not something to
    /// read out at a human; and a bare `local-1a2b` is a name this Mac
    /// can also have, so a question from another machine read exactly
    /// like one from a pane on this desk.
    private func waitingLine(_ agent: String) -> String {
        let who = AgentMonitor.bareID(of: agent)
        let machine = agentMonitor?.machine(ofAgent: agent) ?? ""
        return machine.isEmpty
            ? "\(who) is waiting on this."
            : "\(who) on \(machine) is waiting on this."
    }
}
