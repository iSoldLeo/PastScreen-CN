//
//  OnboardingButtonStyles.swift
//  Mio
//
//  Onboarding controls use Liquid Glass on macOS 26 and the native bordered
//  controls on macOS 15–25.
//

import SwiftUI

extension View {
    @ViewBuilder
    func onboardingSecondaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func onboardingPrimaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
