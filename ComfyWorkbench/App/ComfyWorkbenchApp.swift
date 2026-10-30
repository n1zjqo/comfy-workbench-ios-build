import SwiftUI

@main
struct ComfyWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()
    @StateObject private var clipboard = ClipboardSyncStore()
    @StateObject private var strata = StrataStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store).environmentObject(clipboard).environmentObject(strata).preferredColorScheme(.dark)
                .onAppear { store.resumeMonitoring(); clipboard.resume(); strata.resume(); Task { await store.refreshConnectionStatus(force: true) } }
                .onChange(of: phase) { value in
                    if value == .active { store.resumeMonitoring(); clipboard.resume(); strata.resume(); Task { await store.refreshConnectionStatus(force: true) } }
                    else if value == .background { store.pauseMonitoring(); store.saveDraftsNow(); clipboard.pause(); strata.background() }
                }
        }
    }
}
