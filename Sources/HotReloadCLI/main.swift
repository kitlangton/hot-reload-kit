import ArgumentParser
import Foundation
import HotReloadCore
import HotReloadProtocol

@main
struct HotReloadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hotreload",
    abstract: "Hot-reload safe Swift body edits in an iOS Simulator.",
    version: "0.1.0"
  )

  @Option(help: "Path to the Xcode project.")
  var project: String

  @Option(help: "Scheme and application target to build.")
  var scheme: String

  @Option(help: "Swift source file containing one reloadable computed body.")
  var source: String

  @Option(help: "Simulator UDID. Defaults to a booted simulator.")
  var simulator: String?

  @Option(help: "DerivedData directory.")
  var derivedData = FileManager.default.temporaryDirectory
    .appending(path: "HotReloadKitDerivedData", directoryHint: .isDirectory).path

  @Flag(help: "Run xcodegen before the initial build and structural rebuilds.")
  var xcodegen = false

  @Flag(help: "Use hot-reload compiler and linker settings already defined by the application target.")
  var useProjectBuildSettings = false

  mutating func run() async throws {
    setbuf(stdout, nil)
    setbuf(stderr, nil)

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let projectURL = resolve(project, relativeTo: root)
    let sourceURL = resolve(source, relativeTo: root)
    let derivedDataURL = resolve(derivedData, relativeTo: root)

    guard FileManager.default.fileExists(atPath: projectURL.path) else {
      throw HotReloadError("Project not found at \(projectURL.path)")
    }
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw HotReloadError("Source file not found at \(sourceURL.path)")
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
    let signalSources = Self.installSignalCleanup(removing: sessionURL)
    defer { signalSources.forEach { $0.cancel() } }

    let deviceID = try simulator ?? Self.bootedSimulatorID()
    var session = Session(
      project: projectURL,
      scheme: scheme,
      source: sourceURL,
      derivedData: derivedDataURL,
      deviceID: deviceID,
      sessionDirectory: sessionURL,
      runsXcodeGen: xcodegen,
      usesProjectBuildSettings: useProjectBuildSettings
    )
    try session.bootstrap()

    print("[hotreload] watching \(sourceURL.path) (Ctrl-C to stop)")
    var lastSeenSource = try String(contentsOf: sourceURL, encoding: .utf8)

    while true {
      try await Task.sleep(for: .milliseconds(150))
      guard let initialRead = try? String(contentsOf: sourceURL, encoding: .utf8),
        !initialRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        initialRead != lastSeenSource
      else { continue }

      var edited = initialRead
      for _ in 0..<6 {
        try await Task.sleep(for: .milliseconds(50))
        guard let latest = try? String(contentsOf: sourceURL, encoding: .utf8),
          !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { break }
        if latest == edited { break }
        edited = latest
      }
      guard edited != lastSeenSource else { continue }
      lastSeenSource = edited

      do {
        try session.apply(editedSource: edited)
      } catch {
        print("[hotreload] \(error)")
      }
    }
  }

  private static func installSignalCleanup(removing sessionURL: URL) -> [any DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler {
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

private struct Session {
  let project: URL
  let scheme: String
  let source: URL
  let derivedData: URL
  let deviceID: String
  let sessionDirectory: URL
  let runsXcodeGen: Bool
  let usesProjectBuildSettings: Bool

  private var manifest: URL { sessionDirectory.appending(path: "manifest.json") }
  private var receipt: URL { sessionDirectory.appending(path: "receipt.json") }
  private var projectDirectory: URL { project.deletingLastPathComponent() }

  private var baseline = ""
  private var settings: BuildSettings?
  private var generation = 0

  init(
    project: URL,
    scheme: String,
    source: URL,
    derivedData: URL,
    deviceID: String,
    sessionDirectory: URL,
    runsXcodeGen: Bool,
    usesProjectBuildSettings: Bool
  ) {
    self.project = project
    self.scheme = scheme
    self.source = source
    self.derivedData = derivedData
    self.deviceID = deviceID
    self.sessionDirectory = sessionDirectory
    self.runsXcodeGen = runsXcodeGen
    self.usesProjectBuildSettings = usesProjectBuildSettings
  }

  mutating func bootstrap() throws {
    baseline = try String(contentsOf: source, encoding: .utf8)
    if !ReplacementPlanner.hasSingleReloadableBody(in: baseline) {
      print(
        "[hotreload] warning: \(source.lastPathComponent) does not have a single reloadable body; edits will trigger full rebuilds"
      )
    }
    try buildAndLaunch()
    print("[hotreload] baseline app is running")
  }

  mutating func apply(editedSource: String) throws {
    guard let settings else { throw HotReloadError("Build settings are unavailable") }
    if generation == 0, editedSource == baseline {
      print("[hotreload] source matches running baseline")
      return
    }
    let nextGeneration = generation + 1
    let plan = try ReplacementPlanner.plan(
      baseline: baseline,
      edited: editedSource,
      module: settings.moduleName,
      sourceFile: source.lastPathComponent,
      generation: nextGeneration
    )

    switch plan {
    case .replace(let replacement):
      if generation > 0, generation.isMultiple(of: 50) {
        print("[hotreload] rebuilding to reclaim loaded replacement images")
        try buildAndLaunch()
        baseline = editedSource
        return
      }
      let startedAt = ContinuousClock.now
      let artifact = try compile(
        replacement: replacement, generation: nextGeneration, settings: settings)
      defer { try? FileManager.default.removeItem(at: artifact) }
      generation = nextGeneration
      try publish(artifact: artifact, declaration: replacement.declaration)
      let receipt = try waitForReceipt(generation: generation)
      if let error = receipt.error {
        throw HotReloadError("Runtime rejected generation \(generation): \(error)")
      }
      let duration = startedAt.duration(to: .now)
      print(
        "[hotreload] generation \(generation) visible in \(duration.formatted(.units(allowed: [.seconds, .milliseconds])))"
      )

    case .rebuild(let reason):
      print("[hotreload] rebuilding: \(reason)")
      try buildAndLaunch()
      baseline = editedSource
      print("[hotreload] rebuilt and relaunched")
    }
  }

  private mutating func buildAndLaunch() throws {
    if runsXcodeGen {
      try ProcessRunner.run(
        "xcodegen", ["generate"], directory: projectDirectory)
    }

    print("[hotreload] preparing simulator")
    try ProcessRunner.run("xcrun", ["simctl", "boot", deviceID], quiet: true, allowFailure: true)
    try ProcessRunner.run("xcrun", ["simctl", "bootstatus", deviceID, "-b"], quiet: true)
    print("[hotreload] building baseline")
    try ProcessRunner.run(
      "xcodebuild", buildArguments(command: "build"), directory: projectDirectory
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
      "xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
    let swiftc = try ProcessRunner.captureTrimmed(
      "xcrun", ["--toolchain", "default", "--find", "swiftc"])
    let buildSettings = try BuildSettings(values: values, sdk: sdk, swiftc: swiftc)
    settings = buildSettings

    print("[hotreload] installing baseline")
    try ProcessRunner.run(
      "xcrun", ["simctl", "install", deviceID, buildSettings.app.path], quiet: true)

    try? FileManager.default.removeItem(at: manifest)
    try? FileManager.default.removeItem(at: receipt)

    try ProcessRunner.run(
      "xcrun",
      [
        "simctl", "launch", "--terminate-running-process", deviceID, buildSettings.bundleIdentifier,
      ],
      environment: [
        "SIMCTL_CHILD_HOTRELOAD_MANIFEST_PATH": manifest.path,
        "SIMCTL_CHILD_HOTRELOAD_RECEIPT_PATH": receipt.path,
      ],
      quiet: true
    )
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
      "-destination", "platform=iOS Simulator,id=\(deviceID)",
    ]
    if usesProjectBuildSettings { return base }
    return base + [
      "ENABLE_DEBUG_DYLIB=NO",
      "SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES",
      "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports",
      "OTHER_LDFLAGS=$(inherited) -Xlinker -export_dynamic",
    ]
  }

  private func compile(replacement: Replacement, generation: Int, settings: BuildSettings) throws
    -> URL
  {
    let artifactDirectory = sessionDirectory.appending(
      path: "Artifacts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let base = "\(source.deletingPathExtension().lastPathComponent).\(generation)"
    let thunk = artifactDirectory.appending(path: "\(base).swift")
    let object = artifactDirectory.appending(path: "\(base).o")
    let bundle = artifactDirectory.appending(path: "\(base).bundle")
    defer {
      try? FileManager.default.removeItem(at: thunk)
      try? FileManager.default.removeItem(at: object)
    }
    try replacement.source.write(to: thunk, atomically: true, encoding: .utf8)

    var compilerArguments =
      [
        "--sdk", "iphonesimulator", "swiftc",
        "-emit-object", "-parse-as-library",
        "-module-name", "HotReloadThunk_\(generation)",
        thunk.path,
        "-o", object.path,
        "-target", "\(settings.architecture)-apple-ios\(settings.deploymentTarget)-simulator",
        "-swift-version", settings.swiftVersion,
        "-sdk", settings.sdk,
        "-I", settings.targetBuildDirectory.path,
      ] + settings.frameworkSearchFlags
      + settings.compilationConditions.flatMap { ["-D", $0] }
      + settings.compilerArguments
    if let strictConcurrency = settings.strictConcurrency {
      compilerArguments += ["-Xfrontend", "-strict-concurrency=\(strictConcurrency.lowercased())"]
    }
    try ProcessRunner.run(
      "xcrun",
      compilerArguments
    )

    try ProcessRunner.run(
      "xcrun",
      [
        "--sdk", "iphonesimulator", "clang",
        "-bundle",
        "-arch", settings.architecture,
        "-isysroot", settings.sdk,
        "-mios-simulator-version-min=\(settings.deploymentTarget)",
        "-bundle_loader", settings.executable.path,
        "-L", settings.swiftLibraries.path,
        "-rpath", "/usr/lib/swift",
      ] + settings.frameworkSearchFlags + [
        "-o", bundle.path,
        object.path,
      ])
    return bundle
  }

  private func publish(artifact: URL, declaration: String) throws {
    let command = ReloadCommand(
      generation: generation,
      artifactPath: artifact.path,
      declaration: declaration
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

  init(values: [String: String], sdk: String, swiftc: String) throws {
    func required(_ key: String) throws -> String {
      guard let value = values[key], !value.isEmpty else {
        throw HotReloadError("Missing Xcode build setting \(key)")
      }
      return value
    }

    moduleName = try required("PRODUCT_MODULE_NAME")
    bundleIdentifier = try required("PRODUCT_BUNDLE_IDENTIFIER")
    deploymentTarget = try required("IPHONEOS_DEPLOYMENT_TARGET")
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
    if values["SWIFT_DEFAULT_ACTOR_ISOLATION"] == "MainActor",
      !swiftArgs.contains("-default-isolation=MainActor")
    {
      swiftArgs += ["-default-isolation=MainActor"]
    }
    if values["SWIFT_ENABLE_OPAQUE_TYPE_ERASURE"] == "YES",
      !swiftArgs.contains("OpaqueTypeErasure")
    {
      swiftArgs += ["-enable-experimental-feature", "OpaqueTypeErasure"]
    }
    compilerArguments = swiftArgs

    app = targetBuildDirectory.appending(
      path: try required("FULL_PRODUCT_NAME"), directoryHint: .isDirectory)
    executable = app.appending(path: try required("EXECUTABLE_NAME"))
    self.sdk = sdk
    swiftLibraries = URL(fileURLWithPath: swiftc)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "lib/swift/iphonesimulator")
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
