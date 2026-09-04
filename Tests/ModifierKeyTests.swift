import XCTest
@testable import Synapty

/// [[ModifierKey]] and [[SecureInput]] ([[WI-2026-09-02-019]]).
final class ModifierKeyTests: XCTestCase {

    private let shift = GHOSTTY_MODS_SHIFT.rawValue
    private let ctrl = GHOSTTY_MODS_CTRL.rawValue

    func testALeftShiftPressAndReleaseAreToldApartByTheFlag() {
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x38, rawFlags: 0, mods: shift),
                       .init(mod: shift, pressed: true))
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x38, rawFlags: 0, mods: 0),
                       .init(mod: shift, pressed: false))
    }

    /// RIGHT SHIFT WHILE LEFT SHIFT IS HELD: the flag stays set either way,
    /// so the device-side mask is what says whether the right key went down.
    func testARightHandKeyIsReadFromTheDeviceMask() {
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x3C, rawFlags: ModifierKey.rightShift, mods: shift)?.pressed, true)
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x3C, rawFlags: 0, mods: shift)?.pressed, false,
                       "flag set by the LEFT key only: the right one was released")
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x3E, rawFlags: ModifierKey.rightControl, mods: ctrl)?.pressed, true)
    }

    func testCapsLockIsAModifierAndFnIsNot() {
        XCTAssertEqual(ModifierKey.classify(keyCode: 0x39, rawFlags: 0, mods: GHOSTTY_MODS_CAPS.rawValue)?.mod,
                       GHOSTTY_MODS_CAPS.rawValue)
        XCTAssertNil(ModifierKey.classify(keyCode: 0x3F, rawFlags: 0, mods: 0), "fn sends nothing")
    }

    /// SECURE ENTRY IS ON WHILE ANY SURFACE ASKS: two panes prompting, the
    /// first finishing, the second still protected.
    @MainActor
    func testSecureInputStaysOnUntilTheLastAskerIsDone() {
        var wanting: Set<UnsafeRawPointer> = []
        let a = UnsafeRawPointer(bitPattern: 0x10)!, b = UnsafeRawPointer(bitPattern: 0x20)!
        XCTAssertTrue(SecureInput.decide(GHOSTTY_SECURE_INPUT_ON, surface: a, wanting: &wanting))
        XCTAssertTrue(SecureInput.decide(GHOSTTY_SECURE_INPUT_ON, surface: b, wanting: &wanting))
        XCTAssertTrue(SecureInput.decide(GHOSTTY_SECURE_INPUT_OFF, surface: a, wanting: &wanting),
                      "b is still prompting")
        XCTAssertFalse(SecureInput.decide(GHOSTTY_SECURE_INPUT_OFF, surface: b, wanting: &wanting))
        XCTAssertTrue(SecureInput.decide(GHOSTTY_SECURE_INPUT_TOGGLE, surface: a, wanting: &wanting))
        XCTAssertFalse(SecureInput.decide(GHOSTTY_SECURE_INPUT_TOGGLE, surface: a, wanting: &wanting))
    }
}
