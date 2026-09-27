import CryptoKit
import Foundation
import XCTest
@testable import DisplayRememberCore

final class IdentityTests: XCTestCase {
    // Synthetic test manufacturer "TST" (EISA 0x5274), model and registry path.
    // EDID bytes below are constructed fixtures, never a connected monitor dump.
    private let info: [String: Any] = [
        "DisplayVendorID": 21108, "DisplayProductID": 8208, "DisplaySerialNumber": 0,
        "DisplayProductName": ["en_US": "Synthetic Display A"],
        "IODisplayLocation": "IOService:/SyntheticFramebuffer/FixtureDisplay"
    ]

    private func registry(vendor: Int = 21108, product: Int = 8208, text: String = "MONITOR-A\n", serial: UInt32 = 0, raw: Data? = nil) -> [String: Any] {
        var result: [String: Any] = ["DisplayAttributes": ["ProductAttributes": [
            "LegacyManufacturerID": vendor, "ManufacturerID": "TST", "ProductID": product,
            "AlphanumericSerialNumber": text, "SerialNumber": serial
        ]]]
        result["IODisplayEDID"] = raw
        return result
    }

    private func edid(serial: UInt32 = 42, text: String = "MONITOR-A", extensions: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128 * (extensions + 1))
        bytes.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
        bytes[8] = 0x52; bytes[9] = 0x74
        bytes[10] = 0x10; bytes[11] = 0x20
        for offset in 0..<4 { bytes[12 + offset] = UInt8(truncatingIfNeeded: serial >> (offset * 8)) }
        bytes.replaceSubrange(54..<59, with: [0, 0, 0, 255, 0])
        bytes.replaceSubrange(59..<72, with: Array(text.utf8).prefix(13) + [UInt8](repeating: 32, count: max(0, 13 - text.utf8.count)))
        bytes[126] = UInt8(extensions)
        for offset in stride(from: 0, to: bytes.count, by: 128) {
            bytes[offset + 127] = UInt8((256 - bytes[offset..<(offset + 127)].reduce(0, { $0 + Int($1) }) % 256) % 256)
        }
        return Data(bytes)
    }

    func testExactRegistryTextSerialWorksWhenNumericSerialIsZero() {
        let result = NativeDisplayScanner.extractMetadata(info: info, registry: registry())
        XCTAssertEqual(result.name, "Synthetic Display A")
        XCTAssertEqual(result.identity.serialText, "MONITOR-A")
        XCTAssertEqual(result.identity.serialNumber, 0)
        XCTAssertNil(result.identity.edidSHA256)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testWrongRegistryVendorOrProductIsRejected() {
        for raw in [registry(vendor: 21109), registry(product: 8209)] {
            let result = NativeDisplayScanner.extractMetadata(info: info, registry: raw)
            XCTAssertEqual(result.identity.serialText, "")
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testLetterManufacturerIsVerifiedWhenLegacyNumberIsMissing() {
        let raw: [String: Any] = ["DisplayAttributes": ["ProductAttributes": [
            "ManufacturerID": "TST", "ProductID": 8208, "AlphanumericSerialNumber": "MONITOR-A"
        ]]]
        XCTAssertEqual(NativeDisplayScanner.extractMetadata(info: info, registry: raw).identity.serialText, "MONITOR-A")
    }

    func testNoRegistryDoesNotInventIdentity() {
        let result = NativeDisplayScanner.extractMetadata(info: info)
        XCTAssertEqual(result.identity.serialText, "")
        XCTAssertEqual(result.identity.serialNumber, 0)
        XCTAssertNil(result.identity.edidSHA256)
    }

    func testNumericSerialFallbackAndBuiltin() {
        var rawInfo = info
        rawInfo["DisplaySerialNumber"] = 12345
        let result = NativeDisplayScanner.extractMetadata(info: rawInfo, builtin: true)
        XCTAssertEqual(result.identity.serialNumber, 12345)
        XCTAssertTrue(result.identity.builtin)
    }

    func testConflictingRegistrySerialIsRejected() {
        var rawInfo = info
        rawInfo["DisplaySerialNumber"] = 12345
        let result = NativeDisplayScanner.extractMetadata(info: rawInfo, registry: registry(serial: 67890))
        XCTAssertEqual(result.identity.serialNumber, 12345)
        XCTAssertEqual(result.identity.serialText, "")
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testValidEDIDHashesAllBlocksAndReadsDescriptorSerial() {
        var rawInfo = info
        let data = edid(extensions: 1)
        rawInfo["IODisplayEDID"] = data
        let result = NativeDisplayScanner.extractMetadata(info: rawInfo)
        XCTAssertEqual(result.identity.serialText, "MONITOR-A")
        XCTAssertEqual(result.identity.serialNumber, 42)
        XCTAssertEqual(result.identity.edidSHA256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testInvalidEDIDHeaderChecksumLengthAndWrongMonitorAreRejected() {
        let valid = edid()
        var badHeader = valid; badHeader[0] = 1
        var badChecksum = valid; badChecksum[127] &+= 1
        for data in [Data(), Data(repeating: 0, count: 128), badHeader, badChecksum, valid + Data(repeating: 0, count: 128), Data(edid(extensions: 1).prefix(128))] {
            var rawInfo = info
            rawInfo["IODisplayEDID"] = data
            XCTAssertNil(NativeDisplayScanner.extractMetadata(info: rawInfo).identity.edidSHA256)
        }
        for field in ["DisplayVendorID", "DisplayProductID"] {
            var rawInfo = info
            rawInfo[field] = (info[field] as! Int) + 1
            rawInfo["IODisplayEDID"] = valid
            XCTAssertNil(NativeDisplayScanner.extractMetadata(info: rawInfo).identity.edidSHA256)
        }
    }

    func testScrubbedEDIDPreservesMeaningfulOSSerial() {
        for placeholder in [UInt32(0), UInt32.max] {
            var rawInfo = info
            rawInfo["DisplaySerialNumber"] = 12345
            rawInfo["IODisplayEDID"] = edid(serial: placeholder)
            let result = NativeDisplayScanner.extractMetadata(info: rawInfo)
            XCTAssertEqual(result.identity.serialNumber, 12345)
            XCTAssertNotNil(result.identity.edidSHA256)
        }
    }

    func testConflictingRawEDIDCannotOverwriteKnownOSSerial() {
        var rawInfo = info
        rawInfo["DisplaySerialNumber"] = 12345
        rawInfo["IODisplayEDID"] = edid(serial: 42)
        let result = NativeDisplayScanner.extractMetadata(info: rawInfo)
        XCTAssertEqual(result.identity.serialNumber, 12345)
        XCTAssertEqual(result.identity.serialText, "")
        XCTAssertNil(result.identity.edidSHA256)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testConflictingRawEDIDCannotOverwriteKnownRegistrySerial() {
        for source in ["CoreDisplay", "Registry"] {
            var rawInfo = info
            if source == "CoreDisplay" { rawInfo["IODisplayEDID"] = edid(serial: 42) }
            let rawRegistry = registry(text: "", serial: 12345, raw: source == "Registry" ? edid(serial: 42) : nil)
            let result = NativeDisplayScanner.extractMetadata(info: rawInfo, registry: rawRegistry)
            XCTAssertEqual(result.identity.serialNumber, 12345)
            XCTAssertEqual(result.identity.serialText, "")
            XCTAssertNil(result.identity.edidSHA256)
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testPlaceholderEDIDTextDoesNotHideRegistrySerial() {
        for placeholder in ["00000000", "FFFFFFFF", "unknown", "serial number"] {
            var rawInfo = info
            rawInfo["IODisplayEDID"] = edid(serial: 0, text: placeholder)
            XCTAssertEqual(NativeDisplayScanner.extractMetadata(info: rawInfo, registry: registry()).identity.serialText, "MONITOR-A")
        }
    }

    func testConflictingEDIDTextPreservesVerifiedRegistrySerial() {
        var rawInfo = info
        rawInfo["IODisplayEDID"] = edid(serial: 0, text: "MONITOR-B")
        let result = NativeDisplayScanner.extractMetadata(info: rawInfo, registry: registry())
        XCTAssertEqual(result.identity.serialText, "MONITOR-A")
        XCTAssertNil(result.identity.edidSHA256)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testWrongRegistryCannotContributeRawEDID() {
        let result = NativeDisplayScanner.extractMetadata(info: info, registry: registry(vendor: 21109, raw: edid()))
        XCTAssertNil(result.identity.edidSHA256)
        XCTAssertEqual(result.identity.serialText, "")
    }

    func testMalformedOptionalMetadataIsSafe() {
        let result = NativeDisplayScanner.extractMetadata(info: ["DisplayVendorID": true], registry: ["DisplayAttributes": []])
        XCTAssertEqual(result.identity.vendor, 0)
        XCTAssertEqual(result.name, "Unknown display")
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
