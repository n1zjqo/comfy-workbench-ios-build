import SwiftUI

@main
struct ComfyWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store).preferredColorScheme(.dark)
                .onAppear { store.resumeMonitoring() }
                .onChange(of: phase) { value in
                    if value == .active { store.resumeMonitoring() }
                    else if value == .background { store.pauseMonitoring() }
                }
        }
    }
}
