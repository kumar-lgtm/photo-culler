import Foundation

/// Manages Photo Mechanic-style code replacements.
/// Parses tab-separated `.txt` files where each line is `code\texpansion`.
/// During caption entry, typing `\code\` auto-expands to the mapped value.
///
/// Example file content:
/// ```
/// m10	Lionel Messi
/// cr7	Cristiano Ronaldo
/// loc1	Madison Square Garden, New York
/// ```
public final class CodeReplacementManager: Sendable {
    
    private let codes: [String: String]
    
    public init(codes: [String: String] = [:]) {
        self.codes = codes
    }
    
    /// Loads code replacements from a tab-separated text file.
    /// Each line should be: `code<TAB>expansion`
    /// Lines starting with `#` are treated as comments.
    public static func load(from url: URL) throws -> CodeReplacementManager {
        let content = try String(contentsOf: url, encoding: .utf8)
        var codes: [String: String] = [:]
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            
            let code = parts[0].trimmingCharacters(in: .whitespaces)
            let expansion = parts[1...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            
            if !code.isEmpty, !expansion.isEmpty {
                codes[code] = expansion
            }
        }
        
        return CodeReplacementManager(codes: codes)
    }
    
    /// Expands all delimited codes in the input string.
    /// Codes are delimited by backslashes: `\code\`
    /// Returns the string with all recognized codes expanded.
    public func expand(_ input: String) -> String {
        var result = input
        let pattern = #"\\([^\\]+)\\"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }
        
        // Process matches in reverse to preserve indices
        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: nsRange)
        
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let codeRange = Range(match.range(at: 1), in: result) else { continue }
            
            let code = String(result[codeRange])
            if let expansion = codes[code] {
                result.replaceSubrange(fullRange, with: expansion)
            }
        }
        
        return result
    }
    
    /// Returns all loaded code/expansion pairs for display.
    public var allCodes: [String: String] { codes }
    
    /// Number of loaded codes.
    public var count: Int { codes.count }
}
