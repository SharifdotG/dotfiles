// Catppuccin Latte cursor trail for Ghostty.
//
// A tapered comet behind the cursor, cycling through the Catppuccin Latte
// accent ramp, on EVERY cursor move — typing, arrow keys, jumps alike.
//
// ── Lineage, because two earlier versions of this file were invisible ───────
// v1 (cursor-smear.glsl) drew a uniform-width band. It compiled, loaded and ran
//    every frame while drawing a ONE-PIXEL hairline: its thickness came from
//    min(cursor.z, cursor.w), and with `cursor-style = bar` that is the BAR's
//    width, not the cell's height. Nothing ever errored.
// v2 ported Kitty's `cursor_trail` model, including Kitty's
//    `cursor_trail_start_threshold` of 2 cells — deliberately NO trail for
//    movements under that, so typing stayed clean and only jumps streaked.
// v3 (this file) keeps Kitty's tapered-wedge silhouette and two-speed decay but
//    drops the threshold to 0 and extends the tail past the actual travel, so
//    single-cell moves streak too. That is a deliberate reversal of v2's
//    headline behaviour; see START_THRESHOLD and LENGTH_SCALE.
//
// ── The uniform contract, read out of the 1.3.1 binary itself ───────────────
// `strings /usr/bin/ghostty` carries TWO descriptions of these uniforms: a
// prose doc block and the actual GLSL prelude prepended to this file. THEY
// DISAGREE, and only the prelude is real:
//
//     prose:    vec4 iCursorVisible      vec4 iCurrentCursorStyle
//     prelude:  uniform int iCursorVisible;   uniform int iCurrentCursorStyle;
//
// GLSL permits swizzling a scalar — `iCursorVisible.x` on an int is legal and
// compiles clean — so following the prose produces no error at any point. v1
// did exactly that. Compare against an int.
//
// The prelude in full, so nothing here has to be guessed at again:
//   iResolution iTime iTimeDelta iFrameRate iFrame iChannelTime[4]
//   iChannelResolution[4] iMouse iDate iSampleRate iCurrentCursor
//   iPreviousCursor iCurrentCursorColor iPreviousCursorColor
//   iCurrentCursorStyle iPreviousCursorStyle iCursorVisible iTimeCursorChange
//   iTimeFocus iFocus iPalette[256] iBackgroundColor iForegroundColor
//   iCursorColor iCursorText iSelectionForegroundColor
//   iSelectionBackgroundColor
// plus CURSORSTYLE_BLOCK / _BLOCK_HOLLOW / _BAR / _UNDERLINE / _LOCK.
//
// NB: `iPalette[256]` is the live ANSI palette and would track the theme
// automatically — but it is only the 16 ANSI slots plus the 240-colour cube,
// and Catppuccin Latte's *accent* ramp (mauve/pink/peach/teal/…) is richer than
// its ANSI 16. The ramp below is therefore hardcoded from the same values as
// home/private_dot_config/starship.toml. Ghostty is pinned to
// `theme = Catppuccin Latte`, so this cannot drift out from under the terminal
// — but it WILL be wrong if that theme ever changes. That is the trade.
//
// ── Coordinate space (carried over; still the easiest thing to get wrong) ───
// ".xy is the -X, +Y corner" means Y INCREASES UPWARD, exactly like fragCoord:
// .y is the cursor's TOP edge measured from the BOTTOM of the window. It is NOT
// a top-origin coordinate. An early version assumed top-origin and flipped with
// `iResolution.y - y`, which drew the trail mirrored about the horizontal
// centre line — usually far from the cursor and often off-screen, so the effect
// looked like it simply "wasn't working". Centre = (x + w/2, y - h/2).
//
// ── Verifying a change ──────────────────────────────────────────────────────
// A clean Ghostty launch proves the shader COMPILED and nothing more — v1 and
// v2 both compiled. ctrl+shift+r reloads; the compile-check harness is
// documented in config.ghostty.

// ── behaviour ───────────────────────────────────────────────────────────────
// Minimum cursor movement that produces a trail, in cell sizes. Kitty ships 2
// (its `cursor_trail_start_threshold`) precisely so ordinary typing does NOT
// streak. 0.0 here is the opposite choice, made on purpose: every keystroke and
// every arrow key gets a trail. Set it back to ~1.0 if that turns out to be too
// busy in practice — it is the one knob that changes the character of this
// effect rather than its degree.
const float START_THRESHOLD = 0.0;

// ── length ──────────────────────────────────────────────────────────────────
// A single keystroke moves the cursor ONE cell, so a trail spanning only the
// real travel is one cell long and reads as nothing. The tail is therefore
// anchored PAST where the cursor actually was, along the direction of travel.
//
// NB: this is a deliberate lie about the path — the cursor was never back
// there. It is what makes a comet look like a comet, and it is the only way a
// one-cell move can produce a visible streak.
const float LENGTH_SCALE = 2.2;   // multiple of the real travel distance
const float MIN_LENGTH   = 2.5;   // floor, in cell sizes — carries typing
const float MAX_LENGTH   = 14.0;  // ceiling, so a screen-crossing jump stays sane

