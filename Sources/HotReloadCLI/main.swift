import ArgumentParser
import Foundation
import HotReloadCore
import HotReloadProtocol

@main
struct HotReloadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hotreload",
    abstract:
      "Hot-reload safe Swift body and class method edits in an iOS Simulator or a native macOS app.",
    version: "0.1.0"
  )

  @Option(help: "Path to the Xcode project.")
  var project: String

  @Option(help: "Scheme and application target to build.")
  var scheme: String

  @Option(
    help: ArgumentHelp(
      "Platform to build and run: ios (iOS Simulator, default) or macos (native Mac app).",
      valueName: "ios|macos"
    ),
    transform: { value in
      guard let platform = TargetPlatform(argument: value) else {
        throw ValidationError("Unknown platform '\(value)'. Use ios or macos.")
      }
      return platform
    }
  )
  var platform: TargetPlatform = .iOSSimulator

  @Option(
    help: ArgumentHelp(
      "Command used for xcodebuild builds (for example a wrapper that queues builds). Receives the usual xcodebuild arguments.",
      valueName: "path"
    )
  )
  var xcodebuild = "xcodebuild"

  @Option(
    name: .customLong("launch-argument"),
    help: "Argument passed to the launched app (repeatable)."
  )
  var launchArguments: [String] = []

  @Option(help: "Single Swift source file to watch.")
  var source: String?

  @Option(
    name: .long,
    help: "Directory or Swift file to watch (repeatable). Defaults to the project directory when --source is omitted."
  )
  var watch: [String] = []

  @Option(help: "Simulator UDID. Defaults to a booted simulator.")
  var simulator: String?

  @Option(help: "DerivedData directory.")
  var derivedData = FileManager.default.temporaryDirectory
    .appending(path: "HotReloadKitDerivedData", directoryHint: .isDirectory).path

  @Flag(help: "Run xcodegen before the initial build and structural rebuilds.")
  var xcodegen = false

  @Option(
    help: ArgumentHelp(
      "XcodeGen spec for --xcodegen when it isn't project.yml beside the project (the project is generated into the --project directory).",
      valueName: "path"
    )
  )
  var xcodegenSpec: String?

  @Flag(help: "Use hot-reload compiler and linker settings already defined by the application target.")
  var useProjectBuildSettings = false

  mutating func run() async throws {
    setbuf(stdout, nil)
    setbuf(stderr, nil)

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let projectURL = resolve(project, relativeTo: root)
    let derivedDataURL = resolve(derivedData, relativeTo: root)

    guard FileManager.default.fileExists(atPath: projectURL.path) else {
      throw HotReloadError("Project not found at \(projectURL.path)")
    }

    var watchTargets: [URL] = []
    if let source {
      let sourceURL = resolve(source, relativeTo: root)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw HotReloadError("Source file not found at \(sourceURL.path)")
      }
      watchTargets.append(sourceURL)
    }
    for entry in watch {
      let url = resolve(entry, relativeTo: root)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw HotReloadError("Watch path not found at \(url.path)")
      }
      if !watchTargets.contains(url) {
        watchTargets.append(url)
      }
    }
    if watchTargets.isEmpty {
      watchTargets.append(projectURL.deletingLastPathComponent().standardizedFileURL)
    }

    let sessionURL = derivedDataURL.appending(
      path: "HotReloadSession-\(ProcessInfo.processInfo.processIdentifier)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: sessionURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: sessionURL) }
    let launcher = MacAppLauncher()
    let signalSources = Self.installSignalCleanup(removing: sessionURL, launcher: launcher)
    defer { signalSources.forEach { $0.cancel() } }
    defer { launcher.terminate() }

    let deviceID: String? =
      platform.usesSimulator ? try simulator ?? Self.bootedSimulatorID() : nil
    var watcher = SourceTreeWatcher(roots: watchTargets, excludedRoot: derivedDataURL)
    var session = Session(
      project: projectURL,
      scheme: scheme,
      platform: platform,
      derivedData: derivedDataURL,
      deviceID: deviceID,
      sessionDirectory: sessionURL,
      runsXcodeGen: xcodegen,
      xcodeGenSpec: xcodegenSpec.map { resolve($0, relativeTo: root) },
      usesProjectBuildSettings: useProjectBuildSettings,
      xcodebuild: xcodebuild,
      launchArguments: launchArguments,
      launcher: launcher
    )
    let initialFiles = try watcher.snapshotAllFiles()
    try session.bootstrap(initialSources: initialFiles)

    let watchedDescription = watchTargets.map(\.path).joined(separator: ", ")
    print("[hotreload] watching \(watchedDescription) (\(initialFiles.count) Swift file(s), Ctrl-C to stop)")

    while true {
      try await Task.sleep(for: .milliseconds(150))
      guard let batch = try await watcher.pollSettledChanges() else { continue }
      do {
        let rebuilt = try session.applyBatch(batch)
        if rebuilt {
          if let refreshed = try? watcher.snapshotAllFiles() {
            session.replaceAllBaselines(with: refreshed)
          }
        }
      } catch {
        print("[hotreload] \(error)")
      }
    }
  }

  private static func installSignalCleanup(
    removing sessionURL: URL,
    launcher: MacAppLauncher
  ) -> [any DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler {
        launcher.terminate()
        try? FileManager.default.removeItem(at: sessionURL)
        _exit(128 + sig)
      }
      source.resume()
      return source
    }
  }

  private static func bootedSimulatorID() throws -> String {
    let data = try ProcessRunner.capture("xcrun", ["simctl", "list", "devices", "booted", "-j"])
    let listing = try JSONDecoder().decode(SimulatorListing.self, from: Data(data.utf8))
    let iOSDevices = listing.devices.keys
      .filter { $0.contains("iOS") }
      .sorted()
      .reversed()
      .flatMap { listing.devices[$0] ?? [] }
    guard let device = iOSDevices.first(where: { $0.state == "Booted" }) else {
      throw HotReloadError("No booted iOS Simulator. Boot one or pass --simulator <UDID>.")
    }
    return device.udid
  }
}

