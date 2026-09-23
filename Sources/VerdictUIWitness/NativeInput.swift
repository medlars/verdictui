import ApplicationServices
import AppKit
import Foundation

/// Public Quartz input addressed to one process. No global event tap, app
/// activation, cursor warp, or private API is used.
///
/// Quartz posting has no delivery acknowledgement. A successful return means
/// input was posted; the caller must read the app again and check the requested
/// outcome before claiming the action succeeded.
public struct NativeInput {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidPID
        case processUnavailable(pid_t)
        case invalidPoint
        case invalidKeyChord
        case emptyText
        case permissionDenied
        case eventCreationFailed
        case targetWindowUnavailable

        public var description: String {
            switch self {
            case .invalidPID: "native input requires an application PID greater than 1"
            case .processUnavailable(let pid): "native input target process \(pid) is unavailable"
            case .invalidPoint: "native input coordinates must be finite display points"
            case .invalidKeyChord: "invalid key chord; use a supported key with distinct modifiers"
            case .emptyText: "native input text must not be empty"
            case .permissionDenied: "macOS denied input event posting; no input was sent"
            case .eventCreationFailed: "macOS could not create the requested input event"
            case .targetWindowUnavailable: "the requested target-process window is unavailable or ambiguous"
            }
        }
    }

    /// Coordinates in the global, top-left-origin display space AX publishes.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) throws {
            guard x.isFinite, y.isFinite else { throw Failure.invalidPoint }
            self.x = x
            self.y = y
        }

        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    /// A physical ANSI key plus optional command/control/option/shift modifiers.
    /// Use ``NativeInput/type(_:to:)`` for layout-independent Unicode text.
    public struct KeyChord: Equatable, Sendable {
        public let keyCode: CGKeyCode
        private let rawFlags: UInt64
        public var modifierFlags: CGEventFlags { CGEventFlags(rawValue: rawFlags) }

        public init(_ specification: String) throws {
            let tokens = specification.lowercased().split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = tokens.last, let code = Self.keys[key] else {
                throw Failure.invalidKeyChord
            }
            var flags: CGEventFlags = []
            for token in tokens.dropLast() {
                let flag: CGEventFlags
                switch token {
                case "cmd", "command": flag = .maskCommand
                case "ctrl", "control": flag = .maskControl
                case "alt", "option": flag = .maskAlternate
                case "shift": flag = .maskShift
                default: throw Failure.invalidKeyChord
                }
                guard !flags.contains(flag) else { throw Failure.invalidKeyChord }
                flags.insert(flag)
            }
            keyCode = code
            rawFlags = flags.rawValue
        }

        private static let keys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
            ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "tab": 48, "space": 49, "`": 50, "backspace": 51, "escape": 53,
            "esc": 53, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
            "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
            "f12": 111, "home": 115, "pageup": 116, "delete": 117, "end": 119,
            "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
    }

    private let permission: () -> Bool
    private let isAlive: (pid_t) -> Bool
    private let post: (CGEvent, pid_t) -> Void
    private let windowAtPoint: (pid_t, CGPoint) -> CGWindowID?
    private let windowFrame: (CGWindowID) -> CGRect?

    public init() {
        self.init(
            permission: { CGPreflightPostEventAccess() },
            isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
            windowAtPoint: Self.windowAtPoint,
            windowFrame: Self.windowFrame,
            post: { event, pid in event.postToPid(pid) })
    }

    /// Bind an AX-selected surface to its exact window rather than whichever
    /// same-process window happens to cover the point. Ambiguous geometry is
    /// refused: the public AX API does not expose a portable window-server ID.
    init(targetPID pid: pid_t, matchingWindowFrame frame: CGRect) throws {
        try NativeInput().validate(pid)
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let id = Self.matchingWindow(pid: pid, frame: frame, windows: windows) else {
            throw Failure.targetWindowUnavailable
        }
        self.init(
            permission: { CGPreflightPostEventAccess() },
            isAlive: { candidate in candidate == pid && (kill(pid, 0) == 0 || errno == EPERM) },
            windowAtPoint: { candidate, _ in candidate == pid ? id : nil },
            windowFrame: Self.windowFrame,
            post: { event, candidate in event.postToPid(candidate) })
    }

    static func matchingWindow(pid: pid_t, frame: CGRect, windows: [[String: Any]]) -> CGWindowID? {
        let candidates: [CGWindowID] = windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let candidate = CGRect(dictionaryRepresentation: bounds),
                abs(candidate.minX - frame.minX) <= 0.5, abs(candidate.minY - frame.minY) <= 0.5,
                abs(candidate.width - frame.width) <= 0.5, abs(candidate.height - frame.height) <= 0.5
            else { return nil }
            return window[kCGWindowNumber as String] as? CGWindowID
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    /// Dependency seam exercises permission denial and the exact event stream
    /// without sending events to another process during unit tests.
    init(
        permission: @escaping () -> Bool, isAlive: @escaping (pid_t) -> Bool,
        windowAtPoint: @escaping (pid_t, CGPoint) -> CGWindowID? = { _, _ in 1 },
        windowFrame: @escaping (CGWindowID) -> CGRect? = { _ in CGRect(x: 0, y: 0, width: 1000, height: 1000) },
        post: @escaping (CGEvent, pid_t) -> Void
    ) {
        self.permission = permission
        self.isAlive = isAlive
        self.post = post
        self.windowAtPoint = windowAtPoint
        self.windowFrame = windowFrame
    }

    public func type(_ text: String, to pid: pid_t) throws {
        try validate(pid)
        guard !text.isEmpty else { throw Failure.emptyText }
        let source = try source()
        var events: [CGEvent] = []
        // Keep UTF-16 surrogate pairs in the SAME event. Posting one code unit
        // at a time corrupts emoji and other supplementary Unicode scalars.
        var chunks: [[UInt16]] = []
        var chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                chunks.append(chunk)
                chunk = []
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        for units in chunks {
            for down in [true, false] {
                let event = try keyboard(source: source, key: 0, down: down, flags: [])
                units.withUnsafeBufferPointer {
                    if let address = $0.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: address)
                    }
                }
                events.append(event)
            }
        }
        send(events, to: pid)
    }

    public func key(_ chord: KeyChord, to pid: pid_t) throws {
        try validate(pid)
        let source = try source()
        let events = try [true, false].map {
            try keyboard(source: source, key: chord.keyCode, down: $0, flags: chord.modifierFlags)
        }
        send(events, to: pid)
    }

    public func click(at point: Point, to pid: pid_t) throws {
        try validate(pid)
        let window = try targetWindow(pid: pid, point: point.cgPoint)
        let source = try source()
        let events = try [CGEventType.leftMouseDown, .leftMouseUp].map {
            try mouse(source: source, type: $0, at: point.cgPoint)
        }
        try sendMouse(events, to: pid, window: window)
    }

    public func hover(at point: Point, to pid: pid_t) throws {
        try validate(pid)
        let window = try targetWindow(pid: pid, point: point.cgPoint)
        try sendMouse([try mouse(source: source(), type: .mouseMoved, at: point.cgPoint)], to: pid, window: window)
    }

    public func drag(from start: Point, to end: Point, pid: pid_t) throws {
        try validate(pid)
        let window = try targetWindow(pid: pid, point: start.cgPoint)
        let source = try source()
        var events = [try mouse(source: source, type: .leftMouseDown, at: start.cgPoint)]
        for step in 1...12 {
            let fraction = Double(step) / 12
            // Weighted addition avoids overflow from end - start for finite
            // endpoints at opposite extremes of the coordinate range.
            let point = try Point(
                x: start.x * (1 - fraction) + end.x * fraction,
                y: start.y * (1 - fraction) + end.y * fraction)
            events.append(try mouse(source: source, type: .leftMouseDragged, at: point.cgPoint))
        }
        events.append(try mouse(source: source, type: .leftMouseUp, at: end.cgPoint))
        try sendMouse(events, to: pid, window: window)
    }

    private func validate(_ pid: pid_t) throws {
        guard pid > 1 else { throw Failure.invalidPID }
        guard isAlive(pid) else { throw Failure.processUnavailable(pid) }
        guard permission() else { throw Failure.permissionDenied }
    }

    private func source() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw Failure.eventCreationFailed
        }
        return source
    }

    private func keyboard(
        source: CGEventSource, key: CGKeyCode, down: Bool, flags: CGEventFlags
    ) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
            throw Failure.eventCreationFailed
        }
        event.flags = flags
        return event
    }

    private func mouse(source: CGEventSource, type: CGEventType, at point: CGPoint) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { throw Failure.eventCreationFailed }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    private func send(_ events: [CGEvent], to pid: pid_t) {
        // Construct the whole sequence first: allocation failure cannot leave
        // a button down. The sink is exclusively CGEventPostToPid.
        for event in events { post(event, pid) }
    }

    private func sendMouse(_ events: [CGEvent], to pid: pid_t, window: CGWindowID) throws {
        guard let frame = windowFrame(window) else { throw Failure.targetWindowUnavailable }
        // A raw CGEvent reaches NSApplication with windowNumber == 0. Its
        // public window-under-pointer fields do not establish the destination.
        // NSEvent's constructor does. When that window belongs to ANOTHER
        // process, its CG conversion flips y against the sender's display;
        // the receiver interprets the result in window-relative top-left
        // coordinates. Compensate for that flip before conversion. The live
        // fixture asserts actual mouseDown/drag handlers, not just event bytes.
        let addressed: [CGEvent] = try events.map { event in
            guard let kind = NSEvent.EventType(rawValue: UInt(event.type.rawValue)),
                let appEvent = NSEvent.mouseEvent(
                    with: kind,
                    location: CGPoint(
                        x: event.location.x - frame.minX,
                        y: CGDisplayBounds(CGMainDisplayID()).height + frame.minY - event.location.y),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(window),
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                let quartz = appEvent.cgEvent
            else { throw Failure.eventCreationFailed }
            quartz.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            quartz.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            return quartz
        }
        send(addressed, to: pid)
    }

    private func targetWindow(pid: pid_t, point: CGPoint) throws -> CGWindowID {
        guard let window = windowAtPoint(pid, point) else { throw Failure.targetWindowUnavailable }
        return window
    }

    private static func windowAtPoint(pid: pid_t, point: CGPoint) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point),
                let id = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return id
        }
        return nil
    }

    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        guard let bounds = windows.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}
