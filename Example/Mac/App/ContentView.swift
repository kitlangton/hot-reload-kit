import HotReloadUI
import SwiftUI

@HotReloadable
struct ContentView: View {
  @State private var count = 0

  var body: some View {
    VStack(spacing: 20) {
      Text(Probe.record("swiftui", "SwiftUI Body"))
        .font(.largeTitle.bold())

      subtitle

      Text("State survived: \(count)")
        .monospacedDigit()

      Button("Increment") {
        count += 1
      }
      .buttonStyle(.borderedProminent)

      Divider()

      BadgeRepresentable()
        .frame(height: 64)
    }
    .padding(32)
  }

  private var subtitle: some View {
    Text(Probe.record("helper", "Helper Property"))
      .foregroundStyle(.secondary)
  }
}

struct BadgeRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> BadgeView { BadgeView() }
  func updateNSView(_ nsView: BadgeView, context: Context) {}
}
