import Foundation

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("leaf-mtp-tests-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// Repeated polls, wake scans, and brief resets do not repeat an attempt.
var tracker = MTPConnectionTracker()
let start = Date(timeIntervalSince1970: 100)
check(tracker.observe(["a", "b"], now: start) == ["a", "b"], "two independent Kindles")
check(tracker.observe(["a", "b"], now: start.addingTimeInterval(12)).isEmpty, "once per connection")
check(tracker.observe(["b"], now: start.addingTimeInterval(20)).isEmpty, "missing starts grace period")
check(tracker.observe(["a", "b"], now: start.addingTimeInterval(25)).isEmpty, "USB cleanup reset")
check(tracker.observe(["b"], now: start.addingTimeInterval(30)).isEmpty, "new disconnect")
check(tracker.observe(["b"], now: start.addingTimeInterval(38)).isEmpty, "confirmed disconnect")
check(tracker.observe(["a", "b"], now: start.addingTimeInterval(39)) == ["a"], "reconnect imports again")
// Attempts are consumed before the transfer starts, including failures.
check(tracker.observe(["a", "b"], now: start.addingTimeInterval(50)).isEmpty, "no retry storm after errors")

let syntheticClippings = """
Test Book (Test Author)
- Your Highlight on Location 10-11 | Added on Thursday, October 15, 2026 9:00:00 AM

A synthetic highlight used only by the test suite.
==========

"""
var library = Set<String>()
let bookID = UUID()
let coordinator = ImportCoordinator(
    parseClippings: ClippingsParser.parseClippings(fileURL:),
    upsertBook: { _ in bookID },
    insertHighlightIfNew: { highlight in
        library.insert(DedupeKeyBuilder.makeKey(bookId: bookID, location: highlight.location, quoteText: highlight.quoteText))
    },
    totalHighlightCount: { library.count }
)
let importsRoot = root.appendingPathComponent("imports")
let service = MTPImportService(root: importsRoot, download: { _, file in
    try syntheticClippings.write(to: file, atomically: true, encoding: .utf8)
}, importFile: coordinator.importFile(at:))
let first = service.sync("a")
check(first.error == nil && first.newHighlightCount == 1, "real parser and importer")
check(service.sync("a").newHighlightCount == 0 && library.count == 1, "reconnect deduplication")
check(try fm.contentsOfDirectory(atPath: importsRoot.path).isEmpty, "success removes private download")

var imported = false
let failure = MTPImportService(root: importsRoot, download: { _, file in
    try Data("partial".utf8).write(to: file)
    throw MTPHelperError.failed(14)
}, importFile: { _ in imported = true; return first })
check(failure.sync("a").error != nil && !imported, "partial transfer never imported")
check(try fm.contentsOfDirectory(atPath: importsRoot.path).isEmpty, "failure removes partial download")

let oversized = MTPImportService(root: importsRoot, download: { _, file in
    _ = fm.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 20 * 1024 * 1024 + 1)
    try handle.close()
}, importFile: { _ in imported = true; return first })
check(oversized.sync("a").error?.contains("20 MB") == true && !imported, "oversized file rejected")
check(try fm.contentsOfDirectory(atPath: importsRoot.path).isEmpty, "oversize cleanup")

let stale = importsRoot.appendingPathComponent(UUID().uuidString)
let fresh = importsRoot.appendingPathComponent(UUID().uuidString)
let unrelated = importsRoot.appendingPathComponent("unrelated")
for directory in [stale, fresh, unrelated] {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
}
let oldDate = Date().addingTimeInterval(-25 * 60 * 60)
try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)
try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelated.path)
service.pruneStaleDownloads()
check(!fm.fileExists(atPath: stale.path), "stale crash files removed")
check(fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: unrelated.path), "fresh and unrelated directories preserved")

// Exercise the actual Process wrapper with deterministic synthetic helpers.
let executable = root.appendingPathComponent("helper")
func helperScript(_ body: String) throws {
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
}
var helper = MTPHelperProcess(executableURL: executable, timeout: 1)
try helperScript("printf 'kindle:1-9981-3\\n'")
check(try helper.connectedDevices() == ["1-9981-3"], "helper protocol")
try helperScript("exit 0")
check(try helper.connectedDevices().isEmpty, "no device is normal")
try helperScript("printf 'unexpected output\\n'")
do { _ = try helper.connectedDevices(); preconditionFailure("invalid response accepted") }
catch MTPHelperError.invalidResponse {}
try helperScript("exit 10")
do { _ = try helper.run(["download"]); preconditionFailure("transfer error accepted") }
catch MTPHelperError.failed(10) {}
try helperScript("kill -ALRM $$")
do { _ = try helper.run([]); preconditionFailure("native watchdog signal accepted") }
catch MTPHelperError.timedOut {}
try helperScript("trap '' TERM\nwhile :; do :; done")
helper.timeout = 0.1
let timeoutStart = Date()
do { _ = try helper.run([]); preconditionFailure("timeout accepted") }
catch MTPHelperError.timedOut {}
check(Date().timeIntervalSince(timeoutStart) < 5, "unresponsive child is killed")
print("MTP Swift tests passed: connection tracking, parser/import, deduplication, cleanup, helper protocol and timeout")
