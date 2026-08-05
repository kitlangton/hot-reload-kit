import ComposableArchitecture
import HotReloadUI
import SwiftUI

@main
struct HotReloadExampleApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(
        store: Store(initialState: CounterFeature.State()) {
          CounterFeature()
        }
      )
        .task { HotReloadRuntime.start() }
    }
  }
}
