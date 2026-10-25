import Foundation

/// Tippt Text über QEMU (`send-key`) in den Gast, als hätte jemand die Tasten gedrückt.
/// QEMU kennt nur physische Tasten (qcodes, benannt nach der US-Belegung). Welches Zeichen daraus wird,
/// entscheidet die Tastaturbelegung in Windows, deshalb gibt es je Belegung eine eigene Tabelle.
public enum GuestKeyboard {
    public enum Layout: String, Sendable {
        case us, german, swissGerman
    }

    public enum KeyboardError: LocalizedError {
        case unsupported(Character)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let character): return "Das Zeichen „\(character)“ lässt sich nicht in Windows tippen."
            }
        }
    }

    /// Befehl für „Ausführen“ (Windows+R): sucht die CD „MOONTOOLS“ und startet die Installation.
    /// Nur Zeichen, die es auf allen unterstützten Belegungen gibt, und kein y/z (auf QWERTZ vertauscht).
    public static let installToolsCommand =
        #"cmd /c for %d in (D E F G H I J K L M N O P Q R S T U V W) do if exist %d:\moontools.cmd %d:\moontools.cmd"#

    /// Belegung, die Moonvisor bei der Express-Installation für dieses Windows-Gebietsschema einstellt
    /// (siehe `WindowsLocale.inputLocales`). Nil, wenn Moonvisor sie nicht nachbilden kann.
    public static func layout(forWindowsLocale locale: String) -> Layout? {
        switch locale {
        case "de-DE", "de-AT": return .german
        case "de-CH": return .swissGerman
        // US-International (nl-NL) unterscheidet sich nur bei Akzenten, die der Befehl nicht braucht.
        case "en-US", "nl-NL": return .us
        default: return nil
        }
    }

    /// Tastenkombinationen (qcodes) für jedes Zeichen von `text`.
    public static func keystrokes(for text: String, layout: Layout) throws -> [[String]] {
        try text.map { character in
            guard let keys = keys(for: character, layout: layout) else { throw KeyboardError.unsupported(character) }
            return keys
        }
    }

    static let usSymbols: [Character: [String]] = [
        "%": ["shift", "5"], "(": ["shift", "9"], ")": ["shift", "0"], ":": ["shift", "semicolon"],
        "\\": ["backslash"], ".": ["dot"], "-": ["minus"], "/": ["slash"],
    ]

    /// Deutsche Belegung; die Schweizer unterscheidet sich hier nur beim Backslash.
    static let germanSymbols: [Character: [String]] = [
        "%": ["shift", "5"], "(": ["shift", "8"], ")": ["shift", "9"], ":": ["shift", "dot"],
        "\\": ["alt_r", "minus"], ".": ["dot"], "-": ["slash"], "/": ["shift", "7"],
    ]

    static func keys(for character: Character, layout: Layout) -> [String]? {
        if character.isLetter, character.isASCII {
            var key = character.lowercased()
            // QWERTZ: Y und Z liegen vertauscht.
            if layout != .us {
                if key == "y" { key = "z" } else if key == "z" { key = "y" }
            }
            return character.isUppercase ? ["shift", key] : [key]
        }
        if character.isNumber, character.isASCII { return [String(character)] }
        if character == " " { return ["spc"] }
        switch layout {
        case .us: return usSymbols[character]
        case .german: return germanSymbols[character]
        case .swissGerman:
            return character == "\\" ? ["alt_r", "less"] : germanSymbols[character]
        }
    }
}
