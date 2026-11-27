import SwiftUI

/// Content of the desktop panel: the CPU and memory cards above the disk card. Dragging anywhere moves the panel
/// (position saved); a double-click puts it back in its default place.
struct PanelView: View {
    let model: AppModel
    let system: SystemModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SystemCards(model: system)
            DiskCard(model: model)
        }
        .frame(width: DiskCard.width)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onResetPosition)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in onDrag(.changed) }
                .onEnded { _ in onDrag(.ended) }
        )
        .padding(12)  // room for the glass's own shadow inside the transparent panel
    }
}
