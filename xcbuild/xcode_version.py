"""The Xcode version the stand-ins report (xcodebuild -version, XCODE_VERSION_*, DTXcode).
It matches the SDK that apple-dev builds from Xcode.xip."""
XCODE_VERSION = "27.0"
XCODE_BUILD = "27A266a"
_major, _minor = (XCODE_VERSION.split(".") + ["0"])[:2]
XCODE_VERSION_NUMBER = "%02d%s0" % (int(_major), _minor[:1])  # "2700", as in Xcode's build settings
