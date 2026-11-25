import SwiftUI

@main
struct SigninHubApp: App {
    init() {
        Scheduler.register()
        Scheduler.requestNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
