# FS25_EnhancedHelpMenu

A smarter, always-visible HUD overlay for Farming Simulator 25 that shows every active input action and its key binding across all connected devices.

## Get the mod

Install from the [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

## Coming in the next release

Already finished on the dev branch, waiting for the next ModHub update. If you are about to report one of these, it is already addressed:

- **Precision Farming compatibility** -- PF's combine yield strip no longer overlaps the EHM panel. General coexistence improved with native HUD extensions and other mods that add to the input-help area.
- **Full German localization** -- every HUD string now translates, not just input action labels (v1.0.0.0 shipped only the four input action labels translated).
- **Work-mode status line** -- shows the current work mode of attached implements (e.g. "Mode: Loading") live in the extra-text block.
- **AI-mode status line** -- shows AI Worker / Steering Assist live, with a HOLD-H key hint pill, plus the worker's running state (Driving / Working / Turning / Blocked).
- **Duplicate "Toggle Steering Assist" row removed** -- the unbound row that mirrored the H-bound TOGGLE_AI label no longer appears.
- **German umlauts at line-truncation points** no longer render as garbled glyphs.
- **Rounded backgrounds** for rows and pills now render correctly (v1.0.0.0 fell back to flat fallback rectangles due to an asset-path mismatch).
- **Quieter game log** -- only genuine errors reach FS25's shared `log.txt` now; routine debug events stay in EHM's private log.
- **In-game settings tab** -- ESC -> Settings now includes an "Enhanced Settings" tab with an "Enhanced Help Menu" group. The first setting is **Show base game F1 menu** (default OFF). Pairs with the `FS25_EnhancedGameplay` mod (same shared tab convention) so both mods' settings appear in one place.
- **Show base game F1 menu setting** -- turn ON to use the vanilla F1 menu instead of EHM's overlay. With it ON, F1 cycles through native F1 -> EHM -> both off; with it OFF (default), F1 just toggles EHM on/off. Precision Farming widgets stay visible in either mode (they re-host inside EHM, or render on native F1 when that's the active display).

## Report a bug or suggest a feature

Use the **[Issues tab](../../issues/new/choose)** above. Templates prompt for FS25 version, mod version, log snippet, and repro steps. Please search existing issues first, and check the "Coming in the next release" section above -- your issue may already be fixed.

## License

See `LICENSE` if present. If absent, all rights reserved by the mod author.
