import SwiftUI

@main
struct SigninHubApp: App {
    init() {
        Store.boot()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}