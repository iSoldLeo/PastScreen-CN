// sck_burst_probe
//
// 验证目标：在 macOS 公开 API（ScreenCaptureKit）下，能否用 SCScreenshotManager
// 在按键瞬间对当前所有 eligible 窗口做 burst 抓取（独立窗口模式，含遮挡区域恢复），
// 并测量：
//   - 单次 captureImage 延迟分布
//   - N 个窗口并发 burst 的总耗时（wall-clock）
//   - 系统是否把它视为"持续捕获"（运行期间需要人眼看菜单栏 Video 项）
//
// 用法：
//   swift run -c release sck-burst-probe                    // 用所有 eligible 窗口
//   swift run -c release sck-burst-probe --max 15           // 限制窗口数
//   swift run -c release sck-burst-probe --serial           // 串行而非并发
//   swift run -c release sck-burst-probe --rounds 3         // 跑 3 轮
//   swift run -c release sck-burst-probe --save /tmp/burst  // 把图片落盘
//
// 第一次运行会触发屏幕录制权限弹窗，授权后再次运行。

import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - CLI

struct Options {
    var maxWindows: Int = .max
    var serial: Bool = false
    var rounds: Int = 1
    var saveDir: String? = nil
    var pixelScale: Double = 1.0   // 1.0 = retina 原生；0.5 = 缩到一半减少压力
    var visibleOnly: Bool = true   // 默认只抓"至少一角可见"的窗口
    var debugVisibility: Bool = false
}

