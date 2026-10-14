import Foundation

/// The platform a hot reload session builds, launches, and compiles replacement thunks for.
///
/// The planner is platform-agnostic; this type owns every platform-specific
/// value the CLI needs: the `xcodebuild` destination, SDK, deployment-target
/// build setting, Swift target triple, clang minimum-version flag, and the
/// toolchain's Swift runtime library directory.
package enum TargetPlatform: String, CaseIterable, Equatable, Sendable {
  /// An app running in the iOS Simulator, installed and launched with `simctl`.
  case iOSSimulator = "ios"
  /// A native macOS app, launched directly on the host.
  case macOS = "macos"

  package init?(argument: String) {
    switch argument.lowercased() {
    case "ios", "ios-simulator", "iphonesimulator", "simulator":
      self = .iOSSimulator
    case "macos", "mac", "osx", "macosx", "appkit":
      self = .macOS
    default:
      return nil
    }
  }

  /// The `xcrun --sdk` name.
  package var sdkName: String {
    switch self {
    case .iOSSimulator: "iphonesimulator"
    case .macOS: "macosx"
    }
  }

  /// The build setting holding the app's minimum OS version.
  package var deploymentTargetSetting: String {
    switch self {
    case .iOSSimulator: "IPHONEOS_DEPLOYMENT_TARGET"
    case .macOS: "MACOSX_DEPLOYMENT_TARGET"
    }
  }

  /// The `xcodebuild -destination` specifier.
  package func destination(deviceID: String?, architecture: String) -> String {
    switch self {
    case .iOSSimulator:
      "platform=iOS Simulator,id=\(deviceID ?? "")"
    case .macOS:
      "platform=macOS,arch=\(architecture)"
    }
  }

  /// Whether the session installs and launches through `simctl`.
  package var usesSimulator: Bool { self == .iOSSimulator }

  /// The Swift/clang target triple used to compile replacement thunks.
  package func targetTriple(architecture: String, deploymentTarget: String) -> String {
    switch self {
    case .iOSSimulator:
      "\(architecture)-apple-ios\(deploymentTarget)-simulator"
    case .macOS:
      "\(architecture)-apple-macos\(deploymentTarget)"
    }
  }

  /// The clang flag that sets the minimum OS version when linking the bundle.
  package func minimumVersionFlag(deploymentTarget: String) -> String {
    switch self {
    case .iOSSimulator:
      "-mios-simulator-version-min=\(deploymentTarget)"
    case .macOS:
      "-mmacosx-version-min=\(deploymentTarget)"
    }
  }

  /// The toolchain's Swift runtime library directory for this platform, given the path to `swiftc`.
  package func swiftLibraryDirectory(swiftc: String) -> URL {
    URL(fileURLWithPath: swiftc)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "lib/swift/\(sdkName)")
  }

  /// The app executable inside the built product, relative to `TARGET_BUILD_DIR`.
  ///
  /// Prefers Xcode's `EXECUTABLE_PATH` (`App.app/App` on iOS,
  /// `App.app/Contents/MacOS/App` on macOS) and otherwise derives it.
  package func executableRelativePath(
    executablePath: String?,
    fullProductName: String,
    executableName: String
  ) -> String {
    if let executablePath, !executablePath.isEmpty {
      return executablePath
    }
    switch self {
    case .iOSSimulator:
      return "\(fullProductName)/\(executableName)"
    case .macOS:
      return "\(fullProductName)/Contents/MacOS/\(executableName)"
    }
  }
}
