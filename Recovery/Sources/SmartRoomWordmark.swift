import AppKit

/// SmartRoom carry (CARRY.md patch 4): the banner shown in place of
/// OmarchyWordmark, in the same 400 × 94 point frame. Like upstream's, it is a
/// pixel wordmark drawn from a cell grid, so it stays crisp at any size and
/// needs no image file: "SMARTROOM" over a smaller "FIRMWARE", in the window's
/// own text and accent colours.
final class SmartRoomWordmark: NSView {

  /// 8 × 10 cells, 2-cell strokes.
  private static let large: [Character: [String]] = [
    "S": [
      ".#######", "########", "##......", "##......", "#######.",
      ".#######", "......##", "......##", "########", "#######.",
    ],
    "M": [
      "##....##", "###..###", "########", "##.##.##", "##....##",
      "##....##", "##....##", "##....##", "##....##", "##....##",
    ],
    "A": [
      ".######.", "########", "##....##", "##....##", "########",
      "########", "##....##", "##....##", "##....##", "##....##",
    ],
    "R": [
      "#######.", "########", "##....##", "##....##", "########",
      "#######.", "##..##..", "##...##.", "##....##", "##....##",
    ],
    "T": [
      "########", "########", "...##...", "...##...", "...##...",
      "...##...", "...##...", "...##...", "...##...", "...##...",
    ],
    "O": [
      ".######.", "########", "##....##", "##....##", "##....##",
      "##....##", "##....##", "##....##", "########", ".######.",
    ],
  ]

  /// 5 × 5 cells, 1-cell strokes.
  private static let small: [Character: [String]] = [
    "F": ["#####", "#....", "####.", "#....", "#...."],
    "I": ["#####", "..#..", "..#..", "..#..", "#####"],
    "R": ["####.", "#...#", "####.", "#..#.", "#...#"],
    "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
    "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"],
    "A": [".###.", "#...#", "#####", "#...#", "#...#"],
    "E": ["#####", "#....", "####.", "#....", "#####"],
  ]

  /// Rows of the name; the rows after them are the product line.
  static let nameRows = 10

  /// 88 × 18 cells: the name (rows 0–9), three blank rows, then the product
  /// line (rows 13–17), centred under it.
  static let grid: [String] = {
    let name = SmartRoomWordmark.line("SMARTROOM", glyphs: SmartRoomWordmark.large, spacing: 2)
    let product = SmartRoomWordmark.line("FIRMWARE", glyphs: SmartRoomWordmark.small, spacing: 3)
    let width = name[0].count
    let left = (width - product[0].count) / 2
    let blank = String(repeating: ".", count: width)
    return name + [blank, blank, blank]
      + product.map {
        String(repeating: ".", count: left) + $0
          + String(repeating: ".", count: width - left - $0.count)
      }
  }()

  static let columns = grid[0].count
  static let rows = grid.count

  private static func line(_ text: String, glyphs: [Character: [String]], spacing: Int) -> [String]
  {
    let cells = text.map { glyphs[$0]! }
    let gap = String(repeating: ".", count: spacing)
    return cells[0].indices.map { row in cells.map { $0[row] }.joined(separator: gap) }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let cell = min(bounds.width / CGFloat(Self.columns), bounds.height / CGFloat(Self.rows))
    let originX = (bounds.width - cell * CGFloat(Self.columns)) / 2
    let originY = (bounds.height - cell * CGFloat(Self.rows)) / 2
    for (row, line) in Self.grid.enumerated() {
      (row < Self.nameRows ? OmarchyTheme.text : OmarchyTheme.accent).setFill()
      for (column, character) in line.enumerated() where character == "#" {
        NSBezierPath(
          rect: NSRect(
            x: originX + CGFloat(column) * cell,
            y: originY + CGFloat(row) * cell,
            width: cell + 0.4,
            height: cell + 0.4
          )
        ).fill()
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func accessibilityLabel() -> String? { SmartRoomBrand.osName }
}
