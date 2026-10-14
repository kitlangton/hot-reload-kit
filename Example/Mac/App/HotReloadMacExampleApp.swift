import HotReloadUI
import SwiftUI

@main
struct HotReloadMacExampleApp: App {
  var body: some Scene {
    WindowGroup("HotReloadKit on macOS") {
      ContentView()
        .frame(minWidth: 420, minHeight: 320)
    }
  }
}

/// Lets the smoke test read what the running app drew: when
/// `HOTRELOAD_EXAMPLE_PROBE` names a directory, each recorded value is written
/// to `<directory>/<key>.txt`.
enum Probe {
  @discardableResult
  static func record(_ key: String, _ value: String) -> String {
    if let directory = ProcessInfo.processInfo.environment["HOTRELOAD_EXAMPLE_PROBE"] {
      let url = URL(fileURLWithPath: directory).appending(path: "\(key).txt")
      try? value.write(to: url, atomically: true, encoding: .utf8)
    }
    return value
  }
}
