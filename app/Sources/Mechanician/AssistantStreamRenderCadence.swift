import Foundation

/// Bounds presentation work while an assistant response is growing.
///
/// Provider deltas are still accepted and buffered immediately. Only the foreground transcript's
/// paint cadence changes: terminal events, completed frames, tools, and errors synchronously flush
/// the exact pending text before they mutate turn state. This keeps the provider harness entirely
/// unconstrained while avoiding an accumulated Markdown parse and whole-transcript projection at
/// 60 Hz after either input has become large.
enum AssistantStreamRenderCadence {
    static func framesPerSecond(
        accumulatedUTF8Bytes: Int,
        transcriptEntryCount: Int
    ) -> Double {
        min(
            responseFramesPerSecond(max(0, accumulatedUTF8Bytes)),
            transcriptFramesPerSecond(max(0, transcriptEntryCount)))
    }

    static func delay(
        accumulatedUTF8Bytes: Int,
        transcriptEntryCount: Int
    ) -> TimeInterval {
        1 / framesPerSecond(
            accumulatedUTF8Bytes: accumulatedUTF8Bytes,
            transcriptEntryCount: transcriptEntryCount)
    }

    private static func responseFramesPerSecond(_ bytes: Int) -> Double {
        switch bytes {
        case ..<(16 * 1_024): 60
        case ..<(64 * 1_024): 30
        case ..<(256 * 1_024): 15
        case ..<(1_024 * 1_024): 8
        default: 4
        }
    }

    private static func transcriptFramesPerSecond(_ entries: Int) -> Double {
        switch entries {
        case ..<512: 60
        case ..<2_048: 30
        case ..<8_192: 15
        default: 8
        }
    }
}
