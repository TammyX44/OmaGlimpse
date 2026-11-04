// Shared visual tokens for every card. Pure data (no theme or QML dependency),
// so colors keep resolving in WidgetTheme.js and this file only fixes the
// type scale, spacing rhythm, radii and header rules that cards share.
//
// Values come from what the cards already used most, so adopting them is a
// harmonisation rather than a redesign. Sizes are pixels; compact card heights
// reflow content but never switch to a smaller type size.

// Type scale. Hierarchy: value > title > body > caption/label.
var type = {
  caption: 10,   // secondary detail: "used / size", timestamps, hardware names
  label: 10,     // uppercase tracked labels: gauge names, column headings
  body: 11,      // list rows, status lines, metadata
  title: 12,     // card headings, names that lead a block
  value: 13,     // compact numeric readings
  lead: 14,      // now-playing title
  icon: 16,      // transport glyphs in compact cards
  iconLarge: 20, // transport glyphs, placeholders
  hero: 38,      // single dominant reading (Temperature)
  heroCompact: 34,
  heroShort: 28,
  unit: 16,      // unit suffix beside a hero reading
  unitCompact: 14
}

// Font weights as Qt 6 Font.Weight values (kept numeric so this file loads
// outside QML for tests).
var weight = { regular: 400, medium: 500, semibold: 600, bold: 700 }

// Letter-spacing for uppercase labels.
var tracking = { tight: 1, wide: 1.5 }

// Spacing rhythm (4/8/12/16/24, with 2 for hairline gaps inside a label stack).
var spacing = { xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24 }

// Card padding: standard, the tighter padding small cards (Battery,
// Temperature) already used, and the padding compact heights fall back to.
var padding = { card: 20, cardSmall: 16, compact: 8 }

// Corner radii.
var radius = { card: 18, control: 6, bar: 3 }

// Card header: one gap between heading, note, column labels and content.
var header = { gap: spacing.sm, gapCompact: spacing.xs }

// Rows in list cards (Top Processes, Disk Usage).
var list = { rowGap: spacing.sm, rowHeight: 22, barHeight: 6 }

// Text emphasis as opacity of the card's text color. Each maps to a
// WidgetTheme resolver so QML never repeats a literal alpha.
var emphasis = { secondary: 0.70, muted: 0.60, dim: 0.45 }

if (typeof module !== "undefined") {
  module.exports = {
    type: type,
    weight: weight,
    tracking: tracking,
    spacing: spacing,
    padding: padding,
    radius: radius,
    header: header,
    list: list,
    emphasis: emphasis
  }
}
