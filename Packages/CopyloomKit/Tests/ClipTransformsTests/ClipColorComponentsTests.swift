import ClipTransforms
import Testing

@Suite("Color preview components")
struct ClipColorComponentsTests {
  @Test("HEX, RGB and HSL produce the same red swatch")
  func supportedColorForms() {
    for text in ["#f00", "#FF0000", "rgb(255, 0, 0)", "hsl(0, 100%, 50%)", "hsl(360,100%,50%)"] {
      guard let color = ClipColorComponents(text: text) else {
        Issue.record("Expected supported color components")
        return
      }
      #expect(color.red == 1)
      #expect(color.green == 0)
      #expect(color.blue == 0)
      #expect(color.alpha == 1)
    }
  }

  @Test("RGBA, HSLA and alpha HEX retain opacity with normalized channels")
  func preservesAlpha() {
    let fixtures: [(String, Double)] = [
      ("#0f08", 0.5333333333333333),
      ("#00ff0088", 0.5333333333333333),
      ("rgba(0,255,0,0.25)", 0.25),
      (" \n HSLA(120, 100%, 50%, 0.25) \n", 0.25),
    ]
    for (text, alpha) in fixtures {
      guard let color = ClipColorComponents(text: text) else {
        Issue.record("Expected supported alpha color components")
        return
      }
      #expect(color.red == 0)
      #expect(color.green == 1)
      #expect(color.blue == 0)
      #expect(color.alpha == alpha)
    }
  }

  @Test("RGB channels stay distinct and HSL handles blue and achromatic colors")
  func channelFidelity() {
    let fixtures: [(String, Double, Double, Double)] = [
      ("rgb(255,99,71)", 1, 0.38823529411764707, 0.2784313725490196),
      ("hsl(240,100%,50%)", 0, 0, 1),
      ("hsl(0,0%,50%)", 0.5019607843137255, 0.5019607843137255, 0.5019607843137255),
    ]
    for (text, red, green, blue) in fixtures {
      guard let color = ClipColorComponents(text: text) else {
        Issue.record("Expected known color components")
        return
      }
      #expect(abs(color.red - red) < 0.000000000001)
      #expect(abs(color.green - green) < 0.000000000001)
      #expect(abs(color.blue - blue) < 0.000000000001)
    }
  }

  @Test("unparseable Unicode hex never silently becomes black or transparent")
  func refusesUnicodeHex() {
    let fullwidth = String(UnicodeScalar(0xFF26)!)
    for text in [
      "#" + String(repeating: fullwidth, count: 3), "#12" + fullwidth + "345",
      "#ff0000" + fullwidth + "0",
    ] {
      if ClipColorComponents(text: text) != nil {
        Issue.record("Unsupported Unicode hex must not produce color components")
      }
    }
  }

  @Test("malformed, unsupported and out-of-range colors have no swatch")
  func refusesInvalidColors() {
    for text in [
      "", "red", "#12", "#zzzzzz", "rgb(256,0,0)", "rgb(-1,0,0)",
      "rgb(100%,0%,0%)", "rgb(0,0)", "rgba(0,0,0,1.1)", "rgba(0,0,0,nan)",
      "rgba(0,0,0,inf)", "hsl(361,100%,50%)", "hsl(0,101%,50%)",
      "hsl(0,50%,101%)", "hsl(0,50,50)", "rgb(0,0,0) trailing",
    ] {
      if ClipColorComponents(text: text) != nil {
        Issue.record("Invalid color must not produce swatch components")
      }
    }
  }
}
