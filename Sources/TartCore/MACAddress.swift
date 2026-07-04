import Foundation

public struct MACAddress: Equatable, Hashable, CustomStringConvertible {
  public var mac: [UInt8] = Array(repeating: 0, count: 6)

  public init?(fromString: String) {
    let components = fromString.components(separatedBy: ":")

    if components.count != 6 {
      return nil
    }

    for (index, component) in components.enumerated() {
      mac[index] = UInt8(component, radix: 16)!
    }
  }

  public var description: String {
    String(format: "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
  }
}
