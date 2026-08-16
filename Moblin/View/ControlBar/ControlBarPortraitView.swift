import SwiftUI

@available(iOS 17, *)
private struct ControlBarPageScrollTargetBehavior: ScrollTargetBehavior {
    let model: Model

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = controlBarScrollTargetBehavior(
            model: model,
            containerWidth: context.containerSize.height,
            targetPosition: target.rect.minY
        )
    }
}

private struct QuickButtonsView: View {
    let model: Model
    @ObservedObject var quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    let page: Int
    let height: Double

    private func buttonSize() -> Double {
        if quickButtonsSettings.bigButtons {
            controlBarQuickButtonSingleQuickButtonSize
        } else {
            controlBarButtonSize
        }
    }

    var body: some View {
        HStack {
            ForEach(model.getQuickButtonPairs(page: page + 1)) { pair in
                if quickButtonsSettings.twoColumns {
                    VStack(alignment: .leading) {
                        if let second = pair.second {
                            QuickButtonsInnerView(
                                quickButtons: quickButtons,
                                quickButtonsSettings: quickButtonsSettings,
                                orientation: model.orientation,
                                state: second,
                                size: buttonSize(),
                                nameSize: buttonSize(),
                                nameWidth: buttonSize()
                            )
                        } else {
                            QuickButtonPlaceholderImage(size: buttonSize())
                        }
                        QuickButtonsInnerView(
                            quickButtons: quickButtons,
                            quickButtonsSettings: quickButtonsSettings,
                            orientation: model.orientation,
                            state: pair.first,
                            size: buttonSize(),
                            nameSize: buttonSize(),
                            nameWidth: buttonSize()
                        )
                    }
                } else {
                    if let second = pair.second {
                        QuickButtonsInnerView(
                            quickButtons: quickButtons,
                            quickButtonsSettings: quickButtonsSettings,
                            orientation: model.orientation,
                            state: second,
                            size: buttonSize(),
                            nameSize: buttonSize(),
                            nameWidth: buttonSize()
                        )
                        .frame(height: height - 10)
                    }
                    QuickButtonsInnerView(
                        quickButtons: quickButtons,
                        quickButtonsSettings: quickButtonsSettings,
                        orientation: model.orientation,
                        state: pair.first,
                        size: buttonSize(),
                        nameSize: buttonSize(),
                        nameWidth: buttonSize()
                    )
                    .frame(height: height - 10)
                }
            }
        }
    }
}

private struct PageView: View {
    let model: Model
    let quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    var page: Int
    var height: Double

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            QuickButtonsView(model: model,
                             quickButtons: quickButtons,
                             quickButtonsSettings: quickButtonsSettings,
                             page: page,
                             height: height)
        }
        .scrollDisabled(!quickButtonsSettings.enableScroll)
        .rotationEffect(.degrees(180))
    }
}

private struct IconAndSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleShowingPanel(type: nil, panel: .settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button {
                model.reattachCamera()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
    }
}

private struct CompactDrawerButton: View {
    let model: Model
    let panel: ShowingPanel
    let icon: String
    let label: String

    var body: some View {
        Button {
            model.toggleShowingPanel(type: nil, panel: panel)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CompactDrawerRow: View {
    let model: Model

    var body: some View {
        HStack(spacing: 14) {
            CompactDrawerButton(
                model: model,
                panel: .bitrate,
                icon: "speedometer",
                label: String(localized: "Bitrate")
            )
            CompactDrawerButton(model: model, panel: .mic, icon: "mic", label: String(localized: "Mic"))
            CompactDrawerButton(
                model: model,
                panel: .recordings,
                icon: "record.circle",
                label: String(localized: "Record")
            )
            CompactDrawerButton(model: model, panel: .ctLive, icon: "flag.checkered", label: "CTLive")
        }
    }
}

private struct MainPageView: View {
    let model: Model
    @ObservedObject var quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    @ObservedObject var status: StatusOther
    var height: Double
    @State var presentingThermalState: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                // Compact only. See the note in the landscape control bar.
                CompactDrawerRow(model: model)
                    .padding(.leading, 10)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button {
                        presentingThermalState.toggle()
                    } label: {
                        ThermalStateView(thermalState: status.thermalState)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.top, 3)
                .padding(.trailing, 5)
                .padding(.leading, 0)
                IconAndSettingsView(store: model.store)
                StreamButton()
                    .padding(.top, 10)
                    .padding(.horizontal, 5)
            }
            .padding(.leading, 0)
            .frame(width: controlBarWidthDefault + 30)
            .sheet(isPresented: $presentingThermalState) {
                ThermalStateSheetView(presenting: $presentingThermalState)
            }
        }
    }
}

struct ControlBarPortraitView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var quickButtons: SettingsQuickButtons

    var body: some View {
        MainPageView(model: model,
                     quickButtons: model.quickButtons,
                     quickButtonsSettings: quickButtons,
                     status: model.statusOther,
                     height: controlBarWidthDefault)
            .frame(height: controlBarWidthDefault)
            .background(.black)
            .ignoresSafeArea(.all, edges: [.bottom])
    }
}
