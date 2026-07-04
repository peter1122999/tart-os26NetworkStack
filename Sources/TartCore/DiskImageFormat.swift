import Foundation
import ArgumentParser

public enum DiskImageFormat: String, CaseIterable, Codable {
  case raw = "raw"
  case asif = "asif"

  public var displayName: String {
    switch self {
    case .raw:
      return "RAW"
    case .asif:
      return "ASIF (Apple Sparse Image Format)"
    }
  }


  /// Check if the format is supported on the current system
  public var isSupported: Bool {
    switch self {
    case .raw:
      return true
    case .asif:
      if #available(macOS 26, *) {
        return true
      } else {
        return false
      }
    }
  }


}

extension DiskImageFormat: ExpressibleByArgument {
  public init?(argument: String) {
    self.init(rawValue: argument.lowercased())
  }

  public static var allValueStrings: [String] {
    return allCases.map { $0.rawValue }
  }
}
