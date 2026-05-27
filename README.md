# FS25_EnhancedHelpMenu

A smarter, always-visible HUD overlay for Farming Simulator 25 that shows every active input action and its key binding across all connected devices.

## Get the mod

Install from the [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

## Coming in the next release

Already finished on the dev branch, waiting for the next ModHub update. If you are about to report one of these, it is already addressed:

### Major additions

- **German localization (DE).** Every UI string in the panel is now translated, not just the four action labels. Adding more languages takes one new translation file.
- **In-game settings tab.** A new shared "Enhanced Settings" tab appears under ESC → Settings. Pairs cleanly with FS25_EnhancedGameplay if you run both.
- **"Show native help menu" setting.** OFF (default): F1 toggles EHM on and off. ON: F1 cycles through EHM → native help menu → both hidden. Native is never locked out -- you can always reach the original F1 menu if you want it.
- **Rows-per-page setting.** Pick how tall the panel is: 6, 8, 10, 12, 14, 16, or 20 rows per page. Default 12.
- **Panel width setting.** Width is now a percentage of the native help-menu width (125% to 300% in 25% steps, default 150%). Replaces the old fixed two-preset choice.
- **Follows the game's UI Scale setting.** Settings → Display → UI Scale (50% – 125%) now grows or shrinks the EHM panel along with every other HUD element. Width-scaling and UI-scaling compose multiplicatively.
- **ALL-devices mode in the device cycle.** When two or more input devices are connected, the device-cycle pill now has an "ALL" option that shows every device's bindings on the same row, separated by a "|".
- **Hide-and-restore for header status lines.** Filter mode's hide/un-hide UX (eye icon) now applies to the status lines at the top of the panel too -- work-mode row, AI-mode row, and any mod-pushed extra text. Persists between sessions.

### Native-menu parity

- **Work-mode status line.** The current work mode of an attached implement now appears at the top of the panel.
- **AI-mode status line with HOLD-key pill.** Shows the current AI-helper mode plus the HOLD-H pill exactly like the native menu.
- **Live AI-worker state.** When the AI helper is running, the AI line now appends the live state: Driving / Working / Turning / Blocked.
- **Steering-assist duplicate fix.** The unbound "Toggle Steering Assist" row no longer doubles up with the bound "Toggle AI" row.
- **Coexists with Precision Farming (and other native HUD extensions).** PF's combine / seeder / sprayer overlays no longer collide with EHM -- they're rendered inside EHM's panel in a measured band below the vehicle schema. Works in both "EHM visible" and "native visible" modes of the F1 cycle.

### Default keys

- **New default keybinds: ALT + INS / ALT + HOME / ALT + PGUP / ALT + PGDN.** Replaces the old F4 / F10 / F6 / F7 defaults. The ALT prefix sidesteps the old PGUP/PGDN collision with the camera-zoom axis -- pressing bare PGUP/PGDN now only zooms the camera, as it always did in vanilla. **Existing players keep their current bindings on upgrade**; only new installs (or a manual rebind in the Controls menu) get the new defaults. All four actions remain fully remappable, and rebinding to a two-key combo (e.g. SHIFT + key) now works too.

### Visual & UX polish

- **Header tightened up.** Removed the redundant TOGGLE [F1] pill, the action count, and a duplicate "PAGE" label. The header now shows current page + device on top, and key hints (PAGE / FILTER bindings) below.
- **Cleaner separators in binding rows.** The "+" between chord keys and the "|" between alternate bindings have been re-tuned for calmer brightness.
- **No more sub-pixel seam lines.** At non-integer UI Scale values (e.g. 125%) the panel previously showed thin hairline seams at the edges. Fixed for both axes.

### Bug fixes

- **F1 cycle no longer drifts after construction-mode visits.** Entering and exiting the construction screen used to silently advance the F1 toggle state. F1 now only advances on actual F1 presses.
- **No more native-F1 leak over EHM.** Exiting the construction screen could leave the vanilla F1 menu drawn on top of EHM until you cycled F1. Fixed.
- **Native menu now actually appears in the F1 cycle.** With "Show native help menu" turned on, the "native" step in the cycle previously didn't push the native menu visible. Fixed.
- **Truncated labels render correctly in German.** Umlauts at a truncation point used to produce a garbled glyph. Fixed.
- **Routine events no longer spam the global game log.** EHM now only writes genuine warnings to FS25's shared `log.txt`; routine session output stays in EHM's own debug log.

### Settings copy

- Labels and tooltips for the three settings are shorter, sentence-cased, and no longer reference any specific key name -- so the copy stays correct even after you rebind.

## Report a bug or suggest a feature

Use the **[Issues tab](../../issues/new/choose)** above. Templates prompt for FS25 version, mod version, log snippet, and repro steps. Please search existing issues first, and check the "Coming in the next release" section above -- your issue may already be fixed.

## License

See `LICENSE` if present. If absent, all rights reserved by the mod author.
