import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Try", systemImage: "hammer.fill") {
                TryPushesView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
}
