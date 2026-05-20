//
//  AppCategory.swift
//  PastScreen
//
//  Domain-layer app category for context-aware capture behavior.
//

public enum AppCategory: Sendable {
    case codeEditor
    case webBrowser
    case designTool
    case unknown
}

extension AppCategory {
    /// nonisolated static: pure lookup table, no mutable state.
    public nonisolated static let appCategoryMap: [String: AppCategory] = [
        // Code Editors
        "com.microsoft.VSCode": .codeEditor,
        "com.microsoft.VSCodeInsiders": .codeEditor,
        "dev.zed.Zed": .codeEditor,
        "com.todesktop.230313mzl4w4u92": .codeEditor, // Cursor
        "com.cursor.Cursor": .codeEditor,
        "com.sublimetext.4": .codeEditor,
        "com.apple.dt.Xcode": .codeEditor,
        "com.jetbrains.intellij": .codeEditor,
        "com.jetbrains.pycharm": .codeEditor,
        "com.github.atom": .codeEditor,
        "com.uranusjr.macdown": .codeEditor,
        "abnerworks.Typora": .codeEditor,
        "md.obsidian": .codeEditor,

        // Terminals
        "com.apple.Terminal": .codeEditor,
        "com.googlecode.iterm2": .codeEditor,
        "co.zeit.hyper": .codeEditor,
        "net.kovidgoyal.kitty": .codeEditor,
        "org.alacritty": .codeEditor,

        // Web Browsers
        "com.apple.Safari": .webBrowser,
        "com.apple.SafariTechnologyPreview": .webBrowser,
        "com.google.Chrome": .webBrowser,
        "com.google.Chrome.canary": .webBrowser,
        "org.mozilla.firefox": .webBrowser,
        "org.mozilla.firefoxdeveloperedition": .webBrowser,
        "com.microsoft.edgemac": .webBrowser,
        "com.microsoft.edgemac.Dev": .webBrowser,
        "com.brave.Browser": .webBrowser,
        "com.brave.Browser.dev": .webBrowser,
        "com.operasoftware.Opera": .webBrowser,
        "com.operasoftware.OperaGX": .webBrowser,
        "company.thebrowser.Browser": .webBrowser, // Arc
        "company.thebrowser.dia": .webBrowser, // DIA
        "com.vivaldi.Vivaldi": .webBrowser,
        "org.chromium.Chromium": .webBrowser,
        "com.kagi.kagimacOS": .webBrowser, // Orion
        "com.pushplaylabs.Sidekick": .webBrowser,
        "com.maxthon.mac.Maxthon": .webBrowser,
        "com.microsoft.Outlook": .webBrowser,

        // Design & Communication Tools
        "com.figma.Desktop": .designTool,
        "com.tinyspeck.slackmacgap": .designTool,
        "com.hnc.Discord": .designTool,
        "com.linear": .designTool,
        "notion.id": .designTool,
        "com.sketch.app": .designTool,
        "com.bohemiancoding.sketch3": .designTool,
        "com.adobe.illustrator": .designTool,
        "com.adobe.Photoshop": .designTool,
        "com.adobe.AfterEffects": .designTool,
        "com.adobe.PremierePro": .designTool,
        "com.adobe.LightroomClassicCC7": .designTool,
        "com.adobe.XD": .designTool,
        "com.adobe.InDesign": .designTool,
        "com.panic.transmit": .designTool,
        "com.panic.nova": .designTool,
        "com.freron.MailMate": .designTool,
        "com.apple.mail": .designTool,
    ]
}
