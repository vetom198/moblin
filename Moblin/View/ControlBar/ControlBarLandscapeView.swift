import SwiftUI

private func edgesToIgnore() -> Edge.Set {
    if isPhone() {
        [.trailing]
    } else {
        []
    }
}

func controlBarWidth(quickButtons: SettingsQuickButtons) -> Double {
    if quickButtons.bigButtons, quickButtons.twoColumns {
        controlBarWidthBigQuickButtons
    } else {
        controlBarWidthDefault
    }
}

private struct QuickButtonsView: View {
    let model: Model
    @ObservedObject var quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    let page: Int
    let width: Double

    private func buttonSize() -> Double {
        if quickButtonsSettings.bigButtons {
            controlBarQuickButtonSingleQuickButtonSize
        } else {
            controlBarButtonSize
        }
    }

    private func nameSize() -> Double {
        if quickButtonsSettings.bigButtons {
            controlBarQuickButtonNameSingleColumnSize
        } else {
            controlBarQuickButtonNameSize
        }
    }

    var body: some View {
        VStack {
            ForEach(model.getQuickButtonPairs(page: page + 1)) { pair in
                if quickButtonsSettings.twoColumns {
                    HStack(alignment: .bottom) {
                        if let second = pair.second {
                            QuickButtonsInnerView(
                                quickButtons: quickButtons,
                                quickButtonsSettings: quickButtonsSettings,
                                orientation: model.orientation,
                                state: second,
                                size: buttonSize(),
                                nameSize: nameSize(),
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
                            nameSize: nameSize(),
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
                            nameSize: nameSize(),
                            nameWidth: width - 10
                        )
                        .frame(width: width - 10)
                    }
                    QuickButtonsInnerView(
                        quickButtons: quickButtons,
                        quickButtonsSettings: quickButtonsSettings,
                        orientation: model.orientation,
                        state: pair.first,
                        size: buttonSize(),
                        nameSize: nameSize(),
                        nameWidth: width - 10
                    )
                    .frame(width: width - 10)
                }
            }
        }
    }
}

private struct StatusView: View {
    let model: Model
    @ObservedObject var status: StatusOther
    @State var presentingThermalState: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isPhone() {
                BatteryView(model: model, battery: model.battery)
            }
            Spacer(minLength: 0)
            Button {
                presentingThermalState.toggle()
            } label: {
                ThermalStateView(thermalState: status.thermalState)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if isPhone() {
                Text(status.digitalClock)
                    .foregroundStyle(.white)
                    .font(smallFont)
            }
        }
        .padding([.leading, .bottom], 0)
        .padding(.trailing, 5)
        .sheet(isPresented: $presentingThermalState) {
            ThermalStateSheetView(presenting: $presentingThermalState)
        }
    }
}

private struct IconAndSettingsView: View {
    let model: Model
    @ObservedObject var store: Store
    @Binding var drawerOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleShowingPanel(type: nil, panel: .settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderless)
            Button {
                drawerOpen.toggle()
            } label: {
                Image(systemName: drawerOpen ? "shippingbox.fill" : "shippingbox")
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderless)
            Button {
                model.reattachCamera()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: controlBarButtonSize, height: controlBarButtonSize)
                    .overlay(Circle().stroke(.secondary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderless)
        }
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

private struct CompactDrawerView: View {
    let model: Model

    var body: some View {
        VStack(spacing: 10) {
            CompactDrawerButton(model: model, panel: .bitrate, icon: "speedometer", label: String(localized: "Bitrate"))
            CompactDrawerButton(model: model, panel: .mic, icon: "mic", label: String(localized: "Mic"))
            CompactDrawerButton(model: model, panel: .recordings, icon: "record.circle", label: String(localized: "Record"))
            CompactDrawerButton(model: model, panel: .obs, icon: "tv", label: "OBS")
        }
        .padding(.top, 10)
    }
}

private struct PageView: View {
    let model: Model
    let quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    let page: Int
    let width: Double

    var body: some View {
        ScrollView(showsIndicators: false) {
            QuickButtonsView(model: model,
                             quickButtons: quickButtons,
                             quickButtonsSettings: quickButtonsSettings,
                             page: page,
                             width: width)
        }
        .scrollDisabled(!quickButtonsSettings.enableScroll)
        .rotationEffect(.degrees(180))
        .padding(.horizontal, 0)
    }
}

private struct MainPageView: View {
    let model: Model
    @ObservedObject var quickButtons: QuickButtons
    @ObservedObject var quickButtonsSettings: SettingsQuickButtons
    let store: Store
    let width: Double
    // Default: compact view with 4 fixed buttons (Bitrate / Mic / Record /
    // OBS). When the user taps the box icon we swap to the original
    // multi-button list configured in Settings > Quick buttons.
    @State private var showFullPanel: Bool = false

    private func buttonsWidth() -> Double {
        width - 10
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            IconAndSettingsView(model: model, store: store, drawerOpen: $showFullPanel)
                .padding(.vertical, 2)
                .frame(width: buttonsWidth())
            if showFullPanel {
                PageView(model: model,
                         quickButtons: quickButtons,
                         quickButtonsSettings: quickButtonsSettings,
                         page: 0,
                         width: width)
            } else {
                CompactDrawerView(model: model)
                    .frame(width: buttonsWidth())
            }
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                StreamButton()
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .frame(width: buttonsWidth())
            .padding(.bottom, 8)
        }
    }
}

@available(iOS 17, *)
private struct ControlBarPageScrollTargetBehavior: ScrollTargetBehavior {
    let model: Model

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = controlBarScrollTargetBehavior(
            model: model,
            containerWidth: context.containerSize.width,
            targetPosition: target.rect.minX
        )
    }
}

private struct PageIndicatorView: View {
    @ObservedObject var quickButtons: QuickButtons

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1 ... controlBarPages, id: \.self) { page in
                Image(systemName: quickButtons.activePage == page ? "circle.fill" : "circle")
                    .font(.system(size: 5))
                    .padding(.bottom, 0)
                    .foregroundStyle(.white)
            }
        }
    }
}

struct ControlBarLandscapeView: View {
    let model: Model
    @ObservedObject var quickButtons: SettingsQuickButtons

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !isPhone() {
                    Spacer(minLength: 0)
                }
                StatusView(model: model, status: model.statusOther)
                    .frame(width: controlBarWidthDefault)
                Spacer(minLength: 0)
            }
            MainPageView(model: model,
                         quickButtons: model.quickButtons,
                         quickButtonsSettings: quickButtons,
                         store: model.store,
                         width: controlBarWidthDefault)
        }
        .padding(.vertical, 0)
        .frame(width: controlBarWidthDefault)
        .background(.black)
        .ignoresSafeArea(.all, edges: edgesToIgnore())
    }
}
