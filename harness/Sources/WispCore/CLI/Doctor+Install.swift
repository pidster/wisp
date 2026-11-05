import Foundation

extension Doctor {
    /// The `install` finding: which install the running `wisp` is, and whether the move from Homebrew's formula to its
    /// cask finished ([ADR 0084](../../../../docs/decisions/0084-homebrew-installs-the-app-from-a-cask.md), decision 7).
    /// The formula fails, since it ends at 0.34.2; from `Wisp.app`, the formula's `wisp` still first on `PATH` fails,
    /// the move unfinished, and its keg left installed behind the cask is named for removal.
    ///
    /// - Returns: The finding.
    func install() -> Finding {
        let homebrew = probes.homebrew()
        let name = "install"
        let source = AppInstall.source(of: probes.layout())
        switch source {
        case .homebrew:
            return Finding(
                name: name, ok: false,
                detail: "Homebrew's formula, which ends at 0.34.2; wisp is a cask from 0.35.0. Move to it: "
                    + HomebrewMove.line)
        case .app(let app):
            if homebrew.formulaOnPath, let path = homebrew.onPath {
                let finish =
                    homebrew.cask
                    ? "brew uninstall --formula wisp && brew reinstall --cask \(HomebrewMove.cask)" : HomebrewMove.line
                return Finding(
                    name: name, ok: false,
                    detail: "Wisp.app at \(app.path), but the wisp on PATH is Homebrew's old formula, \(path.path); "
                        + "finish the move to the cask: \(finish)")
            }
            let by = homebrew.cask ? ", installed by Homebrew's cask" : ""
            let keg =
                homebrew.keg
                ? "; Homebrew's old formula is still installed: remove it with "
                    + "brew uninstall --formula --force wisp" : ""
            return Finding(name: name, ok: true, detail: "Wisp.app at \(app.path)\(by)\(keg)")
        case .diskImage(let app), .translocated(let app):
            return Finding(name: name, ok: false, detail: "Wisp.app at \(app.path): \(source.refusal ?? "")")
        case .elsewhere:
            return Finding(
                name: name, ok: true,
                detail: "not an installed package (a build directory, or a tarball unpacked by hand)")
        }
    }
}
