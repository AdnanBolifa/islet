import Foundation

/// CPU die temperature on Apple Silicon, read from IOKit's HID sensor services.
/// These IOKit functions are exported but missing from the public headers (why the App Store
/// rejects them), so they're looked up at runtime; anything missing just means "no reading".
public final class TemperatureReader {
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private var client: CFTypeRef?
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?
    public private(set) var sensorNames: [String] = []
    private var sensors: [CFTypeRef] = []

    public init() {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) } }

        guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return }

        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary) // temperature sensors
        let services = copyServices(client).map { $0.takeRetainedValue() as NSArray as [AnyObject] } ?? []
        let named = services.map { ($0, copyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String ?? "") }
        let dies = named.filter { $0.1.contains("tdie") } // CPU die sensors, e.g. "PMU tdie1"
        let chosen = dies.isEmpty ? named.filter { $0.1.hasPrefix("PMU") && !$0.1.contains("tcal") } : dies

        self.client = client
        sensors = chosen.map(\.0)
        sensorNames = named.map(\.1)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self)
        getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self)
    }

    /// Average CPU die temperature in °C, or nil when the Mac doesn't expose it (e.g. Intel).
    public func cpuCelsius() -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        let temperatureEvent: Int64 = 15
        let readings = sensors.compactMap { sensor -> Double? in
            guard let event = copyEvent(sensor, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let celsius = getFloat(event, Int32(temperatureEvent << 16))
            return (1...130).contains(celsius) ? celsius : nil
        }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }
}
