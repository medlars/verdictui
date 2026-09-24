import Foundation

/// Resolve the copied asset directory without relying on Foundation's bundle-layout inference.
public enum WorkbenchResources {
    public enum Failure: Error {
        case invalidDirectory, missingOrAmbiguousLayout, invalidPage
    }

    public static func directory(in bundle: URL) throws -> URL {
        let manager = FileManager.default
        var candidates: [URL] = []
        for components in [["Contents", "Resources", "Resources"], ["Resources"]] {
            var current = bundle.standardizedFileURL
            var complete = true
            for component in components {
                current.appendPathComponent(component)
                let attributes: [FileAttributeKey: Any]
                do { attributes = try manager.attributesOfItem(atPath: current.path) }
                catch CocoaError.fileReadNoSuchFile { complete = false; break }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw Failure.invalidDirectory
                }
            }
            if complete { candidates.append(current) }
        }
        guard candidates.count == 1, let directory = candidates.first else {
            throw Failure.missingOrAmbiguousLayout
        }
        let page = directory.appendingPathComponent("index.html")
        let attributes = try manager.attributesOfItem(atPath: page.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.invalidPage
        }
        return directory
    }
}
