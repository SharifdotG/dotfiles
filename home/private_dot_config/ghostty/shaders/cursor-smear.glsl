// Fluid cursor trail for Ghostty.
//
// Ghostty runs Shadertoy-style shaders (`void mainImage(out vec4, in vec2)`)
// and, beyond the standard Shadertoy uniforms, exposes four of its own that
// exist specifically for cursor effects. Verified present in the 1.3.1 binary:
//
//   iCurrentCursor       vec4  (x, y, width, height) of the cursor, in PIXELS
//   iPreviousCursor      vec4  same, for where it was before it last moved
//   iCurrentCursorColor  vec4  the cursor's colour
//   iPreviousCursorColor vec4
//   iTimeCursorChange    float the iTime value at the moment it last moved
//
// NB: the cursor rectangles measure Y from the TOP of the window, while
// fragCoord measures Y from the BOTTOM. Everything below flips one into the
// other exactly once — get that wrong and the trail appears mirrored
// vertically, which looks like the shader "not working" rather than like a
// coordinate bug.

// How long the smear takes to catch up, in seconds. Lower = snappier.
const float DURATION = 0.22;
// Trail opacity at its strongest.
const float STRENGTH = 0.55;

// Signed distance to a capsule (a line segment with radius r).
float sdSegment(vec2 p, vec2 a, vec2 b, float r) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Cursor rect -> centre point, in fragCoord space (Y flipped).
vec2 cursorCentre(vec4 c) {
    return vec2(c.x + c.z * 0.5, iResolution.y - (c.y + c.w * 0.5));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // The terminal's own rendered output. Everything we do is composited on top.
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);

    vec2 cur  = cursorCentre(iCurrentCursor);
    vec2 prev = cursorCentre(iPreviousCursor);

    // Normalised progress since the cursor moved, eased so it decelerates.
    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float eased = 1.0 - pow(1.0 - t, 3.0);

    // The tail retracts toward the cursor as the animation plays, so the smear
    // shortens rather than simply fading in place.
    vec2 tail = mix(prev, cur, eased);

    // Radius from the cursor's own size, so it scales with font-size.
    float r = max(min(iCurrentCursor.z, iCurrentCursor.w) * 0.5, 1.0);

    float d = sdSegment(fragCoord, tail, cur, r);

    // Soft edge, and fade the whole trail out as it catches up.
    float edge  = 1.0 - smoothstep(-1.0, 1.5, d);
    float alpha = edge * (1.0 - eased) * STRENGTH;

    // NB: additive-ish blend rather than a straight mix. A mix() would paint
    // over glyphs the trail passes through and make text vanish mid-animation.
    fragColor = vec4(base.rgb + iCurrentCursorColor.rgb * alpha, base.a);
}
