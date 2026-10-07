import CoreFoundation
import Darwin
import Foundation

/// Neural Engine activity without root, read the way mactop 2.1.6 does on macOS 27 / M5:
/// IOReport's PMP channels (group "PMP0" on M5 Max; "PMP" / "PMP1" elsewhere).
///
///  - utilization: time NOT spent in the lowest performance-floor state of the ANE floor
///    channels ("SOC Floor" / "ANE-LNK<n>-AF-BW", "DCS Floor" / "ANE-DCS-BW"), max over them.
///    A true time fraction: 0% idle, 100% under sustained inference.
///  - bandwidth: residency-weighted average of the "AF BW" rate histograms ("ANE L<n> RD",
///    "WR", "RD+WR"; bucket names are "<N>GB/s"), summed over links.
///
/// On macOS 27 / M5 the ANE energy counter mactop reads stays at 0 W even under full load
/// unless powermetrics (root) is sampling the ANE; this does not depend on either. libIOReport is private: it is loaded with
/// dlopen, so nothing links against an SDK stub.
public final class ANEMonitor {
    public struct Reading {
        public var utilizationPercent: Double
        public var bandwidthGBs: Double
    }

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias Samples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: Samples
    private let createDelta: Delta
    private let subGroup: GetString
    private let channelName: GetString
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let subscription: OpaquePointer
    private let subscribed: CFMutableDictionary
    private var previous: CFDictionary?

    /// nil when IOReport or the ANE PMP channels are not available on this Mac.
    public init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let subscribe = sym("IOReportCreateSubscription", Subscribe.self),
              let createSamples = sym("IOReportCreateSamples", Samples.self),
              let createDelta = sym("IOReportCreateSamplesDelta", Delta.self),
              let subGroup = sym("IOReportChannelGetSubGroup", GetString.self),
              let channelName = sym("IOReportChannelGetChannelName", GetString.self),
              let stateCount = sym("IOReportStateGetCount", StateCount.self),
              let stateName = sym("IOReportStateGetNameForIndex", StateName.self),
              let stateResidency = sym("IOReportStateGetResidency", StateResidency.self)
        else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.subGroup = subGroup
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency

        // Keep only the ANE floor and bandwidth channels of every PMP group present.
        var keep: [CFDictionary] = []
        var template: CFDictionary?
        for group in ["PMP", "PMP0", "PMP1"] {
            guard let channels = copyChannels(group as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
                  let items = (channels as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { continue }
            template = template ?? channels
            for item in items {
                let name = channelName(item)?.takeUnretainedValue() as String? ?? ""
                let sub = subGroup(item)?.takeUnretainedValue() as String? ?? ""
                if name.contains("ANE"), sub == "AF BW" || sub.contains("Floor") { keep.append(item) }
            }
        }
        guard let template, !keep.isEmpty else { return nil }
        let filtered = NSMutableDictionary(dictionary: template as NSDictionary)
        filtered["IOReportChannels"] = keep
        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, filtered as CFMutableDictionary, &out, 0, nil),
              let subscribed = out?.takeRetainedValue() else { return nil }
        self.subscription = sub
        self.subscribed = subscribed
        previous = createSamples(sub, subscribed, nil)?.takeRetainedValue()
    }

    /// Activity since the previous call (the first call covers the time since init).
    public func read() -> Reading? {
        guard let now = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        defer { previous = now }
        guard let previous, let delta = createDelta(previous, now, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        var util = 0.0
        var read = 0.0, write = 0.0, combined = 0.0
        for item in items {
            let name = channelName(item)?.takeUnretainedValue() as String? ?? ""
            let sub = subGroup(item)?.takeUnretainedValue() as String? ?? ""
            let n = stateCount(item)
            guard n > 1 else { continue }
            var total: Int64 = 0, active: Int64 = 0, weighted = 0.0
            for s in 0..<n {
                let r = stateResidency(item, s)
                let state = stateName(item, s)?.takeUnretainedValue() as String? ?? ""
                total += r
                if sub.contains("Floor"), !["VMIN", "F1", "F2", "OFF", "IDLE", "DOWN", "SLEEP", "0%"].contains(state) {
                    active += r
                }
                // bucket names are padded: "   2GB/s" -> 2
                let rate = state.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }
                weighted += (Double(rate) ?? 0) * Double(r)
            }
            guard total > 0 else { continue }
            if sub.contains("Floor") {
                util = max(util, 100 * Double(active) / Double(total))
            } else if sub == "AF BW" {
                let gbs = weighted / Double(total)
                if name.contains("RD+WR") || name.contains("RW") { combined += gbs }
                else if name.contains("RD") { read += gbs }
                else if name.contains("WR") { write += gbs }
            }
        }
        return Reading(utilizationPercent: util, bandwidthGBs: combined > 0 ? combined : read + write)
    }
}
