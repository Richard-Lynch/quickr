QuickrUI resources (fonts, colour and image assets), processed into the target's bundle and read
through `Bundle.module`. This file also keeps the bundle non-empty: Xcode refuses to code-sign an
empty resource bundle, and SwiftPM ignores hidden files such as `.gitkeep`.
