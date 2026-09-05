import SwiftUI
import WidgetKit

@main
struct NostrVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        VaultPulseWidget()
        FeedGlanceWidget()
        QuickActionsWidget()
        SatsWidget()
        MosaicWidget()
        LockScreenWidget()
    }
}
