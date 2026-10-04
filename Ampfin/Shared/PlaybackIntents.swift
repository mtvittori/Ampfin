// PlaybackIntents.swift — compiled into the app AND the widget extension.
// Play/pause, next and previous for widget buttons and Control Center. They are
// AudioPlaybackIntents: iOS runs them in the app's process (where the player lives),
// even when the button is tapped in a widget.

import AppIntents
import Foundation

enum PlaybackCommand: Sendable {
    case playPause, next, previous
}

/// Set by the app at launch; the intents call it. Nil in the widget process.
@MainActor
enum PlaybackCommands {
    static var handler: ((PlaybackCommand) -> Void)?

    static func run(_ command: PlaybackCommand) {
        handler?(command)
    }
}

struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Riproduci o metti in pausa"
    static let description = IntentDescription("Mette in pausa o riprende la musica di amplifin.")

    func perform() async throws -> some IntentResult {
        await PlaybackCommands.run(.playPause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Brano successivo"

    func perform() async throws -> some IntentResult {
        await PlaybackCommands.run(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Brano precedente"

    func perform() async throws -> some IntentResult {
        await PlaybackCommands.run(.previous)
        return .result()
    }
}