private struct SourceBatch {
  var structuralFileSetChangeReason: String?
  var changedFiles: [(url: URL, content: String)]
}

private struct SourceTreeWatcher {
  let roots: [URL]
  let excludedRoot: URL

  private struct FileStamp: Equatable {
    let modificationDate: Date?
    let fileSize: Int?
  }

  private static let ignoredDirectoryNames: Set<String> = [
    ".build", ".git", ".swiftpm", ".hotreload", ".lab-build", ".lab-output",
    "DerivedData", "build", "Build", "Carthage", "Pods", "SourcePackages",
    "xcuserdata", "node_modules", "prototypes", "tools", "scripts", "docs",
  ]

  private var stamps: [URL: FileStamp] = [:]
  private var lastSeenContents: [URL: String] = [:]

  init(roots: [URL], excludedRoot: URL) {
    self.roots = roots.map(\.standardizedFileURL)
    self.excludedRoot = excludedRoot.standardizedFileURL
  }

  mutating func snapshotAllFiles() throws -> [URL: String] {
    let discovered = discoverFiles()
    var result: [URL: String] = [:]
    var nextStamps: [URL: FileStamp] = [:]
    for (url, stamp) in discovered {
      guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
      result[url] = content
      nextStamps[url] = stamp
    }
    stamps = nextStamps
    lastSeenContents = result
    if result.isEmpty {
      throw HotReloadError("No Swift source files found under \(roots.map(\.path).joined(separator: ", "))")
    }
    return result
  }

