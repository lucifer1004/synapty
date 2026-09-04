import Foundation

/// The one place a value is made safe for a remote shell.
///
/// THREE COPIES OF THIS EXISTED AND TWO CALL SITES USED NONE
/// ([[WI-2026-09-02-024]]): an agent id reached `synapty end --id '…'`
/// inside hand-written quotes, which hold until the id contains one.
/// The rule is POSIX single-quoting — wrap in single quotes and close,
/// escape and reopen around any embedded one — and a rule with one home
/// is a rule every caller can be checked against.
///
/// NOT FOR SFTP. scp's `-s` path and the file browser hand paths to a
/// subsystem that has no shell, where quotes become part of the name;
/// the quoting bug in [[WI-2026-08-15-010]] was exactly that confusion.
enum Shell {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
