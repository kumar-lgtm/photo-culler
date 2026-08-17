import Foundation

public struct RenameContext: Sendable {
    public let originalURL: URL
    public let sequence: Int
    public let rating: String?
    public let color: String?
    public let camera: String?
    public let lens: String?
    public let iso: String?
    
    public init(originalURL: URL, sequence: Int, rating: String? = nil, color: String? = nil, camera: String? = nil, lens: String? = nil, iso: String? = nil) {
        self.originalURL = originalURL
        self.sequence = sequence
        self.rating = rating
        self.color = color
        self.camera = camera
        self.lens = lens
        self.iso = iso
    }
}

public class RenameFormatter {
    
    public init() {}
    
    /// Formats a single filename based on the template and context.
    public func format(template: String, context: RenameContext) -> String {
        var result = template
        
        let date = context.originalURL.creationDate ?? Date.now
        
        // Advanced Photo Mechanic-style tokens with arguments: {Token(arg)}
        result = expandAdvancedTokens(result, date: date, context: context)
        
        // Date formats
        result = replace(result, token: "{date}", with: formatDate(date, format: "yyyyMMdd"))
        result = replace(result, token: "{date:yyyymmdd}", with: formatDate(date, format: "yyyyMMdd"))
        result = replace(result, token: "{date:yyyy-mm-dd}", with: formatDate(date, format: "yyyy-MM-dd"))
        result = replace(result, token: "{date:mmddyy}", with: formatDate(date, format: "MMddyy"))
        
        // Time formats
        result = replace(result, token: "{time}", with: formatDate(date, format: "HHmmss"))
        result = replace(result, token: "{time:hhmmss}", with: formatDate(date, format: "HHmmss"))
        result = replace(result, token: "{time:hh-mm-ss}", with: formatDate(date, format: "HH-mm-ss"))
        
        // Sequence formats
        result = replace(result, token: "{seq}", with: formatSequence(context.sequence, format: "%04d"))
        result = replace(result, token: "{seq:0000}", with: formatSequence(context.sequence, format: "%04d"))
        result = replace(result, token: "{seq:000}", with: formatSequence(context.sequence, format: "%03d"))
        result = replace(result, token: "{seq:00}", with: formatSequence(context.sequence, format: "%02d"))
        result = replace(result, token: "{seq:0}", with: "\(context.sequence)")
        
        // Name formats
        let originalName = context.originalURL.deletingPathExtension().lastPathComponent
        result = replace(result, token: "{name}", with: originalName)
        result = replace(result, token: "{name:original}", with: originalName)
        result = replace(result, token: "{name:lower}", with: originalName.lowercased())
        result = replace(result, token: "{name:upper}", with: originalName.uppercased())
        
        // Ext formats
        let ext = context.originalURL.pathExtension
        result = replace(result, token: "{ext}", with: ext.lowercased())
        result = replace(result, token: "{ext:lower}", with: ext.lowercased())
        result = replace(result, token: "{ext:upper}", with: ext.uppercased())
        
        // Metadata
        result = replace(result, token: "{rating}", with: context.rating ?? "")
        result = replace(result, token: "{color}", with: context.color ?? "")
        
        // Exif
        result = replace(result, token: "{camera}", with: context.camera ?? "")
        result = replace(result, token: "{lens}", with: context.lens ?? "")
        result = replace(result, token: "{iso}", with: context.iso ?? "")
        
        // Standalone shortcuts
        result = replace(result, token: "{year}", with: formatDate(date, format: "yyyy"))
        result = replace(result, token: "{month}", with: formatDate(date, format: "MM"))
        result = replace(result, token: "{day}", with: formatDate(date, format: "dd"))
        result = replace(result, token: "{hour}", with: formatDate(date, format: "HH"))
        result = replace(result, token: "{minute}", with: formatDate(date, format: "mm"))
        result = replace(result, token: "{second}", with: formatDate(date, format: "ss"))
        
        // If extension wasn't explicitly included in the template, append it automatically
        if !template.contains("{ext}") && !template.contains("{ext:lower}") && !template.contains("{ext:upper}") {
            result += ".\(ext)"
        }
        
        return result
    }
    
    /// Expands advanced Photo Mechanic-style tokens with parenthesized arguments.
    /// e.g., {Date(YYMMDD)}, {Sequence(001)}, {CameraModel}
    private func expandAdvancedTokens(_ input: String, date: Date, context: RenameContext) -> String {
        var result = input
        
        // {Date(format)} — custom date format string
        if let regex = try? NSRegularExpression(pattern: #"\{Date\(([^)]+)\)\}"#) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let fmtRange = Range(match.range(at: 1), in: result) else { continue }
                let fmt = String(result[fmtRange])
                let dateStr = formatDate(date, format: fmt)
                result.replaceSubrange(fullRange, with: dateStr)
            }
        }
        
