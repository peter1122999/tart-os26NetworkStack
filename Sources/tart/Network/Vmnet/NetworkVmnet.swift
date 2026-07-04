import Foundation
import Semaphore
import Virtualization
import vmnet

/// `Network` implementation backed by `VZVmnetNetworkDeviceAttachment`, i.e. the custom
/// vmnet topology introduced in macOS 26. Slots into the exact same `Network` protocol
/// that `NetworkShared`, `NetworkBridged` and `Softnet` already implement, so `VM.swift`
/// and `Run.swift` don't need to know vmnet exists beyond choosing to construct this type.
///
/// Unlike `Softnet`, there's no child process to babysit: the vmnet network lives
/// in-process, owned by the Virtualization.framework attachment. `run(_:)` therefore just
/// records the runtime state (actual subnet, start time) instead of spawning anything.
@available(macOS 26.0, *)
class NetworkVmnet: Network {
  let config: VmnetConfig
  let network: vmnet_network_ref

  private let vmName: String
  private let macAddress: String?
  private let stateStore: VmnetStateStore?
  private let attachment: VZVmnetNetworkDeviceAttachment

  /// - Parameters:
  ///   - config: must have already passed `VmnetValidator.validate(_:)`; this initializer
  ///     re-validates defensively (cheap, pure) but callers should validate up front so
  ///     mistakes are reported before any process/VM state has been touched.
  ///   - vmName: used to key the shared `VmnetStateStore` and `VmnetPolicyHooks` entries.
  ///   - macAddress: the VM's MAC address, so the state store can correlate resolved IPs
  ///     back to a VM for the policy integration hooks (`endpointMappings()` etc).
  ///   - stateStore: injected for testability; production callers use `VmnetStateStore.shared`.
  init(config: VmnetConfig, vmName: String, macAddress: String? = nil, stateStore: VmnetStateStore? = .shared) throws {
    try VmnetValidator.validate(config).throwIfInvalid()

    self.config = config
    self.vmName = vmName
    self.macAddress = macAddress
    self.stateStore = stateStore

    let nativeConfig = try VmnetNativeBridge.buildConfiguration(from: config)
    let network = try VmnetNativeBridge.createNetwork(from: nativeConfig)

    // vmnet.h documents both objects as CF_RETURNS_RETAINED ("Use CFRelease() to
    // release..."), but Swift's importer recognizes vmnet_network_(configuration_)ref as
    // CF-managed and handles retain/release automatically — calling CFRelease() manually
    // is in fact a compile error ("Core Foundation objects are automatically memory
    // managed"). `nativeConfig` simply falls out of scope once this initializer returns.
    self.network = network
    self.attachment = VmnetNativeBridge.makeAttachment(network: network)
  }

  func attachments() -> [VZNetworkDeviceAttachment] {
    [attachment]
  }

  func run(_ sema: AsyncSemaphore) throws {
    guard let stateStore = stateStore else { return }

    var runtimeState = VmnetRuntimeState(vmName: vmName)
    runtimeState.actualSubnet = VmnetNativeBridge.actualSubnet(of: network) ?? config.subnet
    runtimeState.gatewayAddress = runtimeState.actualSubnet?.address.debugDescription
    runtimeState.interfaceStartedAt = Date()

    let capturedState = runtimeState
    let vmName = self.vmName
    let macAddress = self.macAddress
    let config = self.config
    Task {
      await stateStore.publish(vmName: vmName, config: config, macAddress: macAddress)
      await stateStore.update(capturedState)
    }
  }

  func stop() async throws {
    await stateStore?.remove(vmName: vmName)
    // `network` is released automatically once this instance (and the attachment, which
    // shares ownership of it) are deallocated — see the note in init().
  }
}

/// Factory used by `Run.swift` (and, in principle, any other caller that needs a vmnet
/// network) so callers don't have to sprinkle `#available(macOS 26, *)` checks and
/// `NetworkVmnet` construction throughout the CLI layer. Fails fast with a structured
/// `VmnetError.unsupportedOSVersion` on older hosts, per the "fail fast on unsupported
/// systems" requirement, instead of letting the type system's availability check turn
/// into an opaque compiler error or a runtime trap.
enum VmnetNetworkFactory {
  static func make(config: VmnetConfig, vmName: String, macAddress: String? = nil) throws -> Network {
    guard #available(macOS 26.0, *) else {
      throw VmnetError.unsupportedOSVersion(
        required: NetworkMode.vmnet.minimumSupportedOSVersion!,
        current: PlatformVersion(ProcessInfo.processInfo.operatingSystemVersion)
      )
    }

    return try NetworkVmnet(config: config, vmName: vmName, macAddress: macAddress)
  }
}