  mutating func pollSettledChanges() async throws -> SourceBatch? {
    let firstScan = scanDelta()
    guard firstScan.hasChanges else { return nil }

    var latestScan = firstScan
    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(55))
      let nextScan = scanDelta()
      if nextScan == latestScan {
        break
      }
      latestScan = nextScan
    }

    guard latestScan.hasChanges else { return nil }

    stamps = latestScan.currentStamps
    for (url, content) in latestScan.changedContents {
      lastSeenContents[url] = content
    }
    for removed in latestScan.removedURLs {
      lastSeenContents.removeValue(forKey: removed)
    }

    let orderedChanges = latestScan.changedContents.keys
      .sorted { $0.path < $1.path }
      .compactMap { url -> (url: URL, content: String)? in
        guard let content = latestScan.changedContents[url] else { return nil }
        return (url: url, content: content)
      }

    var structuralReason: String?
    if !latestScan.addedURLs.isEmpty {
      let names = latestScan.addedURLs.map(\.lastPathComponent).sorted().joined(separator: ", ")
      structuralReason = "Added Swift file(s): \(names)"
    } else if !latestScan.removedURLs.isEmpty {
      let names = latestScan.removedURLs.map(\.lastPathComponent).sorted().joined(separator: ", ")
      structuralReason = "Removed Swift file(s): \(names)"
    }

    return SourceBatch(
      structuralFileSetChangeReason: structuralReason,
      changedFiles: orderedChanges
    )
  }

  private struct ScanDelta: Equatable {
    var currentStamps: [URL: FileStamp]
    var addedURLs: Set<URL>
    var removedURLs: Set<URL>
    var changedContents: [URL: String]

    var hasChanges: Bool {
      !addedURLs.isEmpty || !removedURLs.isEmpty || !changedContents.isEmpty
    }
  }

  private func scanDelta() -> ScanDelta {
    let discovered = discoverFiles()
    let previousKeys = Set(lastSeenContents.keys)
    let currentKeys = Set(discovered.keys)

    let added = currentKeys.subtracting(previousKeys)
    let removed = previousKeys.subtracting(currentKeys)
    var changed: [URL: String] = [:]

    let isSingleFileMode = roots.count == 1 && currentKeys.count == 1
    for (url, stamp) in discovered {
      let stampChanged = isSingleFileMode || stamps[url] != stamp || added.contains(url)
      guard stampChanged else { continue }
      guard let content = try? String(contentsOf: url, encoding: .utf8),
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      if content != lastSeenContents[url] {
        changed[url] = content
      }
    }

    return ScanDelta(
      currentStamps: discovered,
      addedURLs: added,
      removedURLs: removed,
      changedContents: changed
    )
  }

  private func discoverFiles() -> [URL: FileStamp] {
    let fm = FileManager.default
    var files: [URL: FileStamp] = [:]
    let resourceKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
    ]

    for root in roots {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
      if !isDir.boolValue {
        if root.pathExtension == "swift" {
          let values = try? root.resourceValues(forKeys: resourceKeys)
          files[root] = FileStamp(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize
          )
        }
        continue
      }

      guard
        let enumerator = fm.enumerator(
          at: root,
          includingPropertiesForKeys: Array(resourceKeys),
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else { continue }

      for case let fileURL as URL in enumerator {
        let standardized = fileURL.standardizedFileURL
        if standardized.path.hasPrefix(excludedRoot.path) {
          enumerator.skipDescendants()
          continue
        }
        let values = try? standardized.resourceValues(forKeys: resourceKeys)
        if values?.isDirectory == true {
          let name = standardized.lastPathComponent
          if Self.shouldIgnoreDirectory(named: name) {
            enumerator.skipDescendants()
          }
          continue
        }
        guard standardized.pathExtension == "swift",
          standardized.lastPathComponent != "Package.swift"
        else { continue }
        files[standardized] = FileStamp(
          modificationDate: values?.contentModificationDate,
          fileSize: values?.fileSize
        )
      }
    }
    return files
  }

  private static func shouldIgnoreDirectory(named name: String) -> Bool {
    if name.hasPrefix(".") { return true }
    if ignoredDirectoryNames.contains(name) { return true }
    if name.hasSuffix("Tests") || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
      || name.hasSuffix(".xcassets") || name.hasSuffix(".xcresult") || name.hasSuffix(".bundle")
      || name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".dSYM")
    {
      return true
    }
    return false
  }
}

private struct Session {
  let project: URL
  let scheme: String
  let platform: TargetPlatform
  let derivedData: URL
  let deviceID: String?
  let sessionDirectory: URL
  let runsXcodeGen: Bool
  let xcodeGenSpec: URL?
  let usesProjectBuildSettings: Bool
  let xcodebuild: String
  let launchArguments: [String]
  let launcher: MacAppLauncher

  private var manifest: URL { sessionDirectory.appending(path: "manifest.json") }
  private var receipt: URL { sessionDirectory.appending(path: "receipt.json") }
  private var projectDirectory: URL { project.deletingLastPathComponent() }
  private var appLog: URL { derivedData.appending(path: "hotreload-app.log") }

  private var baselines: [URL: String] = [:]
  private var settings: BuildSettings?
  private var generation = 0

