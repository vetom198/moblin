import SwiftUI

// The compact control bar used to draw its controls as hairline circles: a
// 1 pt stroke around a glyph with a 9 pt caption, which reads fine indoors and
// disappears on a start line in daylight. These cards replace that. Each
// control is a filled surface with its icon and name inside, and a control
// with a state to show tints the whole card rather than just the glyph, so
// recording reads as a red card from an arm's length away, not as a small red
// dot.
//
// Layout rules learned the hard way and kept: the cards fill the width the bar
// hands them and never widen it, because the bar's frame is exactly what its
// parent reserves and what the layout system hit-tests. The whole card is the
// touch target.

private let controlBarCardCornerRadius = 12.0
let controlBarCardHeight = 52.0

private func cardShape() -> RoundedRectangle {
    RoundedRectangle(cornerRadius: controlBarCardCornerRadius, style: .continuous)
}

struct ControlBarCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ControlBarCardLabel: View {
    let icon: String
    let label: String
    // Nil is the resting look. A color floods the card with it, for states
    // that must be readable without looking closely.
    var tint: Color?

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(tint ?? .white)
        .frame(maxWidth: .infinity)
        .frame(height: controlBarCardHeight)
        .background(cardShape().fill((tint ?? Color.white).opacity(tint == nil ? 0.09 : 0.22)))
        .overlay(cardShape().stroke((tint ?? Color.white).opacity(tint == nil ? 0.18 : 0.6), lineWidth: 1))
        .contentShape(cardShape())
    }
}

// The settings and camera-reattach controls: present, but visually quieter
// than the cards, because neither is something an operator reaches for during
// a broadcast.
struct ControlBarSmallCardButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(cardShape().fill(.white.opacity(0.09)))
                .overlay(cardShape().stroke(.white.opacity(0.18), lineWidth: 1))
                .contentShape(cardShape())
        }
        .buttonStyle(ControlBarCardButtonStyle())
    }
}

struct ControlBarPanelCardButton: View {
    let model: Model
    let panel: ShowingPanel
    let icon: String
    let label: String

    var body: some View {
        Button {
            model.toggleShowingPanel(type: nil, panel: panel)
        } label: {
            ControlBarCardLabel(icon: icon, label: label)
        }
        .buttonStyle(ControlBarCardButtonStyle())
    }
}

// The Record entry in settings opens the list of recordings, which is not the
// same thing as starting one. With the full quick button list hidden there was
// nowhere left to actually begin or end a recording, so this is that control:
// state visible at a glance, because an operator has to be able to tell from
// across a bike whether the camera is rolling.
struct ControlBarRecordCardButton: View {
    @ObservedObject var model: Model
    @State private var presentingConfirm = false

    private func toggle() {
        model.toggleRecording()
    }

    var body: some View {
        Button {
            if model.database.startStopRecordingConfirmations {
                presentingConfirm = true
            } else {
                toggle()
            }
        } label: {
            ControlBarCardLabel(
                icon: model.isRecording ? "record.circle.fill" : "record.circle",
                label: model.isRecording
                    ? String(localized: "Recording")
                    : String(localized: "Record"),
                tint: model.isRecording ? .red : nil
            )
        }
        .buttonStyle(ControlBarCardButtonStyle())
        .confirmationDialog("", isPresented: $presentingConfirm) {
            Button(model.isRecording ? "Stop recording" : "Start recording") {
                toggle()
            }
        }
    }
}
