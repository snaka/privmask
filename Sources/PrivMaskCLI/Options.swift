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
        with --json. Everything found is masked, including low-confidence
        findings such as a placeholder in a credential slot. Use --json to
        see the confidence of each finding. Nothing is sent anywhere: all
        detection runs locally.

        Anything privmask did not examine is named on stderr, and in the
        "warnings" array under --json. That array is empty only when every
        layer ran over the whole input, so it is what to check before treating
        the output as safe to pass on.

        OPTIONS
          --json               Report findings as JSON instead of masked text.
          --dictionary PATH    Term list to use.
                               Default: ~/.config/privmask/terms.txt
          --no-dictionary      Ignore the term list.
          --no-model           Skip the on-device language model layer, which is
                               used by default wherever it is available.
                               Japanese personal names are found only by that
                               layer, so this turns their detection off, and it
                               is the way to trade them for speed: the layer
                               reads the Japanese in chunks, one call after
                               another, so a long document takes proportionally
                               longer. The layer itself needs macOS 26 with
                               Apple Intelligence enabled; without it, names are
                               not detected either way and privmask says so.
          --version            Print the version.
          -h, --help           Print this message.

        FOR AN AGENT RUNNING THIS
          Use --json and check "warnings". It is empty only when every layer
          ran over the whole input. A non-empty "warnings" means something was
          not looked for — most often Japanese personal names, which no other
          layer finds — so the text has not been cleared for sharing just
          because it went through privmask.

          The --json report carries the original, unmasked values in
          findings[].text. It is as sensitive as the input: do not write it to
          a file, quote it, or attach it anywhere.

          Masking is not reversible. Feeding masked text back in recovers
          nothing.

          Do not reach for --no-model to make a run faster. It turns off the
          only layer that finds Japanese personal names.
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
            // A file path is not a misspelled flag, and saying "unknown option"
            // leaves the caller no better off. It is the first thing anyone
            // tries, an agent included.
            case let argument where !argument.hasPrefix("-"):
                throw CLIError.positionalArgument(argument)
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
    /// An argument that is not a flag — almost always a file, because that is
    /// how most tools take input.
    case positionalArgument(String)

    var description: String {
        switch self {
        case .missingValue(let option): return "\(option) needs a value"
        case .unknownOption(let option): return "unknown option: \(option)"
        case .positionalArgument(let argument):
            // No leading "privmask": `fail` already prefixes the line.
            return "input is read from stdin — try: privmask < \(argument)"
        }
    }
}
