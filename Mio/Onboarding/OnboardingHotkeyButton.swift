//
//  OnboardingHotkeyButton.swift
//  Mio
//
//  Onboarding 三页共用的"快捷键设置按钮"。
//
//  设计取舍：
//    - 不做 sheet/弹窗，inline 录入：点一下进入"按下任意组合…"，
//      监听到下一个 keyDown 即写入。和 SettingsView 的录入逻辑同源
//      （NSEvent.addLocalMonitorForEvents + HotKeyManager.setRecordingHotKey），
//      避免在 onboarding 现场出现两套录入交互。
//    - 默认显示当前 hotkey 值（如 ⌥⌘S）。"老用户已自定义"和"新用户走默认"
//      在 HotKeySettings.init 那一层就已合一——这里只读 Binding，不再做
//      "探测系统其它 app 用过什么键"的工作（macOS 没有该 API）。
//    - macOS 26 使用 .glass 胶囊大按钮；macOS 15–25 回退到原生 bordered
//      样式。两种系统下都与底栏"返回 / 下一步"保持一致。
//    - 录入态不抢焦点：只挂 local monitor，把按下的组合写入 binding；
//      用户随时点"取消"或按 ESC 返回。
//

import SwiftUI
import AppKit

struct OnboardingHotkeyButton: View {
    @Binding var hotkey: HotKey

    @State private var isRecording = false
    @State private var localMonitor: Any?

    /// 按钮内文字。录入中显示提示语，未配置显示"未设置"，否则显示当前组合。
    private var label: LocalizedStringKey {
        if isRecording {
            return "onboarding.hotkey.recording"
        }
        if hotkey.isUnset {
            return "onboarding.hotkey.unset"
        }
        // 组合键 symbol 字面（如 ⌥⌘S）跨语言相同,不需要本地化:把它包成
        // LocalizedStringKey 等价于一条永远找不到 key 的回退路径,SwiftUI
        // 会原样渲染,不进 xcstrings。
        return LocalizedStringKey(hotkey.symbolDisplayString)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "keyboard.fill" : "keyboard")
                        .font(.body.weight(.semibold))
                    Text(label)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(minWidth: 96)
                        .contentTransition(.opacity)
                }
                .frame(minHeight: 32)
            }
            .onboardingSecondaryButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .accessibilityLabel(Text(isRecording
                                     ? "onboarding.hotkey.cancel_recording"
                                     : "onboarding.hotkey.change"))
            .accessibilityValue(hotkey.isUnset
                                ? Text("onboarding.hotkey.unset")
                                : Text(hotkey.symbolDisplayString))

            // 清除按钮：未配置或录入中时隐藏（保持布局占位避免抖动）。
            Button {
                hotkey = .unset
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hotkey.isUnset || isRecording ? 0 : 1)
            .disabled(hotkey.isUnset || isRecording)
            .help(Text("onboarding.hotkey.clear"))
            .accessibilityLabel(Text("onboarding.hotkey.clear"))
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard localMonitor == nil else { return }
        isRecording = true
        HotKeyManager.shared.setRecordingHotKey(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // SAFETY: NSEvent.addLocalMonitorForEvents always delivers on main thread.
            MainActor.assumeIsolated {
                // ESC 取消录入,不写入。
                if event.keyCode == 53 {
                    stopRecording()
                    return
                }
                let modifiers = HotKey.normalizedModifiers(event.modifierFlags)
                let characters = event.charactersIgnoringModifiers?.lowercased()
                hotkey = HotKey(
                    keyCode: event.keyCode,
                    modifiers: modifiers.rawValue,
                    characters: characters
                )
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
        HotKeyManager.shared.setRecordingHotKey(false)
    }
}