        // {Sequence(padding)} — e.g., {Sequence(001)} = 3-digit zero-padded
        if let regex = try? NSRegularExpression(pattern: #"\{Sequence\(([^)]+)\)\}"#) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let padRange = Range(match.range(at: 1), in: result) else { continue }
                let pad = String(result[padRange])
                let width = pad.count
                let seqStr = formatSequence(context.sequence, format: "%0\(width)d")
                result.replaceSubrange(fullRange, with: seqStr)
            }
        }
        
        // {CameraModel} shorthand
        result = replace(result, token: "{CameraModel}", with: context.camera ?? "")
        
        return result
    }
    
    private func replace(_ string: String, token: String, with replacement: String) -> String {
        return string.replacingOccurrences(of: token, with: replacement)
    }
    
    private func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    
    private func formatSequence(_ seq: Int, format: String) -> String {
        return String(format: format, seq)
    }
}

public struct RenameOperation: Equatable {
    public let originalURL: URL
    public let newURL: URL
}

public class BatchRenamer {
    
    private var undoStack: [[RenameOperation]] = []
    
    public init() {}
    
    /// Previews a batch rename and returns collisions if any.
    public func preview(items: [RenameContext], template: String, formatter: RenameFormatter = RenameFormatter()) -> (operations: [RenameOperation], collisions: [URL]) {
        var operations: [RenameOperation] = []
        var newNames: Set<String> = []
        var collisions: [URL] = []
        let originalURLs = Set(items.map { $0.originalURL.standardizedFileURL })
        
        for item in items {
            let newName = formatter.format(template: template, context: item)
            let newURL = item.originalURL.deletingLastPathComponent().appendingPathComponent(newName)
            let collisionKey = newURL.lastPathComponent.lowercased()
            
            if newNames.contains(collisionKey) {
                collisions.append(item.originalURL)
            } else {
                newNames.insert(collisionKey)
            }

            if FileManager.default.fileExists(atPath: newURL.path),
               !originalURLs.contains(newURL.standardizedFileURL) {
                collisions.append(item.originalURL)
            }
            
            operations.append(RenameOperation(originalURL: item.originalURL, newURL: newURL))
        }
        
        return (operations, collisions)
    }
    
    /// Executes a batch rename and adds to undo stack.
    public func execute(operations: [RenameOperation]) throws {
        var completed: [RenameOperation] = []
        
        for op in operations {
            if op.originalURL == op.newURL { continue }
            
            do {
                try FileManager.default.moveItem(at: op.originalURL, to: op.newURL)
                
                // Rename sidecar if it exists
                let sidecarExt = "xmp"
                let oldSidecar = op.originalURL.deletingPathExtension().appendingPathExtension(sidecarExt)
                let newSidecar = op.newURL.deletingPathExtension().appendingPathExtension(sidecarExt)
                
                if FileManager.default.fileExists(atPath: oldSidecar.path) {
                    try? FileManager.default.moveItem(at: oldSidecar, to: newSidecar)
                }
                
                completed.append(op)
            } catch {
                // Rollback completed ones if we fail midway
                try? rollback(operations: completed)
                throw error
            }
        }
        
        if !completed.isEmpty {
            undoStack.append(completed)
        }
    }
    
    public func canUndo() -> Bool {
        return !undoStack.isEmpty
    }
    
    public func undo() throws {
        guard let lastBatch = undoStack.popLast() else { return }
        try rollback(operations: lastBatch)
    }
    
    private func rollback(operations: [RenameOperation]) throws {
        // Reverse the operations to rollback
        for op in operations.reversed() {
            try? FileManager.default.moveItem(at: op.newURL, to: op.originalURL)
            
            // Revert sidecar
            let sidecarExt = "xmp"
            let oldSidecar = op.originalURL.deletingPathExtension().appendingPathExtension(sidecarExt)
            let newSidecar = op.newURL.deletingPathExtension().appendingPathExtension(sidecarExt)
            
            if FileManager.default.fileExists(atPath: newSidecar.path) {
                try? FileManager.default.moveItem(at: newSidecar, to: oldSidecar)
            }
        }
    }
}

// Extension to help with dates
extension URL {
    var creationDate: Date? {
        return (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
