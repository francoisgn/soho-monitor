import Foundation
import Yams

/// Reads and validates the YAML configuration. Every problem is reported at once, with its line, so that one edit
/// can fix them all; unknown keys are warnings (a newer file still loads in an older app).
public enum ConfigParser {
    /// `home` expands `~`; `directoryExists` checks the Claude config directories (missing one: warning).
    public static func parse(
        _ yaml: String, home: String = NSHomeDirectory(),
        directoryExists: @escaping (String) -> Bool = ConfigParser.isDirectory
    ) throws(ConfigError) -> ConfigLoadResult {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch let error as YamlError {
            throw ConfigError(issues: [syntaxIssue(error)])
        } catch {
            throw ConfigError(issues: [ConfigIssue(line: 1, keyPath: "config", message: "YAML syntax: \(error)")])
        }
        var reader = Reader(home: home, directoryExists: directoryExists)
        let config = reader.read(root)
        if !reader.errors.isEmpty { throw ConfigError(issues: inFileOrder(reader.errors)) }
        return ConfigLoadResult(config: config, warnings: inFileOrder(reader.warnings))
    }

    /// True for an existing directory (through symbolic links).
    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Sorted by line (stable: same-line issues keep the order they were found in).
    private static func inFileOrder(_ issues: [ConfigIssue]) -> [ConfigIssue] {
        issues.enumerated()
            .sorted { ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset) }
            .map(\.element)
    }

    private static func syntaxIssue(_ error: YamlError) -> ConfigIssue {
        switch error {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _),
            .composer(_, let problem, let mark, _):
            return ConfigIssue(line: mark.line, keyPath: "config", message: "YAML syntax: \(problem)")
        default:
            // The description of the other cases has no location; keep its first line only.
            let first = String(describing: error).split(separator: "\n").first.map(String.init) ?? ""
            return ConfigIssue(line: 1, keyPath: "config", message: "YAML syntax: \(first)")
        }
    }
}

/// Walks the node tree; collects errors and warnings in file order. Module sections may live in their own file as
/// extensions (`ClaudeConfig.swift`).
struct Reader {
    let home: String
    let directoryExists: (String) -> Bool
    var errors: [ConfigIssue] = []
    var warnings: [ConfigIssue] = []

    static let knownSources = ["ios-runtimes": DiskCategory.Source.iosRuntimes]
    static let reservedGroups = [DiskSnapshot.macOSGroup, DiskSnapshot.otherGroup]

    mutating func error(_ node: Node?, _ keyPath: String, _ message: String, fallbackLine: Int? = nil) {
        errors.append(ConfigIssue(line: node?.mark?.line ?? fallbackLine, keyPath: keyPath, message: message))
    }

    /// Key/value pairs of a mapping, in file order; unknown keys become warnings.
    mutating func entries(_ mapping: Node.Mapping, at keyPath: String, known: Set<String>) -> [String: Node] {
        var result: [String: Node] = [:]
        for (key, value) in mapping {
            let name = key.scalar?.string ?? String(describing: key)
            let path = keyPath.isEmpty ? name : "\(keyPath).\(name)"
            if known.contains(name) {
                result[name] = value
            } else {
                warnings.append(ConfigIssue(line: key.mark?.line, keyPath: path, message: "unknown key, ignored"))
            }
        }
        return result
    }

    mutating func read(_ root: Node?) -> AppConfig {
        guard let root else {
            error(nil, "config", "the file is empty", fallbackLine: 1)
            return .empty
        }
        guard case .mapping(let mapping) = root else {
            error(root, "config", "expected a mapping at the top level")
            return .empty
        }
        let top = entries(mapping, at: "", known: ["disk", "claude", "synology"])
        let claude = top["claude"].map { readClaude($0) } ?? .disabled
        let synology = top["synology"].flatMap { readSynology($0) }
        guard let disk = top["disk"] else {
            error(root, "disk", "required section is missing")
            return .empty
        }
        return AppConfig(disk: readDisk(disk), claude: claude, synology: synology)
    }

    mutating func readDisk(_ node: Node) -> DiskConfig {
        var config = DiskConfig(categories: [])
        guard case .mapping(let mapping) = node else {
            error(node, "disk", "expected a mapping (scan_interval_minutes, free_space, categories)")
            return config
        }
        let keys = entries(mapping, at: "disk", known: ["scan_interval_minutes", "free_space", "categories"])
        if let interval = keys["scan_interval_minutes"] {
            if let minutes = wholeNumber(interval), (1...1440).contains(minutes) {
                config.scanIntervalMinutes = minutes
            } else {
                error(interval, "disk.scan_interval_minutes", "must be a whole number of minutes between 1 and 1440")
            }
        }
        if let freeSpace = keys["free_space"] {
            readFreeSpace(freeSpace, into: &config)
        }
        guard let categories = keys["categories"] else {
            error(node, "disk.categories", "required: the list of categories to measure")
            return config
        }
        config.categories = readCategories(categories)
        return config
    }

    mutating func readFreeSpace(_ node: Node, into config: inout DiskConfig) {
        guard case .mapping(let mapping) = node else {
            error(node, "disk.free_space", "expected a mapping (warning_below_percent, critical_below_percent)")
            return
        }
        let keys = entries(
            mapping, at: "disk.free_space", known: ["warning_below_percent", "critical_below_percent"])
        var valid = true
        for (key, assign) in [
            ("warning_below_percent", { (c: inout DiskConfig, v: Double) in c.freeWarningPercent = v }),
            ("critical_below_percent", { (c: inout DiskConfig, v: Double) in c.freeCriticalPercent = v }),
        ] {
            guard let value = keys[key] else { continue }
            if let percent = number(value), (0...100).contains(percent) {
                assign(&config, percent)
            } else {
                valid = false
                error(value, "disk.free_space.\(key)", "must be a percentage between 0 and 100")
            }
        }
        if valid, config.freeCriticalPercent >= config.freeWarningPercent {
            error(
                keys["critical_below_percent"] ?? keys["warning_below_percent"] ?? node, "disk.free_space",
                "critical_below_percent (\(format(config.freeCriticalPercent))) must be lower than "
                    + "warning_below_percent (\(format(config.freeWarningPercent)))")
        }
    }

