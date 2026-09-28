import SwiftUI

/// Liquid Glass panel over the viewfinder: brand tabs, a strip of live-scene thumbnails,
/// and a fine intensity dial for the selected look.
struct FilterBrowser: View {
    let model: CameraModel
    @State private var brand: String = ""
    @State private var mode: Mode = .looks

    enum Mode: Hashable { case looks, grain }

    /// Tab id for the favorites strip (never a real brand name).
    private static let favoritesTab = "★favorites"
    private var inFavorites: Bool { brand == Self.favoritesTab }

    private var looks: [LUTInfo] {
        inFavorites ? model.favoriteLooks : model.library.catalog.filter { $0.brand == brand }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("Adjust", selection: $mode) {
                    Text("Looks").tag(Mode.looks)
                    Text(model.preferences.grain.isActive ? "Grain •" : "Grain").tag(Mode.grain)
                }
                .pickerStyle(.segmented)
                Button {
                    withAnimation(.smooth(duration: 0.25)) { model.showFilters = false }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close filters")
            }

            switch mode {
            case .looks where model.library.catalog.isEmpty:
                Text("No looks installed. Pack your own .cube LUTs with tools/pack_luts.py and rebuild (see the README). Grain works without them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            case .looks:
                brandTabs
                thumbnails
                if let selection = model.preferences.filter, let info = model.library.info(selection.id) {
                    intensityRow(info: info, intensity: selection.intensity)
                }
            case .grain:
                grainControls
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .sensoryFeedback(.success, trigger: model.preferences.favoriteLooks) { _, _ in model.preferences.haptics }
        .onAppear {
            if brand.isEmpty {
                brand = model.filterInfo?.brand ?? model.library.brands.first ?? ""
            }
        }
    }

    private var brandTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach([Self.favoritesTab] + model.library.brands, id: \.self) { name in
                    let active = name == brand
                    Button {
                        brand = name
                    } label: {
                        if name == Self.favoritesTab {
                            Label("Favorites", systemImage: "star.fill").labelStyle(.iconOnly)
                        } else {
                            Text(name)
                        }
                    }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(active ? Color.black : Color.primary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(active ? Color.yellow : Color.clear, in: .capsule)
                        .contentShape(.capsule)
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    FilterTile(title: String(localized: "None"), image: nil,
                               selected: model.preferences.filter == nil) {
                        model.selectFilter(nil)
                    }
                    if inFavorites, looks.isEmpty {
                        Text("Tap and hold a look to add it here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity)
                            .padding(.leading, 8)
                    }
                    ForEach(looks) { info in
                        FilterThumbnail(model: model, info: info, inFavorites: inFavorites)
                            .id(info.id)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .frame(height: 96)
            .onChange(of: brand) {
                if let id = model.preferences.filter?.id, looks.contains(where: { $0.id == id }) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let id = model.preferences.filter?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var grainControls: some View {
        let grain = model.preferences.grain
        let fine = model.preferences.stepSize == .tenth
        return VStack(spacing: 6) {
            grainRow(title: String(localized: "Amount"), valueText: "\(Int((grain.amount * 100).rounded()))%",
                     dial: FineDial(title: String(localized: "Grain Amount"), value: Double(grain.amount * 100), range: 0...100,
                                    step: 1, majorEvery: 25, pointsPerStep: 6 / model.preferences.dialSensitivity,
                                    haptics: model.preferences.haptics,
                                    tickLabel: { "\(Int($0))" }, valueText: { "\(Int($0))%" },
                                    onChange: { v in model.setGrain { $0.amount = Float(v / 100) } }))
            grainRow(title: String(localized: "Size"), valueText: String(format: "%.2f", grain.size),
                     dial: FineDial(title: String(localized: "Grain Size"), value: Double(grain.size), range: 0.5...4,
                                    step: fine ? 0.05 : 0.25, majorEvery: 1, pointsPerStep: (fine ? 6 : 12) / model.preferences.dialSensitivity,
                                    haptics: model.preferences.haptics, isDimmed: !grain.isActive,
                                    tickLabel: { String(format: "%.0f", $0) }, valueText: { String(format: "%.2f", $0) },
                                    onChange: { v in model.setGrain { $0.size = Float(v) } }))
            Text(Grain.isAvailable
                 ? "Monochrome, strongest in the midtones like film. Baked into the HEIC only — the DNG stays clean."
                 : "Grain isn't supported on this device's GPU.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func grainRow(title: String, valueText: String, dial: FineDial) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .frame(width: 58, alignment: .leading)
            dial
            Text(valueText)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.yellow)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func intensityRow(info: LUTInfo, intensity: Float) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(info.group.isEmpty ? info.brand : "\(info.brand) · \(info.group)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
            FineDial(title: String(localized: "Intensity"), value: Double(intensity * 100), range: 0...100,
                     step: 1, majorEvery: 25, pointsPerStep: 6 / model.preferences.dialSensitivity,
                     haptics: model.preferences.haptics,
                     tickLabel: { "\(Int($0))" }, valueText: { "\(Int($0))%" },
                     onChange: { model.setFilterIntensity(Float($0 / 100)) })
            Text("\(Int((intensity * 100).rounded()))%")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.yellow)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct FilterThumbnail: View {
    let model: CameraModel
    let info: LUTInfo
    let inFavorites: Bool
    @State private var image: UIImage?

    var body: some View {
        FilterTile(title: info.name, image: image, selected: model.preferences.filter?.id == info.id,
                   favorite: model.isFavorite(info.id)) {
            model.selectFilter(info.id)
        } hold: {
            if inFavorites { model.removeFavorite(info) } else { model.addFavorite(info) }
        }
        .task(id: info.id) {
            image = await model.thumbnail(for: info.id)
        }
        .accessibilityLabel("\(info.brand) \(info.name)")
        .accessibilityAction(named: inFavorites ? "Remove from Favorites" : "Add to Favorites") {
            if inFavorites { model.removeFavorite(info) } else { model.addFavorite(info) }
        }
    }
}

/// Tap selects; tap-and-hold runs `hold` (favorites). Plain gestures rather than a Button, so a
/// recognized hold doesn't also fire the tap on release.
private struct FilterTile: View {
    let title: String
    let image: UIImage?
    let selected: Bool
    var favorite = false
    let action: () -> Void
    var hold: (() -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if title == String(localized: "None") {
                        Image(systemName: "circle.slash").font(.title3).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 58, height: 72)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.yellow : .clear, lineWidth: 2))
                if favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 62)
                .foregroundStyle(selected ? Color.yellow : Color.primary)
        }
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .onLongPressGesture(minimumDuration: 0.45) { hold?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(favorite ? String(localized: "Favorite") : "")
    }
}
