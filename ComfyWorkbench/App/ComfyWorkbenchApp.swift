import SwiftUI

@main
struct ComfyWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()
    @StateObject private var clipboard = ClipboardSyncStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store).environmentObject(clipboard).preferredColorScheme(.dark)
                .onAppear { store.resumeMonitoring(); clipboard.resume() }
                .onChange(of: phase) { value in
                    if value == .active { store.resumeMonitoring(); clipboard.resume() }
                    else if value == .background { store.pauseMonitoring(); store.saveDraftsNow(); clipboard.pause() }
                }
        }
    }
}