  init(
    project: URL,
    scheme: String,
    platform: TargetPlatform,
    derivedData: URL,
    deviceID: String?,
    sessionDirectory: URL,
    runsXcodeGen: Bool,
    xcodeGenSpec: URL?,
    usesProjectBuildSettings: Bool,
    xcodebuild: String,
    launchArguments: [String],
    launcher: MacAppLauncher
  ) {
    self.project = project
    self.scheme = scheme
    self.platform = platform
    self.derivedData = derivedData
    self.deviceID = deviceID
    self.sessionDirectory = sessionDirectory
    self.runsXcodeGen = runsXcodeGen
    self.xcodeGenSpec = xcodeGenSpec
    self.usesProjectBuildSettings = usesProjectBuildSettings
    self.xcodebuild = xcodebuild
    self.launchArguments = launchArguments
    self.launcher = launcher
  }

  mutating func bootstrap(initialSources: [URL: String]) throws {
    baselines = initialSources
    if initialSources.count == 1, let (url, source) = initialSources.first,
      !ReplacementPlanner.hasReloadableDeclarations(in: source)
    {
      print(
        "[hotreload] warning: \(url.lastPathComponent) has no reloadable declarations; edits will trigger full rebuilds"
      )
    }
    try buildAndLaunch()
    print("[hotreload] baseline app is running")
  }

  mutating func replaceAllBaselines(with updated: [URL: String]) {
    baselines = updated
  }

  @discardableResult
  mutating func applyBatch(_ batch: SourceBatch) throws -> Bool {
    guard let settings else { throw HotReloadError("Build settings are unavailable") }

    if let structuralReason = batch.structuralFileSetChangeReason {
      print("[hotreload] rebuilding: \(structuralReason)")
      try buildAndLaunch()
      for (url, content) in batch.changedFiles {
        baselines[url] = content
      }
      print("[hotreload] rebuilt and relaunched")
      return true
    }

    guard !batch.changedFiles.isEmpty else { return false }

    if !platform.usesSimulator, !launcher.isRunning {
      print("[hotreload] app is no longer running; rebuilding and relaunching")
      try buildAndLaunch()
      for (url, content) in batch.changedFiles {
        baselines[url] = content
      }
      print("[hotreload] rebuilt and relaunched")
      return true
    }

    if generation == 0,
      batch.changedFiles.allSatisfy({ baselines[$0.url] == $0.content })
    {
      print("[hotreload] source matches running baseline")
      return false
    }

    let nextGeneration = generation + 1
    var replacements: [(url: URL, replacement: Replacement)] = []
    var rebuildReason: String?

    for (url, editedSource) in batch.changedFiles {
      guard let baselineSource = baselines[url] else {
        rebuildReason = "New file \(url.lastPathComponent) requires a rebuild"
        break
      }
      let plan = try ReplacementPlanner.plan(
        baseline: baselineSource,
        edited: editedSource,
        module: settings.moduleName,
        sourceFile: url.lastPathComponent,
        generation: nextGeneration
      )
      switch plan {
      case .replace(let replacement):
        replacements.append((url: url, replacement: replacement))
      case .rebuild(let reason):
        rebuildReason =
          batch.changedFiles.count > 1 ? "\(url.lastPathComponent): \(reason)" : reason
      }
      if rebuildReason != nil { break }
    }

    if let reason = rebuildReason {
      print("[hotreload] rebuilding: \(reason)")
      try buildAndLaunch()
      for (url, content) in batch.changedFiles {
        baselines[url] = content
      }
      print("[hotreload] rebuilt and relaunched")
      return true
    }

    if generation > 0, generation.isMultiple(of: 50) {
      print("[hotreload] rebuilding to reclaim loaded replacement images")
      try buildAndLaunch()
      for (url, content) in batch.changedFiles {
        baselines[url] = content
      }
      return true
    }

    let startedAt = ContinuousClock.now
    let artifact = try compileBatch(
      replacements: replacements,
      generation: nextGeneration,
      settings: settings
    )
    defer { try? FileManager.default.removeItem(at: artifact) }
    generation = nextGeneration

    var allDeclarations: [String] = []
    for (_, replacement) in replacements {
      for decl in replacement.declarations where !allDeclarations.contains(decl) {
        allDeclarations.append(decl)
      }
    }

    try publish(artifact: artifact, declarations: allDeclarations)
    let receipt = try waitForReceipt(generation: generation)
    if let error = receipt.error {
      throw HotReloadError("Runtime rejected generation \(generation): \(error)")
    }
    let duration = startedAt.duration(to: .now)
    let formattedDuration = duration.formatted(.units(allowed: [.seconds, .milliseconds]))
    print("[hotreload] generation \(generation) visible in \(formattedDuration)")
    return false
  }

