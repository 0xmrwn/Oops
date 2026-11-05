import AppKit

// Activates the process whose command line contains the given marker (by pid; no Apple Events).
let marker = CommandLine.arguments[1]
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); task.arguments = ["-f", "-o", marker]
let pipe = Pipe(); task.standardOutput = pipe; try task.run(); task.waitUntilExit()
guard let pid = Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
      let app = NSRunningApplication(processIdentifier: pid) else { print("not found"); exit(1) }
print(app.activate(), pid)
