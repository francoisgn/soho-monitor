import SwiftUI

/// The cards of the desktop panel, stacked: disk first, then the cards of the enabled modules.
struct PanelStack: View {
    let model: AppModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        VStack(spacing: -12) {  // each card keeps 12 pt around its glass for the shadow: overlap those margins
            DiskCard(model: model, onDrag: onDrag, onResetPosition: onResetPosition)
            if model.claude.isEnabled {
                ClaudeCard(model: model.claude, onDrag: onDrag, onResetPosition: onResetPosition)
            }
        }
    }
}
