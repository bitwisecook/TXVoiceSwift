# TXVoiceSwift

macOS app for creating `.wav` files for Taranis FrSky and EdgeTX/OpenTX controllers using Mac speech synthesis voices.

## Build

- Open `TXVoice.xcodeproj` in Xcode
- Deployment target: macOS 13.0 (Ventura)
- Swift 5.0, no external dependencies

## Guidelines

- Follow Apple's Liquid Glass design language where possible: https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass
- Gate Liquid Glass and other macOS 26+ APIs behind `#available(macOS 26, *)` with sensible fallbacks
- Maintain backward compatibility to macOS 13.0 — avoid APIs newer than macOS 13 without `#available` guards
- Use only Apple-native frameworks (AVFoundation, SwiftUI, Foundation)

## Agent Skills

Reference skills in `.agents/skills/` for SwiftUI, Swift Testing, and Swift Concurrency best practices.
