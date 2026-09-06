import Foundation
import PrivMask

struct Options {
    var json = false
    var dictionaryURL: URL? = DictionaryFile.defaultURL
    /// True when --dictionary was given. A missing default file is normal — most
    /// people never create one — but a missing file the user named is a typo,
    /// and continuing would mask less than they asked for.
    var dictionaryWasNamed = false
    var useModel = true
    var showHelp = false
    var showVersion = false

    static let usage = """
        privmask — mask privacy-sensitive information in text, on device.

        USAGE
          privmask [options] < input
          cat app.log | privmask --json

        Reads text on stdin. Writes the masked text on stdout, or a JSON report
        with --json. Nothing is sent anywhere: all detection runs locally.

        OPTIONS
          --json               Report findings as JSON instead of masked text.
          --dictionary PATH    Term list to use.
                               Default: ~/.config/privmask/terms.txt
          --no-dictionary      Ignore the term list.
          --no-model           Skip the on-device language model layer.
                               Japanese personal names are only found by that
                               layer, so this turns their detection off.
          --version            Print the version.
          -h, --help           Print this message.
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                options.json = true
            case "--no-model":
                options.useModel = false
            case "--no-dictionary":
                options.dictionaryURL = nil
            case "--dictionary":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue("--dictionary")
                }
                options.dictionaryURL = URL(fileURLWithPath: arguments[index])
                options.dictionaryWasNamed = true
            case "--version":
                options.showVersion = true
            case "-h", "--help":
                options.showHelp = true
            case let unknown:
                throw CLIError.unknownOption(unknown)
            }
            index += 1
        }
        return options
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .missingValue(let option): return "\(option) needs a value"
        case .unknownOption(let option): return "unknown option: \(option)"
        }
    }
}
