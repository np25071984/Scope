// scope.conf.

import Testing
@testable import scope

@Suite("Config")
struct ConfigTests {
    @Test("an empty file means every default")
    func defaults() {
        let (config, warnings) = Config.parse("")
        #expect(config == Config(modifier: .cmd, mouse: true, refocus: true, trace: false))
        #expect(warnings.isEmpty)
    }

    @Test("every setting")
    func everySetting() {
        let (config, warnings) = Config.parse("""
            modifier = alt
            mouse = false
            refocus = no
            trace = on
            """)
        #expect(config == Config(modifier: .alt, mouse: false, refocus: false, trace: true))
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
        #expect(Config().lines == ["modifier = cmd", "mouse    = true", "refocus  = true", "trace    = false"])
    }
}