  private mutating func buildAndLaunch() throws {
    if runsXcodeGen {
      var arguments = ["generate"]
      if let xcodeGenSpec {
        arguments += ["--spec", xcodeGenSpec.path, "--project", projectDirectory.path, "--quiet"]
      }
      try ProcessRunner.run("xcodegen", arguments, directory: projectDirectory)
    }

    if let deviceID, platform.usesSimulator {
      print("[hotreload] preparing simulator")
      try ProcessRunner.run("xcrun", ["simctl", "boot", deviceID], quiet: true, allowFailure: true)
      try ProcessRunner.run("xcrun", ["simctl", "bootstatus", deviceID, "-b"], quiet: true)
    }
    print("[hotreload] building baseline")
    try ProcessRunner.run(
      xcodebuild, buildArguments(command: "build"), directory: projectDirectory
    )

    print("[hotreload] reading build settings")
    let settingsJSON = try ProcessRunner.capture(
      "xcodebuild",
      buildArguments(command: "-showBuildSettings") + ["-json"],
      directory: projectDirectory
    )
    let jsonSubstring =
      settingsJSON.firstIndex(of: "[").map { settingsJSON[$0...] } ?? Substring(settingsJSON)
    let decoded = try JSONDecoder().decode(
      [BuildSettingsEnvelope].self, from: Data(jsonSubstring.utf8))
    let appEnvelopes = decoded.filter {
      $0.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.application"
    }
    guard
      let values =
        (appEnvelopes.first(where: {
          $0.target == scheme || $0.buildSettings["TARGET_NAME"] == scheme
        }) ?? appEnvelopes.first)?.buildSettings
    else {
      throw HotReloadError("xcodebuild returned no application build settings")
    }
    let sdk = try ProcessRunner.captureTrimmed(
      "xcrun", ["--sdk", platform.sdkName, "--show-sdk-path"])
    let swiftc = try ProcessRunner.captureTrimmed(
      "xcrun", ["--toolchain", "default", "--find", "swiftc"])
    let buildSettings = try BuildSettings(
      values: values, platform: platform, sdk: sdk, swiftc: swiftc)
    settings = buildSettings

    switch platform {
    case .iOSSimulator:
      guard let deviceID else { throw HotReloadError("No simulator selected") }
      print("[hotreload] installing baseline")
      try ProcessRunner.run(
        "xcrun", ["simctl", "install", deviceID, buildSettings.app.path], quiet: true)

      try? FileManager.default.removeItem(at: manifest)
      try? FileManager.default.removeItem(at: receipt)

      try ProcessRunner.run(
        "xcrun",
        [
          "simctl", "launch", "--terminate-running-process", deviceID,
          buildSettings.bundleIdentifier,
        ] + launchArguments,
        environment: [
          "SIMCTL_CHILD_HOTRELOAD_MANIFEST_PATH": manifest.path,
          "SIMCTL_CHILD_HOTRELOAD_RECEIPT_PATH": receipt.path,
        ],
        quiet: true
      )
    case .macOS:
      launcher.terminate()
      try? FileManager.default.removeItem(at: manifest)
      try? FileManager.default.removeItem(at: receipt)
      try launcher.launch(
        executable: buildSettings.executable,
        arguments: launchArguments,
        environment: [
          "HOTRELOAD_MANIFEST_PATH": manifest.path,
          "HOTRELOAD_RECEIPT_PATH": receipt.path,
        ],
        log: appLog
      )
      print("[hotreload] app output: \(appLog.path)")
    }
    print("[hotreload] launched baseline")
    generation = 0
  }

  private func buildArguments(command: String) -> [String] {
    let base = [
      command,
      "-quiet",
      "-project", project.path,
      "-scheme", scheme,
      "-derivedDataPath", derivedData.path,
      "-destination", platform.destination(deviceID: deviceID, architecture: hostArchitecture),
    ]
    if usesProjectBuildSettings { return base }
    return base + [
      "ENABLE_DEBUG_DYLIB=NO",
      "SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES",
      "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports",
      "OTHER_LDFLAGS=$(inherited) -Xlinker -export_dynamic",
    ]
  }

