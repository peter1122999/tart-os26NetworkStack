import Virtualization

@available(macOS 13, *)
public struct Linux: Platform {
  public init() {}

  public func os() -> OS {
    .linux
  }

  public func bootLoader(nvramURL: URL) throws -> VZBootLoader {
    let result = VZEFIBootLoader()

    result.variableStore = VZEFIVariableStore(url: nvramURL)

    return result
  }

  public func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
    let config = VZGenericPlatformConfiguration()
    if #available(macOS 15, *) {
      config.isNestedVirtualizationEnabled = needsNestedVirtualization
    }
    return config
  }

  public func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
    let result = VZVirtioGraphicsDeviceConfiguration()

    result.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: vmConfig.display.width,
        heightInPixels: vmConfig.display.height
      )
    ]

    return result
  }

  public func keyboards() -> [VZKeyboardConfiguration] {
    [VZUSBKeyboardConfiguration()]
  }

  public func pointingDevices() -> [VZPointingDeviceConfiguration] {
    [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }

  public func pointingDevicesSimplified() -> [VZPointingDeviceConfiguration] {
    // Linux doesn't support trackpad, so just return the regular pointing devices
    return pointingDevices()
  }
}
