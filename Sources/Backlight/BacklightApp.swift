import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LightController.shared.start() }
    }
}

@main
struct BacklightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = LightController.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(c: controller)
        } label: {
            Image(systemName: controller.isOn ? "light.strip.2.fill" : "light.strip.2")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @ObservedObject var c: LightController

    private let whites: [(String, Double)] = [("Тёплый", 2700), ("Мягкий", 4000), ("Белый", 6600)]
    private let colors: [RGB] = [
        RGB(r: 1, g: 0, b: 0), RGB(r: 1, g: 0.45, b: 0), RGB(r: 1, g: 0.85, b: 0),
        RGB(r: 0, g: 1, b: 0.2), RGB(r: 0, g: 0.8, b: 1), RGB(r: 0.1, g: 0.2, b: 1),
        RGB(r: 0.6, g: 0, b: 1), RGB(r: 1, g: 0, b: 0.6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Подсветка").font(.headline)
                Spacer()
                Toggle("", isOn: $c.isOn).toggleStyle(.switch).labelsHidden()
            }
            statusLine

            section("Белый") {
                HStack(spacing: 6) {
                    ForEach(whites, id: \.1) { name, k in
                        Button(name) { c.selectWhite(kelvin: k) }
                            .buttonStyle(.bordered)
                            .tint(c.mode == .white && abs(c.kelvin - k) < 1 ? .accentColor : nil)
                    }
                }
                HStack(spacing: 8) {
                    Text("Тепл.").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { c.kelvin }, set: { c.selectWhite(kelvin: $0) }), in: 2200...6600)
                    Text("Хол.").font(.caption).foregroundStyle(.secondary)
                }
            }

            section("Цвет") {
                HStack(spacing: 7) {
                    ForEach(colors.indices, id: \.self) { i in
                        Circle()
                            .fill(colors[i].color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(
                                c.mode == .color && c.customColor == colors[i] ? 0.9 : 0.15), lineWidth: 2))
                            .onTapGesture { c.selectColor(colors[i]) }
                    }
                    ColorPicker("", selection: Binding(get: { c.customColor.color },
                                                       set: { c.selectColor(RGB($0)) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }

            section("Яркость") {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $c.brightness, in: 5...255)
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
                Toggle("Полная яркость", isOn: $c.fullPower)
                Text(c.fullPower
                     ? "Лента берёт заметно больше тока от USB. Если она мигает, желтеет к концу или сбрасывается в радугу — выключите."
                     : "Экономия питания USB, как в SyncLight: белый ≈ 1/3 мощности.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("Гасить, когда экран засыпает", isOn: $c.offWhenDisplaySleeps)
            Toggle("Запускать при входе в систему", isOn: $c.launchAtLogin)
            Divider()

            HStack {
                Button("Применить заново") { c.reapply() }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch c.status {
        case .connected: .green
        case .busy: .orange
        case .disconnected: .gray
        }
    }

    private var statusText: String {
        switch c.status {
        case .connected:
            if let i = c.info { return "Лента подключена · \(i.lamps) LED · прошивка \(i.firmware)" }
            return "Лента подключена"
        case .busy: return "Лента занята другим приложением — закройте SyncLight"
        case .disconnected: return "Лента не найдена"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }
}
