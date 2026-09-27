import Darwin
import Foundation

// Atomically exchange complete bundles on one volume, preserving the old app at
// the staging path until the build script cleans its own staging directory.
guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: replace-app.swift STAGED_APP DESTINATION_APP\n".utf8))
    exit(2)
}
let staged = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard staged != destination, staged.lastPathComponent == "Display Remember.app",
      destination.lastPathComponent == "Display Remember.app" else { exit(2) }
let result: Int32
if FileManager.default.fileExists(atPath: destination.path) {
    result = renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP))
} else {
    result = rename(staged.path, destination.path)
}
if result != 0 {
    FileHandle.standardError.write(Data("Could not atomically replace app: \(String(cString: strerror(errno)))\n".utf8))
    exit(1)
}
