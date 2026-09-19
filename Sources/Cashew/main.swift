import AppKit
import CashewCore

// Everything lives in CashewCore so the test target can reach it. This file exists only because
// top-level code has to be in an executable target's main.swift — keep it this small.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
