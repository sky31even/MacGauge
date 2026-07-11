import SwiftUI

@main
struct MacGaugeApp: App {
    @StateObject private var engine = StatsEngine()

    var body: some Scene {
        MenuBarExtra {
            StatusView()
                .environmentObject(engine)
        } label: {
            // The label is in the menu bar from launch, so this starts sampling.
            Label {
                Text(Format.percent(engine.snapshot.cpuPercent))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
            }
            .onAppear { engine.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
