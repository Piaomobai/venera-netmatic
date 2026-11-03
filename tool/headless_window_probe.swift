// macOS regression check: headless commands must create no WindowServer windows,
// never become the active application, and run with prohibited activation policy.
// Build: swiftc -o /tmp/headless-window-probe tool/headless_window_probe.swift
// Run: /tmp/headless-window-probe <app executable> <writable profile root>
import Cocoa
import CoreGraphics

let arguments = CommandLine.arguments
if arguments.count != 3 {
  fputs("Usage: headless-window-probe <executable> <profile-root>\n", stderr)
  exit(2)
}
let executable = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let profile = URL(fileURLWithPath: arguments[2]).appendingPathComponent("window-probe-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: profile) }
let sources = profile.appendingPathComponent("comic_source")
try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
try """
class AuthUiFixture extends ComicSource {
  name = 'UI Fixture'; key = 'auth_ui'; version = '1.0.0'; minAppVersion = '1.0.0';
  url = 'http://127.0.0.1/unused.js'; explore = []; search = {}; comic = {};
  account = {login: async () => { await UI.showInputDialog('Fixture'); }, logout: () => {}};
}
""".write(to: sources.appendingPathComponent("auth-ui.js"), atomically: true, encoding: .utf8)
let credentials = profile.appendingPathComponent("fixture-credentials.json")
try """
{"username":"fixture","password":"fixture-only"}
""".write(to: credentials, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentials.path)

var tracked = Set<pid_t>()
var prohibited = Set<pid_t>()
var failures = Set<String>()
var completed = 0
let workspace = NSWorkspace.shared
let observer = workspace.notificationCenter.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { notification in
  if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
     tracked.contains(application.processIdentifier) {
    failures.insert("Headless process activated: \(application.processIdentifier)")
  }
}
defer { workspace.notificationCenter.removeObserver(observer) }

func inspect() {
  if let active = workspace.frontmostApplication, tracked.contains(active.processIdentifier) {
    failures.insert("Headless process became frontmost: \(active.processIdentifier)")
  }
  guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
    failures.insert("Could not inspect WindowServer windows")
    return
  }
  for window in windows {
    if let owner = window[kCGWindowOwnerPID as String] as? Int,
       tracked.contains(pid_t(owner)) {
      failures.insert("Headless process created a window: pid \(owner)")
    }
  }
  for pid in tracked {
    if let application = NSRunningApplication(processIdentifier: pid), application.isFinishedLaunching {
      if application.activationPolicy == .prohibited {
        prohibited.insert(pid)
      } else {
        failures.insert("Headless process has Dock/activation policy \(application.activationPolicy.rawValue): pid \(pid)")
      }
    }
  }
}

func run(_ args: [String], expectedCode: Int32) throws {
  let process = Process()
  let output = Pipe()
  let errors = Pipe()
  process.executableURL = executable
  process.arguments = ["--headless", "--json", "--data-dir", profile.path] + args
  process.standardOutput = output
  process.standardError = errors
  try process.run()
  tracked.insert(process.processIdentifier)
  let limit = Date().addingTimeInterval(20)
  while process.isRunning && Date() < limit {
    inspect()
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  }
  if process.isRunning {
    process.terminate()
    failures.insert("Headless command timed out: \(args)")
  }
  process.waitUntilExit()
  inspect()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  if process.terminationStatus != expectedCode {
    failures.insert("Unexpected exit \(process.terminationStatus) for \(args): \(String(data: data, encoding: .utf8) ?? "") \(diagnostic)")
  }
  let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
  if lines.isEmpty { failures.insert("No JSON result for \(args)") }
  for line in lines {
    if (try? JSONSerialization.jsonObject(with: Data(line.utf8))) == nil {
      failures.insert("Non-JSON stdout for \(args)")
    }
  }
  completed += 1
}

for _ in 0..<5 { try run(["help"], expectedCode: 0) }
try run(["sources", "list"], expectedCode: 0)
try run(["sources", "status", "auth_ui"], expectedCode: 0)
try run(["sources", "login", "auth_ui", "--credentials-file", credentials.path], expectedCode: 1)
try run(["sources", "logout", "auth_ui"], expectedCode: 0)
try run(["library", "list"], expectedCode: 0)
try run(["search", "missing", "test"], expectedCode: 1)
try run(["scheduler", "serve", "--timeout", "2"], expectedCode: 124)
let socket = URL(fileURLWithPath: arguments[2]).appendingPathComponent("s\(UUID().uuidString.prefix(8))")
defer { try? FileManager.default.removeItem(at: socket) }
try run(["service", "serve", "--socket", socket.path, "--timeout", "2"], expectedCode: 124)
if prohibited.isEmpty { failures.insert("No running process was observed with prohibited activation policy") }
let result: [String: Any] = [
  "commands": completed,
  "processesObservedWithProhibitedPolicy": prohibited.count,
  "windowOrFocusViolations": failures.sorted(),
  "passed": failures.isEmpty,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
// exit() does not unwind top-level defer blocks.
try? FileManager.default.removeItem(at: profile)
try? FileManager.default.removeItem(at: socket)
exit(failures.isEmpty ? 0 : 1)
