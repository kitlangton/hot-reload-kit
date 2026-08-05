import Combine
import Foundation
import HotReloadProtocol

#if DEBUG
  import Darwin
#endif

package enum ReloadResult: Equatable, Sendable {
  case loaded
  case failed(String)
}

@MainActor
public final class HotReloadObserver: ObservableObject {
  @Published package private(set) var generation = 0

  fileprivate func invalidate() {
    generation += 1
  }
}

#if DEBUG
  @MainActor
  public enum HotReloadRuntime {
    private static var loadedArtifacts: [UnsafeMutableRawPointer] = []
    private static var declarationObservers: [String: HotReloadObserver] = [:]
    private static var hasStarted = false
    private static var manifestTask: Task<Void, Never>?

    public static func observer(for declaration: String) -> HotReloadObserver {
      if let observer = declarationObservers[declaration] { return observer }
      let observer = HotReloadObserver()
      declarationObservers[declaration] = observer
      return observer
    }

    public static func start() {
      guard !hasStarted else { return }
      hasStarted = true

      let environment = ProcessInfo.processInfo.environment
      if let manifest = environment["HOTRELOAD_MANIFEST_PATH"],
        let receipt = environment["HOTRELOAD_RECEIPT_PATH"]
      {
        manifestTask = Task.detached {
          await watchManifest(
            at: URL(fileURLWithPath: manifest),
            receiptURL: URL(fileURLWithPath: receipt)
          )
        }
      }
    }

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declaration: String
    ) -> ReloadResult {
      dlerror()
      guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
        let message = dlerror().map { String(cString: $0) } ?? "Unknown dlopen error"
        return .failed(message)
      }

      // Swift images remain loaded for the process lifetime. Retaining the handles
      // makes that constraint explicit and prevents accidental dlclose attempts.
      loadedArtifacts.append(handle)
      declarationObservers[declaration]?.invalidate()
      return .loaded
    }

    nonisolated private static func watchManifest(at url: URL, receiptURL: URL) async {
      var generation = 0
      var pendingReceipt: ReloadReceipt?
      let decoder = JSONDecoder()
      let encoder = JSONEncoder()

      while !Task.isCancelled {
        if let pending = pendingReceipt,
          let receipt = try? encoder.encode(pending),
          (try? receipt.write(to: receiptURL, options: .atomic)) != nil
        {
          pendingReceipt = nil
        }
        if let data = try? Data(contentsOf: url),
          let command = try? decoder.decode(ReloadCommand.self, from: data),
          command.generation > generation
        {
          let result = await loadArtifact(
            at: URL(fileURLWithPath: command.artifactPath),
            declaration: command.declaration
          )
          generation = command.generation
          let error: String?
          switch result {
          case .loaded: error = nil
          case .failed(let message): error = message
          }
          pendingReceipt = ReloadReceipt(generation: generation, error: error)
        }
        try? await Task.sleep(for: .milliseconds(120))
      }
    }

  }
#else
  @MainActor
  public enum HotReloadRuntime {
    private static let disabledObserver = HotReloadObserver()

    public static func observer(for declaration: String) -> HotReloadObserver {
      disabledObserver
    }

    public static func start() {}

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declaration: String
    ) -> ReloadResult {
      .failed("HotReloadRuntime is disabled outside Debug builds")
    }
  }
#endif
