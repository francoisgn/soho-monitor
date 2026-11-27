import SwiftUI

/// The cards of the desktop panel, stacked from the top: CPU and memory, disk, then the cards of the enabled modules.
struct PanelStack: View {
    let model: AppModel
    let system: SystemModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        VStack(spacing: -12) {  // each card keeps 12 pt around its glass for the shadow: overlap those margins
            SystemCards(model: system)
                .frame(width: DiskCard.width)
                .panelDraggable(onDrag: onDrag, onResetPosition: onResetPosition)
            DiskCard(model: model, onDrag: onDrag, onResetPosition: onResetPosition)
            if model.claude.isEnabled {
                ClaudeCard(model: model.claude, onDrag: onDrag, onResetPosition: onResetPosition)
            }
        }
    }
}

extension View {
    /// Drag anywhere to move the panel (position saved), double-click to put it back in its default place; 12 pt
    /// around for the glass's own shadow inside the transparent panel. Same behaviour as the disk and Claude cards.
    func panelDraggable(
        onDrag: @escaping (DesktopPanelController.DragPhase) -> Void, onResetPosition: @escaping () -> Void
    ) -> some View {
        contentShape(.rect)
            .onTapGesture(count: 2, perform: onResetPosition)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { _ in onDrag(.changed) }
                    .onEnded { _ in onDrag(.ended) }
            )
            .padding(12)
    }
}
