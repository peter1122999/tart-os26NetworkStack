import Virtualization

public struct UnsupportedHostOSError: Error, CustomStringConvertible {
  public var description: String {
    "error: host macOS version is outdated to run this virtual machine"
  }
}

#if arch(arm64)

  public struct Darwin: PlatformSuspendable {
    public var ecid: VZMacMachineIdentifier
    public var hardwareModel: VZMacHardwareModel

    public init(ecid: VZMacMachineIdentifier, hardwareModel: VZMacHardwareModel) {
      self.ecid = ecid
      self.hardwareModel = hardwareModel
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      let encodedECID = try container.decode(String.self, forKey: .ecid)
      guard let data = Data.init(base64Encoded: encodedECID) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize Data using the provided value")
      }
      guard let ecid = VZMacMachineIdentifier.init(dataRepresentation: data) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize VZMacMachineIdentifier using the provided value")
      }
      self.ecid = ecid

      let encodedHardwareModel = try container.decode(String.self, forKey: .hardwareModel)
      guard let data = Data.init(base64Encoded: encodedHardwareModel) else {
        throw DecodingError.dataCorruptedError(forKey: .hardwareModel, in: container, debugDescription: "")
      }
      guard let hardwareModel = VZMacHardwareModel.init(dataRepresentation: data) else {
        throw UnsupportedHostOSError()
      }
      self.hardwareModel = hardwareModel
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(ecid.dataRepresentation.base64EncodedString(), forKey: .ecid)
      try container.encode(hardwareModel.dataRepresentation.base64EncodedString(), forKey: .hardwareModel)
    }

    public func os() -> OS {
      .darwin
    }

    public func bootLoader(nvramURL: URL) throws -> VZBootLoader {
      VZMacOSBootLoader()
    }

    public func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
      if needsNestedVirtualization {
        throw RuntimeError.VMConfigurationError("macOS virtual machines do not support nested virtualization")
      }

      let result = VZMacPlatformConfiguration()

      result.machineIdentifier = ecid
      result.auxiliaryStorage = VZMacAuxiliaryStorage(url: nvramURL)

      if !hardwareModel.isSupported {
        // At the moment support of M1 chip is not yet dropped in any macOS version
        // This mean that host software is not supporting this hardware model and should be updated
        throw UnsupportedHostOSError()
      }

      result.hardwareModel = hardwareModel

      return result
    }

    public func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
      let result = VZMacGraphicsDeviceConfiguration()

      if (vmConfig.display.unit ?? .point) == .point, let hostMainScreen = NSScreen.main {
        let vmScreenSize = NSSize(width: vmConfig.display.width, height: vmConfig.display.height)
        result.displays = [
          VZMacGraphicsDisplayConfiguration(for: hostMainScreen, sizeInPoints: vmScreenSize)
        ]

        return result
      }

      result.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: vmConfig.display.width,
          heightInPixels: vmConfig.display.height,
          // A reasonable guess according to Apple's documentation[1]
          // [1]: https://developer.apple.com/documentation/coregraphics/1456599-cgdisplayscreensize
          pixelsPerInch: 72
        )
      ]

      return result
    }

    public func keyboards() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        // Mac keyboard is only supported by guests starting with macOS Ventura
        return [VZUSBKeyboardConfiguration(), VZMacKeyboardConfiguration()]
      } else {
        return [VZUSBKeyboardConfiguration()]
      }
    }

    public func keyboardsSuspendable() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacKeyboardConfiguration()]
      } else {
        // fallback to the regular configuration
        return keyboards()
      }
    }

    public func pointingDevices() -> [VZPointingDeviceConfiguration] {
      // Trackpad is only supported by guests starting with macOS Ventura
      [VZUSBScreenCoordinatePointingDeviceConfiguration(), VZMacTrackpadConfiguration()]
    }

    public func pointingDevicesSimplified() -> [VZPointingDeviceConfiguration] {
      // Only include the USB pointing device, not the trackpad
      return [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    public func pointingDevicesSuspendable() -> [VZPointingDeviceConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacTrackpadConfiguration()]
      } else {
        // fallback to the regular configuration
        return pointingDevices()
      }
    }
  }

#endif