// ── timing ──────────────────────────────────────────────────────────────────
// Kitty's `cursor_trail_decay` is two-speed: long jumps decay fast, short hops
// slow. Kitty ships 0.1 / 0.4. Both are slower here — the complaint that
// started this rewrite was that the trail was too fast to see.
const float DECAY_FAST  = 0.28;   // long jumps
const float DECAY_SLOW  = 0.55;   // short hops, i.e. typing
const float DECAY_RANGE = 10.0;   // travel, in cells, at which decay hits FAST
const float FADE_START  = 0.70;   // fraction of the window held at full opacity

// ── appearance ──────────────────────────────────────────────────────────────
const float STRENGTH   = 0.45;   // peak opacity at the head. Was 0.95.
const float TAIL_ALPHA = 0.15;   // opacity at the tail, relative to the head
// Tail half-width as a fraction of the head's. 0 = a sharp point, i.e. the
// wedge is a triangle. This is a WIDTH, not a corner radius — the shape has no
// rounding to control any more; see sdQuad.
const float TAIL_WIDTH = 0.0;
// Floor on head thickness, in cell sizes.
//
// NB: this is not cosmetic. The head radius is the cursor box's support along
// the travel NORMAL, and for a bar cursor moving VERTICALLY — up/down arrow
// keys, the exact case this effect was extended to cover — that normal is
// horizontal, so the support collapses to the bar's own width and the trail
// becomes the same one-pixel hairline that made v1 invisible. This floor is
// what stops that. Scales with font size.
const float MIN_RADIUS = 0.18;
// Palette cycles across the trail's length, and scrolls over time.
const float COLOR_SPREAD = 1.6;  // ramp repeats per trail length
const float COLOR_SPEED  = 0.9;  // ramp scroll, per second
// Set STRENGTH to 0.0 to disable the effect without touching the config.

// ── Catppuccin Latte accent ramp ────────────────────────────────────────────
// Same hexes as home/private_dot_config/starship.toml. Ordered around the wheel
// so consecutive entries blend without passing through mud.
//   mauve #8839ef · blue #1e66f5 · sky #04a5e5 · teal #179299
//   green #40a02b · yellow #df8e1d · peach #fe640b · pink #ea76cb
const int LATTE_N = 8;
const vec3 LATTE[8] = vec3[8](
    vec3(0.5333, 0.2235, 0.9373),
    vec3(0.1176, 0.4000, 0.9608),
    vec3(0.0157, 0.6471, 0.8980),
    vec3(0.0902, 0.5725, 0.6000),
    vec3(0.2510, 0.6275, 0.1686),
    vec3(0.8745, 0.5569, 0.1137),
    vec3(0.9961, 0.3922, 0.0431),
    vec3(0.9176, 0.4627, 0.7961)
);

// Cyclic ramp. u wraps, so the tail colour meets the head colour cleanly.
vec3 latteRamp(float u) {
    float x = fract(u) * float(LATTE_N);
    int   i = int(x);
    i = clamp(i, 0, LATTE_N - 1);            // guard the fract(1.0) edge
    int   j = (i + 1) % LATTE_N;
    return mix(LATTE[i], LATTE[j], smoothstep(0.0, 1.0, x - float(i)));
}

