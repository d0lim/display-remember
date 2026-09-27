import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import IOKit

/// Reads identities through exact display-to-registry associations. No settings are changed.
public final class NativeDisplayScanner {
    private typealias CreateInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private typealias CreateUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
    private let coreDisplayHandle: UnsafeMutableRawPointer
    private let applicationServicesHandle: UnsafeMutableRawPointer
    private let createInfo: CreateInfo
    private let createUUID: CreateUUID

    public init() throws {
        guard let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL) else {
            throw DisplayRememberError("CoreDisplay is unavailable on this macOS version.")
        }
        guard let application = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL) else {
            dlclose(core)
            throw DisplayRememberError("ApplicationServices is unavailable on this macOS version.")
        }
        guard let infoSymbol = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary"),
              let uuidSymbol = dlsym(application, "CGDisplayCreateUUIDFromDisplayID") else {
            dlclose(application)
            dlclose(core)
            throw DisplayRememberError("Required private macOS display APIs are unavailable; this macOS version is unsupported.")
        }
        coreDisplayHandle = core
        applicationServicesHandle = application
        createInfo = unsafeBitCast(infoSymbol, to: CreateInfo.self)
        createUUID = unsafeBitCast(uuidSymbol, to: CreateUUID.self)
    }

    deinit {
        dlclose(applicationServicesHandle)
        dlclose(coreDisplayHandle)
    }

    public func snapshotIDs() throws -> [UInt32: String] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            throw DisplayRememberError("macOS could not enumerate online displays.")
        }
        let capacity = count + 16
        var ids = [UInt32](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success, count < capacity else {
            throw DisplayRememberError("Display list changed while being enumerated; retry after connections settle.")
        }
        var result: [UInt32: String] = [:]
        for id in ids.prefix(Int(count)) {
            guard let ownedUUID = createUUID(id),
                  let text = CFUUIDCreateString(kCFAllocatorDefault, ownedUUID.takeRetainedValue()) else {
                throw DisplayRememberError("Display \(id) has no readable UUID; retry after connections settle.")
            }
            result[id] = (text as String).uppercased()
        }
        return result
    }

    public func enrich(_ displays: [DisplaySnapshot], expected: [UInt32: String]? = nil) throws -> [DisplaySnapshot] {
        let before = try snapshotIDs()
        if let expected, before != expected {
            throw DisplayRememberError("Displays changed during inventory; retry after connections settle.")
        }
        var observed: [UInt32: String] = [:]
        for display in displays {
            guard observed.updateValue(display.uuid.uppercased(), forKey: display.id) == nil else {
                throw DisplayRememberError("displayplacer reported duplicate contextual display IDs.")
            }
        }
        guard observed == before else {
            throw DisplayRememberError("displayplacer and macOS disagree about display IDs; retry after connections settle.")
        }
        var result: [DisplaySnapshot] = []
        for var display in displays {
            guard let ownedInfo = createInfo(display.id),
                  let info = ownedInfo.takeRetainedValue() as NSDictionary as? [String: Any] else {
                throw DisplayRememberError("macOS returned no metadata for display \(display.id).")
            }
            if let uuid = info["kCGDisplayUUID"] as? String, uuid.uppercased() != before[display.id] {
                throw DisplayRememberError("Display UUID changed during metadata lookup; retry after connections settle.")
            }
            let location = info["IODisplayLocation"] as? String ?? ""
            let registry = registryProperties(at: location)
            let metadata = Self.extractMetadata(info: info, registry: registry, builtin: CGDisplayIsBuiltin(display.id) != 0)
            display.name = metadata.name
            display.identity = metadata.identity
            display.warnings += metadata.warnings
            if !location.isEmpty && registry == nil {
                display.warnings.append("Exact registry path could not be read; using CoreDisplay metadata only.")
            }
            let mirror = CGDisplayMirrorsDisplay(display.id)
            display.mirrorPrimaryID = mirror == kCGNullDirectDisplay ? nil : mirror
            result.append(display)
        }
        guard try snapshotIDs() == before else {
            throw DisplayRememberError("Displays changed during metadata lookup; retry after connections settle.")
        }
        return result
    }

    private func registryProperties(at location: String) -> [String: Any]? {
        let path = location.hasPrefix("/") ? "IOService:" + location : location
        guard path.hasPrefix("IOService:/"), !path.contains("\0") else { return nil }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
        // A Create function transfers ownership even if an unexpected error returns a value.
        let dictionary = properties?.takeRetainedValue()
        guard status == KERN_SUCCESS, let dictionary else { return nil }
        return dictionary as NSDictionary as? [String: Any]
    }

    /// ``registry`` must be the properties of the exact ``IODisplayLocation`` in ``info``.
    /// This pure function allows identity checks without accessing connected hardware.
    public static func extractMetadata(
        info: [String: Any], registry: [String: Any]? = nil, builtin: Bool = false
    ) -> (name: String, identity: HardwareIdentity, warnings: [String]) {
        let vendor = number(info["DisplayVendorID"])
        let product = number(info["DisplayProductID"])
        var identity = HardwareIdentity(
            vendor: vendor, product: product,
            serialNumber: serialNumber(info["DisplaySerialNumber"]), builtin: builtin
        )
        var warnings: [String] = []
        let names = info["DisplayProductName"] as? [String: String] ?? [:]
        var name = names["en_US"] ?? names.keys.sorted().compactMap { names[$0] }.first
            ?? (info["DisplayProductName"] as? String) ?? "Unknown display"
        var acceptedRegistry: [String: Any]?
        if let registry {
            let attributes = registry["DisplayAttributes"] as? [String: Any] ?? [:]
            let productAttributes = attributes["ProductAttributes"] as? [String: Any] ?? [:]
            let legacyVendor = number(productAttributes["LegacyManufacturerID"])
            let manufacturerVendor = manufacturer(productAttributes["ManufacturerID"])
            let registryVendor = legacyVendor != 0 ? legacyVendor : manufacturerVendor != 0 ? manufacturerVendor : number(registry["DisplayVendorID"])
            let attributeProduct = number(productAttributes["ProductID"])
            let registryProduct = attributeProduct != 0 ? attributeProduct : number(registry["DisplayProductID"])
            let attributeSerial = serialNumber(productAttributes["SerialNumber"])
            let registrySerial = attributeSerial != 0 ? attributeSerial : serialNumber(registry["DisplaySerialNumber"])
            if vendor == 0 || product == 0 || vendor != registryVendor || product != registryProduct {
                warnings.append("Registry vendor/product does not match CoreDisplay; registry identity ignored.")
            } else if identity.serialNumber != 0 && registrySerial != 0 && identity.serialNumber != registrySerial {
                warnings.append("Registry serial does not match CoreDisplay; registry identity ignored.")
            } else {
                acceptedRegistry = registry
                if identity.serialNumber == 0 { identity.serialNumber = registrySerial }
                identity.serialText = textSerial(productAttributes["AlphanumericSerialNumber"])
                if name.isEmpty || name == "Unknown display", let registryName = productAttributes["ProductName"] as? String {
                    name = registryName
                }
            }
        }
        for (source, raw) in [("CoreDisplay", info["IODisplayEDID"]), ("Registry", acceptedRegistry?["IODisplayEDID"])] {
            guard let candidate = edid(raw, vendor: vendor, product: product) else { continue }
            if (identity.serialNumber != 0 && candidate.serialNumber != 0 && identity.serialNumber != candidate.serialNumber)
                || (!identity.serialText.isEmpty && !candidate.serialText.isEmpty && identity.serialText != candidate.serialText) {
                warnings.append("\(source) EDID serial conflicts with verified metadata; raw EDID identity ignored.")
                continue
            }
            if identity.serialText.isEmpty { identity.serialText = candidate.serialText }
            if identity.serialNumber == 0 { identity.serialNumber = candidate.serialNumber }
            if identity.edidSHA256 == nil { identity.edidSHA256 = candidate.hash }
        }
        return (name.isEmpty ? "Unknown display" : name, identity, warnings)
    }

    private static func number(_ value: Any?) -> UInt32 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max) else { return 0 }
        return number.uint32Value
    }

    private static func serialNumber(_ value: Any?) -> UInt32 {
        let result = number(value)
        return result == UInt32.max ? 0 : result
    }

    private static func textSerial(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        return HardwareIdentity.normalizedSerialText(text)
    }

    private static func manufacturer(_ value: Any?) -> UInt32 {
        if let text = value as? String {
            let letters = Array(text.utf8)
            guard letters.count == 3, letters.allSatisfy({ 65...90 ~= $0 }) else { return 0 }
            return (UInt32(letters[0] - 64) << 10) | (UInt32(letters[1] - 64) << 5) | UInt32(letters[2] - 64)
        }
        return number(value)
    }

    private struct EDIDMetadata {
        var serialText: String
        var serialNumber: UInt32
        var hash: String
    }

    private static func edid(_ raw: Any?, vendor: UInt32, product: UInt32) -> EDIDMetadata? {
        guard let data = raw as? Data, data.count >= 128, data.count % 128 == 0 else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              bytes.count == 128 * (1 + Int(bytes[126])), vendor != 0, product != 0,
              (UInt32(bytes[8]) << 8) | UInt32(bytes[9]) == vendor,
              UInt32(bytes[10]) | (UInt32(bytes[11]) << 8) == product else { return nil }
        for offset in stride(from: 0, to: bytes.count, by: 128) {
            guard bytes[offset..<(offset + 128)].reduce(0, { $0 + Int($1) }) % 256 == 0 else { return nil }
        }
        var serialText = ""
        for offset in stride(from: 54, to: 126, by: 18) {
            if Array(bytes[offset..<(offset + 5)]) == [0, 0, 0, 255, 0],
               let rawText = String(bytes: bytes[(offset + 5)..<(offset + 18)], encoding: .ascii) {
                serialText = textSerial(rawText)
                if !serialText.isEmpty { break }
            }
        }
        let numeric = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[12 + $1]) << ($1 * 8)) }
        return EDIDMetadata(
            serialText: serialText, serialNumber: numeric == UInt32.max ? 0 : numeric,
            hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
