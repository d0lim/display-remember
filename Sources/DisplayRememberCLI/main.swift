import Foundation
import DisplayRememberCore

let usage = """
display-remember — remember physical monitors, restore their layouts

  scan                               Hardware identity and available modes (JSON)
  save FILE [--name NAME]             Capture layout, including mirrors and disabled displays
  import OLD_FILE NEW_FILE            Import a legacy v1 JSON profile
  apply FILE [--execute]              Preview or restore a saved layout
  watch FILE [--execute] [--once]     Check every 5 seconds; restore after two stable observations
  displayplacer ARGS...               Full bundled displayplacer interface (applies immediately)
  --help | --version

Native displayplacer examples:
  display-remember displayplacer list
  display-remember displayplacer "id:42 res:1920x1080 hz:60 scaling:off origin:(0,0) degree:0"
  display-remember displayplacer "id:42+43 mode:1 origin:(0,0) degree:0"
  display-remember displayplacer "id:43 enabled:false"

Display-setting changes require --execute for profile commands. The displayplacer
subcommand preserves the original command's behavior, including immediate changes.
"""

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { print(usage); return 0 }
    if command == "--help" || command == "help" { print(usage); return 0 }
    if command == "--version" { print("display-remember \(DisplayRememberVersion.current)"); return 0 }
    if command == "displayplacer" {
        let result = try DisplayPlacerEngine().run(arguments: Array(arguments.dropFirst()))
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        return result.status
    }
    if command == "import" {
        guard arguments.count == 3 else { throw DisplayRememberError("Usage: import OLD_FILE NEW_FILE") }
        let profile = try ProfileStorage.read(URL(fileURLWithPath: arguments[1]))
        try ProfileStorage.write(profile, to: URL(fileURLWithPath: arguments[2]))
        print("Imported \(profile.displays.count) physical displays.")
        return 0
    }
    let service = try DisplayService()
    if command == "scan" {
        guard arguments.count == 1 else { throw DisplayRememberError("Usage: scan") }
        try emit(service.inventory())
        return 0
    }
    guard ["save", "apply", "watch"].contains(command), arguments.count >= 2 else {
        throw DisplayRememberError(usage)
    }
    let file = URL(fileURLWithPath: arguments[1])
    if command == "save" {
        var name = file.deletingPathExtension().lastPathComponent
        if arguments.count == 4 && arguments[2] == "--name" { name = arguments[3] }
        else if arguments.count != 2 { throw DisplayRememberError("Usage: save FILE [--name NAME]") }
        try ProfileStorage.write(service.capture(name: name), to: file)
        print("Saved \(name) to \(file.path)")
        return 0
    }
    let options = Set(arguments.dropFirst(2))
    let allowed: Set<String> = command == "watch" ? ["--execute", "--once"] : ["--execute"]
    guard options.isSubset(of: allowed) else { throw DisplayRememberError("Unknown option.") }
    let profile = try ProfileStorage.read(file)
    let execute = options.contains("--execute")
    if command == "apply" {
        print(DisplayService.preview(try ProfileMatcher.arguments(profile: profile, displays: service.inventory())))
        if execute { try service.apply(profile); print("Layout restored and verified.") }
        else { print("Preview only. Add --execute to apply.") }
        return 0
    }
    let once = options.contains("--once")
    var previous: [DisplaySnapshot]?
    var lastAttempt = Date.distantPast
    var lastMessage = ""
    repeat {
        let message: String
        do {
            let current = try service.inventory()
            let plan = try ProfileMatcher.arguments(profile: profile, displays: current)
            if try ProfileMatcher.matches(profile: profile, displays: current) { message = "Layout matches saved profile." }
            else if current != previous && !once { message = "Waiting for display connections to settle." }
            else if !execute { message = "Would apply: " + DisplayService.preview(plan) }
            else if Date().timeIntervalSince(lastAttempt) < 30 { message = "Waiting before retrying restoration." }
            else {
                lastAttempt = Date()
                try service.apply(profile)
                message = "Layout restored and verified."
            }
            previous = current
        } catch {
            if once { throw error }
            previous = nil
            message = "Waiting: \(error.localizedDescription)"
        }
        if message != lastMessage { print(message); fflush(stdout); lastMessage = message }
        if !once { Thread.sleep(forTimeInterval: 5) }
    } while !once
    return 0
}

do { exit(try run()) }
catch { FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8)); exit(1) }
