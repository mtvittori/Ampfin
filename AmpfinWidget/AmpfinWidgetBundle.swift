import WidgetKit
import SwiftUI

@main
struct AmpfinWidgetBundle: WidgetBundle {
    var body: some Widget {
        AmpfinNowPlayingWidget()
        AmpfinRecentWidget()
        AmpfinFavoritesWidget()
        #if os(iOS)
        PlayPauseControl()
        NextTrackControl()
        #endif
    }
}
