// Cursor row highlight — "where is my prompt".
//
// A faint band across the row the cursor is on. The problem it solves is
// specific to this workload: after a long agent run or a verbose build dumps a
// few hundred lines, finding the prompt again means scanning the whole screen.
// A tinted row makes it a glance instead.
//
// Runs FIRST in the chain (see config.ghostty), so the cursor trail draws on
// top of it rather than being washed out by it.
//
// ── Design decisions that are not obvious ───────────────────────────────────
//
// NOT guarded on `iCursorVisible`. That is the reflex — the row is only
// meaningful if there is a cursor — and it is wrong here, because
// `cursor-style-blink = true` drives that uniform to 0 on every blink-off. A
// band that follows it would strobe at the blink rate, roughly twice a second,
// permanently, in the corner of your eye. Guarded on `iFocus` instead.
//
// UNVERIFIED, worth checking by eye: what the cursor uniform reports while the
// screen is SCROLLED BACK. If Ghostty keeps reporting the cursor's viewport
// position when it has scrolled out of view, the band will sit at a stale row
// while you page through scrollback. If it reports it off-screen, the band
// simply leaves with it, which is correct. Scroll up a page and look; if it
// misbehaves, the fix is to bound the band to the cursor also being on screen.
// This is not something the shader can detect on its own — there is no
// scroll-offset uniform.
//
// ── Coordinate space ────────────────────────────────────────────────────────
// Y INCREASES UPWARD, like fragCoord. `iCurrentCursor.y` is the cursor's TOP
// edge measured from the BOTTOM of the window, so the row spans
// [y - height, y]. Getting this backwards draws the band mirrored about the
// screen's centre line — see the long note in cursor-trail.glsl.

// How far the row is tinted toward the foreground colour. This wants to be
// small: it is on screen permanently, so anything you actually notice is
// something you will be annoyed by within a day. 0.05-0.08 is the useful range.
const float ROW_TINT = 0.06;
// Vertical softening of the band's edges, in px. 1.0 ≈ one pixel of feather.
const float ROW_FEATHER = 1.0;
// How aggressively glyph pixels are spared. See GLYPH_GUARD below.
const float GLYPH_GUARD = 0.25;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // NB: `iFocus` is an int in the real prelude, whatever the prose docs in
    // the binary say. See the header of cursor-trail.glsl.
    if (iFocus == 0) return;

    float top    = iCurrentCursor.y;
    float bottom = iCurrentCursor.y - abs(iCurrentCursor.w);

    float band = smoothstep(bottom - ROW_FEATHER, bottom + ROW_FEATHER, fragCoord.y)
               * (1.0 - smoothstep(top - ROW_FEATHER, top + ROW_FEATHER, fragCoord.y));
    if (band <= 0.0) return;

    // Tint the empty cells, not the text.
    //
    // NB: without this the band mixes into the GLYPHS on that row too, which
    // makes the one line you are trying to read very slightly muddier than
    // every other line — the exact opposite of the point. Pixels already close
    // to the background colour get the tint; pixels that are part of a glyph
    // are left alone. It costs one distance() and it is the difference between
    // this reading as "highlighted row" and "smudged row".
    float isBg = 1.0 - smoothstep(0.0, GLYPH_GUARD, distance(base.rgb, iBackgroundColor));

    // Toward the foreground rather than a fixed colour, so this stays correct
    // if the theme ever changes — unlike the hardcoded accent ramp in
    // cursor-trail.glsl, which is pinned to Catppuccin Latte on purpose.
    fragColor = vec4(mix(base.rgb, iForegroundColor, band * isBg * ROW_TINT), base.a);
}
