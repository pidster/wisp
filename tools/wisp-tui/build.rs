//! Records which commit `wisp-tui` was built from, so `--version` agrees with `wisp --version`: the bare
//! crate version for a release build (`WISP_RELEASE=1`, set only by `scripts/release`), otherwise
//! `<version>-dev+<commit>`, with ` (modified)` when the working tree had changes. The commit is
//! unknown, and the version is `<version>-dev`, where `git` is missing or there is no repository.

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn main() {
    println!("cargo:rerun-if-env-changed=WISP_RELEASE");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src");
    // A commit or a staged change moves HEAD or the index; an unstaged edit outside this crate does not,
    // so `(modified)` can lag until the crate is next built after one of those.
    for path in ["HEAD", "index"] {
        if let Some(file) = git(&["rev-parse", "--git-path", path]) {
            println!("cargo:rerun-if-changed={file}");
        }
    }
    let commit = git(&["rev-parse", "--short=7", "HEAD"]).filter(|hash| !hash.is_empty());
    let modified = commit.is_some()
        && git(&["status", "--porcelain", "--untracked-files=no"])
            .is_some_and(|status| !status.is_empty());
    let release = std::env::var("WISP_RELEASE").is_ok_and(|value| value == "1");
    println!(
        "cargo:rustc-env=WISP_BUILD_COMMIT={}",
        commit.unwrap_or_default()
    );
    println!("cargo:rustc-env=WISP_BUILD_MODIFIED={modified}");
    println!("cargo:rustc-env=WISP_BUILD_RELEASE={release}");
}