    mutating func readCategories(_ node: Node) -> [DiskCategory] {
        guard case .sequence(let sequence) = node else {
            error(node, "disk.categories", "expected a list of categories")
            return []
        }
        if sequence.isEmpty {
            error(node, "disk.categories", "must list at least one category")
            return []
        }
        var categories: [DiskCategory] = []
        var seen = Set<String>()
        for (index, item) in sequence.enumerated() {
            guard let category = readCategory(item, at: "disk.categories[\(index)]") else { continue }
            let id = "\(category.group)/\(category.label)"
            if seen.insert(id).inserted {
                categories.append(category)
            } else {
                error(item, "disk.categories[\(index)]", "duplicate category \(id)")
            }
        }
        return categories
    }

    mutating func readCategory(_ node: Node, at keyPath: String) -> DiskCategory? {
        guard case .mapping(let mapping) = node else {
            error(node, keyPath, "expected a mapping (group, label, paths or source)")
            return nil
        }
        let keys = entries(mapping, at: keyPath, known: ["group", "label", "paths", "source"])
        let errorCount = errors.count

        let group = nonEmptyString(keys["group"])
        if group == nil {
            error(keys["group"] ?? node, "\(keyPath).group", "required (a non-empty string)")
        } else if let group, Self.reservedGroups.contains(group) {
            error(keys["group"], "\(keyPath).group", "\"\(group)\" is reserved (computed by the app)")
        }
        var label = group ?? ""
        if let labelNode = keys["label"] {
            if let value = nonEmptyString(labelNode) {
                label = value
            } else {
                error(labelNode, "\(keyPath).label", "must be a non-empty string")
            }
        }

        var source: DiskCategory.Source?
        switch (keys["paths"], keys["source"]) {
        case (.some, .some):
            error(node, keyPath, "use either paths or source, not both")
        case (nil, nil):
            error(node, keyPath, "needs paths (a list) or source (ios-runtimes)")
        case (.some(let pathsNode), nil):
            source = readPaths(pathsNode, at: "\(keyPath).paths").map { .paths($0) }
        case (nil, .some(let sourceNode)):
            let name = sourceNode.scalar?.string ?? ""
            if let known = Self.knownSources[name] {
                source = known
            } else {
                let list = Self.knownSources.keys.sorted().joined(separator: ", ")
                error(sourceNode, "\(keyPath).source", "unknown source \"\(name)\" (known: \(list))")
            }
        }
        guard errors.count == errorCount, let group, let source else { return nil }
        return DiskCategory(group: group, label: label, source: source)
    }

    mutating func readPaths(_ node: Node, at keyPath: String) -> [String]? {
        guard case .sequence(let sequence) = node else {
            error(node, keyPath, "expected a list of paths")
            return nil
        }
        if sequence.isEmpty {
            error(node, keyPath, "must list at least one path")
            return nil
        }
        var paths: [String] = []
        for (index, item) in sequence.enumerated() {
            // The raw scalar: a bare `~` (YAML null) is the home folder, `yes` stays a folder name.
            if let raw = item.scalar?.string, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                paths.append(raw.trimmingCharacters(in: .whitespaces))
            } else {
                error(item, "\(keyPath)[\(index)]", "must be a non-empty string")
            }
        }
        return paths.count == sequence.count ? paths : nil
    }

    func nonEmptyString(_ node: Node?) -> String? {
        guard let scalar = node?.scalar, node?.null == nil else { return nil }
        let value = scalar.string.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    func number(_ node: Node) -> Double? {
        guard node.scalar != nil else { return nil }
        if let int = node.int { return Double(int) }
        if let float = node.float, float.isFinite { return float }
        return nil
    }

    func wholeNumber(_ node: Node) -> Int? {
        guard node.scalar != nil else { return nil }
        if let int = node.int { return int }
        if let float = node.float, float.isFinite, float.rounded() == float, abs(float) < 1e9 { return Int(float) }
        return nil
    }

    func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// Where the configuration lives, and reading it from disk.
public enum ConfigFile {
    /// `$SOHO_MONITOR_CONFIG`, else `$XDG_CONFIG_HOME/soho-monitor/config.yaml`, else
    /// `~/.config/soho-monitor/config.yaml`.
    public static func defaultURL(environment: [String: String], home: String) -> URL {
        if let override = environment["SOHO_MONITOR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: PathDisplay.expandingTilde(override, home: home))
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        return URL(fileURLWithPath: base).appendingPathComponent("soho-monitor/config.yaml")
    }

    public static func load(_ url: URL) -> Result<ConfigLoadResult, ConfigError> {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .failure(
                ConfigError(issues: [
                    ConfigIssue(
                        line: nil, keyPath: "config",
                        message: "\(url.path) not found: copy config/example.yaml from the repository there")
                ]))
        } catch {
            return .failure(
                ConfigError(issues: [
                    ConfigIssue(line: nil, keyPath: "config", message: "cannot read \(url.path): \(error)")
                ]))
        }
        return Result { () throws(ConfigError) in try ConfigParser.parse(text) }
    }
}
