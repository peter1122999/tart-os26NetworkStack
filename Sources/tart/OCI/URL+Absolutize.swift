import Foundation
import TartCore

extension URL {
  func absolutize(_ baseURL: URL) -> Self {
    URL(string: absoluteString, relativeTo: baseURL)!
  }
}
