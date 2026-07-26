# Semantic text tokens meet the 4.5:1 text floor; categorical slots keep colourblind separation, and the two are allowed to differ

**Status:** accepted

#315 found the theme's `good` green at 3.24:1 and its `neutral` amber at 3.72:1 against
the card surface `#FCFCFB`, both below the 4.5:1 WCAG AA floor for text under 18pt, while
`bad` red sat at 6.39:1 — so good news rendered quieter than bad news in exactly the
element that carries the verdict. The issue's locked plan was to darken both tokens and
keep them identical to the categorical palette slots they share a hue with, on the
grounds that two greens with no visible role distinction is worse than the shift.

Verification during implementation showed that plan is not available for amber. Darkening
a colour to 4.5:1 against a near-white surface pins its lightness, and `bad` red already
sits at that lightness; under deuteranopia the two then collapse to OKLab deltaE **1.0**
against a floor of 6.0, so an amber and a red series become the same colour. The chosen
`#7D6100` is not a bad pick — an exhaustive sweep of all 16,777,216 sRGB colours found
**zero** in the gold-to-olive band clearing both contrast >= 4.5 and the CVD deltaE
**target of 8** against red *and* purple.

Relaxing to the CVD **floor of 6** admits 140 colours, so a single-token solution is not
strictly impossible — it is merely worse than diverging, on three counts. Every one of the
140 sits at contrast 4.51-4.53, i.e. 0.01 of headroom above the floor on a background this
report varies slightly by card; the decision round had already rejected a candidate for
leaving only 0.32. They all land at hue 72-75 rather than the brand amber's 89, a visible
shift toward brown-orange — and orange is red-adjacent, the wrong direction for a colour
whose whole problem is being mistaken for red. And 6-8 is the band the validator permits
"ONLY with secondary encoding", which a bare chart series does not have.

## Decisions

- **The two roles are separate token families with separate floors.** A **semantic text
  token** (`good` / `neutral` / `bad`) tints text and meets **4.5:1**. A **categorical
  slot** (`dataColors[]`, `categoricalLight[]`) fills a mark and meets **3:1** plus
  colourblind separation from its neighbours. Where one colour cannot satisfy both, the
  families diverge and the divergence is the point, not an oversight.
- **Green is shared; amber is not.** `good` and `dataColors[2]` both move to `#4F6F17`
  (5.65:1) because hue 128 stays CVD-separable at that lightness. `neutral` moves to
  `#7D6100` (5.71:1) while `dataColors[4]` / `categoricalLight[4]` keep `#A17E00`
  (3.72:1) — which clears the graphical floor it is actually held to.
- **A semantic text token owes no colour separation because it never carries meaning
  alone.** Every delta sub-line spells the sign (`+4.2% vs prior 28 days`) and every
  freshness pill spells the state (`Fresh`, `Delayed`, `Stale`). Hue is redundant
  reinforcement there, so the CVD standard that governs chart series does not apply.
  A categorical slot has no such words and therefore cannot borrow this exemption.
- **`bad` red is the anchor and does not move.** It already passes at 6.39:1, and
  lightening it to open CVD headroom for amber would spend contrast to buy separation —
  the wrong trade when the words already carry the meaning.
- **The palette claim is a computed claim, so it is recomputed.** `design-tokens.json`
  records the six-checks verdict and the worst adjacent CVD deltaE per mode; any slot
  edit re-runs the dataviz validator and rewrites those figures. The pre-existing
  19.7/28.9 figures did not reproduce under the current Machado CVD model (10.5 light /
  9.8 dark) and were corrected in the same pass.

## Consequences

- The report contains exactly one green (`#4F6F17`) and two ambers. The second amber is
  legitimate and named: `neutral` is text, `dataColors[4]` is a mark. A design review that
  re-files "two ambers" is answered by this ADR.
- `Freshness Color` and the sixteen `<metric> Delta Color` measures are semantic text
  tokens expressed in DAX, so they carry the text hexes, not the slot hexes. They are
  hardcoded literals with no theme binding available to a measure — a known duplication
  that a token change must sweep by hand.
- `center` (`#A17E00`) is the midpoint of a diverging conditional-format scale that no
  visual currently uses. It is a fill role, so the text floor does not reach it, and it
  was left untouched rather than swept along with a token it merely shares a hex with.
- Sentiment weight is now near-symmetric where it is read: 5.65 green, 5.71 amber, 6.39
  red, against a 5.84 label grey. The asymmetry #315 was filed about is closed for text.
- ADR-0012 governs how *large* report text is; this ADR governs what *colour* it is. A new
  semantic colour meets 4.5:1 and spells its meaning out; a new chart series takes the
  next categorical slot and re-runs the validator.
