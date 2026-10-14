import SwiftUI

struct DailyStudyWeightPicker: View {
    @Binding var weight: Double

    var body: some View {
        HStack(spacing: 10) {
            Text("每日加量").font(.callout.weight(.medium))
            Picker("每日加量", selection: $weight) {
                Text("标准").tag(1.0)
                Text("1.5 倍").tag(1.5)
                Text("2 倍").tag(2.0)
                Text("3 倍").tag(3.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
