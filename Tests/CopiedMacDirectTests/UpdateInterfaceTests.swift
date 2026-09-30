import AppKit
import SwiftUI
import Sparkle
import XCTest
@testable import CopiedDirect

@MainActor
final class UpdateInterfaceTests: XCTestCase {
    func testAboutSelectionWhileSettingsAlreadyExists() {
        let navigation = SettingsNavigation.shared
        let original = navigation.selectedTab
        defer { navigation.selectedTab = original }
        navigation.selectedTab = 1
        SettingsWindowController.shared.show(tab: 4)
        XCTAssertEqual(navigation.selectedTab, 4)
        SettingsWindowController.shared.show()
        XCTAssertEqual(navigation.selectedTab, 4)
    }

    func testSparkleStatusesAndHomebrewLayout() async throws {
        let manager = UpdateManager(channel: .homebrew, startUpdater: false)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater

        let current = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [
            SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)
        ])
        manager.updaterDidNotFindUpdate(updater, error: current)
        XCTAssertEqual(manager.status, .upToDate)
        manager.updater(updater, didAbortWithError: current)
        XCTAssertEqual(manager.status, .upToDate)
        try await snapshot(manager, name: "current")

        let incompatible = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [
            SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue),
            NSLocalizedDescriptionKey: "This update requires a newer version of macOS."
        ])
        manager.updaterDidNotFindUpdate(updater, error: incompatible)
        XCTAssertEqual(manager.status, .unavailable(incompatible.localizedDescription))

        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
        ])
        manager.updater(updater, didAbortWithError: networkError)
        XCTAssertEqual(manager.status, .failed(networkError.localizedDescription))
        try await snapshot(manager, name: "error")

        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "title": "Copied 1.3.3 (15)",
            "enclosure": [
                "url": "https://www.getcopied.app/test.pkg",
                "sparkle:version": "15",
                "sparkle:shortVersionString": "1.3.3"
            ]
        ]))
        manager.updater(updater, didFindValidUpdate: item)
        XCTAssertEqual(manager.status, .available("1.3.3 (15)"))
        try await snapshot(manager, name: "available")
    }

    func testWebsiteUpdatesLayout() async throws {
        let manager = UpdateManager(channel: .directDownload, startUpdater: false)
        XCTAssertEqual(manager.status, .idle)
        try await snapshot(manager, name: "website")
    }

    private func snapshot(_ manager: UpdateManager, name: String) async throws {
        let view = NSHostingView(rootView:
            Form { Section("Updates") { MacUpdatesView(updater: manager) } }
                .formStyle(.grouped)
                .frame(width: 560, height: 360)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/copied-updates-\(name).png"))
    }
}
