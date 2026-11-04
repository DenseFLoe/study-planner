import SwiftUI

struct CalendarDateJumpButton: View {
    @Binding var selectedDay: Date
    @Binding var month: Date
    @State private var draft = Date()
    @State private var showing = false

    var body: some View {
        Button("跳到日期") { draft = selectedDay; showing = true }
            .buttonStyle(SoftButtonStyle())
            .focusEffectDisabled()
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("查看指定日期").font(.headline)
                    DatePicker("日期", selection: $draft, displayedComponents: .date)
                    HStack {
                        Button("取消") { showing = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("今天") { draft = Calendar.current.startOfDay(for: Date()) }
                        Button("跳转") {
                            selectedDay = Calendar.current.startOfDay(for: draft)
                            month = selectedDay
                            showing = false
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 300)
            }
    }
}
