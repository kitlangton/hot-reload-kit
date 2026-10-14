import Foundation
import HotReloadCore
import Testing

@Suite("macOS target platform")
struct MacTargetPlatformTests {
  @Test("platform arguments resolve to iOS Simulator or macOS")
  func argumentsResolve() {
    #expect(TargetPlatform(argument: "macos") == .macOS)
    #expect(TargetPlatform(argument: "Mac") == .macOS)
    #expect(TargetPlatform(argument: "ios") == .iOSSimulator)
    #expect(TargetPlatform(argument: "simulator") == .iOSSimulator)
    #expect(TargetPlatform(argument: "watchos") == nil)
  }

  @Test("macOS builds for the host Mac and compiles thunks against the macOS SDK")
  func macOSValues() {
    let platform = TargetPlatform.macOS
    #expect(!platform.usesSimulator)
    #expect(platform.sdkName == "macosx")
    #expect(platform.deploymentTargetSetting == "MACOSX_DEPLOYMENT_TARGET")
    #expect(platform.destination(deviceID: nil, architecture: "arm64") == "platform=macOS,arch=arm64")
    #expect(platform.targetTriple(architecture: "arm64", deploymentTarget: "26.0") == "arm64-apple-macos26.0")
    #expect(platform.minimumVersionFlag(deploymentTarget: "15.0") == "-mmacosx-version-min=15.0")
    #expect(
      platform.swiftLibraryDirectory(swiftc: "/Toolchains/X.xctoolchain/usr/bin/swiftc").path
        == "/Toolchains/X.xctoolchain/usr/lib/swift/macosx")
  }

  @Test("iOS Simulator values are unchanged")
  func iOSValues() {
    let platform = TargetPlatform.iOSSimulator
    #expect(platform.usesSimulator)
    #expect(platform.sdkName == "iphonesimulator")
    #expect(platform.deploymentTargetSetting == "IPHONEOS_DEPLOYMENT_TARGET")
    #expect(platform.destination(deviceID: "ABC", architecture: "arm64") == "platform=iOS Simulator,id=ABC")
    #expect(
      platform.targetTriple(architecture: "arm64", deploymentTarget: "18.0")
        == "arm64-apple-ios18.0-simulator")
    #expect(platform.minimumVersionFlag(deploymentTarget: "18.0") == "-mios-simulator-version-min=18.0")
  }

  @Test("the Mac executable lives in Contents/MacOS unless Xcode reports EXECUTABLE_PATH")
  func executablePath() {
    #expect(
      TargetPlatform.macOS.executableRelativePath(
        executablePath: nil, fullProductName: "App.app", executableName: "App")
        == "App.app/Contents/MacOS/App")
    #expect(
      TargetPlatform.iOSSimulator.executableRelativePath(
        executablePath: nil, fullProductName: "App.app", executableName: "App")
        == "App.app/App")
    #expect(
      TargetPlatform.macOS.executableRelativePath(
        executablePath: "OpenCode Mac.app/Contents/MacOS/OpenCodeMac",
        fullProductName: "OpenCode Mac.app", executableName: "OpenCodeMac")
        == "OpenCode Mac.app/Contents/MacOS/OpenCodeMac")
  }
}

@Suite("AppKit replacement planning")
struct AppKitPlanningTests {
  @Test("an NSView draw(_:) override edit produces a replacement without override")
  func drawOverrideEdit() throws {
    let baseline = """
      import AppKit

      final class BadgeView: NSView {
        var tint = NSColor.systemBlue

        override func draw(_ dirtyRect: NSRect) {
          tint.setFill()
          bounds.fill()
        }
      }
      """
    let edited = baseline.replacingOccurrences(
      of: "tint.setFill()", with: "NSColor.systemOrange.setFill()")

    let plan = try ReplacementPlanner.plan(
      baseline: baseline, edited: edited, module: "MacApp",
      sourceFile: "BadgeView.swift", generation: 2)

    guard case .replace(let replacement) = plan else {
      Issue.record("Expected a replacement, got \(plan)")
      return
    }
    #expect(replacement.declarations == ["BadgeView"])
    #expect(replacement.source.contains(#"@_private(sourceFile: "BadgeView.swift") import MacApp"#))
    #expect(replacement.source.contains("import AppKit"))
    #expect(replacement.source.contains("@_dynamicReplacement(for: draw(_:))"))
    #expect(replacement.source.contains("func __hotReload_draw_2(_ dirtyRect: NSRect)"))
    #expect(!replacement.source.contains("override func __hotReload"))
    #expect(replacement.source.contains("NSColor.systemOrange.setFill()"))
  }

  @Test("NSViewController lifecycle, @objc actions, and NSTableCellView configuration reload")
  func controllerAndCellEdits() throws {
    let baseline = """
      import AppKit

      final class SessionsViewController: NSViewController {
        private let label = NSTextField(labelWithString: "")

        override func viewDidLoad() {
          super.viewDidLoad()
          label.stringValue = "Sessions"
        }

        @objc func refresh(_ sender: Any?) {
          label.stringValue = "Refreshing"
        }
      }

      final class SessionCellView: NSTableCellView {
        func configure(title: String, isUnread: Bool = false) {
          textField?.stringValue = title
          textField?.font = .systemFont(ofSize: 13, weight: isUnread ? .semibold : .regular)
        }
      }
      """
    let edited =
      baseline
      .replacingOccurrences(of: #""Sessions""#, with: #""All Sessions""#)
      .replacingOccurrences(of: #""Refreshing""#, with: #""Refreshing…""#)
      .replacingOccurrences(of: "ofSize: 13", with: "ofSize: 14")

    let plan = try ReplacementPlanner.plan(
      baseline: baseline, edited: edited, module: "MacApp",
      sourceFile: "Sessions.swift", generation: 7)

    guard case .replace(let replacement) = plan else {
      Issue.record("Expected a replacement, got \(plan)")
      return
    }
    #expect(replacement.declarations == ["SessionsViewController", "SessionCellView"])
    #expect(replacement.source.contains("@_dynamicReplacement(for: viewDidLoad())"))
    #expect(replacement.source.contains("@_dynamicReplacement(for: refresh(_:))"))
    #expect(replacement.source.contains("@_dynamicReplacement(for: configure(title:isUnread:))"))
    #expect(replacement.source.contains("(title: String, isUnread: Bool)"))
    #expect(replacement.source.contains(#"label.stringValue = "All Sessions""#))
  }

  @Test("adding a stored property to an NSView requires a rebuild")
  func storedPropertyRebuilds() throws {
    let baseline = """
      import AppKit

      final class BadgeView: NSView {
        override func layout() {
          super.layout()
        }
      }
      """
    let edited = baseline.replacingOccurrences(
      of: "final class BadgeView: NSView {",
      with: "final class BadgeView: NSView {\n  private var count = 0")

    let plan = try ReplacementPlanner.plan(
      baseline: baseline, edited: edited, module: "MacApp",
      sourceFile: "BadgeView.swift", generation: 1)
    guard case .rebuild = plan else {
      Issue.record("Expected a rebuild, got \(plan)")
      return
    }
  }
}
