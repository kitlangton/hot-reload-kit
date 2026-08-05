import Foundation
import HotReloadRuntime
import Testing

@MainActor
@Test("loading a missing artifact reports the loader error without invalidating views")
func missingArtifactIsRejected() {
  let observer = HotReloadRuntime.observer(for: "TestView")
  let generation = observer.generation

  let result = HotReloadRuntime.loadArtifact(
    at: URL(fileURLWithPath: "/tmp/hot-reload-artifact-that-does-not-exist.bundle"),
    declaration: "TestView"
  )

  guard case .failed(let message) = result else {
    Issue.record("Expected the artifact to be rejected")
    return
  }
  #expect(message.contains("hot-reload-artifact-that-does-not-exist.bundle"))
  #expect(observer.generation == generation)
}
