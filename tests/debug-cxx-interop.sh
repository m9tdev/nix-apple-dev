#!/usr/bin/env bash
# Debug builds: Objective-C++ that includes a C++-interop -Swift.h must compile
# with DEBUG defined. Without the swiftToCxx patch in pkgs/swift.nix and
# pkgs/ios-sdk.nix, clang stops with "recursive template instantiation exceeded
# maximum depth of 1024" at TypeMetadataTrait<swift::Optional<T>>.
#
# usage: debug-cxx-interop.sh SWIFT_TOOLCHAIN SDK_BUNDLE
#   SWIFT_TOOLCHAIN  .#swift
#   SDK_BUNDLE       .#ios-sdk's darwin.artifactbundle (needs Xcode.xip)
set -euo pipefail
swift=$1
dev=$2/Developer
sdk=$dev/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
toolchain=$dev/Toolchains/XcodeDefault.xctoolchain
target=arm64-apple-ios17.0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
export HOME=$work

cat >M.swift <<'EOF'
import Foundation
public final class Box {
  public var name: String? = nil
  public init() {}
}
EOF
printf '#import <Foundation/Foundation.h>\n#include "M-Swift.h"\n' >use.mm

"$swift/usr/bin/swiftc" -parse-as-library -target $target -sdk "$sdk" \
  -resource-dir "$toolchain/usr/lib/swift" -module-cache-path mc \
  -emit-module -module-name M -o M.swiftmodule M.swift \
  -cxx-interoperability-mode=default -Xcc -std=gnu++20 \
  -emit-clang-header-path M-Swift.h
grep -q 'swift::Optional' M-Swift.h

for debug in -DDEBUG=1 -UDEBUG; do
  echo "clang $debug"
  "$swift/usr/bin/clang" -target $target -isysroot "$sdk" \
    -isystem "$swift/usr/include" -fmodules -fmodules-cache-path=mc \
    -x objective-c++ -std=gnu++20 -fsyntax-only $debug use.mm
done
echo "debug-cxx-interop: ok"
