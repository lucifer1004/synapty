import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let ghosttyApp = appDelegate.ghosttyApp {
                TerminalView(ghosttyApp: ghosttyApp)
            } else {
                Text("Initializing terminal...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .foregroundColor(.white)
            }
        }
    }
}
