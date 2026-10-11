# Let `xtool sdk build` run without network (the Nix build sandbox):
#   XTOOL_TOOLSET_TARBALL  local darwin-tools-linux-llvm toolset-<arch>.tar.gz
#   XTOOL_OAM_SERVER       local OpenAppleMacrosServer binary
# Without the variables xtool downloads them from GitHub as before.
import sys

p = "Sources/XToolSupport/SDKBuilder.swift"
s = open(p).read()


def once(old):
    n = s.count(old)
    if n != 1:
        sys.exit(f"patch-xtool: expected 1 of {old[:60]!r}, found {n}")


start = '''        @Dependency(\\.httpClient) var httpClient
        let url = URL(string: """
        https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\\'''
end = '''        .checkSuccess()

        // swift-build assumes we have an Apple-flavored librarian'''
once(start)
once(end)
a = s.index(start)
b = s.index(end) + len("        .checkSuccess()")
s = s[:a] + '''        if let local = ProcessInfo.processInfo.environment["XTOOL_TOOLSET_TARBALL"] {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            tar.arguments = ["tar", "xzf", local, "-C", toolsetDir.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw Console.Error("Could not unpack toolset \\(local)") }
        } else {
''' + s[a:b] + '''
        }''' + s[b:]

start = '''    private func installMacros(in output: URL) async throws {
'''
once(start)
s = s.replace(start, start + '''        if let local = ProcessInfo.processInfo.environment["XTOOL_OAM_SERVER"] {
            let dest = output.appendingPathComponent("OpenAppleMacrosServer")
            // write a new file: a copy would keep the read-only mode of the Nix store
            try Data(contentsOf: URL(fileURLWithPath: local)).write(to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return
        }
''')
open(p, "w").write(s)
print("patched xtool: XTOOL_TOOLSET_TARBALL, XTOOL_OAM_SERVER")
