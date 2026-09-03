// Fluid cursor trail for Ghostty.
//
// Ghostty runs Shadertoy-style shaders and adds its own uniforms for cursor
// effects. Taken verbatim from the spec embedded in the 1.3.1 binary:
//
//   vec4  iCurrentCursor       .xy = the -X,+Y CORNER of the cursor
//                              .zw = its width and height
//   vec4  iPreviousCursor      same, for where it was before it last moved
//   vec4  iCurrentCursorColor  the cursor's colour
//   vec4  iCursorVisible       whether the cursor is currently drawn
//   float iTimeCursorChange    the iTime value at the moment it last moved
//   int   iFocus               1 when the surface is focused, 0 when not
//
// NB — THE COORDINATE SPACE IS THE THING TO GET RIGHT, and the first version of
// this shader got it wrong. ".xy is the -X, +Y corner" means Y INCREASES
// UPWARD, exactly like fragCoord: .y is the cursor's TOP edge measured from the
// bottom of the window. It is NOT a top-origin coordinate. An earlier version
// assumed top-origin and flipped with `iResolution.y - y`, which drew the trail
// mirrored about the horizontal centre line — usually far from the cursor and
// often off-screen, so the effect looked like it simply "wasn't working".
// The centre is therefore (x + w/2, y - h/2): half a cursor DOWN from the top.

// How long the smear takes to catch up, in seconds. Lower = snappier.
const float DURATION = 0.20;
// Peak trail opacity. 0.0 disables the effect without touching the config.
const float STRENGTH = 0.45;

// Signed distance to a capsule (line segment of radius r).
float sdSegment(vec2 p, vec2 a, vec2 b, float r) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Cursor rect -> centre, in fragCoord space. No Y flip; see the NB above.
vec2 cursorCentre(vec4 c) {
    return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // Nothing to trail if the cursor is hidden or the window is unfocused —
    // without this the smear replays whenever you tab back in.
    if (iCursorVisible.x < 0.5 || iFocus == 0) return;

    vec2 cur  = cursorCentre(iCurrentCursor);
    vec2 prev = cursorCentre(iPreviousCursor);

    float t     = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float eased = 1.0 - pow(1.0 - t, 3.0);
    if (eased >= 1.0) return;              // settled; nothing to draw

    // The tail retracts toward the cursor, so the smear shortens rather than
    // fading in place.
    vec2 tail = mix(prev, cur, eased);

    float r = max(min(iCurrentCursor.z, iCurrentCursor.w) * 0.5, 1.0);
    float d = sdSegment(fragCoord, tail, cur, r);

    float edge  = 1.0 - smoothstep(-1.0, 1.5, d);
    float alpha = edge * (1.0 - eased) * STRENGTH;

    // NB — mix(), NOT additive. The first version did `base.rgb + colour*alpha`,
    // which is invisible on this setup for a second reason: Catppuccin Latte's
    // background is #eff1f5, i.e. almost white, and you cannot make white
    // brighter. Additive trails only show on dark themes. Mixing toward the
    // cursor colour darkens instead, which reads on light and dark alike.
    fragColor = vec4(mix(base.rgb, iCurrentCursorColor.rgb, alpha), base.a);
}
