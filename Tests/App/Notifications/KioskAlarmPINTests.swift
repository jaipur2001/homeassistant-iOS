@testable import HomeAssistant
import Testing

struct KioskAlarmPINTests {
    @Test func acceptsExactlySixAsciiDigits() {
        #expect(KioskAlarmView.isValidPIN("012345"))
        #expect(KioskAlarmView.isValidPIN("000000"))
        #expect(!KioskAlarmView.isValidPIN("12345"))
        #expect(!KioskAlarmView.isValidPIN("1234567"))
        #expect(!KioskAlarmView.isValidPIN("12a456"))
        #expect(!KioskAlarmView.isValidPIN("１２３４５６"))
        #expect(!KioskAlarmView.isValidPIN(""))
    }
}
