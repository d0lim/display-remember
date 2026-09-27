import Foundation
import XCTest
@testable import DisplayRememberAppSupport

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageLoadsItsResourceTable() {
        let english = AppLocalizer(language: .english)
        let korean = AppLocalizer(language: .korean)
        XCTAssertEqual(english.text("Open Displays Settings"), "Open Displays Settings")
        XCTAssertEqual(korean.text("Open Displays Settings"), "디스플레이 설정 열기")
        XCTAssertEqual(korean.text("Launch at login"), "로그인 시 실행")
        XCTAssertEqual(english.locale.identifier, "en")
        XCTAssertEqual(korean.locale.identifier, "ko")
    }

    func testLanguageCanChangeWithoutRestarting() {
        var localizer = AppLocalizer(language: .english)
        XCTAssertEqual(localizer.text("Language"), "Language")
        localizer = AppLocalizer(language: .korean)
        XCTAssertEqual(localizer.text("Language"), "언어")
        localizer = AppLocalizer(language: .english)
        XCTAssertEqual(localizer.text("Language"), "Language")
    }

    func testLocalizedFormattingPreservesArguments() {
        let korean = AppLocalizer(language: .korean)
        XCTAssertEqual(korean.text("%d displays connected", 2), "모니터 2대 연결됨")
        XCTAssertEqual(korean.text("%d seconds (default)", 5), "5초 (기본값)")
        XCTAssertEqual(korean.format("Saved “%@”", arguments: ["My Desk"]), "“My Desk” 저장됨")
        XCTAssertEqual(AppLocalizer(language: .english).text("Saved “%@”", "My Desk"), "Saved “My Desk”")
    }

    func testMissingStringsFallBackToSourceAndSystemUsesSupportedLanguage() {
        XCTAssertEqual(AppLocalizer(language: .korean).text("Missing diagnostic key"), "Missing diagnostic key")
        XCTAssertTrue(["en", "ko"].contains(AppLocalizer(language: .system).locale.identifier))
    }

    func testResourceTablesHaveMatchingKeysAndFormatPlaceholders() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DisplayRememberAppSupport/Resources")
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let korean = try table("ko")
        XCTAssertEqual(Set(english.keys), Set(korean.keys))
        let expression = try NSRegularExpression(pattern: "%[0-9$.*+-]*[@diuoxXfFeEgGcCsSp]")
        func placeholders(_ string: String) -> [String] {
            expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
                .map { (string as NSString).substring(with: $0.range) }
        }
        for (key, value) in english {
            XCTAssertEqual(placeholders(value), placeholders(try XCTUnwrap(korean[key])), key)
        }
    }
}