  private func compileBatch(
    replacements: [(url: URL, replacement: Replacement)],
    generation: Int,
    settings: BuildSettings
  ) throws -> URL {
    let artifactDirectory = sessionDirectory.appending(
      path: "Artifacts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    var tempFiles: [URL] = []
    var objectPaths: [String] = []
    defer {
      for file in tempFiles {
        try? FileManager.default.removeItem(at: file)
      }
    }

    for (index, item) in replacements.enumerated() {
      let stem = item.url.deletingPathExtension().lastPathComponent
      let base = replacements.count > 1 ? "\(stem).\(index).\(generation)" : "\(stem).\(generation)"
      let moduleName =
        replacements.count > 1
        ? "HotReloadThunk_\(generation)_\(index)" : "HotReloadThunk_\(generation)"
      let thunk = artifactDirectory.appending(path: "\(base).swift")
      let object = artifactDirectory.appending(path: "\(base).o")
      tempFiles.append(thunk)
      tempFiles.append(object)

      try item.replacement.source.write(to: thunk, atomically: true, encoding: .utf8)

      var compilerArguments =
        [
          "--sdk", platform.sdkName, "swiftc",
          "-emit-object", "-parse-as-library",
          "-module-name", moduleName,
          thunk.path,
          "-o", object.path,
          "-target",
          platform.targetTriple(
            architecture: settings.architecture, deploymentTarget: settings.deploymentTarget),
          "-swift-version", settings.swiftVersion,
          "-sdk", settings.sdk,
          "-I", settings.targetBuildDirectory.path,
        ] + settings.frameworkSearchFlags
        + settings.compilationConditions.flatMap { ["-D", $0] }
        + settings.compilerArguments
      if let strictConcurrency = settings.strictConcurrency {
        compilerArguments += ["-Xfrontend", "-strict-concurrency=\(strictConcurrency.lowercased())"]
      }
      try ProcessRunner.run("xcrun", compilerArguments)
      objectPaths.append(object.path)
    }

    let firstStem = replacements[0].url.deletingPathExtension().lastPathComponent
    let bundleName =
      replacements.count > 1 ? "Batch.\(generation).bundle" : "\(firstStem).\(generation).bundle"
    let bundle = artifactDirectory.appending(path: bundleName)

    try ProcessRunner.run(
      "xcrun",
      [
        "--sdk", platform.sdkName, "clang",
        "-bundle",
        "-arch", settings.architecture,
        "-isysroot", settings.sdk,
        platform.minimumVersionFlag(deploymentTarget: settings.deploymentTarget),
        "-bundle_loader", settings.executable.path,
        "-L", settings.swiftLibraries.path,
        "-rpath", "/usr/lib/swift",
      ] + settings.frameworkSearchFlags + [
        "-o", bundle.path,
      ] + objectPaths)
    return bundle
  }

  private func publish(artifact: URL, declarations: [String]) throws {
    let primary = declarations.first ?? ""
    let command = ReloadCommand(
      generation: generation,
      artifactPath: artifact.path,
      declaration: primary,
      declarations: declarations
    )
    try JSONEncoder().encode(command).write(to: manifest, options: .atomic)
  }

  private func waitForReceipt(generation: Int) throws -> ReloadReceipt {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while ContinuousClock.now < deadline {
      if let data = try? Data(contentsOf: receipt),
        let value = try? JSONDecoder().decode(ReloadReceipt.self, from: data),
        value.generation == generation
      {
        return value
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw HotReloadError("Timed out waiting for generation \(generation) to load")
  }
}

private struct BuildSettingsEnvelope: Decodable {
  let target: String?
  let buildSettings: [String: String]
}

private struct BuildSettings {
  let moduleName: String
  let bundleIdentifier: String
  let deploymentTarget: String
  let architecture: String
  let swiftVersion: String
  let strictConcurrency: String?
  let compilationConditions: [String]
  let targetBuildDirectory: URL
  let app: URL
  let executable: URL
  let sdk: String
  let swiftLibraries: URL
  let frameworkSearchFlags: [String]
  let compilerArguments: [String]

  init(values: [String: String], platform: TargetPlatform, sdk: String, swiftc: String) throws {
    func required(_ key: String) throws -> String {
      guard let value = values[key], !value.isEmpty else {
        throw HotReloadError("Missing Xcode build setting \(key)")
      }
      return value
    }

    moduleName = try required("PRODUCT_MODULE_NAME")
    bundleIdentifier = try required("PRODUCT_BUNDLE_IDENTIFIER")
    deploymentTarget = try required(platform.deploymentTargetSetting)
    architecture = values["NATIVE_ARCH_ACTUAL"] ?? "arm64"
    let configuredSwiftVersion = values["SWIFT_VERSION"] ?? "6"
    swiftVersion =
      configuredSwiftVersion.hasSuffix(".0")
      ? String(configuredSwiftVersion.dropLast(2)) : configuredSwiftVersion
    strictConcurrency = values["SWIFT_STRICT_CONCURRENCY"]
    compilationConditions = (values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "DEBUG")
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    targetBuildDirectory = URL(fileURLWithPath: try required("TARGET_BUILD_DIR"))

    var frameworkFlags = ["-F", targetBuildDirectory.path]
    let packageFrameworks = targetBuildDirectory.appending(
      path: "PackageFrameworks", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: packageFrameworks.path) {
      frameworkFlags += ["-F", packageFrameworks.path]
    }
    frameworkFlags += Self.searchPaths(in: values["FRAMEWORK_SEARCH_PATHS"], flag: "-F")
    frameworkSearchFlags = frameworkFlags

    var swiftArgs =
      Self.arguments(in: values["OTHER_SWIFT_FLAGS"])
      + Self.searchPaths(in: values["SWIFT_INCLUDE_PATHS"], flag: "-I")
    let includeDirectory = targetBuildDirectory.appending(
      path: "include", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: includeDirectory.path) {
      swiftArgs += ["-I", includeDirectory.path, "-Xcc", "-I\(includeDirectory.path)"]
    }
    if let objectDirNormal = values["OBJECT_FILE_DIR_normal"] {
      let archObjectDir = URL(fileURLWithPath: objectDirNormal)
        .appending(path: architecture, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: archObjectDir.path) {
        swiftArgs += ["-I", archObjectDir.path]
      }
    }
    if values["SWIFT_DEFAULT_ACTOR_ISOLATION"] == "MainActor",
      !swiftArgs.contains("-default-isolation=MainActor")
    {
      swiftArgs += ["-default-isolation=MainActor"]
    }
    if values["SWIFT_APPROACHABLE_CONCURRENCY"] == "YES" {
      if !swiftArgs.contains("InferIsolatedConformances") {
        swiftArgs += ["-enable-upcoming-feature", "InferIsolatedConformances"]
      }
      if !swiftArgs.contains("NonisolatedNonsendingByDefault") {
        swiftArgs += ["-enable-upcoming-feature", "NonisolatedNonsendingByDefault"]
      }
    }
    if values["SWIFT_ENABLE_OPAQUE_TYPE_ERASURE"] == "YES",
      !swiftArgs.contains("OpaqueTypeErasure")
    {
      swiftArgs += ["-enable-experimental-feature", "OpaqueTypeErasure"]
    }
    if let bridgingHeader = values["SWIFT_OBJC_BRIDGING_HEADER"],
      !bridgingHeader.isEmpty,
      !swiftArgs.contains("-import-objc-header")
    {
      let srcRoot = URL(
        fileURLWithPath: values["SRCROOT"] ?? values["PROJECT_DIR"]
          ?? FileManager.default.currentDirectoryPath
      )
      let headerURL = resolve(bridgingHeader, relativeTo: srcRoot)
      if FileManager.default.fileExists(atPath: headerURL.path) {
        swiftArgs += ["-import-objc-header", headerURL.path]
      }
    }
    compilerArguments = swiftArgs

    let fullProductName = try required("FULL_PRODUCT_NAME")
    app = targetBuildDirectory.appending(path: fullProductName, directoryHint: .isDirectory)
    executable = targetBuildDirectory.appending(
      path: platform.executableRelativePath(
        executablePath: values["EXECUTABLE_PATH"],
        fullProductName: fullProductName,
        executableName: try required("EXECUTABLE_NAME")
      ))
    self.sdk = sdk
    swiftLibraries = platform.swiftLibraryDirectory(swiftc: swiftc)
  }

  private static func searchPaths(in value: String?, flag: String) -> [String] {
    guard let value else { return [] }
    let cleaned = value.replacingOccurrences(of: "$(inherited)", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
    if !cleaned.contains("\""), !cleaned.contains("'"),
      FileManager.default.fileExists(atPath: cleaned)
    {
      return [flag, cleaned]
    }
    return arguments(in: cleaned).flatMap { [flag, $0] }
  }

  private static func arguments(in value: String?) -> [String] {
    guard let value else { return [] }
    var arguments: [String] = []
    var argument = ""
    var quote: Character?
    var escaped = false

    for character in value {
      if escaped {
        argument.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if let activeQuote = quote {
        if character == activeQuote { quote = nil } else { argument.append(character) }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character.isWhitespace {
        if !argument.isEmpty {
          arguments.append(argument)
          argument = ""
        }
      } else {
        argument.append(character)
      }
    }
    if escaped { argument.append("\\") }
    if !argument.isEmpty { arguments.append(argument) }
    return arguments.filter { $0 != "$(inherited)" }
  }
}

private struct SimulatorListing: Decodable {
  struct Device: Decodable {
    let udid: String
    let state: String
  }

  let devices: [String: [Device]]
}

private enum ProcessRunner {
  static func run(
    _ executable: String,
    _ arguments: [String],
    directory: URL? = nil,
    environment: [String: String] = [:],
    quiet: Bool = false,
    allowFailure: Bool = false
  ) throws {
    _ = try execute(
      executable,
      arguments,
      directory: directory,
      environment: environment,
      capturesOutput: quiet,
      allowFailure: allowFailure
    )
  }

  static func capture(_ executable: String, _ arguments: [String], directory: URL? = nil) throws
    -> String
  {
    try execute(executable, arguments, directory: directory, capturesOutput: true)
  }

  static func captureTrimmed(
    _ executable: String, _ arguments: [String], directory: URL? = nil
  ) throws -> String {
    try capture(executable, arguments, directory: directory)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func execute(
    _ executable: String,
    _ arguments: [String],
    directory: URL? = nil,
    environment: [String: String] = [:],
    capturesOutput: Bool,
    allowFailure: Bool = false
  ) throws -> String {
    let process = Process()
    let output = Pipe()
    let errorURL =
      capturesOutput
      ? FileManager.default.temporaryDirectory.appending(
        path: "hotreload-process-\(UUID().uuidString).log") : nil
    if let errorURL {
      FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    }
    let errorHandle = try errorURL.map(FileHandle.init(forWritingTo:))
    defer {
      try? errorHandle?.close()
      if let errorURL { try? FileManager.default.removeItem(at: errorURL) }
    }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    if capturesOutput {
      process.standardOutput = output
      process.standardError = errorHandle
    }

    try process.run()
    let data = capturesOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    try? errorHandle?.synchronize()
    let errorData = errorURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let errorText = String(decoding: errorData, as: UTF8.self)
    guard process.terminationStatus == 0 || allowFailure else {
      throw HotReloadError(
        "\(executable) failed (\(process.terminationStatus))\n\(text)\(errorText)")
    }
    return text
  }
}

#if arch(arm64)
  private let hostArchitecture = "arm64"
#else
  private let hostArchitecture = "x86_64"
#endif

/// Owns the native macOS app process a `--platform macos` session launches.
///
/// The app is spawned directly (not through LaunchServices), so the session
/// always knows the exact process it published replacements to, and a second
/// copy with the same bundle identifier never activates instead. It runs in its
/// own session, so closing the terminal or SSH connection that started
/// `hotreload` doesn't hang it up; the session terminates it on exit instead.
private final class MacAppLauncher: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: pid_t?

  var isRunning: Bool {
    lock.withLock {
      guard let pid else { return false }
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == 0 { return true }
      self.pid = nil
      return false
    }
  }

  func launch(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    log: URL
  ) throws {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(
      &fileActions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let mergedEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp = mergedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }

    var child: pid_t = 0
    let result = posix_spawn(&child, executable.path, &fileActions, &attributes, argv, envp)
    guard result == 0 else {
      throw HotReloadError(
        "Couldn't launch \(executable.path): \(String(cString: strerror(result)))")
    }
    lock.withLock { pid = child }
  }

  /// Sends SIGTERM, waits up to three seconds, then SIGKILL.
  func terminate() {
    guard let pid = lock.withLock({ () -> pid_t? in
      defer { self.pid = nil }
      return self.pid
    }) else { return }
    var status: Int32 = 0
    guard waitpid(pid, &status, WNOHANG) == 0 else { return }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if waitpid(pid, &status, WNOHANG) != 0 { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    kill(pid, SIGKILL)
    waitpid(pid, &status, 0)
  }
}

private struct HotReloadError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private func resolve(_ path: String, relativeTo root: URL) -> URL {
  if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
  return root.appending(path: path).standardizedFileURL
}
