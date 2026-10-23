import Carbon.HIToolbox
import MoonvisorCore

/// Übersetzt macOS-Tastencodes (kVK_*) in PC-XT-Scancodes (Set 1).
/// Erweiterte Codes (0xE0 xx) sind wie im QEMU-VNC-Protokoll als `0x80 | xx` kodiert.
enum KeyMap {
    static let windowsKey: UInt32 = 0xDB
    static let rightWindowsKey: UInt32 = 0xDC
    static let leftControl: UInt32 = 0x1D
    static let rightControl: UInt32 = 0x9D

    static let table: [Int: UInt32] = [
        kVK_ANSI_A: 0x1E, kVK_ANSI_S: 0x1F, kVK_ANSI_D: 0x20, kVK_ANSI_F: 0x21, kVK_ANSI_H: 0x23,
        kVK_ANSI_G: 0x22, kVK_ANSI_Z: 0x2C, kVK_ANSI_X: 0x2D, kVK_ANSI_C: 0x2E, kVK_ANSI_V: 0x2F,
        kVK_ISO_Section: 0x56, kVK_ANSI_B: 0x30, kVK_ANSI_Q: 0x10, kVK_ANSI_W: 0x11, kVK_ANSI_E: 0x12,
        kVK_ANSI_R: 0x13, kVK_ANSI_Y: 0x15, kVK_ANSI_T: 0x14, kVK_ANSI_1: 0x02, kVK_ANSI_2: 0x03,
        kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05, kVK_ANSI_6: 0x07, kVK_ANSI_5: 0x06, kVK_ANSI_Equal: 0x0D,
        kVK_ANSI_9: 0x0A, kVK_ANSI_7: 0x08, kVK_ANSI_Minus: 0x0C, kVK_ANSI_8: 0x09, kVK_ANSI_0: 0x0B,
        kVK_ANSI_RightBracket: 0x1B, kVK_ANSI_O: 0x18, kVK_ANSI_U: 0x16, kVK_ANSI_LeftBracket: 0x1A,
        kVK_ANSI_I: 0x17, kVK_ANSI_P: 0x19, kVK_Return: 0x1C, kVK_ANSI_L: 0x26, kVK_ANSI_J: 0x24,
        kVK_ANSI_Quote: 0x28, kVK_ANSI_K: 0x25, kVK_ANSI_Semicolon: 0x27, kVK_ANSI_Backslash: 0x2B,
        kVK_ANSI_Comma: 0x33, kVK_ANSI_Slash: 0x35, kVK_ANSI_N: 0x31, kVK_ANSI_M: 0x32,
        kVK_ANSI_Period: 0x34, kVK_Tab: 0x0F, kVK_Space: 0x39, kVK_ANSI_Grave: 0x29, kVK_Delete: 0x0E,
        kVK_Escape: 0x01,
        kVK_Command: windowsKey, kVK_RightCommand: rightWindowsKey,
        kVK_Shift: 0x2A, kVK_CapsLock: 0x3A, kVK_Option: 0x38, kVK_Control: leftControl,
        kVK_RightShift: 0x36, kVK_RightOption: 0xB8, kVK_RightControl: rightControl,
        kVK_ANSI_KeypadDecimal: 0x53, kVK_ANSI_KeypadMultiply: 0x37, kVK_ANSI_KeypadPlus: 0x4E,
        kVK_ANSI_KeypadClear: 0x45, kVK_VolumeUp: 0xB0, kVK_VolumeDown: 0xAE, kVK_Mute: 0xA0,
        kVK_ANSI_KeypadDivide: 0xB5, kVK_ANSI_KeypadEnter: 0x9C, kVK_ANSI_KeypadMinus: 0x4A,
        kVK_ANSI_KeypadEquals: 0x59, kVK_ANSI_Keypad0: 0x52, kVK_ANSI_Keypad1: 0x4F, kVK_ANSI_Keypad2: 0x50,
        kVK_ANSI_Keypad3: 0x51, kVK_ANSI_Keypad4: 0x4B, kVK_ANSI_Keypad5: 0x4C, kVK_ANSI_Keypad6: 0x4D,
        kVK_ANSI_Keypad7: 0x47, kVK_ANSI_Keypad8: 0x48, kVK_ANSI_Keypad9: 0x49,
        kVK_F1: 0x3B, kVK_F2: 0x3C, kVK_F3: 0x3D, kVK_F4: 0x3E, kVK_F5: 0x3F, kVK_F6: 0x40,
        kVK_F7: 0x41, kVK_F8: 0x42, kVK_F9: 0x43, kVK_F10: 0x44, kVK_F11: 0x57, kVK_F12: 0x58,
        kVK_F13: 0xB7, kVK_F14: 0x46, kVK_Help: 0xD2, kVK_Home: 0xC7, kVK_PageUp: 0xC9,
        kVK_ForwardDelete: 0xD3, kVK_End: 0xCF, kVK_PageDown: 0xD1,
        kVK_LeftArrow: 0xCB, kVK_RightArrow: 0xCD, kVK_DownArrow: 0xD0, kVK_UpArrow: 0xC8,
        kVK_ContextualMenu: 0xDD,
    ]

    /// Auf ISO-Tastaturen (z. B. deutsch) meldet macOS die Tasten „^“ und „<“ vertauscht.
    /// Tastaturbelegung, mit der Moonvisor Text in Windows tippt: dieselbe wie auf dem Mac.
    static var guestLayout: GuestKeyboard.Layout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return .us }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        if id.contains("SwissGerman") || id.contains("Swiss") { return .swissGerman }
        if id.contains("German") || id.contains("Austrian") { return .german }
        return .us
    }

    static let isISOKeyboard: Bool = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO

    static func scancode(for keyCode: UInt16, commandAsControl: Bool) -> UInt32? {
        var code = Int(keyCode)
        if isISOKeyboard {
            if code == kVK_ISO_Section { code = kVK_ANSI_Grave } else if code == kVK_ANSI_Grave { code = kVK_ISO_Section }
        }
        if commandAsControl {
            if code == kVK_Command { return leftControl }
            if code == kVK_RightCommand { return rightControl }
        }
        return table[code]
    }

    /// Geräteabhängige Modifier-Bits aus NSEvent.modifierFlags (IOKit NX_DEVICE*KEYMASK).
    static func modifierIsDown(keyCode: UInt16, rawFlags: UInt) -> Bool? {
        switch Int(keyCode) {
        case kVK_Control: return rawFlags & 0x0001 != 0
        case kVK_Shift: return rawFlags & 0x0002 != 0
        case kVK_RightShift: return rawFlags & 0x0004 != 0
        case kVK_Command: return rawFlags & 0x0008 != 0
        case kVK_RightCommand: return rawFlags & 0x0010 != 0
        case kVK_Option: return rawFlags & 0x0020 != 0
        case kVK_RightOption: return rawFlags & 0x0040 != 0
        case kVK_RightControl: return rawFlags & 0x2000 != 0
        default: return nil
        }
    }
}
