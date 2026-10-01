## Native process inspection for child-survivor assertions.
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

when defined(macosx):
  package ps:
    provisioning:
      nixPackage "nixpkgs#darwin.ps", executablePath = "bin/ps",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash
else:
  package ps:
    provisioning:
      nixPackage "nixpkgs#procps", executablePath = "bin/ps",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash
