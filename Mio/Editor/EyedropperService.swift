//
//  EyedropperService.swift
//  Mio
//
//  屏幕级吸管。封装 macOS NSColorSampler — 系统自带跟随光标的圆形像素级
//  loupe，不需要自己实现放大镜（spec §8）。
//
//  调用 show() 后用户在屏幕任意位置点击都能取到该像素颜色。用户按 ESC
//  取消则 completion 收到 nil。
//

import AppKit

@MainActor
enum EyedropperService {
    /// 弹出屏幕级取色器，返回用户取到的 RGBA（在 sRGB 色彩空间）。
    /// 用户取消（ESC）时返回 nil。
    static func pickColor() async -> ColorRef? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { nsColor in
                guard let nsColor else {
                    continuation.resume(returning: nil)
                    return
                }
                // 转 sRGB 色彩空间，避免不同 ColorSpace 渲染差异
                let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
                continuation.resume(returning: .sampled(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent),
                    alpha: Double(srgb.alphaComponent)
                ))
            }
        }
    }
}
