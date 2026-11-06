// scope.conf.

import Foundation
import Testing
@testable import scope

@Suite("Config")
struct ConfigTests {
    @Test("an empty file means every default")
    func defaults() {
        let (config, warnings) = Config.parse("")
        #expect(config == Config(modifier: .cmd, mouse: true, refocus: true, spaces: .macos, trace: false))
        #expect(warnings.isEmpty)
    }

    @Test("every setting")
    func everySetting() {
        let (config, warnings) = Config.parse("""
            modifier = alt
            mouse = false
            refocus = no
            spaces = 0.4
            trace = on
            """)
        #expect(config == Config(modifier: .alt, mouse: false, refocus: false, spaces: .seconds(0.4), trace: true))
        #expect(warnings.isEmpty)
    }

    @Test("comments, blank lines, spacing and case", arguments: [
        "# a comment\n\nmodifier = ctrl",
        "modifier=ctrl",
        "   MODIFIER   =   CTRL   ",
        "modifier = ctrl   # trailing comment",
    ])
    func layout(text: String) {
        let (config, warnings) = Config.parse(text)
        #expect(config.modifier == .ctrl)
        #expect(warnings.isEmpty)
    }

    @Test("booleans", arguments: [
        ("true", true), ("yes", true), ("on", true), ("1", true),
        ("false", false), ("no", false), ("off", false), ("0", false), ("FALSE", false),
    ])
    func booleans(value: String, expected: Bool) {
        #expect(Config.parse("mouse = \(value)").0.mouse == expected)
    }

    @Test("a bad value keeps that setting's default, warns, and the rest still apply")
    func badValue() {
        let (config, warnings) = Config.parse("mouse = maybe\nmodifier = alt", name: "scope.conf")
        #expect(config.mouse == true)
        #expect(config.modifier == .alt)
        #expect(warnings == ["scope.conf:1: mouse must be true or false, got `maybe`"])
    }

    @Test("an unknown modifier keeps cmd and warns")
    func badModifier() {
        let (config, warnings) = Config.parse("modifier = hyper", name: "f")
        #expect(config.modifier == .cmd)
        #expect(warnings == ["f:1: modifier must be cmd, alt or ctrl, got `hyper`"])
    }

    @Test("spaces: macos, or seconds from 0 to the most a swipe can take; anything else, true and false too, keeps macos and warns")
    func spacesValues() {
        #expect(Config.parse("spaces = MacOS").0.spaces == .macos)
        #expect(Config.parse("spaces = 0").0.spaces == .seconds(0))
        #expect(Config.parse("spaces = 0.25").0.spaces == .seconds(0.25))
        for bad in ["slow", "-0.1", "1.5", "off", "false"] {
            let (config, warnings) = Config.parse("spaces = \(bad)")
            #expect(config.spaces == .macos)
            #expect(warnings.count == 1)
        }
    }

    @Test("a slide length before macOS 27 is kept but warned about: it switches at once there")
    func slideLengthBeforeTimed() {
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        let current = OperatingSystemVersion(majorVersion: Slide.timedFromMacOS, minorVersion: 2, patchVersion: 0)
        #expect(Slide.seconds(0.4).unsupported(on: sequoia)
                == "spaces = 0.4 needs macOS 27 or later to set the slide's length; on macOS 15.4 it switches at once")
        #expect(Slide.seconds(0.4).unsupported(on: tahoe)?.hasSuffix("on macOS 26.1.2 it switches at once") == true)
        #expect(Slide.seconds(0.4).unsupported(on: current) == nil)
        #expect(Slide.seconds(0).unsupported(on: sequoia) == nil)
        #expect(Slide.macos.unsupported(on: sequoia) == nil)
    }

    @Test("an unknown key is reported, not fatal")
    func unknownKey() {
        #expect(Config.parse("colour = red", name: "f").1 == ["f:1: unknown setting `colour`"])
    }

    @Test("a line without `=` is reported with its line number")
    func malformed() {
        #expect(Config.parse("\n\njust words", name: "f").1 == ["f:3: expected `key = value`, got `just words`"])
    }

    @Test("a missing file means defaults, without warnings")
    func missingFile() {
        let (config, warnings) = Config.load(from: "/nonexistent/scope.conf")
        #expect(config == Config())
        #expect(warnings.isEmpty)
    }

    @Test("the effective settings print back as scope.conf lines")
    func lines() {
        #expect(Config().lines == ["modifier = cmd", "mouse    = true", "refocus  = true", "spaces   = macos", "trace    = false"])
    }
}
