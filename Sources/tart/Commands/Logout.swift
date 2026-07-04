import ArgumentParser
import Dispatch
import SwiftUI
import TartCore

struct Logout: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Logout from a registry")

  @Argument(help: "host")
  var host: String

  func run() async throws {
    try KeychainCredentialsProvider().remove(host: host)
  }
}
