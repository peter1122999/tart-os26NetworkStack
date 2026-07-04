import ArgumentParser

/// The legacy `tart ip` resolution strategies. Lives here (rather than in the "tart"
/// executable's `IP` command) so `VmnetIPResolver`'s tier-3 fallback can reference it
/// without depending on the CLI target.
public enum IPResolutionStrategy: String, ExpressibleByArgument, CaseIterable {
  case dhcp, arp, agent

  public private(set) static var allValueStrings: [String] = Self.allCases.map { "\($0)" }
}
