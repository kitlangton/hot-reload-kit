import ComposableArchitecture
import HotReloadUI
import SwiftUI

@HotReloadable
struct ContentView: View {
  let store: StoreOf<CounterFeature>

  var body: some View {
    VStack(spacing: 24) {
      Text("SwiftUI and TCA")
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)

      Text("State survived: \(store.count)")
        .monospacedDigit()

      Button("Increment") {
        store.send(.increment)
      }
      .buttonStyle(.borderedProminent)

      Divider()

      UIKitPreviewSection()
        .frame(height: 150)
    }
    .padding(32)
  }
}