// ── signed distance helpers ─────────────────────────────────────────────────
float sdBox(vec2 p, vec2 he) {
    vec2 d = abs(p) - he;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Where along a→b the closest point to p lies, clamped to the segment. Shared
// by the distance function and the colour/alpha ramps so they cannot disagree.
float segT(vec2 p, vec2 a, vec2 b) {
    vec2 ba = b - a;
    return clamp(dot(p - a, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
}

// Signed distance to a quad with STRAIGHT edges and SHARP corners.
//
// NB: this replaced a tapered capsule (`length(p - closest) - radius`). A
// capsule is a circle swept along a line, so its ends and its whole profile are
// round BY CONSTRUCTION — there is no radius parameter to zero out. Getting
// hard edges is not a matter of tuning; it needs a different primitive. Hence a
// polygon: the trail is now the flat-sided wedge you get by joining the head's
// two silhouette corners straight to the tail's.
//
// iq's polygon SDF — exact, and winding-independent, so the caller does not
// have to care whether the vertices came out clockwise.
//
// NB: v1 == v2 (a zero-length edge) is the NORMAL case here, not a degenerate
// one to guard against — TAIL_WIDTH = 0 makes the tail a single point and the
// quad a triangle. It works out: the clamp() keeps the projection finite, and
// the crossing test cannot fire on an edge of zero height, so a collapsed edge
// contributes nothing to the winding count. The max() on dot(e,e) is there for
// the division only.
float sdQuad(vec2 p, vec2 v0, vec2 v1, vec2 v2, vec2 v3) {
    vec2  v[4] = vec2[4](v0, v1, v2, v3);
    float d = dot(p - v[0], p - v[0]);
    float s = 1.0;
    for (int i = 0, j = 3; i < 4; j = i, i++) {
        vec2 e = v[j] - v[i];
        vec2 w = p - v[i];
        vec2 b = w - e * clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
        d = min(d, dot(b, b));
        bvec3 c = bvec3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || all(not(c))) s = -s;
    }
    return s * sqrt(d);
}

// Cursor rect -> centre, in fragCoord space. No Y flip; see the NB above.
vec2 cursorCentre(vec4 c) {
    return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5);
}

// Cell-size proxy. For a bar cursor this is the height, for an underline the
// width, for a block either — so it survives a change of cursor-style. Every
// length constant above is expressed in these units, so they all track font
// size rather than being pixel values that go wrong on a rescale.
float cellSize(vec4 c) {
    return max(abs(c.z), abs(c.w));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // Nothing to trail if the cursor is hidden or the window is unfocused —
    // without this the trail replays whenever you tab back in.
    // NB: `iCursorVisible == 0`, not `.x < 0.5`. It is an int; see the header.
    if (iCursorVisible == 0 || iFocus == 0) return;

    vec2  head   = cursorCentre(iCurrentCursor);
    vec2  from   = cursorCentre(iPreviousCursor);
    float cell   = max(cellSize(iCurrentCursor), 1.0);
    float travel = distance(head, from);

    // START_THRESHOLD is 0, so this only rejects a cursor that did not move at
    // all — a blink, or a repaint in place. The 1e-4 guard is separate and
    // mandatory: it is what keeps the normalize() below off a zero vector.
    if (travel < START_THRESHOLD * cell || travel < 1e-4) return;

    // Two-speed decay: the further it jumped, the faster it catches up.
    float duration = mix(DECAY_SLOW, DECAY_FAST,
                         clamp(travel / (DECAY_RANGE * cell), 0.0, 1.0));

    float t = clamp((iTime - iTimeCursorChange) / duration, 0.0, 1.0);
    if (t >= 1.0) return;                       // settled; nothing to draw

    // Anchor the tail PAST the previous position, along the direction of
    // travel, so a one-cell keystroke still gets a streak. See LENGTH_SCALE.
    vec2  dir    = (head - from) / travel;
    float trailLen = clamp(travel * LENGTH_SCALE, MIN_LENGTH * cell, MAX_LENGTH * cell);
    vec2  anchor = head - dir * trailLen;

    // Exponential approach, the shape Kitty's per-frame decay integrates to.
    // Normalised so it actually reaches the cursor by t=1 (exp(-5) ≈ 0.0067)
    // instead of leaving a stub behind that vanishes on the last frame.
    float ease = (1.0 - exp(-5.0 * t)) / (1.0 - exp(-5.0));
    vec2  tail = mix(anchor, head, ease);
    if (distance(tail, head) < 0.5) return;

    // Head is the cursor's full size; tail converges to a near-point.
    //
    // NB: the head radius is the cursor box's SUPPORT along the travel NORMAL —
    // how wide the rectangle is seen broadside from the direction it is moving.
    // For a bar crossing a line that is the full half-HEIGHT; for a bar moving
    // between lines it collapses to the bar's own width, which is what
    // MIN_RADIUS exists to catch.
    vec2  he    = abs(iCurrentCursor.zw) * 0.5;
    vec2  d     = head - tail;
    vec2  n     = vec2(-d.y, d.x) / max(length(d), 1e-4);
    float rHead = max(abs(n.x) * he.x + abs(n.y) * he.y, MIN_RADIUS * cell);
    float rTail = rHead * TAIL_WIDTH;

    // Straight-sided wedge: across the head, straight down both flanks, across
    // the tail. With TAIL_WIDTH = 0 the last two vertices coincide and this is
    // a triangle with a sharp point.
    float sd    = min(sdBox(fragCoord - head, he),
                      sdQuad(fragCoord,
                             head + n * rHead, tail + n * rTail,
                             tail - n * rTail, head - n * rHead));
    // Feather tightened from smoothstep(-0.5, 1.0) — a 1.5px ramp visibly
    // softened the corners the polygon exists to produce.
    float cover = 1.0 - smoothstep(-0.5, 0.5, sd);        // 1px feather

    // 0 at the head, 1 at the tail. Drives both the fade and the colour, so the
    // ramp and the taper always agree about which end is which.
    float along = segT(fragCoord, head, tail);

    float fade  = 1.0 - smoothstep(FADE_START, 1.0, t);
    float alpha = cover * fade * STRENGTH * mix(1.0, TAIL_ALPHA, along);

    // Colour cycles along the trail AND scrolls over time, so a held arrow key
    // or a run of typing shimmers rather than repeating one static gradient.
    vec3 tint = latteRamp(along * COLOR_SPREAD - iTime * COLOR_SPEED);

    // NB — mix(), NOT additive. Catppuccin Latte's background is #eff1f5, i.e.
    // almost white, and you cannot make white brighter: an additive trail is
    // invisible on a light theme. Mixing toward the accent darkens instead,
    // which is also why the ramp above uses the saturated accents rather than
    // the pastel surface/overlay tones — those would barely register on #eff1f5.
    fragColor = vec4(mix(base.rgb, tint, alpha), base.a);
}
