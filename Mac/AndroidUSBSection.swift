import SwiftUI

/// A focused native connection panel. Details stay secondary to the next action.
struct AndroidUSBSection: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var usb: AndroidUSB

    var body: some View {
        Section {
            if let issue = usb.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .textSelection(.enabled)
                Button("选择 adb…") {
                    let panel = NSOpenPanel()
                    panel.message = "选择 Android platform-tools 中的 adb 可执行文件"
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        UserDefaults.standard.set(url.path, forKey: "androidADBPath")
                        usb.refresh()
                    }
                }
            } else if usb.devices.isEmpty {
                Label("插入安卓平板即可连接", systemImage: "cable.connector")
                    .font(.headline)
                Text("首次使用请开启 USB 调试，并在平板上允许这台 Mac。需要安装社区版 OpenDisplay 安卓接收端。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(usb.devices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    if let session = controller.session(for: "android:\(device.id)") {
                        SessionRow(title: device.name, session: session, controller: controller)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Label(device.name, systemImage: "ipad.landscape")
                                .font(.headline)
                            Spacer()
                            if device.compatible && device.state == "device" {
                                Button("连接") { controller.reconnectAndroid(device.id) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    Text(device.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(device.id).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        if device.compatible && device.state == "device",
                           controller.session(for: "android:\(device.id)") != nil {
                            Button("重新连接") { controller.reconnectAndroid(device.id) }
                                .controlSize(.small)
                                .help("重新建立 USB 转发并启动平板接收端")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("安卓 USB")
                Spacer()
                Button("重新检测") { usb.refresh() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        } footer: {
            Text("插线后自动建立连接；拔线后释放扩展屏，重新插入会自动恢复。主动断开会暂停自动连接。")
        }
    }
}