func parseArgs() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--max":
            if let v = it.next(), let n = Int(v) { opts.maxWindows = n }
        case "--serial":
            opts.serial = true
        case "--rounds":
            if let v = it.next(), let n = Int(v) { opts.rounds = n }
        case "--save":
            opts.saveDir = it.next()
        case "--scale":
            if let v = it.next(), let s = Double(v) { opts.pixelScale = s }
        case "--all-windows":
            opts.visibleOnly = false
        case "--visible-only":
            opts.visibleOnly = true
        case "--debug-visibility":
            opts.debugVisibility = true
        case "-h", "--help":
            print("""
            sck-burst-probe [--max N] [--serial] [--rounds N] [--save DIR] [--scale S]
                            [--all-windows | --visible-only] [--debug-visibility]
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        }
    }
    return opts
}

// MARK: - Helpers

@inline(__always)
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func ms(_ ns: UInt64) -> Double { Double(ns) / 1_000_000.0 }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let idx = max(0, min(s.count - 1, Int((Double(s.count) - 1) * p)))
    return s[idx]
}

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path,
                                              withIntermediateDirectories: true)
}

func savePNG(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Probe

struct Sample {
    let windowID: CGWindowID
    let appName: String
    let title: String
    let widthPt: CGFloat
    let heightPt: CGFloat
    let elapsedMs: Double
    let okWidth: Int
    let okHeight: Int
    let error: String?
}

// 矩形减法：a − b 返回不重叠的子矩形列表，若 b 完全覆盖 a 返回空数组
extension CGRect {
    func subtracting(_ other: CGRect) -> [CGRect] {
        let inter = self.intersection(other)
        if inter.isNull || inter.isEmpty { return [self] }
        if inter == self { return [] } // 完全被覆盖
        var pieces: [CGRect] = []
        // top strip
        if inter.minY > self.minY {
            pieces.append(CGRect(x: self.minX, y: self.minY,
                                 width: self.width,
                                 height: inter.minY - self.minY))
        }
        // bottom strip
        if inter.maxY < self.maxY {
            pieces.append(CGRect(x: self.minX, y: inter.maxY,
                                 width: self.width,
                                 height: self.maxY - inter.maxY))
        }
        // left bar
        if inter.minX > self.minX {
            pieces.append(CGRect(x: self.minX, y: inter.minY,
                                 width: inter.minX - self.minX,
                                 height: inter.height))
        }
        // right bar
        if inter.maxX < self.maxX {
            pieces.append(CGRect(x: inter.maxX, y: inter.minY,
                                 width: self.maxX - inter.maxX,
                                 height: inter.height))
        }
        return pieces
    }
}

/// 判定一个 rect 减去多个 occluder 后是否仍剩余可见区域
func hasVisibleArea(rect: CGRect, occluders: [CGRect]) -> Bool {
    var pieces: [CGRect] = [rect]
    for occ in occluders {
        var next: [CGRect] = []
        for p in pieces {
            next.append(contentsOf: p.subtracting(occ))
        }
        pieces = next
        if pieces.isEmpty { return false }
    }
    return !pieces.isEmpty
}

func eligibleWindows(_ opts: Options) async throws -> [SCWindow] {
    // SCShareableContent.windows 在 macOS 14+ 默认按 z-order front→back 返回。
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)

    let bundleID = Bundle.main.bundleIdentifier ?? ""
    let pid = ProcessInfo.processInfo.processIdentifier

    let filtered = content.windows.filter { w in
        // 过滤自己
        if let app = w.owningApplication, Int32(app.processID) == pid { return false }
        if let app = w.owningApplication, app.bundleIdentifier == bundleID { return false }
        // 过滤无标题/极小窗口（系统装饰）
        let area = w.frame.width * w.frame.height
        if area < 40_000 { return false } // < ~200x200
        // 过滤非 normal layer（dock/menubar/notification 等）
        if w.windowLayer != 0 { return false }
        return true
    }

    // 可见性过滤（z-order 已是 front→back，逐个累加 occluder）
    let result: [SCWindow]
    if opts.visibleOnly {
        var occluders: [CGRect] = []
        var visible: [SCWindow] = []
        for w in filtered {
            if hasVisibleArea(rect: w.frame, occluders: occluders) {
                visible.append(w)
                if opts.debugVisibility {
                    print("  ✓ visible  [\(w.windowID)] \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")")
                }
            } else if opts.debugVisibility {
                print("  ✗ occluded [\(w.windowID)] \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")")
            }
            occluders.append(w.frame)
        }
        result = visible
    } else {
        result = filtered
    }

    return Array(result.prefix(opts.maxWindows))
}

func captureOne(_ window: SCWindow, scale: Double) async -> Sample {
    let cfg = SCStreamConfiguration()
    // 像素尺寸 = 点尺寸 * backingScale。SCStreamConfiguration 用像素。
    let backing = NSScreen.main?.backingScaleFactor ?? 2.0
    let w = max(2, Int(window.frame.width * backing * scale))
    let h = max(2, Int(window.frame.height * backing * scale))
    cfg.width = w
    cfg.height = h
    cfg.showsCursor = false
    cfg.capturesAudio = false
    cfg.scalesToFit = true
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    if #available(macOS 14.2, *) {
        cfg.captureResolution = .best
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)

    let appName = window.owningApplication?.applicationName ?? "?"
    let title = window.title ?? ""

    let start = nowNs()
    do {
        let image: CGImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: cfg)
        let elapsed = ms(nowNs() - start)
        return Sample(
            windowID: window.windowID,
            appName: appName,
            title: title,
            widthPt: window.frame.width,
            heightPt: window.frame.height,
            elapsedMs: elapsed,
            okWidth: image.width,
            okHeight: image.height,
            error: nil)
    } catch {
        let elapsed = ms(nowNs() - start)
        return Sample(
            windowID: window.windowID,
            appName: appName,
            title: title,
            widthPt: window.frame.width,
            heightPt: window.frame.height,
            elapsedMs: elapsed,
            okWidth: 0,
            okHeight: 0,
            error: "\(error)")
    }
}

func runBurst(_ windows: [SCWindow], opts: Options, round: Int) async -> [Sample] {
    let burstStart = nowNs()
    var samples: [Sample] = []
    samples.reserveCapacity(windows.count)

    if opts.serial {
        for w in windows {
            let s = await captureOne(w, scale: opts.pixelScale)
            samples.append(s)
        }
    } else {
        samples = await withTaskGroup(of: Sample.self) { group in
            for w in windows {
                group.addTask { await captureOne(w, scale: opts.pixelScale) }
            }
            var out: [Sample] = []
            out.reserveCapacity(windows.count)
            for await s in group { out.append(s) }
            return out
        }
    }

    let burstWall = ms(nowNs() - burstStart)

    // 落盘
    if let dir = opts.saveDir {
        let roundDir = "\(dir)/round\(round)"
        ensureDir(roundDir)
        // 重新跑一次拿 image 不划算；这里就只在 saveDir 指定时再跑一次保留图。
        // 简化版：上面 captureOne 没把 CGImage 带出来，避免内存放大。这里再跑一次。
        for w in windows {
            let cfg = SCStreamConfiguration()
            let backing = NSScreen.main?.backingScaleFactor ?? 2.0
            cfg.width = max(2, Int(w.frame.width * backing * opts.pixelScale))
            cfg.height = max(2, Int(w.frame.height * backing * opts.pixelScale))
            cfg.showsCursor = false
            cfg.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: w)
            if let img = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg) {
                let safeApp = (w.owningApplication?.applicationName ?? "x")
                    .replacingOccurrences(of: "/", with: "_")
                savePNG(img, to: "\(roundDir)/\(w.windowID)-\(safeApp).png")
            }
        }
    }

    print("\n── round \(round)  windows=\(windows.count)  mode=\(opts.serial ? "serial" : "parallel")  scale=\(opts.pixelScale)")
    print(String(format: "burst wall-clock total: %.1f ms", burstWall))

    let oks = samples.filter { $0.error == nil }.map(\.elapsedMs)
    if !oks.isEmpty {
        let sum = oks.reduce(0, +)
        let avg = sum / Double(oks.count)
        let p50 = percentile(oks, 0.50)
        let p90 = percentile(oks, 0.90)
        let p99 = percentile(oks, 0.99)
        let mx  = oks.max() ?? 0
        print(String(format: "per-window  ok=%d  avg=%.1f  p50=%.1f  p90=%.1f  p99=%.1f  max=%.1f  (ms)",
                     oks.count, avg, p50, p90, p99, mx))
    }
    let errs = samples.filter { $0.error != nil }
    if !errs.isEmpty {
        print("errors: \(errs.count)")
        for e in errs.prefix(5) {
            print("  - [\(e.windowID)] \(e.appName) :: \(e.error ?? "")")
        }
    }

    print("top-5 slowest:")
    for s in samples.sorted(by: { $0.elapsedMs > $1.elapsedMs }).prefix(5) {
        print(String(format: "  %.1f ms  %dx%d pt → %dx%d px  %@ — %@",
                     s.elapsedMs,
                     Int(s.widthPt), Int(s.heightPt),
                     s.okWidth, s.okHeight,
                     s.appName, s.title.isEmpty ? "(no title)" : s.title))
    }
    return samples
}

// MARK: - main

@main
struct App {
    static func main() async {
        let opts = parseArgs()

        // 触发权限请求（如未授权）
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                    onScreenWindowsOnly: true)
        } catch {
            print("无法访问 SCShareableContent，可能需要授权屏幕录制：\(error)")
            exit(2)
        }

        let windows: [SCWindow]
        do {
            windows = try await eligibleWindows(opts)
        } catch {
            print("枚举窗口失败：\(error)")
            exit(2)
        }

        guard !windows.isEmpty else {
            print("没有 eligible 窗口（请打开几个普通应用窗口再跑）")
            exit(1)
        }

        print("eligible windows: \(windows.count)")
        for w in windows {
            print(String(format: "  [%-6d] %@ — %@  %dx%d",
                         w.windowID,
                         w.owningApplication?.applicationName ?? "?",
                         (w.title?.isEmpty == false ? w.title! : "(no title)"),
                         Int(w.frame.width), Int(w.frame.height)))
        }

        print("\n=== 现在请观察菜单栏。ScreenCaptureKit / 屏幕录制指示在 burst 期间是否点亮？是否进入 Video 菜单的 active streams 列表？===\n")

        for r in 1...opts.rounds {
            _ = await runBurst(windows, opts: opts, round: r)
            if r != opts.rounds {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        print("\n完成。")
    }
}
