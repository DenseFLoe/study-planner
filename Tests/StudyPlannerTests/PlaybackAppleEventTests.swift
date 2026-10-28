import AppKit
import Carbon
import XCTest
@testable import StudyPlanner

final class PlaybackAppleEventTests: XCTestCase {
    func testAllWindowsSpecifierRetainsItsRecordFields() throws {
        let windows = try PlaybackStateReader.object("cwin")
        XCTAssertEqual(windows.descriptorType, typeObjectSpecifier)
        XCTAssertTrue(windows.isRecordDescriptor)
        XCTAssertEqual(windows.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, 0x6377696e)
        XCTAssertEqual(windows.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formAbsolutePosition))
        let selection = try XCTUnwrap(windows.forKeyword(UInt32(keyAEKeyData)))
        XCTAssertEqual(selection.descriptorType, typeAbsoluteOrdinal)
        XCTAssertEqual(selection.data, NSAppleEventDescriptor(enumCode: UInt32(kAEAll)).data)
        XCTAssertEqual(windows.forKeyword(UInt32(keyAEContainer))?.descriptorType, typeNull)
    }

    func testSafariAndChromiumTabsRetainTheirWindowContainerInAnEvent() throws {
        for (tabClass, tabCode) in [("bTab", UInt32(0x62546162)), ("CrTb", UInt32(0x43725462))] {
            let window = try PlaybackStateReader.object("cwin")
            let tabs = try PlaybackStateReader.object(tabClass, container: window)
            let event = NSAppleEventDescriptor(eventClass: UInt32(kAECoreSuite), eventID: UInt32(kAEGetData),
                targetDescriptor: .init(processIdentifier: getpid()), returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(tabs, forKeyword: keyDirectObject)
            let direct = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertTrue(direct.isRecordDescriptor)
            XCTAssertEqual(direct.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, tabCode)
            let container = try XCTUnwrap(direct.forKeyword(UInt32(keyAEContainer)))
            XCTAssertTrue(container.isRecordDescriptor)
            XCTAssertEqual(container.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, 0x6377696e)
        }
    }

    func testPlayerPropertyRetainsItsSelectorAndDocumentContainer() throws {
        let document = try PlaybackStateReader.object("docu")
        let playing = try PlaybackStateReader.object("prop", container: document, property: "play")
        XCTAssertTrue(playing.isRecordDescriptor)
        XCTAssertEqual(playing.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formPropertyID))
        XCTAssertEqual(playing.forKeyword(UInt32(keyAEKeyData))?.typeCodeValue, 0x706c6179)
        let container = try XCTUnwrap(playing.forKeyword(UInt32(keyAEContainer)))
        XCTAssertTrue(container.isRecordDescriptor)
        XCTAssertEqual(container.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, 0x646f6375)
    }
}
