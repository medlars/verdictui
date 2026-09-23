"""Native input refusal, coordinate routing, and key validation witnesses."""

from mutation_catalog_types import Mutation

MUTATIONS: list[Mutation] = [
    Mutation(
        name="native input accepts non-finite display coordinates",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard x.isFinite, y.isFinite else { throw Failure.invalidPoint }",
        new="_ = x.isFinite && y.isFinite",
        test="NativeInputTests/testNonFiniteCoordinatesAreRefused",
    ),
    Mutation(
        name="native input accepts system and broadcast PIDs",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard pid > 1 else { throw Failure.invalidPID }",
        new="_ = pid > 1",
        test="NativeInputTests/testInvalidOrDeadPIDPostsNothing",
    ),
    Mutation(
        name="native input posts to a dead process",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard isAlive(pid) else { throw Failure.processUnavailable(pid) }",
        new="_ = isAlive(pid)",
        test="NativeInputTests/testInvalidOrDeadPIDPostsNothing",
    ),
    Mutation(
        name="native input silently proceeds after event-posting denial",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard permission() else { throw Failure.permissionDenied }",
        new="_ = permission()",
        test="NativeInputTests/testDeniedPermissionPostsNothing",
    ),
    Mutation(
        name="native input accepts empty text as a successful act",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard !text.isEmpty else { throw Failure.emptyText }",
        new="_ = text.isEmpty",
        test="NativeInputTests/testEmptyTextIsRefusedBeforePosting",
    ),
    Mutation(
        name="native key chords accept repeated modifiers",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard !flags.contains(flag) else { throw Failure.invalidKeyChord }",
        new="_ = flags.contains(flag)",
        test="NativeInputTests/testKeyChordsValidateTheWholeSpecification",
    ),
    Mutation(
        name="native key chords invent a modifier for an unknown token",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="default: throw Failure.invalidKeyChord",
        new="default: flag = .maskShift",
        test="NativeInputTests/testKeyChordsValidateTheWholeSpecification",
    ),
    Mutation(
        name="native input posts without a target window",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard let window = windowAtPoint(pid, point) else { throw Failure.targetWindowUnavailable }",
        new="let window = windowAtPoint(pid, point) ?? 0",
        test="NativeInputTests/testMouseInputWithoutATargetWindowIsRefusedBeforePosting",
    ),
    Mutation(
        name="native input invents missing window geometry",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="guard let frame = windowFrame(window) else { throw Failure.targetWindowUnavailable }",
        new="let frame = windowFrame(window) ?? .zero",
        test="NativeInputTests/testMouseInputWithoutWindowGeometryIsRefusedBeforePosting",
    ),
    Mutation(
        name="native mouse events lose the receiving window",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="windowNumber: Int(window),",
        new="windowNumber: 0,",
        test="NativeInputTests/testForeignWindowEventsUseItsIDAndRelativeCoordinates",
    ),
    Mutation(
        name="native mouse coordinates omit the receiving window origin",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="y: CGDisplayBounds(CGMainDisplayID()).height + frame.minY - event.location.y),",
        new="y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y),",
        test="NativeInputTests/testForeignWindowEventsUseItsIDAndRelativeCoordinates",
    ),
    Mutation(
        name="native input drops the Unicode chunk before a supplementary scalar",
        path="Sources/VerdictUIWitness/NativeInput.swift",
        old="if chunk.count + units.count > 20 {\n                chunks.append(chunk)",
        new="if chunk.count + units.count > 20 {\n                _ = chunk",
        test="NativeInputTests/testLongUnicodeChunksDoNotSplitASurrogatePair",
    ),
    Mutation(
        name="AX native actions accept a broadcast process identifier",
        path="Sources/VerdictUIWitness/AXActions.swift",
        old="guard pid > 1 else { throw NativeInput.Failure.invalidPID }",
        new="_ = pid > 1",
        test="AXActionTests/testInvalidPIDIsRejectedBeforeAccessibilityLookup",
    ),
]
