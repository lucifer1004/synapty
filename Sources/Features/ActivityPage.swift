import SwiftUI

/// WHAT HAPPENED ON THIS MACHINE, as its own page — why it is a page and
/// not a tab of Tasks is on `AppPage.activity`.
struct ActivityPage: View {
    var taskMonitor: TaskMonitor
    var transfers: TransferService?

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("Activity")
            DSHairline()
            ActivityStreamView(taskMonitor: taskMonitor, transfers: transfers)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        // POLLING RUNS WHILE THIS IS ON SCREEN and not otherwise — the
        // WI-2026-08-08-041 gate, which followed the stream from
        // ContentView to the Tasks page and now here. Management pages
        // leave the view tree when inactive, so onDisappear fires on every
        // page switch.
        .onAppear { taskMonitor.setActivityPollingEnabled(true) }
        .onDisappear { taskMonitor.setActivityPollingEnabled(false) }
    }
}
