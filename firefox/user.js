// Managed by dotfiles - installed into every profile by scripts/firefox-tune.sh.
// Firefox re-applies user.js over prefs.js at every startup, so this is safe to
// edit while Firefox is running; changes take effect at the next launch.
//
// Scope check, so these are not mistaken for a cure: measured on this machine at
// Firefox 154, 13 tabs across 2 windows cost 5.6 GiB (PSS). The four biggest
// content processes alone were 598 / 583 / 456 / 446 MB, and every one of them
// was a legitimate long-lived web app. The prefs below reclaim roughly half a
// gigabyte of *overhead*. They do not and cannot shrink the pages themselves.
// The ceiling that actually protects the rest of the system is the cgroup cap in
// .config/systemd/user/app-org.mozilla.firefox@.service.d/50-memory.conf.

// ── Tab discarding ───────────────────────────────────────────────────────────
// Firefox's equivalent of Chrome's Memory Saver. about:unloads shows what it
// considers discardable and in what order.
user_pref("browser.tabs.unloadOnLowMemory", true);

// ── Back/forward cache ───────────────────────────────────────────────────────
// Default -1 means "derive from installed RAM", which hits the formula's ceiling
// of 8 on anything with >= 1 GB. A "viewer" is a fully rendered, still-live page
// retained so that Back is instant. Eight of those, on a profile that keeps
// Gmail / Teams / Docs / WhatsApp open permanently, is the largest pref-level
// win available here. 2 still makes Back instant one or two steps into history,
// which is as deep as anyone actually goes.
user_pref("browser.sessionhistory.max_total_viewers", 2);

// ── Closed-tab / closed-window undo ──────────────────────────────────────────
// Defaults are 25 per window and 5 windows. Measured on this profile: 50 closed
// tabs and 5 closed windows were being retained, all of it held by the PARENT
// process, which was itself 533 MB. Ctrl+Shift+T history is not worth that.
user_pref("browser.sessionstore.max_tabs_undo", 5);
user_pref("browser.sessionstore.max_windows_undo", 1);

// Write the session store every 60s instead of every 15s: fewer NVMe writes.
user_pref("browser.sessionstore.interval", 60000);

// ── Content processes ────────────────────────────────────────────────────────
// NB: `dom.ipc.processCount` - the famous "cap Firefox's processes" pref, and
// the one this file used to set to 4 - is a DEAD LETTER under Fission, which has
// been on by default for years. Measured proof from this machine: with
// processCount pinned to 4, Firefox 154 was running 22 content processes for 13
// tabs, because Fission allocates a process per *site*, not from that pool. It
// has been removed rather than left in place looking effective.
//
// NB: DELETING a line from user.js does NOT unset the pref. Anything user.js has
// ever applied was written into prefs.js as a user pref and stays there; on the
// next launch Firefox reads prefs.js and the value survives with nothing in
// user.js to explain it. Verified here - prefs.js still carried
// `dom.ipc.processCount = 4` after the line was dropped. So it is reset
// EXPLICITLY to its shipped default rather than simply removed. Same rule
// applies to anything else retired from this file later.
user_pref("dom.ipc.processCount", 8);
//
// The live knob is the per-site pool below (default 4). Be honest about what it
// buys: with 13 tabs on 13 different domains it changes nothing, because each
// distinct site gets its own process either way. It is a guard against the case
// that does blow up - a dozen tabs of the same site - not a fix for today's
// process count.
user_pref("dom.ipc.processCount.webIsolated", 2);
