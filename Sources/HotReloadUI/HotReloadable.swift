@_exported import HotReloadRuntime

@attached(member, names: named(__hotReload))
public macro HotReloadable() =
  #externalMacro(
    module: "HotReloadMacros",
    type: "HotReloadableMacro"
  )
