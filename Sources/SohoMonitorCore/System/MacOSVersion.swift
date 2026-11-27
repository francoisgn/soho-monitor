import Foundation

/// The Mac's system version for the disk card's subtitle: "macOS 26.2 (25C56)".
public enum MacOSVersion {
    /// "macOS 26.2" (the patch only when not zero), then the build in brackets when there is one.
    public static func display(_ version: OperatingSystemVersion, build: String?) -> String {
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { number += ".\(version.patchVersion)" }
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return build.isEmpty ? "macOS \(number)" : "macOS \(number) (\(build))"
    }

    /// This Mac: `ProcessInfo.operatingSystemVersion` (public API, numbers only) and the build from
    /// `kern.osversion` (`KERN_OSVERSION`, "for build number", `<sys/sysctl.h>` of the macOS SDK), no process run.
    public static func current(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        sysctl: some SysctlReading = SystemSysctl()
    ) -> String {
        display(version, build: sysctl.string("kern.osversion"))
    }
}
