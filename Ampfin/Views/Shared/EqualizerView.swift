import SwiftUI

/// A visual 10-band equalizer with vertical sliders and preset picker.
struct EqualizerView: View {
    @ObservedObject private var eq = EqualizerManager.shared

    var body: some View {
        VStack(spacing: 16) {
            // Enable toggle + preset picker
            Toggle("Equalizzatore", isOn: $eq.isEnabled)

            if eq.isEnabled {
                Picker("Preset", selection: $eq.selectedPreset) {
                    ForEach(EQPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }

                // Band sliders
                HStack(alignment: .center, spacing: 0) {
                    ForEach(0..<10, id: \.self) { index in
                        bandSlider(index: index)
                    }
                }
                .frame(height: 200)
                .padding(.horizontal, 4)

                // dB labels
                HStack {
                    Text("+12")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0 dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("-12")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)

                Button("Ripristina piatto") {
                    eq.resetToFlat()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bandSlider(index: Int) -> some View {
        VStack(spacing: 4) {
            // Vertical slider
            GeometryReader { geo in
                let height = geo.size.height
                let normalizedValue = CGFloat((eq.bandGains[index] + 12) / 24) // -12..+12 -> 0..1
                let yPosition = height * (1 - normalizedValue)

                ZStack(alignment: .bottom) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)

                    // Filled portion from center
                    let centerY = height / 2
                    let fillHeight = abs(yPosition - centerY)
                    let fillBottom = min(yPosition, centerY)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 4, height: fillHeight)
                        .offset(y: -(height - fillBottom - fillHeight))

                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .shadow(color: .accentColor.opacity(0.3), radius: 3)
                        .offset(y: -(height - yPosition - 7))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = 1 - (value.location.y / height)
                            let clamped = min(max(ratio, 0), 1)
                            let gain = Float(clamped) * 24 - 12 // 0..1 -> -12..+12
                            eq.setGain(gain, forBand: index)
                        }
                )
            }

            // Frequency label
            Text(EqualizerManager.bandLabels[index])
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
