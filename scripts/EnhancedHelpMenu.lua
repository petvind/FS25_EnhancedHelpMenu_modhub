-- =============================================================================
-- EnhancedHelpMenu — FS25 Mod
-- Version: see modDesc.xml (single source of truth — read at runtime)
--
-- PURPOSE:
--   Displays all currently active input actions and their key bindings in a
--   clean overlay panel. Acts as a smarter, more complete alternative to the
--   game's built-in F1 hint menu — showing ALL active actions across all
--   devices, not just the ones the game chooses to highlight.
--
-- CONTROLS (defaults; all remappable in the in-game Controls menu):
--   F1            — Cycle display state (game's own toggle key)
--   LALT + INS    — Open/close filter mode (click categories to filter list, click rows to hide them)
--   LALT + PGUP   — Previous page
--   LALT + PGDN   — Next page
--   LALT + HOME   — Cycle device filter (Keyboard/Mouse, Joystick, etc.)
-- (ALT-prefixed defaults since v1.13.0.5 -- bare PGUP/PGDN were sharing keys with
--  vanilla CAMERA_ZOOM_IN_OUT. See version_logs/1.13.0.5.md for the full story.)
--
-- DOCS (canonical — kept in dedicated files, NOT duplicated here, so they
--       cannot drift out of sync with this header):
--   Architecture / internals      — docs/architecture.md
--   FS25 Lua gotchas (cross-mod)   — ../Toolkit/gotchas.md  (path from mod root)
--   Mod-specific gotchas, overview — CLAUDE.md
-- =============================================================================

-- Capture mod directory and name at load time — these globals are nil at draw() time.
local MOD_DIR  = g_currentModDirectory or ""
local MOD_NAME = g_currentModName or ""

-- Mod version, read from modDesc.xml at runtime so there is a single source of
-- truth. A hardcoded string would silently drift out of sync at every version
-- bump (step 8 of the workflow only edits modDesc.xml). pcall-wrapped — any
-- failure falls back to "unknown" rather than breaking log init.
local function getModVersion()
    local version = "unknown"
    pcall(function()
        if g_modManager ~= nil and MOD_NAME ~= "" then
            local mod = g_modManager:getModByName(MOD_NAME)
            if mod ~= nil and mod.version ~= nil then
                version = tostring(mod.version)
            end
        end
    end)
    return version
end

EnhancedHelpMenu = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 500  -- ms between data rebuilds

-- Action rows shown per page. Player-adjustable via the in-game settings menu
-- (Enhanced Settings → Enhanced Help Menu → "Rows per page"). The setting is
-- persisted to EHM_settings.xml under EHM.behavior#rowsPerPage; the historical
-- default (12) is preserved for existing installs without the field.
--
-- currentPageSize() is the single read site for the live value -- the draw
-- loop reads it once per frame and uses the same value for all four page-math
-- sites so a mid-frame change can't desync the math.
local PAGE_SIZE_DEFAULT       = 12
local EHM_ROWS_PER_PAGE_CHOICES = {6, 8, 10, 12, 14, 16, 20}

local EHM_ROWS_PER_PAGE_SET = {}
for _, n in ipairs(EHM_ROWS_PER_PAGE_CHOICES) do EHM_ROWS_PER_PAGE_SET[n] = true end

-- Clamps any input (including nil) to a valid choice. Used on load (forward-
-- compatible with files that pre-date the field, or carry a stale value the
-- choice list no longer offers) and on save (defensive).
local function sanitizeRowsPerPage(n)
    if type(n) == "number" and EHM_ROWS_PER_PAGE_SET[n] then return n end
    return PAGE_SIZE_DEFAULT
end

local function currentPageSize()
    local s = EnhancedHelpMenu and EnhancedHelpMenu.settings
    return sanitizeRowsPerPage(s and s.rowsPerPage or nil)
end

-- ---------------------------------------------------------------------------
-- Layout constants — normalized screen-space coordinates (0.0–1.0).
-- FS25's coordinate system scales all values proportionally to the actual
-- screen resolution automatically. We NEVER compute physical pixels at runtime.
-- Reference basis: 1920×1080 (the design doc reference resolution).
-- PX = 1 pixel horizontal at 1080p reference = 1/1920
-- PY = 1 pixel vertical   at 1080p reference = 1/1080
-- ---------------------------------------------------------------------------
local PX = 1.0 / 1920  -- fixed reference — do NOT detect at runtime
local PY = 1.0 / 1080  -- fixed reference — do NOT detect at runtime

-- Panel position/size (normalized, screen-relative)
local PANEL_X     = 30 * PX   -- 0.015625 — native FS25 left edge (30px @1920)
local PANEL_TOP_Y = 0.9722    -- matches ih.y so native vehicle schema icons
                               -- render naturally inside our header

-- Panel width scaling (since v1.13.0.0). Stored as an integer percentage
-- where 100% == the measured native F1 help menu width
-- (NATIVE_PANEL_WIDTH below). Player picks from a discrete list in the
-- in-game settings menu (Enhanced Settings → Enhanced Help Menu →
-- "Width scaling"). currentPanelWidth() is the single read site, used
-- by the draw loop's `width` local; that value is then multiplied by
-- the global UI scale (HUD scale) at the draw site, so width-scaling
-- and HUD-scaling compose multiplicatively.
--
-- Default 150% ≈ EHM's pre-v1.13 "wider" preset (0.264 / 0.177083 =
-- 1.491; rounded up to the next 25% step). Visually indistinguishable
-- from the old default for users upgrading.
--
-- NATIVE-WIDTH SOURCE
-- NATIVE_PANEL_WIDTH is the measured width of FS25's base-game F1 help
-- menu (`g_currentMission.hud.inputHelp.helpAnchorOffsetX`), captured by
-- the v1.8.1.0 probe on 2026-05-23. ih.x and ih.y match EHM's PANEL_X /
-- PANEL_TOP_Y exactly, and helpAnchorOffsetX is the right-edge offset
-- from ih.x where the native menu anchors its content -- i.e. the box
-- width. probeNativeInputHelpWidth() stays as a session sanity check;
-- if FS25 patches change the value, the log will surface it.
local NATIVE_PANEL_WIDTH         = 0.177083
-- Minimum is 125% (not 100%). Background:
--   - v1.13.0.0 shipped 100% and it overlapped (too many header pills).
--   - v1.13.0.1 bumped the minimum to 125%.
--   - v1.13.0.6 / .7 / .8 trimmed three header items (TOGGLE [F1] pill,
--     action count, PAGE label). Looked like 100% might fit again.
--   - v1.13.0.10 added 100% back to the choice list as an experiment.
--   - v1.13.0.11 (this version) removed 100% again -- in-game testing
--     confirmed the trimmed savings don't compensate for the wider
--     ALT-prefixed key pills added in v1.13.0.5. The header still
--     overlaps at 100%. 125% remains the practical minimum.
-- If anyone wants to revisit 100% in the future, the constraint is the
-- HEADER content width (specifically the longest of the two header
-- rows). Either trim more pills, shorten key labels, or change the
-- rendering to allow overflow into row 2.
local EHM_WIDTH_SCALE_CHOICES    = {125, 150, 175, 200, 225, 250, 275, 300}
local EHM_WIDTH_SCALE_DEFAULT    = 150

local EHM_WIDTH_SCALE_SET = {}
for _, n in ipairs(EHM_WIDTH_SCALE_CHOICES) do EHM_WIDTH_SCALE_SET[n] = true end

-- Clamps any input (nil, out-of-range, off-grid) to a valid choice.
-- Also handles the legacy v1.8 - v1.12 panelWidthMode string values so
-- upgrading installs don't lose their setting.
local function sanitizePanelWidthScale(v)
    if type(v) == "number" and EHM_WIDTH_SCALE_SET[v] then return v end
    if type(v) == "string" then
        -- "native" -> 125 (was 100 in v1.13.0.0, restored to 100 in
        -- v1.13.0.10, back to 125 in v1.13.0.11 when 100 turned out
        -- to still overlap after testing). 125 is the closest valid
        -- choice to the original 100% semantic.
        if v == "native" then return 125 end
        if v == "wider"  then return 150 end
    end
    return EHM_WIDTH_SCALE_DEFAULT
end

local function currentPanelWidth()
    local s = EnhancedHelpMenu and EnhancedHelpMenu.settings
    local scale = sanitizePanelWidthScale(s and s.panelWidthScale or nil)
    return NATIVE_PANEL_WIDTH * scale / 100
end

-- UI scale (50%..125% in 5% steps; default 100%). Follows the player's master
-- HUD scaling setting so EHM grows / shrinks alongside vanilla HUDs like the
-- speedometer or fuel display. Read once per frame in draw() / update() into
-- a local so per-frame uses see a single consistent value.
--
-- Source-of-truth priority:
--   1. g_gameSettings.uiScale -- the master setting the player adjusts in
--      Settings -> Display. Authoritative when present.
--   2. g_currentMission.hud.inputHelp.uiScale -- mirror cached on the
--      native InputHelpDisplay instance; same value, used as fallback in
--      case gameSettings isn't fully initialised yet (early loadMap window).
--   3. 1.0 (100%) -- final fallback if neither source is available.
--
-- The scale is bounded by FS25's choice list (0.5 .. 1.25) but we clamp
-- defensively in case a future patch widens the range and a value outside
-- our assumptions would distort the panel beyond usability.
local function currentUIScale()
    local s
    if g_gameSettings ~= nil and type(g_gameSettings.uiScale) == "number" then
        s = g_gameSettings.uiScale
    elseif g_currentMission ~= nil and g_currentMission.hud ~= nil
       and g_currentMission.hud.inputHelp ~= nil
       and type(g_currentMission.hud.inputHelp.uiScale) == "number" then
        s = g_currentMission.hud.inputHelp.uiScale
    else
        s = 1.0
    end
    -- Defensive clamp to the documented vanilla range.
    if s < 0.5 then s = 0.5 end
    if s > 1.5 then s = 1.5 end
    return s
end

-- Typography
local SIZE_TEXT = 12 * PY  -- 0.011111 — native FS25 font size

-- Row geometry (native FS25 values from design token reference)
local ROW_H     = 25 * PY   -- 0.023148 — native row height
local ROW_GAP   =  5 * PY   -- gap between rows
local TEXT_OY   =  8 * PY   -- 0.007407 — text baseline offset inside row
local HDR_PAD   =  5 * PY   -- top/bottom padding inside header block
local PADDING_X = 14 * PX   -- 0.007292 — horizontal text margin
local KEY_PAD_X = 15 * PX   -- horizontal padding inside key pill

-- Rounded corner caps — native FS25 end cap is exactly 6px @1920 = 0.003125
local ROW_CAP_W = 6 * PX    -- row end cap width  (native: 6px)
local KEY_CAP_W = 6 * PX    -- pill end cap width (native: 6px)
local CORNER_R  = 6 * PX    -- fallback 3-rect corner radius for rows
local PILL_R    = 6 * PX    -- fallback 3-rect corner radius for pills

-- Header 9-slice vertical cap (6px vertical, using PY reference)
local HDR_CAP_H = 6 * PY    -- 0.005556

-- Spacing
local STRIP_GAP     = 3 * PX  -- gap between filter-strip category pills
local SEP_PAD       = 4 * PX  -- extra width around | and + separators
local LABEL_GAP     = 6 * PX  -- gap between action label and binding pills
local ACCENT_BAR_W  = 3 * PX  -- width of the new-action left accent bar

-- Eye icons (Stage 2 hide/un-hide UI). Rendered at the left edge of every action
-- row when filter mode is open, before the label. Source PNG is 64x64 white-on-
-- transparent; tinted at runtime via setOverlayColor so the same texture serves
-- both visible (full white) and hidden (HIDDEN_DIM_ALPHA white) states.
local ICON_W   = 16 * PX  -- icon width  (~16px @1080p reference)
local ICON_H   = 16 * PY  -- icon height (~16px @1080p reference, square render)
local ICON_GAP = 6 * PX   -- horizontal gap between icon and label

-- Panel padding above/below action rows
local PAD_TOP    = 5 * PY   -- 0.004630 — top padding above action rows (matches ROW_GAP)
local PAD_BOTTOM = 5 * PY   -- 0.004630 — bottom padding below action rows
local INNER_ROW_GAP = 4 * PY  -- gap between the two pill lines inside a double-height row

-- Animation timing (all in milliseconds)
local ANIM_SHIFT_DURATION  = 200   -- row shift ease-out duration (new rows inserting)
local ANIM_FADE_DURATION   = 200   -- new row fade-in duration
local ANIM_ACCENT_DELAY    = 200   -- delay before accent bar appears (matches shift animation)
local ANIM_ACCENT_FADEIN   = 100   -- accent bar fade-in
local ANIM_ACCENT_HOLD     = 3200  -- accent bar hold at full opacity
local ANIM_ACCENT_FADEOUT  = 300   -- accent bar fade-out
local ANIM_ACCENT_OPACITY  = 0.75  -- accent bar peak opacity (0–1)
local ANIM_DEPARTED_GRACE  = 4     -- rebuild cycles before a departed animState is discarded

-- DOF blur animation (filter mode open/close)
local DOF_FADE_IN_MS      = 200    -- blur ramp-up duration
local DOF_FADE_OUT_MS     = 150    -- blur ramp-down duration (slightly snappier on close)
local DOF_NEAR_COC        = 5.0    -- near circle-of-confusion radius at full blur
local DOF_FAR_COC         = 4.0    -- far  circle-of-confusion radius at full blur
local DOF_NEAR_BLUR_END   = 0.5    -- near blur zone end (metres)
local DOF_FAR_BLUR_START  = 0      -- far  blur zone start (metres) — 0 eliminates sharp mid zone
local DOF_FAR_BLUR_END    = 25     -- far  blur zone end (metres)
local DOF_NEAR_COC_BASE   = 0.8    -- game default near CoCRadius
local DOF_FAR_COC_BASE    = 0.2    -- game default far  CoCRadius

-- Extra-text block height animation. The block holds the separator + N text rows.
-- Easing the block height (and tying text/separator alpha to it) prevents the visible
-- pop that happens when extratext jumps from 0 to N rows in a single frame.
-- Open is slightly slower than close so appearance feels deliberate, retraction snappy.
local XT_HEIGHT_FADE_IN_MS  = 150  -- expand duration
local XT_HEIGHT_FADE_OUT_MS = 100  -- retract duration

-- Precomputed animation factors (computed once, used every update frame)
local ANIM_SHIFT_DECAY    = math.log(100) / ANIM_SHIFT_DURATION    -- exp decay: ~1% in 200ms
local XT_HEIGHT_DECAY_IN  = math.log(100) / XT_HEIGHT_FADE_IN_MS   -- exp decay: ~1% in 150ms
local XT_HEIGHT_DECAY_OUT = math.log(100) / XT_HEIGHT_FADE_OUT_MS  -- exp decay: ~1% in 100ms
local ANIM_FADE_SPEED  = 1.0 / ANIM_FADE_DURATION             -- linear: 0→1 in 200ms

-- Monotonic counter incremented ONCE per rebuild that detects new actions.
-- Stored in animState so the sort can put most-recently-detected first
-- within the active-animation sub-group. Actions detected together in the same
-- rebuild share the same value, so they don't shuffle relative to each other —
-- they fall through to priority/order tiebreaker. Different rebuilds get
-- different values, so a later-arriving action (ENTER VEHICLE arriving after
-- SELECT CAMERA already animating) sorts above the earlier batch.
local EHM_DETECT_ORDER = 0

-- Row texture UV split constants — 6px corner in 256×32 texture and 64×32 pill texture
-- Horizontal: 6/256 = 0.023438   Vertical: 6/32 = 0.187500
local ROW_UV_X = 0.023438
local ROW_UV_Y = 0.187500

-- Colours — extracted from FS25 HUD design token reference
-- Panel bg: #010101 (native) = RGB(1,1,1)/255
local _c = 1/255  -- #010101 channel value

-- Backgrounds
local COL_BG_PANEL    = { _c,    _c,    _c,    0.65 }  -- action row bg      — native #010101 @ 65%
local COL_BG_HEADER   = { _c,    _c,    _c,    0.65 }  -- header bg          — same as panel to blend with vehicle schema box
local COL_BG_KEY      = { 0,     0,     0,     0.80 }  -- key pill dark bg   — native #000000 @ 80%
local COL_BG_KEY_NEW  = { 0.239, 0.463, 0,     1.0  }  -- key pill green bg  — brand #3d7600

-- Text
local COL_WHITE       = { 0.910, 0.910, 0.910, 1.0  }  -- main text — bold numbers, pill labels
local COL_HINT_LBL    = { 1.0,   1.0,   1.0,   0.35 }  -- dim hint labels, extra text — not bold
local COL_HOLD        = { 1.0,   1.0,   1.0,   0.45 }  -- HOLD prefix text
local COL_SEP_PLUS    = { 1.0,   1.0,   1.0,   0.55 }  -- "+" chord key separator (toned down from 1.00 in v1.13.0.4 -- was the brightest non-primary element in the palette and competed with the key pills it's gluing; rendered as bold text)
local COL_SEP_LINE    = { 1.0,   1.0,   1.0,   0.40 }  -- "|" binding group separator line (toned down from 0.65 in v1.13.0.4 alongside the "+" reduction; sits near the hint-label band so the alt-binding delimiter reads as visual rest rather than competing with the pills)

-- Header selected / active state (device name pill, FILTER pill when open)
local COL_SEL_PILL    = { 1.0,   1.0,   1.0,   0.16 }  -- selected pill bg — white @ 16%

-- Filter strip
local COL_CAT_ON_BG   = { 1.0,   1.0,   1.0,   0.14 }  -- enabled category bg  — monochrome white @ 14%
local COL_CAT_OFF_TEXT = { 0.5,  0.5,   0.5,   0.65 }  -- disabled category text — grey

-- Extra text bar
local COL_XT_BAR      = { 1.0,   1.0,   1.0,   0.22 }  -- extra text accent bar — grey, always visible

-- Hidden-action visual treatment (Stage 2). Multiplied into row background,
-- label, binding pills, HOLD prefix and accent bar of any row whose isHidden
-- flag is true. The same value is used by the strike-through helper for the
-- alpha component of the line through the label.
local HIDDEN_DIM_ALPHA = 0.35

-- ---------------------------------------------------------------------------
-- Logging
--
-- Three tiers, split by audience:
--
--   dbg()  — Verbose rebuild-level detail (rebuild start/end, per-action lists,
--             overlay IDs). EHM_debug.log only. No-op unless DEBUG = true.
--
--   log()  — Operational event trace (context switches, new actions, state
--             changes, setup confirmations). EHM_debug.log only, always on.
--
--   warn() — Genuine warnings and failures. EHM_debug.log AND the game's
--             log.txt, always on — so problems survive a crash and show up in
--             player bug reports. Reserve for things that actually went wrong.
--
-- Only warn() touches the shared log.txt; routine tracing stays in the mod's
-- own log so a published EHM does not spam every player's game log.
--
-- Log file: Documents/My Games/FarmingSimulator2025/modSettings/EHM_debug.log
-- Overwritten each session. Set DEBUG = true for rebuild-level detail.
-- ---------------------------------------------------------------------------

local DEBUG = false

local EHM_LOG = {}
EHM_LOG.file = nil
EHM_LOG.path = nil

function EHM_LOG.init()
    local dir = getUserProfileAppPath() .. "modSettings/"
    createFolder(dir)
    EHM_LOG.path = dir .. "EHM_debug.log"
    EHM_LOG.file = io.open(EHM_LOG.path, "w")
    if EHM_LOG.file then
        EHM_LOG.file:write("=== Enhanced Help Menu ===\n")
        EHM_LOG.file:write(string.format("Version: %s  |  Started: %s  |  DEBUG: %s\n\n",
            getModVersion(),
            tostring(getDate and getDate("%d/%m/%Y %H:%M") or "unknown"),
            tostring(DEBUG)))
        EHM_LOG.file:flush()
    else
        print("[EHM] WARNING: Could not open log file: " .. (EHM_LOG.path or "?"))
    end
end

function EHM_LOG.close()
    if EHM_LOG.file then
        EHM_LOG.file:write("\n=== Session ended ===\n")
        EHM_LOG.file:close()
        EHM_LOG.file = nil
    end
end

-- Always-on operational event trace. Written to EHM_debug.log only — routine
-- events do not reach the shared game log.txt (see warn() for that).
local function log(msg, ...)
    if EHM_LOG.file then
        EHM_LOG.file:write(string.format(msg, ...) .. "\n")
        EHM_LOG.file:flush()
    end
end

-- Always-on warnings/failures. Written to EHM_debug.log AND mirrored to the
-- game log.txt via print(), so genuine problems survive a crash and are visible
-- in player bug reports. The print() fires even if the log file failed to open.
local function warn(msg, ...)
    local line = string.format(msg, ...)
    if EHM_LOG.file then
        EHM_LOG.file:write(line .. "\n")
        EHM_LOG.file:flush()
    end
    print("[EHM] " .. line)
end

-- Verbose: rebuild-level detail. EHM_debug.log only. No-op unless DEBUG = true.
local function dbg(msg, ...)
    if DEBUG and EHM_LOG.file then
        EHM_LOG.file:write("[D] " .. string.format(msg, ...) .. "\n")
        EHM_LOG.file:flush()
    end
end

-- =============================================================================
-- LOCALIZATION
-- Runtime UI strings resolve from translations/translation_<lang>.xml, declared
-- via <l10n filenamePrefix> in modDesc.xml. l10n() wraps g_i18n:getText with a
-- graceful fallback: a missing key or unavailable g_i18n returns the supplied
-- English fallback instead of breaking a render pass.
--
-- Resolved values are memoised in L10N_CACHE — the active game language is
-- fixed for the session, so each key resolves to a constant. Only a successful
-- g_i18n resolution is cached; the fallback path is left uncached so an early
-- call made before g_i18n is ready simply retries on the next call.
-- =============================================================================
local L10N_CACHE = {}
local function l10n(key, fallback)
    local cached = L10N_CACHE[key]
    if cached ~= nil then return cached end
    if g_i18n ~= nil then
        local ok, value = pcall(function()
            if g_i18n.hasText ~= nil and not g_i18n:hasText(key) then return nil end
            return g_i18n:getText(key)
        end)
        if ok and value ~= nil and value ~= "" then
            L10N_CACHE[key] = value
            return value
        end
    end
    return fallback or key
end

-- =============================================================================
-- CATEGORY SYSTEM
-- Base game categories identified by $l10n_inputCategory_ prefix.
-- All other displayCategory values are bucketed under MODS.
-- =============================================================================

-- Ordered list of base game categories. `key` is the engine category id used for
-- matching actions; `abbrKey` is the l10n key for the filter-strip label; `abbr`
-- is the English fallback used when l10n is unavailable.
-- Order determines left-to-right display in the filter strip.
local EHM_CATEGORIES = {
    { key = "$l10n_inputCategory_CAMERA",             abbrKey = "EHM_CAT_CAMERA",             abbr = "CAM"     },
    { key = "$l10n_inputCategory_CONSTRUCTION",       abbrKey = "EHM_CAT_CONSTRUCTION",       abbr = "BUILD"   },
    { key = "$l10n_inputCategory_CRANE",              abbrKey = "EHM_CAT_CRANE",              abbr = "CRANE"   },
    { key = "$l10n_inputCategory_GAME",               abbrKey = "EHM_CAT_GAME",               abbr = "GAME"    },
    { key = "$l10n_inputCategory_PLAYER_INTERACTIVE", abbrKey = "EHM_CAT_PLAYER_INTERACTIVE", abbr = "PLR INT" },
    { key = "$l10n_inputCategory_PLAYER_MOVEMENT",    abbrKey = "EHM_CAT_PLAYER_MOVEMENT",    abbr = "PLR MOV" },
    { key = "$l10n_inputCategory_RADIO",              abbrKey = "EHM_CAT_RADIO",              abbr = "RADIO"   },
    { key = "$l10n_inputCategory_VEHICLE",            abbrKey = "EHM_CAT_VEHICLE",            abbr = "VEHICLE" },
    { key = "$l10n_inputCategory_VEHICLE_DRIVING",    abbrKey = "EHM_CAT_VEHICLE_DRIVING",    abbr = "DRIVING" },
    { key = "$l10n_inputCategory_VEHICLE_GEARBOX",    abbrKey = "EHM_CAT_VEHICLE_GEARBOX",    abbr = "GEARBOX" },
    { key = "$l10n_inputCategory_VEHICLE_LIGHTS",     abbrKey = "EHM_CAT_VEHICLE_LIGHTS",     abbr = "LIGHTS"  },
    { key = "$l10n_inputCategory_VEHICLE_WORK",       abbrKey = "EHM_CAT_VEHICLE_WORK",       abbr = "WORK"    },
    { key = "MODS",                                   abbrKey = "EHM_CAT_MODS",               abbr = "MODS"    },
}

-- Build a lookup from category key → index for fast access in rebuild()
local EHM_CAT_INDEX = {}
for i, cat in ipairs(EHM_CATEGORIES) do
    EHM_CAT_INDEX[cat.key] = i
end
local EHM_MODS_INDEX = #EHM_CATEGORIES  -- MODS is always last

-- =============================================================================
-- SETTINGS PERSISTENCE
-- Stored in modSettings/EHM_settings.xml — global across all saves.
-- Uses the FS25 XMLFile/XMLSchema engine API which works from any callback
-- context (no restrictions like raw io.open). Pattern from Courseplay/ForestryHelper.
-- =============================================================================
local EHM_SETTINGS = {}

function EHM_SETTINGS.getPath()
    return getUserProfileAppPath() .. "modSettings/EHM_settings.xml"
end

-- Schema is created once and reused. Must be registered before any
-- XMLFile.loadIfExists or XMLFile.create call.
local EHM_SETTINGS_SCHEMA = nil
local function EHM_SETTINGS_getSchema()
    if EHM_SETTINGS_SCHEMA ~= nil then return EHM_SETTINGS_SCHEMA end
    local s = XMLSchema.new("EHM")
    -- toggleState: 0=EHM, 1=F1, 2=both off. Default 0 so absent key → EHM.
    s:register(XMLValueType.INT,  "EHM.ui#state", 0)
    for i = 1, #EHM_CATEGORIES do
        s:register(XMLValueType.BOOL, string.format("EHM.filter#cat%d", i), true)
    end
    -- Hidden actions list. The user can hide individual rows from the panel;
    -- those names are persisted here. Only action NAMES are stored — labels and
    -- categories are looked up live from g_inputBinding when needed (hide and
    -- un-hide only happen for actions currently active in the session).
    s:register(XMLValueType.STRING, "EHM.hidden.action(?)#name")
    -- Hidden extra-text rows (filter-mode toggle on the header band).
    -- Each entry stores both the exact text seen at hide time AND the "stem"
    -- (text up to the first digit, trimmed). Match rule at runtime: exact
    -- match wins; stem match is the fallback so rows whose live values
    -- change frame-to-frame (e.g. "Field 12: 47%") stay hidden when the
    -- numeric value updates. Stem is "" for rows with no digits, in which
    -- case only exact match applies (so e.g. "AI Helper: Working" and
    -- "AI Helper: Turning" don't collide).
    s:register(XMLValueType.STRING, "EHM.hidden.extra(?)#exact")
    s:register(XMLValueType.STRING, "EHM.hidden.extra(?)#stem")
    -- Behaviour settings (in-game settings menu — Enhanced Settings tab).
    -- showBaseGameHelp default false → EHM replaces the native F1 menu (the
    -- mod's reason to exist). Toggle ON to use the vanilla F1 menu instead,
    -- in which case EHM stops drawing and lets the native InputHelpDisplay
    -- show PF and other captured help extensions.
    s:register(XMLValueType.BOOL, "EHM.behavior#showBaseGameHelp", false)
    -- rowsPerPage: number of action rows per page in the HUD panel.
    -- Default matches the historical PAGE_SIZE constant.
    s:register(XMLValueType.INT,  "EHM.behavior#rowsPerPage", PAGE_SIZE_DEFAULT)
    -- panelWidthScale (since v1.13.0.0): integer percentage where 100 ==
    -- native F1 help menu width. Player picks from a discrete choice list
    -- (100, 125, 150, ...). Default 150 ≈ EHM's pre-v1.13 "wider" preset.
    s:register(XMLValueType.INT, "EHM.behavior#panelWidthScale", EHM_WIDTH_SCALE_DEFAULT)
    -- Legacy v1.8 - v1.12 field. Still registered so load() can read it
    -- from upgrading installs and migrate to panelWidthScale. Save() no
    -- longer writes it -- after one upgrade cycle the field falls out
    -- of the XML naturally.
    s:register(XMLValueType.STRING, "EHM.behavior#panelWidthMode")
    EHM_SETTINGS_SCHEMA = s
    return s
end

-- Returns savedToggleState (0/1/2 or nil on first-ever run) and settingsExisted (bool).
-- nil/false → truly first install, no file on disk → post-init uses game default.
-- integer/true → file existed → post-init restores saved state.
--
-- Also populates `hiddenActions` (set keyed by action name → true) with any
-- hidden-action entries found in the XML. If the file is missing or has no
-- <hidden> block, the table is left empty.
function EHM_SETTINGS.load(filterEnabled, hiddenActions, hiddenExtraTexts, settings)
    for i = 1, #EHM_CATEGORIES do filterEnabled[i] = true end

    local xmlFile = XMLFile.loadIfExists("EHM_Settings", EHM_SETTINGS.getPath(), EHM_SETTINGS_getSchema())
    if xmlFile == nil then
        return nil, false  -- file does not exist → first-ever run
    end

    -- Behaviour settings — schema defaults apply if the file pre-dates the field.
    if settings ~= nil then
        local v = xmlFile:getValue("EHM.behavior#showBaseGameHelp")
        settings.showBaseGameHelp = (v == true)
        local rpp = xmlFile:getValue("EHM.behavior#rowsPerPage")
        settings.rowsPerPage = sanitizeRowsPerPage(rpp)
        -- Prefer the new panelWidthScale field; if absent (legacy install),
        -- migrate from the v1.8 - v1.12 panelWidthMode field via
        -- sanitizePanelWidthScale (handles both numeric and "native" /
        -- "wider" string inputs).
        local pws = xmlFile:getValue("EHM.behavior#panelWidthScale")
        if pws == nil then
            pws = xmlFile:getValue("EHM.behavior#panelWidthMode")
        end
        settings.panelWidthScale = sanitizePanelWidthScale(pws)
    end

    for i = 1, #EHM_CATEGORIES do
        local val = xmlFile:getValue(string.format("EHM.filter#cat%d", i))
        filterEnabled[i] = (val ~= false)  -- nil (absent) treated as true (default)
    end

    -- Returns 0/1/2 from the file, or the schema default (0 = EHM) if absent.
    local savedState = xmlFile:getValue("EHM.ui#state")

    -- Load hidden-action names if the table was provided. iterate() walks every
    -- <action> under <hidden>; absent entries simply don't fire the callback.
    if hiddenActions ~= nil then
        xmlFile:iterate("EHM.hidden.action", function(_, key)
            local name = xmlFile:getValue(key .. "#name")
            if type(name) == "string" and name ~= "" then
                hiddenActions[name] = true
            end
        end)
    end

    -- Load hidden extra-text entries. Skip rows where exact text is missing
    -- (a corrupt or hand-edited XML entry); stem may legitimately be empty
    -- for rows that had no digits at hide time.
    if hiddenExtraTexts ~= nil then
        xmlFile:iterate("EHM.hidden.extra", function(_, key)
            local exact = xmlFile:getValue(key .. "#exact")
            local stem  = xmlFile:getValue(key .. "#stem") or ""
            if type(exact) == "string" and exact ~= "" then
                table.insert(hiddenExtraTexts, {exact = exact, stem = stem})
            end
        end)
    end

    xmlFile:delete()
    return savedState, true
end

-- Saves all settings. Works from any context (deleteMap, onUIModeExit, etc.)
-- because XMLFile.create uses the engine's own file system, not raw io.
-- hiddenActions is optional; pass nil to skip writing the <hidden> block.
function EHM_SETTINGS.save(filterEnabled, toggleState, hiddenActions, hiddenExtraTexts, settings)
    local dir = getUserProfileAppPath() .. "modSettings/"
    createFolder(dir)

    local xmlFile = XMLFile.create("EHM_Settings", EHM_SETTINGS.getPath(), "EHM", EHM_SETTINGS_getSchema())
    if xmlFile == nil then return end

    for i = 1, #EHM_CATEGORIES do
        xmlFile:setValue(string.format("EHM.filter#cat%d", i), filterEnabled[i] ~= false)
    end
    xmlFile:setValue("EHM.ui#state", toggleState or 0)

    -- Behaviour settings (optional — older callers can pass nil).
    if settings ~= nil then
        xmlFile:setValue("EHM.behavior#showBaseGameHelp",
            settings.showBaseGameHelp == true)
        xmlFile:setValue("EHM.behavior#rowsPerPage",
            sanitizeRowsPerPage(settings.rowsPerPage))
        xmlFile:setValue("EHM.behavior#panelWidthScale",
            sanitizePanelWidthScale(settings.panelWidthScale))
    end

    -- Write hidden-action names. Index runs 0..n-1 to match the schema's
    -- repeating-element pattern. Skipped silently if no table was passed.
    if hiddenActions ~= nil then
        local i = 0
        for name, isHidden in pairs(hiddenActions) do
            if isHidden then
                local key = string.format("EHM.hidden.action(%d)", i)
                xmlFile:setValue(key .. "#name", name)
                i = i + 1
            end
        end
    end

    -- Write hidden extra-text entries. Same 0-based repeating-element index.
    if hiddenExtraTexts ~= nil then
        for i, entry in ipairs(hiddenExtraTexts) do
            local key = string.format("EHM.hidden.extra(%d)", i - 1)
            xmlFile:setValue(key .. "#exact", entry.exact or "")
            xmlFile:setValue(key .. "#stem",  entry.stem  or "")
        end
    end

    xmlFile:save()
    xmlFile:delete()
end

-- =============================================================================
-- EXTRA-TEXT HIDE: MATCH HELPERS
-- Hidden extra-text rows are matched via a two-stage rule:
--   1) exact text match (handles rows with no dynamic content like
--      "AI Helper: Working" -- different from "AI Helper: Turning")
--   2) stem match fallback (handles rows whose live values change
--      frame-to-frame like "Field 12: 47%" -> "Field 12: 49%")
-- The stem is everything before the first digit, trimmed. Stem "" means
-- the text has no digits -- in that case only exact match applies, so
-- two textually different no-digit rows never collide.
-- =============================================================================

local function extraTextStem(text)
    if type(text) ~= "string" then return "" end
    -- Slice text up to the first digit (0-9). Strings without digits keep
    -- their full content. Trim trailing whitespace + common separators.
    local prefix = text:match("^([^%d]*)") or ""
    -- Trim trailing whitespace, ':', '-', '(' so e.g. "Field 12: 47%" gives
    -- stem "Field" not "Field " (with trailing space) which would make exact
    -- comparisons fragile across stored vs. live runs.
    prefix = prefix:gsub("[%s%-%:%(]+$", "")
    return prefix
end

local function isExtraTextHidden(hiddenExtraTexts, text)
    if hiddenExtraTexts == nil or type(text) ~= "string" then return false end
    local stem = extraTextStem(text)
    for _, entry in ipairs(hiddenExtraTexts) do
        if entry.exact == text then return true end
        if stem ~= "" and entry.stem == stem then return true end
    end
    return false
end

-- Returns the 1-based index of the entry that matches (exact OR stem),
-- or nil if no entry matches. Used by toggle to remove on un-hide.
local function findHiddenExtraTextIndex(hiddenExtraTexts, text)
    if hiddenExtraTexts == nil or type(text) ~= "string" then return nil end
    local stem = extraTextStem(text)
    for i, entry in ipairs(hiddenExtraTexts) do
        if entry.exact == text then return i end
        if stem ~= "" and entry.stem == stem then return i end
    end
    return nil
end

-- Toggle hide for the row whose currently-rendered text is `text`. If it's
-- already hidden (exact or stem match), un-hide by removing the entry;
-- otherwise, add a new entry capturing both exact text and stem. Persists
-- via EHM_SETTINGS.save. Returns the new hidden state (true = now hidden).
function EnhancedHelpMenu:toggleExtraTextHidden(text)
    if type(text) ~= "string" or text == "" then return false end
    self.hiddenExtraTexts = self.hiddenExtraTexts or {}
    local idx = findHiddenExtraTextIndex(self.hiddenExtraTexts, text)
    local nowHidden
    if idx ~= nil then
        table.remove(self.hiddenExtraTexts, idx)
        nowHidden = false
    else
        table.insert(self.hiddenExtraTexts, {
            exact = text,
            stem  = extraTextStem(text),
        })
        nowHidden = true
    end
    log("Hidden extra-text toggle: %q -> %s", text, tostring(nowHidden))
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    return nowHidden
end

-- Logs what changed between two active sets.
-- Always logs counts AND names. Large diffs (context switches with 25+ changes)
-- are condensed to first-N + count to keep the log readable.
local function dbgDiff(label, prev, curr)
    local added, removed = {}, {}
    for k in pairs(curr) do
        if not prev or not prev[k] then table.insert(added, k) end
    end
    for k in pairs(prev or {}) do
        if not curr[k] then table.insert(removed, k) end
    end
    if #added > 0 or #removed > 0 then
        log("%s: +%d -%d", label, #added, #removed)
        table.sort(added); table.sort(removed)
        local function brief(list)
            if #list <= 8 then return table.concat(list, ",") end
            local first = {}
            for i = 1, 8 do first[i] = list[i] end
            return table.concat(first, ",") .. ",...(+" .. (#list - 8) .. ")"
        end
        if #added   > 0 then log("  +[%s]", brief(added))   end
        if #removed > 0 then log("  -[%s]", brief(removed)) end
    end
end

-- =============================================================================
-- NATIVE INPUTHELPDISPLAY WIDTH SANITY CHECK
-- Runs once per session as soon as g_currentMission.hud.inputHelp is live.
-- Reads the canonical width field (helpAnchorOffsetX -- identified by the
-- v1.8.1.0 full-table probe; ih.x and ih.y match EHM's PANEL_X/PANEL_TOP_Y
-- exactly, and helpAnchorOffsetX is the right-edge offset from ih.x where
-- the native menu anchors its content) and writes one line to EHM_debug.log:
--
--   nativeWidth: ih.helpAnchorOffsetX = 0.177083 (NATIVE_PANEL_WIDTH = 0.177083)
--
-- If those two numbers ever diverge in the log, FS25 patched the native menu
-- width and NATIVE_PANEL_WIDTH needs updating to match.
-- =============================================================================
local function probeNativeInputHelpWidth()
    if EnhancedHelpMenu._nativeWidthProbeFired then return end
    -- Use direct global access, NOT rawget(_G, ...): FS25 routes globals
    -- through a metatable, so rawget on _G returns nil and the probe
    -- silently no-ops. Direct access mirrors the rest of the file
    -- (inputHelp.setVisible hook, drawVehicleSchema hook, etc.).
    local ih = g_currentMission ~= nil and g_currentMission.hud ~= nil
        and g_currentMission.hud.inputHelp or nil
    if ih == nil then return end  -- try again next tick

    EnhancedHelpMenu._nativeWidthProbeFired = true
    local observed = ih.helpAnchorOffsetX
    if type(observed) == "number" then
        log("nativeWidth: ih.helpAnchorOffsetX = %.6f (NATIVE_PANEL_WIDTH = %.6f)",
            observed, NATIVE_PANEL_WIDTH)
    else
        warn("nativeWidth: ih.helpAnchorOffsetX missing or non-numeric (type=%s) -- FS25 may have changed the InputHelpDisplay schema",
            type(observed))
    end
end

-- =============================================================================
-- IN-GAME SETTINGS MENU
-- Adds an "Enhanced Help Menu" group to the shared "Enhanced Settings" sub-
-- category tab on the pause-menu Settings page (InGameMenuSettingsFrame), per
-- the cross-mod convention in ../Toolkit/conventions.md. The injection
-- technique is adapted from FS25_EnhancedGameplay and the
-- FS25_additionalGameSettings reference mod.
--
-- FS25 soft-restarts between savegame loads, rebuilding the in-game menu and
-- its GUI classes, so the tab is re-injected on every loadMap.
--
-- This is the create-path implementation (Chunk 1): if no Enhanced mod has
-- created the shared tab yet, EHM creates it and registers its group. If the
-- tab already exists (another Enhanced mod created it first), this version
-- logs a deferred-injection notice and no-ops; the append-only branch will be
-- added in the next iteration so both load orders are handled.
-- =============================================================================

local EHM_GUI_XML       = "gui/EnhancedHelpMenuSettingsPage.xml"
local EHM_GUI_NAME      = "EnhancedHelpMenuSettingsPage"
local EHM_TAB_TITLE_KEY = "EnhancedSettings_tabTitle"   -- shared key (convention)
local EHM_TAB_ICON      = "gui.icon_options_device"

-- Sets the showBaseGameHelp setting, resets the F1 cycle for the new mode,
-- and persists. The setVisible override / draw-gate / addHelpExtension hook
-- all read self.settings.showBaseGameHelp on each call so no other wiring is
-- needed beyond resetting state; flipping the flag takes effect immediately.
--
-- State reset on flip:
--   OFF→ON  : state 0 (native visible, EHM hidden) — matches "Show base game F1".
--   ON →OFF : state 0 (EHM visible) — EHM is the primary again.
function EnhancedHelpMenu:setShowBaseGameHelp(enabled)
    if self.settings == nil then self.settings = {} end
    if self.settings.showBaseGameHelp == enabled then return end
    self.settings.showBaseGameHelp = enabled

    -- Both modes start at state 0 but state 0 means different things —
    -- OFF: EHM visible, ON: native visible. Re-derive isVisible accordingly.
    self.toggleState = 0
    self.isVisible   = (not enabled)
    if self.isVisible then
        self.silentRebuild = true
        self:rebuild()
    end

    -- Push the new native-F1 visibility immediately so the player sees the
    -- mode change without having to press F1 or change context. handlingToggle
    -- gates the setVisible override so it passes our call through unchanged
    -- (the hook would otherwise force `desiredF1` based on the freshly-set
    -- settings, which here equals `enabled` -- same result, but going through
    -- the gate keeps the intent explicit).
    pcall(function()
        if g_currentMission ~= nil and g_currentMission.hud ~= nil
           and type(g_currentMission.hud.setInputHelpVisible) == "function" then
            EnhancedHelpMenu.handlingToggle = true
            g_currentMission.hud:setInputHelpVisible(enabled)
            EnhancedHelpMenu.handlingToggle = false
        end
    end)

    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    log("settings menu: 'showBaseGameHelp' set %s", enabled and "enabled" or "disabled")
end

-- Persists panelWidthScale and invalidates the row-layout cache. The cache
-- is keyed by action name + contentW; contentW is derived from panel
-- width, so a scale change makes the cached layouts wrong (text wrap,
-- pill placement). The draw loop repopulates the cache lazily on the
-- next frame.
function EnhancedHelpMenu:setPanelWidthScale(scale)
    if self.settings == nil then self.settings = {} end
    local sanitized = sanitizePanelWidthScale(scale)
    if self.settings.panelWidthScale == sanitized then return end
    self.settings.panelWidthScale = sanitized
    self.rowLayoutCache = {}
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    log("settings menu: 'panelWidthScale' set to %d%% (width=%.4f)",
        sanitized, NATIVE_PANEL_WIDTH * sanitized / 100)
end

-- Persists rowsPerPage and clamps the current page so a smaller new size can't
-- leave the panel showing an empty page. No rebuild / cache invalidation
-- needed: rowLayoutCache is keyed by action name + contentW, both unchanged;
-- the draw loop re-derives totalPages from the live setting each frame and
-- already clamps self.page to that bound.
function EnhancedHelpMenu:setRowsPerPage(value)
    if self.settings == nil then self.settings = {} end
    local sanitized = sanitizeRowsPerPage(value)
    if self.settings.rowsPerPage == sanitized then return end
    self.settings.rowsPerPage = sanitized
    self.page = 1
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    log("settings menu: 'rowsPerPage' set to %d", sanitized)
end

-- --- Page controller -------------------------------------------------------
-- A FrameElement subclass bound to the GUI XML. After injection, GUI callbacks
-- are invoked with the host settings frame as `self` (a consequence of the
-- setTarget calls below), so click handlers fetch the real controller from
-- EnhancedHelpMenu._settingsFrame rather than trusting `self`.

EHMSettingsFrame = {}
local EHMSettingsFrame_mt = Class(EHMSettingsFrame, FrameElement)

function EHMSettingsFrame.new()
    return FrameElement.new(nil, EHMSettingsFrame_mt)
end

function EHMSettingsFrame.register()
    local frame = EHMSettingsFrame.new()
    EnhancedHelpMenu._settingsFrame = frame
    g_gui:loadGui(Utils.getFilename(EHM_GUI_XML, MOD_DIR), EHM_GUI_NAME, frame)
    return frame
end

-- Builds the option-element -> setting-name map and syncs initial state.
-- Runs during loadGui, before setTarget, so `self` is the real controller.
--
-- `checkboxes` covers BinaryOption rows (state == STATE_CHECKED is the truth).
-- `multiOptions` covers MultiTextOption rows whose state index maps into a
-- choice list (state 1..N -> choices[1..N]). Each has its own click handler so
-- the routing logic stays tiny.
function EHMSettingsFrame:onGuiSetupFinished()
    EHMSettingsFrame:superClass().onGuiSetupFinished(self)
    self.checkboxes = {
        [self.checkShowBaseGameHelp] = "showBaseGameHelp",
    }
    self.multiOptions = {
        [self.multiRowsPerPage] = {
            name    = "rowsPerPage",
            choices = EHM_ROWS_PER_PAGE_CHOICES,
        },
        [self.multiWidthScale] = {
            name    = "panelWidthScale",
            choices = EHM_WIDTH_SCALE_CHOICES,
        },
    }
    self:refresh()
    self:updateRowColors()
    -- Tooltips: each BinaryOption row has a child `<Text fs25_multiTextOptionTooltip>`
    -- declared in EHM's XML; the profile handles positioning + per-state
    -- visibility, and the parent's onHighlight cascade brings it into the
    -- highlighted state automatically. No Lua wiring needed. Pattern adapted
    -- from FS25_additionalGameSettings -- see Toolkit/community-mods.md.
    --
    -- Focus behaviour: leave focusOnHighlight=true (vanilla profile default)
    -- so focus follows hover and persists -- matches vanilla settings rows.
    -- Tooltip stays visible while row is focused; this is vanilla-intended
    -- behaviour. Clearing focus aggressively breaks keyboard tab->rows nav.
end


-- Syncs every option element to its setting's current value. Checkboxes use
-- the bool setting (absent/nil = unchecked). Multi-text options find the
-- current value in their choices list and set the matching 1-based state; if
-- the live value is missing from the list (shouldn't happen post-sanitize),
-- fall back to the default value's index.
function EHMSettingsFrame:refresh()
    local settings = EnhancedHelpMenu.settings or {}
    for element, name in pairs(self.checkboxes or {}) do
        if element ~= nil then
            element:setIsChecked(settings[name] == true, true)
        end
    end
    for element, info in pairs(self.multiOptions or {}) do
        if element ~= nil then
            local value = settings[info.name]
            local state = 1
            for i, choice in ipairs(info.choices) do
                if choice == value then state = i; break end
            end
            element:setState(state, false)
        end
    end
end

-- Applies the vanilla alternating row shading. Setting rows are otherwise
-- unstyled (the container Bitmap renders solid white); the game tints each row
-- at runtime from InGameMenuSettingsFrame.COLOR_ALTERNATING.
--
-- Section header elements (name == "sectionHeader") are skipped: they're Text
-- elements, not Bitmap rows, so setImageColor would error AND the alternation
-- pattern shouldn't count headers as rows (counting them would invert shading
-- below every header, which doesn't match vanilla either).
function EHMSettingsFrame:updateRowColors()
    local layout = self.ehmSettingsLayout
    local colors = InGameMenuSettingsFrame.COLOR_ALTERNATING
    if layout == nil or colors == nil then return end
    local alternate = true
    for _, row in ipairs(layout.elements) do
        if row.name ~= "sectionHeader" and type(row.setImageColor) == "function" then
            row:setImageColor(nil, unpack(colors[alternate]))
            alternate = not alternate
        end
    end
end

function EHMSettingsFrame.onClickCheckbox(_, state, element)
    local frame = EnhancedHelpMenu._settingsFrame
    local name = frame ~= nil and frame.checkboxes ~= nil and frame.checkboxes[element] or nil
    if name == "showBaseGameHelp" then
        EnhancedHelpMenu:setShowBaseGameHelp(state == CheckedOptionElement.STATE_CHECKED)
    end
end

-- MultiTextOption click: state is the 1-based index of the new selection in
-- the element's `texts` list. We map state -> value via the controller's
-- multiOptions[element].choices (kept in sync with the XML `texts` attribute
-- order) and dispatch to the setting-specific setter.
function EHMSettingsFrame.onClickRowsPerPage(_, state, element)
    local frame = EnhancedHelpMenu._settingsFrame
    local info  = frame ~= nil and frame.multiOptions ~= nil and frame.multiOptions[element] or nil
    if info == nil then return end
    local value = info.choices[state]
    if value ~= nil then
        EnhancedHelpMenu:setRowsPerPage(value)
    end
end

function EHMSettingsFrame.onClickWidthScale(_, state, element)
    local frame = EnhancedHelpMenu._settingsFrame
    local info  = frame ~= nil and frame.multiOptions ~= nil and frame.multiOptions[element] or nil
    if info == nil then return end
    local value = info.choices[state]
    if value ~= nil then
        EnhancedHelpMenu:setPanelWidthScale(value)
    end
end

function EHMSettingsFrame.onClickEhmSettingsTab()
    local subCategory = InGameMenuSettingsFrame.SUB_CATEGORY.ENHANCED_SETTINGS
    if subCategory ~= nil and g_inGameMenu ~= nil and g_inGameMenu.pageSettings ~= nil then
        g_inGameMenu.pageSettings.subCategoryPaging:setState(subCategory, true)
    end
end

-- --- Injection -------------------------------------------------------------

local function ehmCountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function ehmReparent(element, target, position)
    if element.parent ~= nil then
        element.parent:removeElement(element)
    end
    table.insert(target.elements, position, element)
    element.parent = target
end

-- Registers a BinaryOption row with the HOST's FocusManager scope so the
-- keyboard/gamepad focus scanner can navigate to it.
--
-- NON-RECURSIVE on purpose: the standard FocusManager:loadElementFromCustomValues
-- recursively walks element.elements and registers every descendant. For each
-- descendant the engine appears to allocate an overlay entity that's never
-- cleaned up, producing the Quit-to-Menu "Unknown entity id" cascade
-- (see Toolkit/gotchas.md). The keyboard scanner in
-- FocusManager:getNextFocusElement only iterates idToElementMapping looking
-- for the nearest focusable element, so a single registration per row is
-- enough.
--
-- Scope: the HOST's guiFocusData entry (settingsFrame.name, "ingameMenuSettings").
-- Idempotent: re-running on each loadMap is safe.
local function ehmRegisterRowForKeyboardNav(element, hostScope)
    if element == nil or hostScope == nil then return end
    if FocusManager == nil or FocusManager.guiFocusData == nil then return end
    local data = FocusManager.guiFocusData[hostScope]
    if data == nil or data.idToElementMapping == nil then return end

    if element.focusId ~= nil and data.idToElementMapping[element.focusId] == element then
        return -- already registered under this scope
    end

    element.focusId = element.focusId or FocusManager.serveAutoFocusId()
    element.focusChangeData = element.focusChangeData or {}
    data.idToElementMapping[element.focusId] = element

    if FocusManager.allElements ~= nil then
        if FocusManager.allElements[element] == nil then
            FocusManager.allElements[element] = {}
        end
        local already = false
        for _, scope in ipairs(FocusManager.allElements[element]) do
            if scope == hostScope then already = true; break end
        end
        if not already then
            table.insert(FocusManager.allElements[element], hostScope)
        end
    end
end

-- The mod's l10n keys live in its own (mod-scoped) i18n. The pause-menu
-- settings frame resolves header titles through the game-scoped g_i18n, so
-- the shared title key is bridged into that scope once here. Idempotent: safe
-- when multiple Enhanced mods bridge the same shared key.
local function ehmBridgeTextToGlobalScope(key)
    local meta = getmetatable(_G)
    local globalEnv = meta ~= nil and meta.__index or nil
    if globalEnv ~= nil and globalEnv.g_i18n ~= nil and globalEnv.g_i18n ~= g_i18n then
        globalEnv.g_i18n:setText(key, g_i18n:getText(key))
    end
end

-- After transplanting our elements into the host settings frame, the stale
-- per-mod focus scope that g_gui:loadGui created still holds references to
-- those same elements. FocusManager.guiFocusData ends up with both
-- "EnhancedHelpMenuSettingsPage" (stale, references same elements) AND
-- "InGameMenu" (the host, where we re-registered them) — leading to the
-- "tooltip from the other mod's row stays visible when hovering across mod
-- groups" leak we tracked through the inspect data (FocusManager.md +
-- MultiTextOptionElement.md's onFocusEnter/onFocusLeave pair).
--
-- Deleting the stale scope leaves only the host's, so focus transitions fire
-- onFocusLeave on the right scope. pcall-wrapped: deleteGuiFocusData was
-- introduced in newer FS25 builds; older ones don't have it.
local function ehmDeleteStaleFocusScope()
    pcall(function()
        if FocusManager == nil or FocusManager.guiFocusData == nil then return end
        if FocusManager.guiFocusData[EHM_GUI_NAME] ~= nil
           and type(FocusManager.deleteGuiFocusData) == "function" then
            FocusManager:deleteGuiFocusData(EHM_GUI_NAME)
        end
    end)
end

-- Append-only path: when another Enhanced mod has already created the shared
-- tab, this transplants EHM's group rows out of its own (orphan) layout into
-- the shared layout, then re-binds elements to the host frame so click /
-- focus handling still works.
local function ehmAppendGroupToSharedLayout(settingsFrame, ourLayout, sharedLayout)
    if sharedLayout == nil then
        warn("settings menu: ENHANCED_SETTINGS_LAYOUT missing on host frame; append failed")
        return false
    end

    -- Snapshot the rows first (mutating .elements mid-iteration is brittle).
    local rows = {}
    for _, row in ipairs(ourLayout.elements) do rows[#rows + 1] = row end
    for _, row in ipairs(rows) do
        ehmReparent(row, sharedLayout, #sharedLayout.elements + 1)
    end

    -- Force the shared ScrollingLayout to reflow now that new rows joined: our
    -- ehmReparent is a manual splice (table.insert + parent =) that bypasses
    -- the GuiElement:addElement path that would have invalidated the layout
    -- automatically. Without this, the new rows draw on top of the existing
    -- ones at the original Y positions. updateAbsolutePosition then propagates
    -- the new positions down through every descendant.
    pcall(function() sharedLayout:invalidateLayout(true) end)
    pcall(function() sharedLayout:updateAbsolutePosition() end)

    -- Re-bind all rows in the shared layout (theirs + ours) as named fields on
    -- the host frame. Walking the WHOLE shared layout is idempotent — already-
    -- bound elements get re-bound to the same name, no clash.
    local getDescendants = settingsFrame.getDescendants
    settingsFrame.getDescendants = function() return sharedLayout:getDescendants() end
    settingsFrame:exposeControlsAsFields(settingsFrame.name)
    settingsFrame.getDescendants = getDescendants

    -- Point EHM's controller at the shared layout for updateRowColors/refresh.
    local frame = EnhancedHelpMenu._settingsFrame
    if frame ~= nil then
        frame.ehmSettingsLayout = sharedLayout
        if frame.refresh ~= nil then frame:refresh() end
        if frame.updateRowColors ~= nil then frame:updateRowColors() end

        -- Retarget our BinaryOption rows to the HOST frame so setFocus's
        -- `targetElement.target.name == self.currentGui` check accepts them
        -- (FocusManager.lua:776). Without this, keyboard nav's scanner finds
        -- our rows in idToElementMapping but setFocus refuses to focus them.
        --
        -- The create-branch mod's rows get retargeted automatically by the
        -- host's setTarget cascade (Gui.lua:420) because their page was in
        -- pageSettings's tree when that cascade fired. Append-branch rows are
        -- added AFTER the cascade and don't get retargeted on their own.
        --
        -- Safe for click routing: GuiElement:addCallback captures the
        -- onClickCallback FUNCTION reference at load time (with
        -- self.target == EHMSettingsFrame at that moment), so click routing
        -- doesn't depend on the live target.
        if frame.checkboxes ~= nil then
            for element, _ in pairs(frame.checkboxes) do
                element.target = settingsFrame
            end
        end

        -- Register our rows for keyboard/gamepad navigation against the
        -- HOST's focus scope. Non-recursive (only the BinaryOption itself, not
        -- its descendants) to avoid the overlay leak documented in gotchas.md.
        if frame.checkboxes ~= nil then
            for element, _ in pairs(frame.checkboxes) do
                ehmRegisterRowForKeyboardNav(element, settingsFrame.name)
            end
        end

        -- EXPERIMENT (v1.6.0.0 attempt): also call the AGS-style RECURSIVE
        -- registration on each appended row so the engine wires up host-side
        -- focus delegation. Quit-to-Menu is the explicit regression watch
        -- (v1.3.0.0 / EHM v1.4.0.0 isolated the leak to this call). If the
        -- cascade returns, remove these lines and we're back to the safe
        -- non-recursive registration above.
        local prevGui = FocusManager.currentGui
        FocusManager:setGui(settingsFrame.name)
        if frame.checkboxes ~= nil then
            for element, _ in pairs(frame.checkboxes) do
                FocusManager:removeElement(element)
                FocusManager:loadElementFromCustomValues(element)
            end
        end
        FocusManager:setGui(prevGui)

        -- Wire EXPLICIT focus linkage (focusChangeData[direction] -> focusId,
        -- FocusManager.lua:584-587) between all rows in the shared layout so
        -- arrow-up/down navigates cleanly across the EGP<->EHM mod boundary.
        -- Without explicit links the proximity scanner kicks in and can pick
        -- non-row elements (it was scanning from the layout container itself,
        -- whose coords put EHM rows "above" not "below" the last EGP row).
        -- Runs in EHM's append helper -- by this point both mods' rows are
        -- in the shared layout in visual order.
        local rows = {}
        for _, child in ipairs(sharedLayout.elements) do
            if child.elements ~= nil then
                for _, grandchild in ipairs(child.elements) do
                    if grandchild.profile == "fs25_settingsBinaryOption" then
                        table.insert(rows, grandchild)
                        break
                    end
                end
            end
        end
        for i, row in ipairs(rows) do
            row.focusChangeData = row.focusChangeData or {}
            if rows[i + 1] ~= nil then
                row.focusChangeData[FocusManager.BOTTOM] = rows[i + 1].focusId
            end
            if rows[i - 1] ~= nil then
                row.focusChangeData[FocusManager.TOP] = rows[i - 1].focusId
            end
            -- Note: leave focusChangeOverride alone. Earlier we cleared it
            -- thinking it was redirecting scans incorrectly, but the
            -- redirection is part of how vanilla scrolling-settings nav
            -- delegates through the layout. Clearing it broke tab->rows.
        end

        -- Note: tab->rows keyboard navigation (arrow-down from the tab bar
        -- into our rows) is a known limitation. The `subCategoryPaging`
        -- element holds focus on the tab row and its focusChangeData[BOTTOM]
        -- link is set by host setup to the first vanilla sub-page's content,
        -- not dynamically updated per active tab. We tried hooking setState +
        -- onClickCallback to redirect the link to our rows; the setState
        -- wrapper's writes get reset by something inside vanilla setState,
        -- and adding an onClickCallback wrapper on top caused rapid
        -- tab-flickering (feedback loop with host's onClickSubCategory).
        -- Users mouse-click into a row once, then arrow-keys cycle between
        -- rows. See Toolkit/gotchas.md "Enhanced Settings keyboard nav".
    end

    log("settings menu: 'Enhanced Help Menu' group appended to existing 'Enhanced Settings' tab")
    return true
end

-- Injects EHM's group into the shared "Enhanced Settings" tab. Two branches:
--   create: tab does not yet exist (sentinel nil) — create it and register
--           EHM's group. Saves the layout reference for later mods to append.
--   append: tab exists (another Enhanced mod created it first) — transplant
--           EHM's group rows into the existing shared layout.
local function injectSettingsTab()
    -- Settings-tab injection. Per the binary-search probe in EGP, the recursive
    -- FocusManager.loadElementFromCustomValues call leaks engine overlay
    -- entities that explode on Quit-to-Menu. EHM follows the same fix --
    -- skip those calls in both the create branch (here) and the append
    -- helper. Trade-off: keyboard/gamepad navigation won't reach our settings
    -- rows; mouse still works. See ../../../Toolkit/gotchas.md.

    local settingsFrame = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    if settingsFrame == nil or InGameMenuSettingsFrame == nil then
        warn("settings menu: pageSettings unavailable, tab not injected")
        return
    end

    -- Load our XML ONCE per game session, then cache. Calling g_gui:loadGui on
    -- every loadMap leaks engine overlays: Gui:loadGui (Gui.lua:287) overwrites
    -- g_gui.guis[name] and never explicitly deletes the previous tree's
    -- overlays. Combined with the host pageSettings being re-instantiated on
    -- every loadMap (see ../../../Toolkit/gotchas.md "GUI injection (settings
    -- tab)" -> loadGui-overwrites-without-delete entry), the leak compounds
    -- into thousands of stale overlay refs in InputDisplayManager -- which
    -- spew "Unknown entity id" errors on Quit-to-Menu and can black-screen the
    -- game out to desktop. By caching, register() runs exactly once per
    -- session; on subsequent loadMaps we re-transplant the SAME elements into
    -- the freshly-instantiated host without creating new ones.
    if EnhancedHelpMenu._cachedFrame == nil then
        EnhancedHelpMenu._cachedFrame = EHMSettingsFrame.register()
    end
    local frame  = EnhancedHelpMenu._cachedFrame
    local page   = frame.ehmSettingsPage
    local tab    = frame.ehmSettingsTab
    local layout = frame.ehmSettingsLayout

    -- The class-level sentinel (SUB_CATEGORY.ENHANCED_SETTINGS), the layout ref,
    -- AND the HEADER_SLICES / HEADER_TITLES arrays all live on the
    -- InGameMenuSettingsFrame CLASS and persist across loadMaps. But the host
    -- pageSettings INSTANCE is re-instantiated each loadMap with fresh
    -- subCategoryBox / subCategoryPages / subCategoryTabs arrays (per
    -- gotchas.md). On a new host, the sentinel is stale AND any HEADER_TITLES /
    -- HEADER_SLICES entry we inserted last loadMap is also stale -- if we don't
    -- remove it, table.insert below APPENDS another copy. After N loadMaps the
    -- arrays carry N duplicate entries; the host then creates N overlay handles
    -- per tab on every frame, and at Quit-to-Menu InputDisplayManager:delete
    -- iterates thousands of stale refs ("Unknown entity id" errors -> desktop).
    -- This was the root cause behind the leak the settings work introduced.
    if not settingsFrame._enhancedSettingsTabInjected then
        InGameMenuSettingsFrame.SUB_CATEGORY.ENHANCED_SETTINGS = nil
        InGameMenuSettingsFrame.ENHANCED_SETTINGS_LAYOUT       = nil
        -- Strip ALL stale entries for the shared tab key from the class-level
        -- title/slice arrays. Walk from end so removals don't shift unchecked
        -- indices. Removes EHM's own previous entry, AND any leftover from
        -- another Enhanced mod (they all share the same EnhancedSettings_tabTitle
        -- key -- only one tab is ever in flight, the rest are leaks).
        local titles = InGameMenuSettingsFrame.HEADER_TITLES
        local slices = InGameMenuSettingsFrame.HEADER_SLICES
        if titles ~= nil and slices ~= nil then
            for i = #titles, 1, -1 do
                if titles[i] == EHM_TAB_TITLE_KEY then
                    table.remove(titles, i)
                    if slices[i] ~= nil then table.remove(slices, i) end
                end
            end
        end
    end
    if page == nil or tab == nil or layout == nil then
        warn("settings menu: GUI XML did not yield page/tab/layout elements")
        return
    end

    if InGameMenuSettingsFrame.SUB_CATEGORY.ENHANCED_SETTINGS ~= nil then
        -- Append-only branch: the shared tab already exists.
        ehmAppendGroupToSharedLayout(settingsFrame, layout,
            InGameMenuSettingsFrame.ENHANCED_SETTINGS_LAYOUT)
        return
    end

    -- Create branch: this mod is the first Enhanced mod to inject; build the
    -- shared tab around our page/container and seed the sentinel + layout ref
    -- so later mods can append.
    --
    -- Position 2 (second tab, right after Game Settings) is the desired
    -- visual location. Inserting there shifts native subCategoryTabs entries
    -- one slot to the right, so we must also bump every native SUB_CATEGORY
    -- value >= 2 by +1 to keep native onClick handlers correct -- they call
    -- setState(SUB_CATEGORY.GENERAL_SETTINGS) etc. using the hard-coded
    -- class-level constants, so the constants need to track the new layout.
    --
    -- Bump runs ONCE per session via the class-level _enhancedSettingsBumped
    -- marker; subsequent loadMaps re-insert at position 2 against the freshly-
    -- re-instantiated host but the already-bumped SUB_CATEGORY values stay
    -- correct. The marker is on the CLASS (not an instance) because the host
    -- pageSettings instance disappears each loadMap but SUB_CATEGORY does not.
    local position = 2
    if not InGameMenuSettingsFrame._enhancedSettingsBumped then
        for key, val in pairs(InGameMenuSettingsFrame.SUB_CATEGORY) do
            if type(val) == "number" and val >= position
               and key ~= "ENHANCED_SETTINGS" then
                InGameMenuSettingsFrame.SUB_CATEGORY[key] = val + 1
            end
        end
        InGameMenuSettingsFrame._enhancedSettingsBumped = true
        log("settings menu: bumped native SUB_CATEGORY values >= %d by +1", position)
    end

    ehmReparent(page, settingsFrame.subCategoryPages[1].parent, position)
    ehmReparent(tab,  settingsFrame.subCategoryBox, position)
    table.insert(settingsFrame.subCategoryPages, position, page)
    table.insert(settingsFrame.subCategoryTabs,  position, tab)

    InGameMenuSettingsFrame.SUB_CATEGORY.ENHANCED_SETTINGS  = position
    InGameMenuSettingsFrame.ENHANCED_SETTINGS_LAYOUT        = layout
    table.insert(InGameMenuSettingsFrame.HEADER_SLICES, position, EHM_TAB_ICON)
    ehmBridgeTextToGlobalScope(EHM_TAB_TITLE_KEY)
    table.insert(InGameMenuSettingsFrame.HEADER_TITLES, position, EHM_TAB_TITLE_KEY)

    -- Reflow the subCategoryBox now that we've inserted our tab.
    --
    -- Root cause confirmed via vliDeepInspect g_inGameMenu.pageSettings.subCategoryBox:
    -- subCategoryBox.elements had 7 entries but cells[1] had only 6. The
    -- BoxLayout's updateLayoutCells calls getIsElementIncluded() per element,
    -- which (with useFullVisibility=true on subCategoryBox) requires the tab
    -- to pass getIsVisibleNonRec() == (visible AND alpha > 0). When g_gui:loadGui
    -- loaded our XML, the menuContainer parent loaded hidden, and that propagated
    -- to set our tab Button's visible=false. So the box laid out 6 native tabs
    -- across the full width and our 7th tab stayed in elements[] (rendered, with
    -- its own hitbox at whatever stale position) but with no slot in cells[] --
    -- so GENERAL SETTINGS was positioned where our tab visually appeared, and
    -- clicks on GENERAL SETTINGS hit our tab's stale-position hitbox instead.
    --
    -- Force the tab visible BEFORE reflow so it's included in cells[], then
    -- rebuild cells + apply positions explicitly. updateSize also pins the
    -- Button's width to its text width before cells math runs.
    pcall(function()
        -- Replicate everything BoxLayoutElement.addElement would have set up,
        -- since our ehmReparent uses a manual table.insert that bypasses it.
        -- Without these, the tab's stale anchor/pivot/visible state from its
        -- original menuContainer parent makes getIsElementIncluded return
        -- false (or the layout positions it wrong), and clicks on the next
        -- tab to our right (GENERAL SETTINGS) land on ours instead.
        -- Confirmed via vliDeepInspect: cells[1] had only 6 entries while
        -- elements[] had 7 -- our tab was being excluded.
        tab.layoutIgnore = false
        tab.visible      = true
        tab.alpha        = 1
        if type(tab.setAnchor)  == "function" then tab:setAnchor(0, 0)  end
        if type(tab.setPivot)   == "function" then tab:setPivot(0, 0)   end
        if type(tab.updateSize) == "function" then tab:updateSize()     end
        local box = settingsFrame.subCategoryBox
        if box ~= nil then
            if type(box.updateLayoutCells)  == "function" then box:updateLayoutCells(true) end
            if type(box.applyCellPositions) == "function" then box:applyCellPositions(0, 0) end
        end
    end)

    settingsFrame:updateAbsolutePosition()

    -- Bind our page's id'd elements as named fields on the host frame so the
    -- checkbox handler can resolve EnhancedHelpMenu._settingsFrame.checkboxes.
    local getDescendants = settingsFrame.getDescendants
    settingsFrame.getDescendants = function() return page:getDescendants() end
    settingsFrame:exposeControlsAsFields(settingsFrame.name)
    settingsFrame.getDescendants = getDescendants

    page:setTarget(settingsFrame, page.target)
    tab:setTarget(settingsFrame, tab.target)

    -- setGui + removeElement cleanup -- confirmed clean by the leak probe
    -- (level 4a). Restores focus-context hygiene without the recursive
    -- loadElementFromCustomValues that would normally follow (that call leaked
    -- engine entities). Trade-off: keyboard/gamepad navigation can't enter
    -- our settings rows; mouse interaction still works.
    local currentGui = FocusManager.currentGui
    FocusManager:setGui(settingsFrame.name)
    FocusManager:removeElement(page)
    FocusManager:removeElement(tab)
    FocusManager:setGui(currentGui)

    -- NOTE: ehmDeleteStaleFocusScope() was here. Removed because the probe
    -- isolated the leak to one (or both) of loadElementFromCustomValues and
    -- deleteStaleScope; removing the first alone wasn't enough. See gotchas.md.

    -- Register our rows for keyboard/gamepad navigation against the HOST's
    -- focus scope. Non-recursive (only each BinaryOption itself, not its
    -- descendants) to avoid the overlay leak documented in gotchas.md.
    if frame.checkboxes ~= nil then
        for element, _ in pairs(frame.checkboxes) do
            ehmRegisterRowForKeyboardNav(element, settingsFrame.name)
        end
    end

    -- Mark THIS host instance as having had the Enhanced tab injected, so
    -- later Enhanced mods in the same loadMap see the sentinel as authoritative
    -- (they enter the append branch). Cleared automatically next loadMap when
    -- the host is re-instantiated; the cached-frame guard above then resets the
    -- class-level sentinel and runs create against the fresh host.
    settingsFrame._enhancedSettingsTabInjected = true

    log("settings menu: 'Enhanced Settings' tab created with 'Enhanced Help Menu' group at position %d", position)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:loadMap()
    EHM_LOG.init()

    print("EnhancedHelpMenu: loaded" ..
        (DEBUG and " [DEBUG=true — rebuild detail in EHM_debug.log]" or " [EHM_debug.log active]"))

    -- Display state
    self.isVisible    = false
    self.actions      = {}
    self.refreshTimer = 0
    self.page         = 1

    -- Device filter state
    self.deviceModeIndex   = 1
    self.selectedDeviceKey = "NONE"
    self.deviceModes       = {}

    -- Category filter state
    self.filterEnabled  = {}
    -- Hidden actions: set keyed by action name → true. Persisted in EHM_settings.xml.
    -- The user hides individual rows from the panel via filter mode (Stage 2);
    -- rebuild() skips any action whose name is in this set.
    self.hiddenActions = {}
    -- Hidden extra-text rows: array of {exact = "...", stem = "..."} entries.
    -- Same UX as hiddenActions (filter-mode eye-icon toggle), but matched via
    -- a two-stage rule (exact text first, normalized stem fallback) because
    -- extra-text content can carry live values that change frame-to-frame.
    -- See isExtraTextHidden().
    self.hiddenExtraTexts = {}
    -- Behaviour settings (the in-game Enhanced Settings tab). Defaults applied
    -- here; EHM_SETTINGS.load overwrites from the file if present. Adding new
    -- entries here keeps them forward-compatible (older settings files just
    -- keep the default).
    self.settings = {
        showBaseGameHelp = false,
        rowsPerPage      = PAGE_SIZE_DEFAULT,
        panelWidthScale  = EHM_WIDTH_SCALE_DEFAULT,
    }
    local ok, savedToggleState, settingsExisted = pcall(function()
        return EHM_SETTINGS.load(self.filterEnabled, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    end)
    if not ok then
        for i = 1, #EHM_CATEGORIES do self.filterEnabled[i] = true end
        self.hiddenActions = {}
        self.hiddenExtraTexts = {}
        self.settings = {
            showBaseGameHelp = false,
            rowsPerPage      = PAGE_SIZE_DEFAULT,
            panelWidthScale  = EHM_WIDTH_SCALE_DEFAULT,
        }
        savedToggleState = nil
        settingsExisted  = false
    end

    -- Safety net: if all categories are disabled (e.g. session ended with DESELECT ALL),
    -- reset to all enabled so the player doesn't spawn into a confusing empty state.
    local anyEnabled = false
    for i = 1, #EHM_CATEGORIES do
        if self.filterEnabled[i] ~= false then anyEnabled = true; break end
    end
    if not anyEnabled then
        for i = 1, #EHM_CATEGORIES do self.filterEnabled[i] = true end
        warn("WARNING: all categories were disabled in saved settings — reset to all enabled")
    end

    -- Count hidden actions for the startup log. The set is small — it only grows
    -- when the user explicitly hides a row, and shrinks when they un-hide — so
    -- no prune is needed. Entries simply persist until the user un-hides them.
    local hiddenCount = 0
    for _ in pairs(self.hiddenActions) do hiddenCount = hiddenCount + 1 end
    log("Hidden actions: %d loaded", hiddenCount)

    -- savedToggleState : 0/1/2 if explicitly saved, nil otherwise.
    -- settingsExisted  : true if a settings file was found on disk.
    --
    -- Post-init logic (see update()):
    --   savedToggleState set  → restore it exactly.
    --   savedToggleState nil, settingsExisted true  → returning player, old file
    --     format (no <ui> tag yet); default to EHM (0).
    --   savedToggleState nil, settingsExisted false → truly first-ever run;
    --     follow the game's own F1 state (new game shows F1 tutorial).
    self.savedToggleState  = savedToggleState
    self.settingsExisted   = settingsExisted
    self.uiMode           = false  -- true when filter UI is active
    self.uiModeMouseX     = 0
    self.uiModeMouseY     = 0
    self.uiModeClicked    = false  -- set true on left-click, consumed in draw()
    self.hoveredToggle    = nil    -- index of hovered category toggle
    self.hoveredAllToggle = false
    self.allBtnRect       = nil    -- hit rect for SELECT/DESELECT ALL button
    -- Per-action animation state. Keyed by actionName.
    -- Each entry: {shiftOffset, fadeAlpha, accentAlpha, accentPhase, accentTimer}
    -- shiftOffset: Y offset animating to 0 (ease-out) as row settles into position.
    -- fadeAlpha:   0→1 fade for newly inserted rows.
    -- accentPhase: "delay"|"fadein"|"hold"|"fadeout"|"done" — left accent bar lifecycle.
    self.animState    = {}
    self.prevPositions = {}  -- actionName → sorted index from previous rebuild
    self.departedAnimState = {}  -- animState saved when action leaves list (grace period)
    self.rowLayoutCache = {}  -- row layout descriptors, keyed by action name, cleared each rebuild
    self.cachedTotalPages = 1 -- slot-based total pages, updated each draw(), read by onPageNext
    self.currentContextName = nil
    self.inMenuContext       = false  -- true while inside any MENU/DIALOG context
    self.menuSavedPrevActive = nil   -- prevActive saved on menu entry, restored on exit
    self.menuSavedFromCtx    = nil   -- context we were in before entering menu
    self.spawnInitDone       = false  -- prevents f1InitFrames re-triggering on vehicle entry
    -- silentRebuild: suppresses new-action detection AND animations for one
    -- rebuild. Set on every real context switch and on filter changes so the
    -- list appears in final form without any animations. Always cleared at
    -- the end of rebuild() automatically.
    self.silentRebuild      = false
    -- warmupTimer (ms): grace period after spawn or context switch during
    -- which late-arriving actions are suppressed. Three values used:
    --   2000ms — initial spawn (fromCtx=nil): covers late-loading mods.
    --   ~600ms — vehicle entry: catches RADIO_TOGGLE which activates ~500ms after entry.
    --   0ms    — vehicle exit: ENTER appearing ~500ms later is meaningful and should highlight.
    -- See handlePrevActiveOnSwitch real-switch branch.
    self.warmupTimer        = 0
    self.extraPrintTexts    = {}   -- texts captured from addExtraPrintText() each frame

    -- Vehicle selectable group (G-key) tracking.
    -- currentSelectableIdx: the isSelected index last seen in the selectable chain.
    -- gPressSelectableChange: set true when a G press is detected; consumed in rebuild()
    -- to skip the departedAnimState grace period so returning actions get highlighted.
    self.currentSelectableIdx   = 0
    self.gPressSelectableChange = false

    -- DOF blur animation state for filter mode
    self.dofBlendAlpha = 0      -- 0=no blur, 1=full blur
    self.dofFading     = "none" -- "in", "out", "none"

    -- Extra text bar animation — same phase machine as action accent bars.
    -- Triggered only when extra text appears from nothing (prevExtraCount 0 → >0).
    self.extraTextAccentPhase  = "done"
    self.extraTextAccentTimer  = 0
    self.extraTextAccentAlpha  = 0
    self.prevExtraCount        = 0   -- count of extra texts in previous visible draw()
    self.prevExtraTexts        = {}  -- set of text strings shown in previous draw() frame
    self.extraTextBaseSet      = {}  -- texts that existed BEFORE the last trigger; used
                                     -- to identify which rows are "new" during animation

    -- Extra-text block height animation. xtBlockH is the eased height; xtTargetH is
    -- the geometric target (computed each draw from numExtra). xtDisplayAlpha eases
    -- the text + separator opacity in lockstep with the height. xtLastTexts preserves
    -- the most recent rendered list so the retraction phase still has content to draw
    -- after the game stops calling addExtraPrintText.
    self.xtBlockH       = 0
    self.xtTargetH      = 0
    self.xtDisplayAlpha = 0
    self.xtLastTexts    = {}

    -- Engine hooks: install ONCE per session, not per loadMap. The class-level
    -- guard EnhancedHelpMenu._hooksInstalled survives across loadMaps so a
    -- "load save -> quit to menu -> load save" cycle doesn't restack our
    -- Utils.appendedFunction / overwrittenFunction wrappers. Without this
    -- guard, after N loadMaps every native call invokes N stacked wrappers,
    -- our registerGlobalPlayerActionEvents adds 4*N action events on every
    -- context switch, and InputDisplayManager.onActionEventsChanged rebuilds
    -- its overlay list N times more often -- accumulating thousands of stale
    -- overlay refs that explode into "Unknown entity id" errors on
    -- Quit-to-Menu.
    if not EnhancedHelpMenu._hooksInstalled then
    -- Hook addExtraPrintText on the current mission so we capture any text that mods
    -- push to the game's built-in help overlay. The hook appends to extraPrintTexts;
    -- draw() reads and clears that table each frame.
    -- Using Utils.appendedFunction keeps the original call intact.
    if g_currentMission ~= nil and g_currentMission.addExtraPrintText ~= nil then
        g_currentMission.addExtraPrintText = Utils.appendedFunction(
            g_currentMission.addExtraPrintText,
            function(_, text)
                if type(text) == "string" and text ~= ""
                   and EnhancedHelpMenu.isVisible then
                    table.insert(EnhancedHelpMenu.extraPrintTexts, text)
                end
            end
        )
        dbg("addExtraPrintText hook installed")
    else
        warn("WARNING: could not hook addExtraPrintText (mission or method not found)")
    end

    -- Toggle state is determined after the player spawns (see f1InitFrames in update()).
    -- We hide EHM during that brief init window; correct state is set once settled.
    self.toggleState     = 0
    self.isVisible       = false  -- hidden until post-spawn init completes
    self.handlingToggle  = false
    self.ignoreF1Changes = true   -- suppress hook until post-spawn init is done
    self.f1InitFrames    = nil    -- set in onRegisterGlobalActionEvents
    self.lastKnownCtx    = nil    -- tracks context for immediate rebuild on change
    self.postInitCooldown = 0     -- ms; gates raw-key F1 polling for 1 s after
                                  -- post-init so the game can finish its own
                                  -- spawn setup without competing with player F1

    -- Hook setInputHelpVisible on the HUD (catches game initialization calls)
    -- AND setVisible on inputHelp directly (catches user-triggered F1 presses).
    -- Both paths call onF1Changed; ignoreF1Changes + handlingToggle guards prevent
    -- false triggers during init or from our own override calls.
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        -- setInputHelpVisible hook: intentionally empty body. FS25 fires
        -- this for many reasons that aren't player F1 presses (post-init,
        -- screen transitions, construction menu open/close, etc.);
        -- treating any of them as F1 presses was the root cause of the
        -- cycle-drift bug chased through v1.11.0.x. Player F1 detection
        -- since v1.11.1.x lives in pollF1Action() via raw-key polling on
        -- TOGGLE_HELP_TEXT -- that fires only on actual key presses, not
        -- on internal setInputHelpVisible calls.
        --
        -- (v1.11.2.0 briefly tried using a TOGGLE_HELP_TEXT action-event
        -- registration as the "proper" API path, but FS25's dispatcher
        -- doesn't broadcast vanilla-owned actions to additional
        -- registrants -- even with triggerAlways=true the callback
        -- didn't fire. Reverted to raw-poll in v1.11.2.1.)
        --
        -- The appendedFunction hook is kept (rather than removing it
        -- entirely) so the file's flow keeps documenting the integration
        -- point -- and in case a future FS25 version needs any side
        -- effect here it's already plumbed.
        g_currentMission.hud.setInputHelpVisible = Utils.appendedFunction(
            g_currentMission.hud.setInputHelpVisible,
            function(_, f1Visible)
                -- no-op; see comment above
            end
        )
        dbg("setInputHelpVisible hook installed")
        local hi = g_currentMission.hud.inputHelp
        if hi ~= nil then
            -- Full override (not appendedFunction) so we can pass the DESIRED
            -- visibility to the original before it renders — prevents any flicker.
            local origSetVisible = hi.setVisible
            hi.setVisible = function(hiSelf, visible)
                if EnhancedHelpMenu.handlingToggle
                   or EnhancedHelpMenu.ignoreF1Changes
                   or EnhancedHelpMenu.postInitCooldown > 0 then
                    return origSetVisible(hiSelf, visible)
                end
                -- Decoupled from cycle advancement (v1.11.1.0). The hook
                -- no longer calls onF1Changed at all; it just enforces
                -- the visibility EHM's current state wants, regardless
                -- of what the caller requested. That stops every
                -- spurious setVisible call from advancing the F1 cycle.
                --
                --   Setting OFF: native always hidden (EHM is the display).
                --   Setting ON : native visible iff toggleState == 0
                --                (state 1 = EHM visible, state 2 = both off).
                local showBaseGameHelp = EnhancedHelpMenu.settings ~= nil
                    and EnhancedHelpMenu.settings.showBaseGameHelp == true
                local desiredF1
                if not showBaseGameHelp then
                    desiredF1 = false
                else
                    desiredF1 = (EnhancedHelpMenu.toggleState == 0)
                end
                return origSetVisible(hiSelf, desiredF1)
            end
            log("inputHelp.setVisible override installed")
        else
            warn("WARNING: hud.inputHelp is nil — inputHelp hook not installed")
        end
    else
        warn("WARNING: could not hook setInputHelpVisible")
    end

    -- Hook addHelpExtension — EHM intercepts native HUD help extensions
    -- (Precision Farming's combine/seeder/sprayer widgets, etc.) so it can
    -- re-host them inside its own panel below the vehicle schema.
    --
    -- When the "Show base game F1 menu" setting is ON, EHM is sitting out:
    -- it must forward the call to the original native handler so the
    -- extensions register with the real InputHelpDisplay and draw on the
    -- vanilla F1 menu. The setting is read on every call, so toggling at
    -- runtime takes effect the next frame (vehicle specs re-register their
    -- extensions every frame in onDraw).
    if g_currentMission ~= nil and g_currentMission.hud ~= nil
       and type(g_currentMission.hud.addHelpExtension) == "function" then
        local nativeAddHelpExtension = g_currentMission.hud.addHelpExtension
        EnhancedHelpMenu.nativeAddHelpExtension = nativeAddHelpExtension
        g_currentMission.hud.addHelpExtension = function(hud, extension)
            -- Forward to native only when native is the currently-displayed
            -- help menu (setting ON and cycle at state 0). In every other
            -- mode/state EHM is either the active display (state 1 with
            -- setting ON, or state 0 with setting OFF) or everything is
            -- hidden; either way, capture for potential re-host so EHM has
            -- the extensions on hand the moment the cycle returns to it.
            local nativeIsTheDisplay = EnhancedHelpMenu.settings ~= nil
                and EnhancedHelpMenu.settings.showBaseGameHelp == true
                and EnhancedHelpMenu.toggleState == 0
            if nativeIsTheDisplay then
                return nativeAddHelpExtension(hud, extension)
            end
            EnhancedHelpMenu:captureHelpExtension(extension)
        end
        log("addHelpExtension hook installed")
    else
        warn("WARNING: hud.addHelpExtension missing — extension hook not installed")
    end

    -- Hook InputHelpDisplay.drawVehicleSchema — it returns the Y where the
    -- native vehicle schema ends. The game draws that schema unconditionally
    -- above EHM's panel; capturing its true bottom lets EHM anchor itself
    -- dynamically below it, however tall it is (Precision Farming adds a
    -- CONTROL GROUP title that makes it taller than any fixed reservation).
    if InputHelpDisplay ~= nil and type(InputHelpDisplay.drawVehicleSchema) == "function" then
        InputHelpDisplay.drawVehicleSchema = Utils.overwrittenFunction(
            InputHelpDisplay.drawVehicleSchema,
            function(ihSelf, superFunc, posX, posY, ...)
                local retPosY, retCtrlPosY = superFunc(ihSelf, posX, posY, ...)
                if type(posY) == "number" and type(retPosY) == "number" then
                    EnhancedHelpMenu.nativeSchemaHeight = math.max(0, posY - retPosY)
                end
                return retPosY, retCtrlPosY
            end)
        log("drawVehicleSchema hook installed")
    else
        warn("WARNING: InputHelpDisplay.drawVehicleSchema missing — schema hook not installed")
    end

    -- Hook into FS25's player input registration cycle.
    -- registerGlobalPlayerActionEvents is called on every context switch
    -- (player spawns, enters/exits vehicle, etc.) — the correct place to
    -- register our own action events.
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        EnhancedHelpMenu.onRegisterGlobalActionEvents)

    PlayerInputComponent.unregisterActionEvents = Utils.appendedFunction(
        PlayerInputComponent.unregisterActionEvents,
        EnhancedHelpMenu.onUnregisterActionEvents)

        EnhancedHelpMenu._hooksInstalled = true
        log("engine hooks installed (session-level)")
    end

    -- Overlay creation is deferred to first draw() call to ensure the
    -- rendering pipeline is fully initialised before createImageOverlay runs.
    self.overlaysReady  = false
    self.overlaysDone   = false  -- set true once we've attempted creation

    -- Inject EHM's group into the shared "Enhanced Settings" tab on the
    -- pause-menu Settings page. Re-injected on every loadMap because FS25
    -- soft-restarts between savegame loads and rebuilds the in-game menu.
    -- pcall-isolated: a settings-menu failure must never block the rest of
    -- the mod from loading.
    local injectOk, injectErr = pcall(injectSettingsTab)
    if not injectOk then
        warn("settings menu inject threw: %s", tostring(injectErr))
    end

    log("loadMap complete")
end

function EnhancedHelpMenu:deleteMap()
    -- (Overlay-leak diagnostic that lived here is gone now that the root
    -- cause is fixed; ehmOverlayLeaks console command still exists for
    -- on-demand inspection if needed.)

    -- Exit UI mode cleanly if active when map unloads
    if self.uiMode then
        pcall(function() g_inputBinding:setShowMouseCursor(false) end)
        self.uiMode = false
    end
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    -- Delete sprite overlays
    if self.overlaysReady and deleteImageOverlay ~= nil then
        for _, ov in ipairs({self.ovRowL, self.ovRowC, self.ovRowR,
                             self.ovKeyL, self.ovKeyC, self.ovKeyR,
                             self.ovHdrTL, self.ovHdrTC, self.ovHdrTR,
                             self.ovHdrML, self.ovHdrMR,
                             self.ovHdrBL, self.ovHdrBC, self.ovHdrBR,
                             self.ovEyeOpen, self.ovEyeHidden}) do
            if ov ~= nil then pcall(function() deleteImageOverlay(ov) end) end
        end
        self.overlaysReady = false
        self.overlaysDone  = false
    end
    log("deleteMap called")
    EHM_LOG.close()
    self.actions     = nil
    self.deviceModes = nil
    print("EnhancedHelpMenu: deleted")
end

-- ---------------------------------------------------------------------------
-- Input Action Registration
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu.onRegisterGlobalActionEvents(playerInputComponent, contextName)
    if playerInputComponent.player == nil or not playerInputComponent.player.isOwner then return end
    dbg("onRegisterGlobalActionEvents: contextName=%s", tostring(contextName))

    local self = EnhancedHelpMenu

    -- Player has spawned — start a short countdown before reading F1 state,
    -- but only on the very first call (spawn). Subsequent vehicle entries
    -- also fire this event but should not re-trigger the init window.
    if self.f1InitFrames == nil and not self.spawnInitDone then
        self.f1InitFrames = 5
    end

    local newCtx = contextName or "PLAYER"
    if self.currentContextName ~= newCtx then
        log("Context changed: %s → %s", tostring(self.currentContextName), newCtx)
        local fromCtx = self.currentContextName
        self.currentContextName = newCtx
        self:handlePrevActiveOnSwitch(fromCtx, newCtx)
        -- (No F1-suppression window needed since v1.11.1.0: hooks no
        -- longer advance the cycle; cycle advances only on raw F1
        -- keypress detected by pollF1Action.)
    end

    -- Wrap in context modification so keys work in the correct input context
    local currentContextName = g_inputBinding:getContextName()
    local newContextName     = contextName or currentContextName
    if currentContextName ~= newContextName then
        g_inputBinding:beginActionEventsModification(newContextName)
    end

    -- EHM_PAGE_PREV / EHM_PAGE_NEXT are registered for Controls-menu
    -- visibility only -- their callbacks are no-ops because the page logic
    -- runs from a raw-key poll in update() (see pollPageActions). Keeping
    -- the registration means the action shows up in the rebinding UI and
    -- the user can still rebind it; the binding is the source of truth our
    -- poll reads.
    local function reg(actionName, callback)
        local action = InputAction[actionName]
        if action == nil then
            warn("WARNING: InputAction.%s not found — mod may need a hash (run as ZIP)", actionName)
            return
        end
        local valid, eventId = g_inputBinding:registerActionEvent(
            action, self, self[callback], false, true, false, true)
        if valid and eventId then
            -- Hide from F1 hint overlay (still shows in Controls remapping screen)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
        end
    end

    reg("EHM_UI_MODE",      "onUIMode")
    reg("EHM_CYCLE_DEVICE", "onCycleDevice")
    reg("EHM_PAGE_PREV",    "onPagePrev")
    reg("EHM_PAGE_NEXT",    "onPageNext")
    -- TOGGLE_HELP_TEXT is NOT registered here. The proper action-event path
    -- doesn't work for it: vanilla HUD owns the listener and FS25's
    -- dispatcher doesn't broadcast to additional registrants (confirmed
    -- in v1.11.2.0 testing -- registration with triggerAlways=true didn't
    -- fire the callback either). F1 detection lives in pollF1Action()
    -- instead. Limitation: single-key keyboard binding only. Combo /
    -- gamepad rebinds won't fire the cycle.

    if currentContextName ~= newContextName then
        g_inputBinding:beginActionEventsModification(currentContextName)
    end
end

function EnhancedHelpMenu.onUnregisterActionEvents(playerInputComponent)
    if playerInputComponent.player == nil or not playerInputComponent.player.isOwner then return end
    g_inputBinding:removeActionEventsByTarget(EnhancedHelpMenu)
end

-- F1 cycle handler. Invoked by pollF1Action() once per rising-edge
-- detection of the bound TOGGLE_HELP_TEXT key. Only fires on actual
-- player F1 presses -- internal setInputHelpVisible / setVisible calls
-- from FS25 screens (construction etc.) don't touch the raw key state,
-- so they can't reach this function. That's how we avoid the
-- cycle-drift bug chased through v1.11.0.x.
function EnhancedHelpMenu:onF1Changed()
    if not self.spawnInitDone or self.postInitCooldown > 0 then return end

    local stateBefore = self.toggleState
    -- The cycle depends on "Show base game F1 menu" (Enhanced Settings tab):
    --
    --   Setting OFF (default) - 2-state cycle, EHM is the only display:
    --     0 → EHM visible
    --     1 → EHM hidden
    --     Native F1 is force-hidden by the setVisible override at every state.
    --
    --   Setting ON - 3-state cycle, native is primary but EHM is reachable:
    --     0 → native visible, EHM hidden
    --     1 → native hidden,  EHM visible
    --     2 → both hidden
    --     (Per user request: "if they don't want EHM they can just uninstall
    --     mod" - the toggle should never lock out EHM completely.)
    --
    -- Explicit if/else instead of modulo so a stale toggleState (e.g. legacy
    -- 2 from the old 3-state cycle saved with setting OFF) always advances
    -- to a visible state on the next press, never burns a press as a no-op.
    local showBaseGameHelp = self.settings ~= nil
        and self.settings.showBaseGameHelp == true

    if showBaseGameHelp then
        if self.toggleState == 0 then
            self.toggleState = 1
        elseif self.toggleState == 1 then
            self.toggleState = 2
        else
            self.toggleState = 0
        end
    else
        if self.toggleState == 0 then
            self.toggleState = 1
        else
            -- Any non-zero (1 or legacy 2) → back to EHM visible.
            self.toggleState = 0
        end
    end

    -- Map state → EHM visibility.
    local eihOn
    if showBaseGameHelp then
        eihOn = (self.toggleState == 1)
    else
        eihOn = (self.toggleState == 0)
    end
    self.isVisible = eihOn
    if eihOn then
        -- Establish a silent baseline so actions visible when EHM turns on
        -- don't falsely flash green. They were already there — the player
        -- just had EHM hidden. rebuild() clears silentRebuild when done.
        self.silentRebuild = true
        self:rebuild()
    end

    -- Push the new NATIVE visibility into FS25's HUD immediately so the
    -- cycle's "native visible" states actually show native on screen.
    -- Without this push, native visibility only updates when something
    -- else calls setInputHelpVisible -- the setVisible hook forces our
    -- desired value, but that's reactive. Vanilla's own F1 handler will
    -- fire too on the same event, but its desired value may not match
    -- ours; the explicit push ensures the value we want wins.
    --
    -- handlingToggle gates the setVisible override so it passes our
    -- chosen value through to origSetVisible unchanged. pcall isolates
    -- I/O failures.
    local wantNativeVisible
    if showBaseGameHelp then
        wantNativeVisible = (self.toggleState == 0)
    else
        wantNativeVisible = false
    end
    pcall(function()
        if g_currentMission ~= nil and g_currentMission.hud ~= nil
           and type(g_currentMission.hud.setInputHelpVisible) == "function" then
            EnhancedHelpMenu.handlingToggle = true
            g_currentMission.hud:setInputHelpVisible(wantNativeVisible)
            EnhancedHelpMenu.handlingToggle = false
        end
    end)

    log("F1 cycle: state %d -> %d, EHM=%s, native=%s",
        stateBefore or -1, self.toggleState, tostring(eihOn), tostring(wantNativeVisible))
    -- State is persisted in deleteMap and onUIModeExit only. io.open("w") from
    -- event callbacks silently fails in FS25 (creates a 0-byte file and drops
    -- the write), so we do not save here. deleteMap fires on every clean exit
    -- and before any reload via the main menu.
end

-- Camera look axes disabled while in UI mode using the proper FS25 setContextEventsActive API.
local EHM_LOOK_ACTIONS = {
    { context = "PLAYER",  action = "AXIS_LOOK_LEFTRIGHT_PLAYER" },
    { context = "PLAYER",  action = "AXIS_LOOK_UPDOWN_PLAYER" },
    { context = "VEHICLE", action = "AXIS_LOOK_LEFTRIGHT_VEHICLE" },
    { context = "VEHICLE", action = "AXIS_LOOK_UPDOWN_VEHICLE" },
}

function EnhancedHelpMenu:onUIMode()
    if not self.isVisible then return end
    dbg("Filter mode: %s", self.uiMode and "closing" or "opening")
    if self.uiMode then
        self:onUIModeExit()
    else
        self:onUIModeEnter()
    end
end

-- Applies interpolated DOF blur intensity based on dofBlendAlpha (0=default, 1=full blur).
-- Called every frame during fade-in and fade-out.
function EnhancedHelpMenu:applyDOFBlend()
    if g_depthOfFieldManager == nil then return end
    local a       = self.dofBlendAlpha
    local nearCoC = DOF_NEAR_COC_BASE + (DOF_NEAR_COC - DOF_NEAR_COC_BASE) * a
    local farCoC  = DOF_FAR_COC_BASE  + (DOF_FAR_COC  - DOF_FAR_COC_BASE)  * a
    pcall(function()
        local info = g_depthOfFieldManager:createInfo(
            nearCoC, DOF_NEAR_BLUR_END,
            farCoC,  DOF_FAR_BLUR_START, DOF_FAR_BLUR_END, true)
        g_depthOfFieldManager:applyInfo(info)
    end)
end

function EnhancedHelpMenu:onUIModeEnter()
    self.uiMode           = true
    self.hoveredToggle    = nil
    self.hoveredAllToggle = false
    self.uiModeClicked    = false
    pcall(function() g_inputBinding:setShowMouseCursor(true) end)
    for _, entry in ipairs(EHM_LOOK_ACTIONS) do
        pcall(function()
            g_inputBinding:setContextEventsActive(entry.context, entry.action, false)
        end)
    end
    -- Push the blur distance zone immediately, then fade intensity in via update()
    if g_depthOfFieldManager ~= nil then
        pcall(function()
            g_depthOfFieldManager:pushArea(0, DOF_NEAR_BLUR_END, DOF_FAR_BLUR_START, DOF_FAR_BLUR_END, true)
        end)
    end
    self.dofBlendAlpha = 0
    self.dofFading     = "in"
    -- Mirror onUIModeExit: rebuild silently so hidden actions appear and row
    -- layouts pick up the new (narrower) content width for the eye-icon column.
    -- Without this the list and layouts could lag by up to REFRESH_INTERVAL ms
    -- after F4 open, briefly overlapping labels and bindings before settling.
    self.silentRebuild = true
    self:rebuild()
    self.silentRebuild = false
end

function EnhancedHelpMenu:onUIModeExit()
    self.uiMode = false
    pcall(function() g_inputBinding:setShowMouseCursor(false) end)
    for _, entry in ipairs(EHM_LOOK_ACTIONS) do
        pcall(function()
            g_inputBinding:setContextEventsActive(entry.context, entry.action, true)
        end)
    end
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
    -- Fade blur out — popArea fires in update() when alpha reaches 0
    self.dofFading = "out"
    self.silentRebuild = true
    self:rebuild()
    self.silentRebuild = false
end

function EnhancedHelpMenu:mouseEvent(posX, posY, isDown, eventUsed, button)
    if not self.isVisible then return end

    -- Always track mouse position when in UI mode
    if self.uiMode then
        self.uiModeMouseX = posX
        self.uiModeMouseY = posY
    end

    if not self.uiMode then return end

    if isDown then
        if button == Input.MOUSE_BUTTON_LEFT then
            dbg("mouseEvent: LEFT CLICK at %.3f,%.3f", posX, posY)
            self.uiModeClicked = true
        end
    end
end

function EnhancedHelpMenu:onCycleDevice()
    if not self.isVisible then return end
    self.deviceModeIndex = self.deviceModeIndex + 1
    if self.deviceModeIndex > #self.deviceModes then self.deviceModeIndex = 1 end
    self.selectedDeviceKey = self.deviceModes[self.deviceModeIndex] ~= nil
        and self.deviceModes[self.deviceModeIndex].key or "NONE"
    self.refreshTimer = 0
end

-- Pressed-edge filter for axis-bound keys.
--
-- EHM_PAGE_PREV / EHM_PAGE_NEXT default to PGUP / PGDN, which collide with
-- vanilla CAMERA_ZOOM_IN_OUT's keyboard axis. Once `triggerAlways = true`
-- in registerActionEvent gives EHM a seat at the table, FS25 then dispatches
-- the callback on every axis-value-change tick while the key is held -- 20+
-- fires per press. Without edge filtering, the page jumps multiple steps
-- per tap (or, on page 1 / last page, silently no-ops dozens of times,
-- looking like "nothing happened").
--
-- Solution: stash the pressed/released state per action and only react on
-- the rising edge (released -> pressed). FS25 calls the callback as
--   target:callback(actionName, inputValue, callbackState, isAnalog)
-- so inputValue is the second positional arg. Treat anything > 0.5 as
-- "pressed" -- digital keys map to 1.0 exactly; the threshold is a
-- safety margin for noisy axis hardware.
-- Page actions: raw-key polling instead of FS25 action-event dispatch.
--
-- Why: the page actions default-bind onto PGUP / PGDN, which collide with
-- vanilla CAMERA_ZOOM_IN_OUT's keyboard axis. FS25 normalizes mod keyboard
-- bindings to axisComponent="+" regardless of what modDesc declares, while
-- vanilla's PGDN binding uses axisComponent="-" -- so PGDN dispatch never
-- reaches us. Even on PGUP (matching "+"), FS25 sends our callback with
-- inputValue=1 every frame the key is held and never a release event,
-- making edge detection impossible from inside the callback alone
-- (confirmed by v1.9.1.0 diagnostic).
--
-- Solution: keep the action registered (so it still appears in the Controls
-- menu and can be rebound -- the binding is the source of truth), but
-- bypass FS25's event dispatch entirely. Each frame, look up the action's
-- current keyboard binding and poll Input.isKeyPressed directly on that
-- key. Rising-edge detection gives us clean one-shot-per-tap semantics
-- regardless of axis-flooding or arbitration.
--
-- Limitations:
--   - Two-token combos ("LALT + PGUP") are supported since v1.13.0.5 --
--     getActionKeys returns (mainKey, modifierKey) and the poll requires
--     both. Three-token combos ("LCTRL + LSHIFT + PGUP") are not supported.
--   - Non-keyboard rebinds (gamepad, mouse) are not polled. The registered
--     action-event callbacks remain wired, so those bindings get whatever
--     dispatch FS25 gives them (may or may not work depending on conflict).
--
-- The registered onPagePrev / onPageNext callbacks are kept as no-ops so
-- removing the registration code wouldn't be needed if we ever revert.

-- Look up the first usable keyboard binding for an action.
-- Returns (mainKeyId, modifierKeyId) where modifierKeyId is nil for
-- single-key bindings (e.g. bare KEY_pageup) and non-nil for two-token
-- combo bindings (e.g. "KEY_lalt KEY_pageup" -> main=KEY_pageup,
-- modifier=KEY_lalt).
--
-- Used by the raw-poll path (pollPageActions, pollF1Action). The poll
-- treats nil-modifier as "no modifier required" and a non-nil modifier
-- as "this key must be held while the main key is pressed" -- single-key
-- semantics fall out for free.
--
-- (Renamed from getActionSingleKeyId in v1.13.0.5. The old name only
-- returned single-key bindings; the new one handles two-token combos
-- too. Combo support was added to let EHM ship ALT-prefixed defaults
-- that don't collide with vanilla CAMERA_ZOOM_IN_OUT on PGUP/PGDN --
-- see v1.13.0.5 version_log + feedback_fs25_input_arbitration.md.)
--
-- Multi-modifier combos (3+ tokens, e.g. "LCTRL + LSHIFT + key") are
-- not supported; they fall through silently with both return values nil.
-- That's an acceptable limitation -- FS25's UI accepts up to two-key
-- combos for vanilla action defaults too.
local function getActionKeys(actionName)
    if g_inputBinding == nil or g_inputBinding.nameActions == nil then return nil, nil end
    if Input == nil then return nil, nil end

    local actionDef = g_inputBinding.nameActions[actionName]
    if actionDef == nil and InputAction ~= nil then
        local actionId = InputAction[actionName]
        if actionId ~= nil then
            actionDef = g_inputBinding.nameActions[actionId]
        end
    end
    if actionDef == nil or actionDef.activeBindings == nil then return nil, nil end

    for _, binding in pairs(actionDef.activeBindings) do
        local s = binding ~= nil and binding.inputString or nil
        if type(s) ~= "string" or s:sub(1, 4) ~= "KEY_" then
            -- non-keyboard binding (gamepad, mouse, joystick) -- skip
        else
            local spaceIdx = s:find(" ", 1, true)
            if spaceIdx == nil then
                -- Single-key keyboard binding (e.g. "KEY_pageup")
                local keyId = Input[s]
                if type(keyId) == "number" then return keyId, nil end
            else
                -- Two-token combo (e.g. "KEY_lalt KEY_pageup").
                -- Reject if there's a third token (multi-modifier combo).
                local modStr  = s:sub(1, spaceIdx - 1)
                local mainStr = s:sub(spaceIdx + 1)
                if mainStr:find(" ", 1, true) == nil
                   and modStr:sub(1, 4) == "KEY_"
                   and mainStr:sub(1, 4) == "KEY_" then
                    local modId  = Input[modStr]
                    local mainId = Input[mainStr]
                    if type(modId) == "number" and type(mainId) == "number" then
                        return mainId, modId
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Returns true iff the given (mainKey, modifierKey) pair is currently
-- down. nil mainKey -> false. nil modifierKey -> ignores modifier check
-- (single-key binding semantics). Used by every raw-poll site.
local function isComboDown(mainKey, modifierKey)
    if mainKey == nil then return false end
    if modifierKey ~= nil and Input.isKeyPressed(modifierKey) ~= true then return false end
    return Input.isKeyPressed(mainKey) == true
end

-- Action-event callbacks remain registered for Controls-menu visibility and
-- to give non-keyboard rebinds a chance to work via the standard dispatch
-- path. Body left empty because the keyboard path is handled by
-- pollPageActions() in update() -- moving any logic here would cause
-- double-fires for axis-flooded keys like PGUP.
function EnhancedHelpMenu:onPagePrev() end
function EnhancedHelpMenu:onPageNext() end

-- Raw-key polling for the page actions. Runs once per update tick.
-- Edge-detected via per-action "was-held-last-frame" flags so each tap
-- advances exactly one page; holding the key doesn't auto-repeat (matches
-- the action-event semantics the user would expect from F4 / F10).
function EnhancedHelpMenu:pollPageActions()
    if not self.isVisible then
        -- Reset edge state so a held key released while hidden doesn't
        -- spuriously fire on next show.
        self._rawPagePrevHeld = false
        self._rawPageNextHeld = false
        return
    end
    if Input == nil or type(Input.isKeyPressed) ~= "function" then return end

    -- Combo-aware lookup (v1.13.0.5): single-key bindings return
    -- modifierKey=nil so the modifier check is a no-op; combo bindings
    -- like "KEY_lalt KEY_pageup" require both keys down. Edge detection
    -- is on the MAIN key only -- toggling the modifier while the main
    -- key is held doesn't trigger a re-fire because the held-flag won't
    -- have cleared back to false in between.
    local prevMain, prevMod = getActionKeys("EHM_PAGE_PREV")
    local nextMain, nextMod = getActionKeys("EHM_PAGE_NEXT")

    local prevDown = isComboDown(prevMain, prevMod)
    local nextDown = isComboDown(nextMain, nextMod)

    if prevDown and not self._rawPagePrevHeld then
        self.page = math.max(1, (self.page or 1) - 1)
    end
    if nextDown and not self._rawPageNextHeld then
        self.page = math.min(self.cachedTotalPages or 1, (self.page or 1) + 1)
    end

    self._rawPagePrevHeld = prevDown
    self._rawPageNextHeld = nextDown
end

-- Raw-key polling for F1 (TOGGLE_HELP_TEXT). FS25's action-event
-- dispatcher doesn't broadcast vanilla-owned actions to additional
-- registrants (tested via registerActionEvent with triggerAlways=true
-- in v1.11.2.0 -- no firing). So we poll the bound key directly, like
-- we do for PGUP / PGDN. Works for any single-key keyboard binding
-- (default KEY_f1 or rebound to a single key) AND, since v1.13.0.5,
-- any two-token combo (e.g. LSHIFT + F1) via the combo-aware
-- getActionKeys / isComboDown helpers above. Doesn't work for gamepad
-- rebinds (raw-poll is keyboard-only by design).
--
-- Combined with the native-visibility push in onF1Changed, this gives
-- correct cycle behaviour for both showBaseGameHelp ON and OFF without
-- the cycle-drift symptoms from the v1.11.0.x hook-based detection.
function EnhancedHelpMenu:pollF1Action()
    if not self.spawnInitDone or self.postInitCooldown > 0 then
        self._rawF1Held = false
        return
    end
    if Input == nil or type(Input.isKeyPressed) ~= "function" then return end
    local mainKey, modKey = getActionKeys("TOGGLE_HELP_TEXT")
    local down = isComboDown(mainKey, modKey)
    if down and not self._rawF1Held then
        self:onF1Changed()
    end
    self._rawF1Held = down
end

-- ---------------------------------------------------------------------------
-- Device Filter
--
-- FS25 stores bindings per device. We enumerate connected devices from active
-- bindings and let the user cycle through them with F10 / HOME.
-- Phantom devices (saved in inputBinding.xml but no longer connected) are
-- skipped by checking the device registry (devicesByInternalId).
--
-- Multi-device "ALL" mode (since v1.11.0.0):
-- When two or more real devices are connected, rebuildDeviceModes appends a
-- synthetic entry with key = DEVICE_KEY_ALL. Selecting it makes
-- bindingMatchesDevice() short-circuit to true for every binding, so the
-- panel displays bindings for every connected device side by side -- useful
-- for players running e.g. wheel/pedals + a side-mounted farmstick.
-- The render pipeline already handles multi-binding rows (drawBindingPills
-- splits "  |  "-joined alternates into separate pill groups), so no
-- renderer changes are needed -- the wider per-row content just promotes
-- more rows to the double-line layout if pills overflow the panel width.
-- ---------------------------------------------------------------------------

local DEVICE_KEY_ALL = "__ALL__"  -- sentinel; never a real deviceId

function EnhancedHelpMenu:getDeviceKey(binding)
    if binding ~= nil and binding.deviceId ~= nil then
        return tostring(binding.deviceId)
    end
    return nil
end

-- Returns human-readable device name, or nil if device is not connected.
function EnhancedHelpMenu:getDeviceLabel(binding)
    if binding == nil then return nil end

    if g_inputBinding ~= nil and g_inputBinding.devicesByInternalId ~= nil then
        -- Primary: direct registry lookup by internalDeviceId
        local internalId = binding.internalDeviceId
        if internalId ~= nil then
            local device = g_inputBinding.devicesByInternalId[internalId]
            if device ~= nil and device.deviceName ~= nil then
                local name = tostring(device.deviceName)
                if name == "KB_MOUSE_DEFAULT" then return l10n("EHM_UI_KB_MOUSE", "KB/Mouse") end
                return name
            end
        end

        -- Secondary: match by deviceId string (for bindings without internalDeviceId)
        local bindingDevId = tostring(binding.deviceId or "")
        if bindingDevId ~= "" then
            for _, device in pairs(g_inputBinding.devicesByInternalId) do
                if type(device) == "table" and tostring(device.deviceId) == bindingDevId then
                    local name = tostring(device.deviceName)
                    if name == "KB_MOUSE_DEFAULT" then return l10n("EHM_UI_KB_MOUSE", "KB/Mouse") end
                    return name
                end
            end
        end

        -- No registry match — device not connected, skip phantom binding
        if binding.isGamepad == true then return nil end
    end

    if binding.isKeyboard == true or binding.isMouse == true then
        return l10n("EHM_UI_KB_MOUSE", "KB/Mouse")
    end
    return nil
end

function EnhancedHelpMenu:rebuildDeviceModes()
    local modes = {}
    local seen  = {}

    if g_inputBinding ~= nil and g_inputBinding.nameActions ~= nil then
        for _, actionDef in pairs(g_inputBinding.nameActions) do
            if type(actionDef) == "table" and actionDef.activeBindings ~= nil then
                for _, binding in pairs(actionDef.activeBindings) do
                    local key = self:getDeviceKey(binding)
                    if key ~= nil and not seen[key] then
                        local label = self:getDeviceLabel(binding)
                        if label ~= nil then
                            seen[key] = true
                            table.insert(modes, { key = key, label = label })
                        end
                    end
                end
            end
        end
    end

    -- Multi-device convenience: when 2+ real devices are connected, append a
    -- synthetic "ALL" mode at the end of the cycle. Skipped when only one
    -- device is connected -- ALL would be a no-op alias for that one device
    -- and would only add a confusing extra step to the F10 / HOME cycle.
    if #modes >= 2 then
        table.insert(modes, { key = DEVICE_KEY_ALL, label = l10n("EHM_UI_ALL_DEVICES", "ALL") })
    end

    -- Log device list only when it changes (not on every 500ms rebuild)
    if DEBUG then
        local prev = self.deviceModes or {}
        local changed = #modes ~= #prev
        if not changed then
            for i, m in ipairs(modes) do
                if not prev[i] or prev[i].key ~= m.key then
                    changed = true; break
                end
            end
        end
        if changed then
            for _, m in ipairs(modes) do log("Device: %s", m.label) end
        end
    end

    self.deviceModes = modes

    -- Restore previously selected device if still connected
    local found = false
    for i, mode in ipairs(self.deviceModes) do
        if mode.key == self.selectedDeviceKey then
            self.deviceModeIndex = i
            found = true
            break
        end
    end
    if not found then
        self.deviceModeIndex   = 1
        self.selectedDeviceKey = self.deviceModes[1] ~= nil
            and self.deviceModes[1].key or "NONE"
    end
end

function EnhancedHelpMenu:bindingMatchesDevice(binding)
    local mode = self.deviceModes[self.deviceModeIndex]
    if mode == nil then return true end
    if mode.key == DEVICE_KEY_ALL then return true end
    return self:getDeviceKey(binding) == mode.key
end

-- ---------------------------------------------------------------------------
-- Binding String Formatting
--
-- ALL display overrides live here — do not format elsewhere.
-- Goal: minimal changes, keep as close to raw data as possible.
--
-- Rules applied in order:
--   1. Spaces between tokens = simultaneous keys → " + "
--      e.g. "KEY_lshift KEY_tab" → "LSHIFT + TAB"
--   2. Strip KEY_ prefix
--   3. Underscores → spaces  (e.g. "BUTTON_18" → "BUTTON 18")
--   4. Uppercase everything
--
-- Friendly name overrides (Step 5) — add future substitutions here,
-- matching against the already-processed uppercase string.
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:formatInput(s)
    s = string.gsub(s, " ", "~")        -- protect combo spaces
    s = string.gsub(s, "KEY_", "")      -- strip KEY_ prefix
    s = string.gsub(s, "_", " ")        -- underscores to spaces
    s = string.upper(s)                 -- uppercase
    s = string.gsub(s, "~", " + ")      -- combo spaces → " + "

    -- Friendly name overrides — order is critical: longest/most-specific first
    -- to prevent partial matches corrupting later substitutions.
    --
    -- Mouse wheel — handle both raw form (MOUSE BUTTON WHEEL …) and any
    -- already-partially-processed form (MOUSE WHEEL …) for robustness.
    s = string.gsub(s, "MOUSE BUTTON WHEEL UP",   "MWHEEL UP")
    s = string.gsub(s, "MOUSE BUTTON WHEEL DOWN", "MWHEEL DN")
    s = string.gsub(s, "MOUSE WHEEL UP",           "MWHEEL UP")
    s = string.gsub(s, "MOUSE WHEEL DOWN",         "MWHEEL DN")
    -- Mouse buttons — named before numbered so MIDDLE/LEFT/RIGHT are caught
    -- before the generic MOUSE BUTTON (%d+) pattern can fire.
    s = string.gsub(s, "MOUSE BUTTON LEFT",   "MBTN L")
    s = string.gsub(s, "MOUSE BUTTON RIGHT",  "MBTN R")
    s = string.gsub(s, "MOUSE BUTTON MIDDLE", "MBTN MID")
    s = string.gsub(s, "MOUSE BUTTON (%d+)",  "MBTN %1")
    -- Generic numbered button (joystick / farmstick / gamepad).
    -- Applied after all mouse button substitutions so those are unaffected.
    s = string.gsub(s, "BUTTON (%d+)", "BTN %1")
    -- Page keys — raw form has no space (KEY_pageup → PAGEUP after KEY_ strip)
    s = string.gsub(s, "PAGEUP",   "PGUP")
    s = string.gsub(s, "PAGEDOWN", "PGDN")

    return s
end

function EnhancedHelpMenu:getBindings(actionName)
    if g_inputBinding == nil or g_inputBinding.nameActions == nil then return nil end

    -- Mod actions are keyed by string name; game actions may be keyed by their
    -- integer InputAction constant — try both.
    local actionDef = g_inputBinding.nameActions[actionName]
    if actionDef == nil and InputAction ~= nil then
        local actionId = InputAction[actionName]
        if actionId ~= nil then
            actionDef = g_inputBinding.nameActions[actionId]
        end
    end
    if actionDef == nil then return nil end

    local parts = {}
    local seen  = {}

    if actionDef.activeBindings ~= nil then
        for _, binding in pairs(actionDef.activeBindings) do
            if binding ~= nil and self:bindingMatchesDevice(binding) then
                local s = binding.inputString
                if s ~= nil and s ~= "" and not seen[s] then
                    seen[s] = true
                    table.insert(parts, self:formatInput(s))
                end
            end
        end
    end

    if #parts > 0 then return table.concat(parts, "  |  ") end
    return nil
end

-- ---------------------------------------------------------------------------
-- Data Rebuild
--
-- Reads all active action events every 500ms and rebuilds self.actions.
--
-- NEW ACTION DETECTION:
--   prevActive    — set of action names active in the previous rebuild.
--   animState     — per-action animation state (shift, fade, accent bar).
--   prevPositions — action name → sorted index from previous rebuild.
--
--   An action is new when it appears in currentActive but was NOT in prevActive,
--   and detection is not suppressed.
--   New actions trigger a fade-in and a left accent bar via animState.
--   Existing actions that moved down trigger a shift animation.
--
-- SUPPRESSION (prevents false highlights):
--   silentRebuild — set for one rebuild on context switches and filter changes.
--                   The list appears in final form with no animations.
--   warmupTimer   — grace period (ms) after spawn or context switch. Catches
--                   late-registering actions (mods on spawn, RADIO_TOGGLE on
--                   vehicle entry) so they quietly join the natural sort.
--   departedAnimState — action briefly left the list and came back. Reuses
--                       previous animation state to prevent flicker.
--
-- SORT ORDER:
--   1. Pinned tier — animState[name] exists with isPinned=true:
--      detectedOrder DESC → priority ASC → order ASC
--      Covers both actively-animating actions (green bar visible) AND
--      settled actions (animation complete, stayed at top because nothing
--      newer arrived yet).
--   2. Natural tier (everything else):
--      isVisible DESC → priority ASC → order ASC
--
--   When a newer action is detected, all settled-pinned actions are demoted
--   from animState in the SAME rebuild (before sort runs) — so the new arrival
--   and old demotion happen as a single visible transition, not a two-step
--   "settle to position 2 then drop to natural" shuffle.
-- ---------------------------------------------------------------------------

-- Returns true for menu/dialog contexts that are transient interruptions
-- (ESC pause, in-game menus, confirmation dialogs). prevActive is saved and
-- restored around these so returning from a pause doesn't re-flash everything.
local function isMenuContext(ctx)
    if ctx == nil then return false end
    return ctx:find("^MENU") ~= nil or ctx:find("^DIALOG") ~= nil
end

-- Returns the index (1-based) of the currently selected object in the vehicle's
-- selectable chain (the G-key cycle). Uses the isSelected flag on each selectable
-- because v.selectedObject is nil in this game build — confirmed by diagnostic probe.
-- Returns 0 if not in a vehicle or no selectable is flagged.
-- Pcall-wrapped so a missing field never crashes the game.
local function getActiveSelectableIdx()
    local result = 0
    pcall(function()
        if g_currentMission == nil then return end
        local ih = g_currentMission.hud and g_currentMission.hud.inputHelp
        if ih == nil or ih.vehicle == nil then return end
        local so = ih.vehicle.selectableObjects
        if so == nil then return end
        for i, obj in ipairs(so) do
            if type(obj) == "table" and obj.isSelected == true then
                result = i; return
            end
        end
    end)
    return result
end

-- Called at every context switch. Manages prevActive so that:
--
--   Menu interruptions (ESC/pause/map):
--     prevActive is saved on entry and restored on exit so stable actions
--     don't falsely re-trigger as new when returning from a menu.
--
--   Real context switches (PLAYER ↔ VEHICLE, etc.):
--     prevActive is reset to nil, animState/departedAnimState cleared,
--     silentRebuild=true so the first rebuild appears in natural sort with
--     no animations. A warmup grace period follows (duration depends on
--     transition kind — see real-switch branch below).

function EnhancedHelpMenu:handlePrevActiveOnSwitch(fromCtx, toCtx)
    if isMenuContext(toCtx) then
        -- Entering a menu: save prevActive at outermost level only.
        -- animState is preserved — animations may still be running.
        -- prevPositions is cleared; menu actions have different positions.
        if not self.inMenuContext then
            self.menuSavedPrevActive = self.prevActive
            self.menuSavedFromCtx    = fromCtx
            self.inMenuContext        = true
        end
        self.prevActive    = nil
        self.prevPositions = {}
        self.silentRebuild = true  -- menu actions should never flash
        log("prevActive: nil (entering menu %s)", toCtx)
    elseif isMenuContext(fromCtx) then
        -- Leaving the menu system entirely.
        -- animState is preserved throughout menu — no reset needed.
        self.inMenuContext = false
        if self.menuSavedFromCtx == toCtx then
            -- Returning to same context: restore prevActive so nothing is falsely new.
            -- Fresh prevPositions + silentRebuild means the first rebuild establishes a
            -- clean position baseline without shift animations or new-action detections.
            -- Genuinely new actions since the menu are caught on the second rebuild.
            self.prevActive    = self.menuSavedPrevActive
            self.prevPositions = {}
            self.silentRebuild = true
            log("prevActive: RESTORED from menu (back to %s), silentRebuild for clean baseline", toCtx)
        else
            -- Leaving to a different context after menu: fresh start.
            self.prevActive    = nil
            self.prevPositions = {}
            log("prevActive: nil (leaving menu to different ctx %s)", toCtx)
        end
        self.menuSavedPrevActive = nil
        self.menuSavedFromCtx    = nil
    else
        -- Real context switch (PLAYER ↔ VEHICLE etc.): reset all animation state.
        --
        -- Context baseline rule: every real context switch is treated as a silent
        -- list swap. The new context's actions appear instantly in their natural
        -- sort order — no green bars, no shuffle. The list change itself IS the
        -- visual signal that the context changed. A short warmup grace period
        -- after the switch suppresses late-arriving actions (e.g. RADIO_TOGGLE
        -- which activates ~500ms after vehicle entry) so they quietly join the
        -- natural sort instead of triggering false "new" highlights.
        --
        -- Genuinely new actions appearing AFTER warmup expires (chainsaw activation,
        -- ENTER prompt when approaching a vehicle, etc.) get the full new-action
        -- treatment — green bar, pin to top, sort by detectedOrder.
        self.prevActive          = nil
        self.prevPositions       = {}
        self.animState           = {}
        self.departedAnimState   = {}
        self.menuSavedPrevActive = nil
        self.menuSavedFromCtx    = nil
        self.inMenuContext        = false
        -- If filter mode was open when the context switch happened, close it cleanly.
        -- The engine resets DOF state on context switches, so we snap (not animate)
        -- the blur away. Mouse cursor and look-axis locks must be released so the
        -- player is not stuck with the cursor showing in the new context.
        if self.uiMode then
            self.uiMode = false
            pcall(function() g_inputBinding:setShowMouseCursor(false) end)
            for _, entry in ipairs(EHM_LOOK_ACTIONS) do
                pcall(function()
                    g_inputBinding:setContextEventsActive(entry.context, entry.action, true)
                end)
            end
            -- Snap DOF state — the engine has already reset it on context switch,
            -- so an animated fade-out would never complete. popArea balances the
            -- pushArea from onUIModeEnter.
            if g_depthOfFieldManager ~= nil then
                pcall(function() g_depthOfFieldManager:popArea() end)
            end
            self.dofBlendAlpha = 0
            self.dofFading     = "none"
            EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
            log("Filter mode force-closed (context switch while open: %s → %s)",
                tostring(fromCtx), tostring(toCtx))
        end
        -- Reset extra text accent so it can fire again in the new context
        self.extraTextAccentPhase  = "done"
        self.extraTextAccentTimer  = 0
        self.extraTextAccentAlpha  = 0
        self.prevExtraCount        = 0
        self.prevExtraTexts        = {}
        self.extraTextBaseSet      = {}
        -- Snap height animation state so the block disappears with the old context.
        self.xtBlockH       = 0
        self.xtTargetH      = 0
        self.xtDisplayAlpha = 0
        self.xtLastTexts    = {}
        -- Silent first rebuild + warmup grace period for ALL real switches.
        -- Warmup duration depends on what kind of switch this is:
        --   Initial spawn (fromCtx=nil): 2000ms — covers late-registering mods
        --     like LumberJack which add their actions ~1.5s after world load.
        --   Vehicle exit / other → PLAYER (fromCtx ~= nil): 0ms — no mods are
        --     loading, and ENTER appearing ~500ms after exit is meaningful and
        --     should highlight, not be suppressed.
        --   Vehicle / other entry: ~600ms — covers late-arriving in-context
        --     actions like RADIO_TOGGLE which activates one rebuild after entry.
        self.silentRebuild = true
        if fromCtx == nil then
            self.warmupTimer = 2000
        elseif toCtx == "PLAYER" then
            self.warmupTimer = 0
        else
            self.warmupTimer = REFRESH_INTERVAL + 100
        end
        -- Reset selectable tracking so next vehicle entry starts clean.
        self.currentSelectableIdx   = 0
        self.gPressSelectableChange = false
        log("prevActive: nil + silentRebuild=true + warmup=%dms (real switch %s→%s)",
            self.warmupTimer, tostring(fromCtx), tostring(toCtx))
    end
end

function EnhancedHelpMenu:rebuild()
    self.actions      = {}
    self:rebuildDeviceModes()

    if g_inputBinding == nil or g_inputBinding.actionEvents == nil then return end

    -- Detect context switches that don't fire onRegisterGlobalActionEvents (e.g. vehicle exit).
    -- onRegisterGlobalActionEvents fires reliably for vehicle ENTRY but not for the return
    -- to the player context on exit, so self.currentContextName can be stale. Reading
    -- g_inputBinding:getContextName() directly here catches those missed transitions.
    local engineCtx = g_inputBinding:getContextName() or "PLAYER"
    if engineCtx ~= self.currentContextName then
        log("Context switch (rebuild): %s → %s", tostring(self.currentContextName), engineCtx)
        self:handlePrevActiveOnSwitch(self.currentContextName, engineCtx)
        self.currentContextName = engineCtx
    end

    local currentList   = {}
    local currentActive = {}

    -- Compute once — used in logging, detection loop, and animState update.
    local inWarmup = (self.warmupTimer or 0) > 0

    -- Tracks whether any action was newly detected this rebuild. Used after the
    -- detection loop to demote settled-pinned actions in the same rebuild — that
    -- way the new arrival and old demotion happen as a single visible transition,
    -- not a two-step "settle to position 2 then drop to natural" shuffle.
    local anyNewDetected = false

    -- Log the suppression state once per rebuild so we can diagnose issues.
    dbg("rebuild START: ctx=%s prevActiveIsNil=%s silentRebuild=%s inWarmup=%s warmupTimer=%.0f",
        tostring(self.currentContextName), tostring(self.prevActive == nil),
        tostring(self.silentRebuild), tostring(inWarmup), self.warmupTimer or 0)
    -- (cachedF1Key for the header's TOGGLE [F1] pill was removed in
    -- v1.13.0.6 alongside the pill itself. F1 is a universal "help menu"
    -- mnemonic; dedicating header real estate to it was redundant. The
    -- TOGGLE_HELP_TEXT row in the main action list still surfaces F1 via
    -- the standard rendering path, no extra cache needed.)

    for action, events in pairs(g_inputBinding.actionEvents) do
        if type(events) == "table" then
            for _, event in pairs(events) do
                if event.isActive == true then
                    local actionName = event.actionName
                    if actionName == nil then
                        local t = tostring(action)
                        actionName = string.match(t, "%[([^:]+):") or t
                    end

                    -- Skip our own mod actions, help-toggle actions (shown in header),
                    -- and camera look axes (disabled during filter mode — would cause
                    -- +2/-2 oscillation every time filter mode opens or closes).
                    if actionName ~= "EHM_UI_MODE" and
                       actionName ~= "EHM_CYCLE_DEVICE" and
                       actionName ~= "EHM_PAGE_PREV" and
                       actionName ~= "EHM_PAGE_NEXT" and
                       actionName ~= "TOGGLE_HELP" and
                       actionName ~= "TOGGLE_HELP_TEXT" and
                       actionName ~= "AXIS_LOOK_LEFTRIGHT_PLAYER" and
                       actionName ~= "AXIS_LOOK_UPDOWN_PLAYER" and
                       actionName ~= "AXIS_LOOK_LEFTRIGHT_VEHICLE" and
                       actionName ~= "AXIS_LOOK_UPDOWN_VEHICLE" then

                        local label = event.contextDisplayText
                        if label ~= nil and label ~= "" then

                            -- Determine category for this action
                            local na = g_inputBinding.nameActions ~= nil
                                and g_inputBinding.nameActions[actionName] or nil
                            local displayCat = na ~= nil and na.displayCategory or nil
                            local catIndex   = (displayCat ~= nil and EHM_CAT_INDEX[displayCat])
                                           or EHM_MODS_INDEX  -- unknown/mod = MODS bucket

                            -- Apply category filter
                            if self.filterEnabled[catIndex] ~= false then

                                -- Per-action hide/un-hide (Stage 2):
                                --   isHidden: name is present in self.hiddenActions.
                                --   In normal mode, hidden actions are skipped from currentList
                                --     so they don't draw — but still recorded in currentActive
                                --     so prevActive consistently tracks input reality (prevents
                                --     spurious departed/returned oscillations when F4 toggles).
                                --   In filter mode, hidden actions ARE included so the user can
                                --     un-hide them; the renderer (Steps 2-3) will dim/strike them.
                                --   isNewToActive is forced false for hidden actions in BOTH
                                --     modes — they never trigger the green-bar animation.
                                local isHidden = self.hiddenActions[actionName] == true

                                currentActive[actionName] = true

                                if not isHidden or self.uiMode then

                                    -- Determine suppression:
                                    --   silentRebuild: baseline rebuild — nothing should flash.
                                    --   inWarmup: grace period after spawn or context switch
                                    --   (suppresses late-arriving actions like RADIO_TOGGLE).
                                    local suppress = self.silentRebuild or inWarmup

                                    -- isNewToActive: brand-new to prevActive in this rebuild.
                                    --   Drives animState creation (with detectedOrder) below.
                                    -- The sort uses animState[name].isPinned directly to decide
                                    -- pinned vs natural tier — that flag stays true for both
                                    -- actively-animating and settled actions, so they stay at
                                    -- top until something newer pushes them down.
                                    -- Hidden actions never flash green even when shown in
                                    -- filter mode — the `not isHidden` guard handles that.
                                    local notInPrev      = not (self.prevActive and self.prevActive[actionName])
                                    local notInDeparted  = not self.departedAnimState[actionName]
                                    local isNewToActive  = not suppress and notInPrev and notInDeparted and not isHidden

                                    if isNewToActive then
                                        anyNewDetected = true
                                        log("NEW: %s", actionName)
                                    end

                                    table.insert(currentList, {
                                        name      = actionName,
                                        label     = label,
                                        binding   = self:getBindings(actionName),
                                        priority  = tonumber(event.displayPriority) or 999,
                                        order     = tonumber(event.orderValue)      or 999,
                                        isVisible = event.displayIsVisible == true,
                                        isNewToActive = isNewToActive,
                                        catIndex  = catIndex,
                                        isHidden  = isHidden,
                                    })
                                end
                            end
                        end
                    end
                    break
                end
            end
        end
    end

    -- De-duplicate by label: an UNBOUND row whose display label is identical to
    -- a BOUND row's label is pure noise. FS25 registers some actions as separate
    -- rebindable slots that mirror an already-bound action's label — e.g. the
    -- unbound TOGGLE_AI_STEERING reads "Toggle Steering Assist", the very same
    -- label the H-bound TOGGLE_AI shows while in steering-assist mode. The
    -- unbound twin has no key to press, so it tells the player nothing the bound
    -- row doesn't already. Drop it. If the player ever binds it, it gains a key
    -- and is kept. Behavioural (label + binding presence) — no action names.
    do
        local boundLabels = {}
        for _, item in ipairs(currentList) do
            if item.binding ~= nil and item.binding ~= "" then
                boundLabels[item.label] = true
            end
        end
        for i = #currentList, 1, -1 do
            local item = currentList[i]
            if (item.binding == nil or item.binding == "")
               and boundLabels[item.label] then
                log("DEDUP: dropped unbound '%s' (%s) — label duplicates a bound row",
                    tostring(item.label), tostring(item.name))
                table.remove(currentList, i)
            end
        end
    end

    -- Pre-sort pass: create animState (and assign detectedOrder) for any actions
    -- newly detected in this rebuild. This must happen BEFORE the sort, otherwise
    -- the sort's detectedOrder lookup defaults to 0 for every newly-detected action,
    -- producing a different order than the next rebuild (which DOES see detectedOrder
    -- values) — that mismatch would cause the visible "resort" half a second later.
    --
    -- All actions detected in the same rebuild get the SAME detectedOrder so they
    -- don't shuffle relative to each other (priority/order tiebreaker decides their
    -- internal arrangement). The counter is incremented once per rebuild that
    -- actually detected new actions.
    local detectedThisRebuild = false
    for _, item in ipairs(currentList) do
        local name = item.name
        -- Restore from departed grace if applicable (returning action keeps prior state).
        if self.departedAnimState[name] ~= nil and self.animState[name] == nil then
            self.animState[name] = self.departedAnimState[name]
            self.animState[name].shiftOffset = 0  -- reset any stale shift
        end
        -- Genuinely new action — give it a fresh animState with detectedOrder.
        if item.isNewToActive and self.animState[name] == nil
           and not self.silentRebuild and not inWarmup then
            if not detectedThisRebuild then
                EHM_DETECT_ORDER  = EHM_DETECT_ORDER + 1
                detectedThisRebuild = true
            end
            self.animState[name] = {
                shiftOffset   = 0,
                fadeAlpha     = 0,
                accentAlpha   = 0,
                accentPhase   = "delay",
                accentTimer   = ANIM_ACCENT_DELAY,
                isPinned      = true,
                detectedOrder = EHM_DETECT_ORDER,
            }
        end
    end

    -- Demote settled-pinned actions in the SAME rebuild that a new action arrives.
    -- Runs AFTER pre-sort restore so it correctly catches both:
    --   1. Pre-existing settled-pinned animStates
    --   2. Settled-pinned animStates restored from departedAnimState in this rebuild
    --
    -- Without this, the transition would be two-step:
    --   Rebuild N: ENTER arrives, sort = [ENTER pinned, CAMERA_SWITCH still pinned, ...]
    --   Rebuild N+1: CAMERA_SWITCH demoted, sort = [ENTER pinned, ..., CAMERA_SWITCH at natural]
    -- Doing the demote here makes it one-step: ENTER lands at top, CAMERA_SWITCH
    -- slides directly to its natural position. No intermediate "stuck below new" frame.
    --
    -- Newly-created animStates from the pre-sort pass have accentPhase="delay",
    -- so they're never accidentally demoted here.
    if anyNewDetected then
        for name, anim in pairs(self.animState) do
            if anim.isPinned == true and anim.accentPhase == "done" then
                self.animState[name] = nil
                log("DEMOTED-SETTLED: %s (newer action arrived)", name)
            end
        end
    end

    -- Sort: pinned tier at top, natural tier below.
    --
    -- Pinned tier — animState[name] exists with isPinned=true:
    --   This covers BOTH actively-animating actions (green bar visible) AND
    --   settled actions (animation complete but stayed at top because nothing
    --   newer has arrived yet). The demote-settled step above ensures settled
    --   actions are dropped from animState the moment a newer action arrives.
    --   Within: detectedOrder DESC → priority ASC → order ASC.
    --
    -- Natural tier — everything else:
    --   isVisible DESC → priority ASC → order ASC.
    table.sort(currentList, function(a, b)
        local aAnim = self.animState[a.name]
        local bAnim = self.animState[b.name]
        local aPinned = aAnim ~= nil and aAnim.isPinned == true
        local bPinned = bAnim ~= nil and bAnim.isPinned == true
        if aPinned ~= bPinned then return aPinned end
        if aPinned then
            local aOrd = aAnim.detectedOrder or 0
            local bOrd = bAnim.detectedOrder or 0
            if aOrd ~= bOrd then return aOrd > bOrd end
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.order < b.order
        end
        if a.isVisible ~= b.isVisible then return a.isVisible end
        if a.priority  ~= b.priority  then return a.priority < b.priority end
        return a.order < b.order
    end)

    -- Build position map from sorted list for shift animation.
    local newPositions = {}
    for i, item in ipairs(currentList) do
        newPositions[item.name] = i
    end

    -- Update animState based on what moved. animState creation for new actions
    -- already happened in the pre-sort pass above. This loop now only handles
    -- shift animation for existing actions whose sorted position changed.
    for _, item in ipairs(currentList) do
        local name    = item.name
        local prevIdx = self.prevPositions[name]
        local newIdx  = newPositions[name]

        if prevIdx ~= nil then
            -- Existing action: animate shift if it moved.
            -- "Settled" actions (animation completed but still pinned because nothing
            -- newer has arrived) skip the shift animation so they don't visually
            -- shuffle when active-animation actions appear or depart around them.
            local moved = newIdx - prevIdx  -- non-zero = position changed
            if moved ~= 0 then
                if self.animState[name] == nil then
                    self.animState[name] = {
                        shiftOffset = 0, fadeAlpha = 1,
                        accentAlpha = 0, accentPhase = "done", accentTimer = 0,
                        isPinned    = false,
                    }
                end
                local settled = self.animState[name].isPinned == true
                            and self.animState[name].accentPhase == "done"
                if not settled then
                    -- Accumulate shift (handles rapid overlapping updates cleanly).
                    -- Scale by uiScale so the shift magnitude matches the rendered
                    -- row geometry at any HUD scale; if scale changes mid-animation
                    -- the new shifts use the new scale (existing in-progress shifts
                    -- finish at old magnitudes -- rare and acceptable).
                    local scale = self.uiScale or 1
                    self.animState[name].shiftOffset =
                        (self.animState[name].shiftOffset or 0) + moved * (ROW_H + ROW_GAP) * scale
                end
            end
        end
    end

    -- Prune animState for actions that left the list, with age-based grace period.
    -- SKIPPED during menu context: vehicle actions aren't active in menu but must
    -- keep their animState so the list is stable when we return.
    if not self.inMenuContext then
        -- Move newly departed actions from animState into departedAnimState.
        -- G-press exception: when gPressSelectableChange is true, don't add to the
        -- grace list — the action may return on a different selectable and should
        -- be treated as genuinely new rather than a brief bounce.
        for name in pairs(self.animState) do
            if not newPositions[name] then
                if not self.gPressSelectableChange then
                    self.departedAnimState[name] = self.animState[name]
                    self.departedAnimState[name].departedAge = 0
                end
                self.animState[name] = nil
                log("DEPARTED (had animState)%s: %s",
                    self.gPressSelectableChange and " [G-press, no grace]" or "", name)
            end
        end

        -- Also track plain departing actions (those without an animState entry).
        -- A regular action that sat at its natural position never had animState,
        -- so the loop above wouldn't catch it. Without this, an action like
        -- CAMERA_SWITCH that briefly disappears (e.g. while picking up a tool)
        -- would be flagged NEW when it returns, even though the user perceives
        -- it as having been there all along.
        --
        -- G-press exception: same as above — skip the grace list so returning
        -- selectable-specific actions (LOWER_IMPLEMENT, ATTACH) get highlighted.
        if self.prevActive then
            for name in pairs(self.prevActive) do
                if not newPositions[name] and not self.departedAnimState[name] then
                    if not self.gPressSelectableChange then
                        self.departedAnimState[name] = {
                            shiftOffset = 0, fadeAlpha = 1,
                            accentAlpha = 0, accentPhase = "done", accentTimer = 0,
                            isPinned    = false,
                            departedAge = 0,
                        }
                    end
                    log("DEPARTED (plain)%s: %s",
                        self.gPressSelectableChange and " [G-press, no grace]" or "", name)
                end
            end
        end

        -- Consume the G-press flag — applies to exactly one rebuild.
        self.gPressSelectableChange = false

        -- Age all departed entries; remove ones that came back or exceeded grace period.
        for name, state in pairs(self.departedAnimState) do
            if newPositions[name] then
                self.departedAnimState[name] = nil
                log("DEPARTED-RETURNED: %s (was age=%d)", name, state.departedAge or 0)
            else
                state.departedAge = (state.departedAge or 0) + 1
                if state.departedAge > ANIM_DEPARTED_GRACE then
                    self.departedAnimState[name] = nil
                    log("DEPARTED-EXPIRED: %s (age=%d > grace=%d)",
                        name, state.departedAge, ANIM_DEPARTED_GRACE)
                end
            end
        end
    end

    self.prevPositions = newPositions

    -- Count changes for page-reset and logging.
    local addedCount, removedCount = 0, 0
    if self.prevActive ~= nil then
        for name in pairs(currentActive) do
            if not self.prevActive[name] then addedCount = addedCount + 1 end
        end
        for name in pairs(self.prevActive) do
            if not currentActive[name] then removedCount = removedCount + 1 end
        end
    end

    dbgDiff("Active diff", self.prevActive, currentActive)

    -- Reset to page 1 when active set changes so new actions are visible.
    if self.prevActive == nil or addedCount > 0 or removedCount > 0 then
        self.page = 1
        if self.prevActive == nil then
            log("Page reset: fresh context → total=%d", #currentList)
        else
            log("Page reset: +%d -%d → total=%d", addedCount, removedCount, #currentList)
        end
    end

    self.prevActive     = currentActive
    self.silentRebuild  = false
    self.rowLayoutCache = {}  -- invalidate cached row layouts when action list changes

    for _, item in ipairs(currentList) do
        table.insert(self.actions, item)
    end

    dbg("rebuild END: total=%d page=%d prevActiveIsNil=%s",
        #self.actions, self.page, tostring(self.prevActive == nil))

    if DEBUG then
        dbg("Rebuild: %d actions, page %d", #self.actions, self.page)
        for i = 1, math.min(5, #currentList) do
            local item = currentList[i]
            local isPinned = self.animState[item.name] ~= nil
                         and self.animState[item.name].isPinned == true
            dbg("  [%d] %s newToActive=%s pinned=%s visible=%s pri=%d ord=%d",
                i, item.name, tostring(item.isNewToActive),
                tostring(isPinned),
                tostring(item.isVisible), item.priority, item.order)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:update(dt)
    -- Clear extraPrintTexts at the top of every update so that texts added by
    -- other mods never pile up across multiple update() calls that happen without
    -- a draw() in between (e.g. during the spawn transition). draw() also clears
    -- them immediately on read, so only texts added in the current update→draw
    -- cycle ever make it to the screen.
    self.extraPrintTexts = {}

    -- Fire the native-width probe once per session, as soon as inputHelp is
    -- live. Cheap (single pcall, single iteration over a small table) and the
    -- function itself early-returns after first success.
    if not self._nativeWidthProbeFired then
        pcall(probeNativeInputHelpWidth)
    end

    -- Raw-key polling for the page actions and F1. The page actions need
    -- this because of axis-flooded dispatch on PGUP / PGDN; F1 needs it
    -- because FS25's dispatcher doesn't broadcast vanilla-owned actions
    -- (TOGGLE_HELP_TEXT) to additional registrants -- see pollF1Action.
    pcall(EnhancedHelpMenu.pollPageActions, self)
    pcall(EnhancedHelpMenu.pollF1Action, self)

    -- Post-spawn init window: wait a few frames for the game to finish its own
    -- setInputHelpVisible calls, then read the settled F1 state and set up correctly.
    if self.f1InitFrames ~= nil then
        self.f1InitFrames = self.f1InitFrames - 1
        if self.f1InitFrames <= 0 then
            self.f1InitFrames = nil
            local f1On = g_currentMission ~= nil
                and g_currentMission.hud ~= nil
                and g_currentMission.hud.inputHelp ~= nil
                and g_currentMission.hud.inputHelp.isVisible == true

            -- Determine the desired toggle state using three-tier priority:
            --
            --   1. savedToggleState is set (explicit save exists)
            --        → restore it exactly; player knows what they want.
            --
            --   2. savedToggleState is nil but settingsExisted is true
            --        → returning player upgrading from an older version of
            --          the mod whose settings file has no <ui> tag yet.
            --          Default to EHM (0) so they don't land on the base
            --          game F1 menu just because the tag is missing.
            --
            --   3. settingsExisted is false
            --        → truly first-ever run (no settings file at all).
            --          Follow the game's own F1 state: new games auto-show
            --          F1 as a tutorial; existing saves hide it → EHM shows.
            local desiredState
            if self.savedToggleState ~= nil then
                desiredState = self.savedToggleState
                log("Post-init: restoring saved state=%d (game f1On=%s)",
                    desiredState, tostring(f1On))
            elseif self.settingsExisted then
                desiredState = 0  -- returning player, old file format → EHM
                log("Post-init: settings exist but no state tag (old format) → EHM (game f1On=%s)",
                    tostring(f1On))
            else
                desiredState = f1On and 1 or 0  -- first-ever run, follow game
                log("Post-init: first-ever run, using game default (f1On=%s) → state=%d",
                    tostring(f1On), desiredState)
            end

            -- Map desiredState → (EHM visible, native visible). The mapping
            -- depends on showBaseGameHelp; legacy saves from the old uniform
            -- 3-state cycle migrate cleanly because state 0 still means "EHM
            -- visible" in OFF-mode and state 2 still means "both off" in
            -- ON-mode. Stale ON-mode-only values (like state=2 written when
            -- the setting was ON) saved with setting OFF are clamped to 1.
            local showBaseGameHelp = self.settings ~= nil
                and self.settings.showBaseGameHelp == true
            local wantF1
            local ehmShouldShow
            if showBaseGameHelp then
                ehmShouldShow = (desiredState == 1)
                wantF1        = (desiredState == 0)
            else
                if desiredState >= 1 then desiredState = 1 end
                ehmShouldShow = (desiredState == 0)
                wantF1        = false
            end
            self.toggleState = desiredState
            self.isVisible   = ehmShouldShow

            -- Sync the game's F1 visibility to match our desired state.
            -- handlingToggle suppresses our own hooks so we don't re-enter onF1Changed.
            if wantF1 ~= f1On then
                self.handlingToggle = true
                pcall(function() g_currentMission.hud:setInputHelpVisible(wantF1) end)
                self.handlingToggle = false
            end

            -- If EHM is going to be visible, establish a silent prevActive baseline.
            -- warmupTimer (2000ms) covers late-registering mods on initial spawn so
            -- their actions don't flash green when they register ~1.5s after world load.
            -- (handlePrevActiveOnSwitch also sets these on the nil→PLAYER transition,
            -- so this is belt-and-braces.)
            if ehmShouldShow then
                self.silentRebuild = true
                self.warmupTimer   = 2000
                self:rebuild()
                self.silentRebuild = false
            end

            self.spawnInitDone    = true
            self.ignoreF1Changes  = false
            -- Give the game 1 s to finish its own initialization calls before
            -- reacting to F1 visibility changes. Without this, game-triggered
            -- setInputHelpVisible/setVisible calls fired right after post-init
            -- would advance the toggle state machine as if the user pressed F1.
            self.postInitCooldown = 1000
            log("Post-init state=%d wantF1=%s EHM=%s",
                self.toggleState, tostring(wantF1), tostring(self.isVisible))
        end
        return  -- don't process anything else during the init window
    end

    -- Post-init cooldown: absorb spurious game F1 calls for 1 s after spawn.
    -- Runs unconditionally (not gated on isVisible) so it always expires
    -- even if EHM starts hidden.
    if self.postInitCooldown > 0 then
        self.postInitCooldown = self.postInitCooldown - dt
    end

    -- (Context-switch F1 suppression removed in v1.11.1.0; no longer
    -- needed since the hooks don't advance the cycle.)

    -- Defensive: keep native F1 hidden whenever EHM should be the display.
    -- Our setVisible hook (line ~1610) catches calls that go through the
    -- normal path, but some FS25 screens (the construction screen is the
    -- known offender) set inputHelp.isVisible = true directly on exit,
    -- bypassing setVisible entirely. Result: native F1 leaks over EHM
    -- until the player F1-cycles. Polling the flag each frame and forcing
    -- it back to false fixes that without needing a per-screen hook.
    --
    -- Gated on spawnInitDone + postInitCooldown == 0 so we don't fight
    -- FS25's own initialization sequence during the first second after
    -- loadMap (during which the game may legitimately set isVisible=true
    -- as part of tutorial flow / spawn defaults).
    if self.spawnInitDone and self.postInitCooldown <= 0 then
        pcall(function()
            if g_currentMission == nil or g_currentMission.hud == nil then return end
            local ih = g_currentMission.hud.inputHelp
            if ih == nil then return end
            local showBaseGameHelp = self.settings ~= nil
                and self.settings.showBaseGameHelp == true
            local shouldNativeShow
            if not showBaseGameHelp then
                shouldNativeShow = false   -- EHM is the display; native always hidden
            else
                shouldNativeShow = (self.toggleState == 0)  -- state 0 = native visible
            end
            if not shouldNativeShow and ih.isVisible == true then
                ih.isVisible = false
            end
        end)
    end

    -- DOF blur fade — runs unconditionally so fade-out completes even if
    -- the player closes EHM while filter mode is still fading out.
    if self.dofFading == "in" then
        self.dofBlendAlpha = math.min(1, self.dofBlendAlpha + dt / DOF_FADE_IN_MS)
        self:applyDOFBlend()
        if self.dofBlendAlpha >= 1 then self.dofFading = "none" end
    elseif self.dofFading == "out" then
        self.dofBlendAlpha = math.max(0, self.dofBlendAlpha - dt / DOF_FADE_OUT_MS)
        self:applyDOFBlend()
        if self.dofBlendAlpha <= 0 then
            self.dofFading = "none"
            if g_depthOfFieldManager ~= nil then
                pcall(function()
                    g_depthOfFieldManager:popArea()
                    g_depthOfFieldManager:applyInfo(g_depthOfFieldManager.defaultState)
                end)
            end
        end
    end

    if self.isVisible then
        -- G-press detection: poll the active selectable every frame while in vehicle.
        -- When G cycles to a new selectable, gPressSelectableChange is set so the
        -- next rebuild skips the departedAnimState grace period — actions that return
        -- on the new selectable are treated as genuinely new and get highlighted.
        -- Also cancels the warmup timer so highlights aren't suppressed.
        -- Only fires when the selectable index actually changes (not on every frame).
        if self.currentContextName ~= nil
           and self.currentContextName ~= "PLAYER"
           and not isMenuContext(self.currentContextName) then
            local newSelIdx = getActiveSelectableIdx()
            if newSelIdx ~= 0 and newSelIdx ~= self.currentSelectableIdx then
                if self.currentSelectableIdx ~= 0 then
                    -- Real G press (not initial entry): enable re-highlighting.
                    log("G-press: selectable %d → %d (clearing departure grace for re-highlight)",
                        self.currentSelectableIdx, newSelIdx)
                    self.gPressSelectableChange = true
                    self.warmupTimer  = 0      -- cancel warmup so highlights aren't suppressed
                    self.refreshTimer = 0      -- rebuild soon to capture the departure cleanly
                end
                self.currentSelectableIdx = newSelIdx
            end
        end

        -- Warmup timer: suppress new-action detection briefly after spawn
        -- so late-registering mod actions don't cause a false flash.
        if (self.warmupTimer or 0) > 0 then
            self.warmupTimer = self.warmupTimer - dt
        end

        -- Per-action animation updates.
        -- shiftOffset: exponential ease-out toward 0 (reaches ~1% of start in 200ms).
        -- fadeAlpha:   linear 0→1 over 200ms for newly inserted rows.
        -- accentPhase: phase machine — delay → fadein → hold → fadeout → done.
        for _, anim in pairs(self.animState) do
            if anim.shiftOffset ~= 0 then
                anim.shiftOffset = anim.shiftOffset * math.exp(-ANIM_SHIFT_DECAY * dt)
                if math.abs(anim.shiftOffset) < 0.0003 then anim.shiftOffset = 0 end
            end
            if anim.fadeAlpha < 1 then
                anim.fadeAlpha = math.min(1, anim.fadeAlpha + ANIM_FADE_SPEED * dt)
            end
            anim.accentTimer = anim.accentTimer - dt
            if anim.accentPhase == "delay" then
                if anim.accentTimer <= 0 then
                    anim.accentPhase = "fadein"
                    anim.accentTimer = ANIM_ACCENT_FADEIN
                end
            elseif anim.accentPhase == "fadein" then
                anim.accentAlpha = math.max(0, 1 - anim.accentTimer / ANIM_ACCENT_FADEIN)
                if anim.accentTimer <= 0 then
                    anim.accentAlpha = 1
                    anim.accentPhase = "hold"
                    anim.accentTimer = ANIM_ACCENT_HOLD
                end
            elseif anim.accentPhase == "hold" then
                if anim.accentTimer <= 0 then
                    anim.accentPhase = "fadeout"
                    anim.accentTimer = ANIM_ACCENT_FADEOUT
                end
            elseif anim.accentPhase == "fadeout" then
                anim.accentAlpha = math.max(0, anim.accentTimer / ANIM_ACCENT_FADEOUT)
                if anim.accentTimer <= 0 then
                    anim.accentAlpha  = 0
                    anim.accentPhase  = "done"
                    anim.accentTimer  = 0
                end
            end
        end

        -- Extra text bar animation — same phase machine as action accent bars.
        -- Only triggered when extra text appears from nothing (see draw()).
        self.extraTextAccentTimer = self.extraTextAccentTimer - dt
        if self.extraTextAccentPhase == "delay" then
            if self.extraTextAccentTimer <= 0 then
                self.extraTextAccentPhase = "fadein"
                self.extraTextAccentTimer = ANIM_ACCENT_FADEIN
            end
        elseif self.extraTextAccentPhase == "fadein" then
            self.extraTextAccentAlpha = math.max(0, 1 - self.extraTextAccentTimer / ANIM_ACCENT_FADEIN)
            if self.extraTextAccentTimer <= 0 then
                self.extraTextAccentAlpha = 1
                self.extraTextAccentPhase = "hold"
                self.extraTextAccentTimer = ANIM_ACCENT_HOLD
            end
        elseif self.extraTextAccentPhase == "hold" then
            if self.extraTextAccentTimer <= 0 then
                self.extraTextAccentPhase = "fadeout"
                self.extraTextAccentTimer = ANIM_ACCENT_FADEOUT
            end
        elseif self.extraTextAccentPhase == "fadeout" then
            self.extraTextAccentAlpha = math.max(0, self.extraTextAccentTimer / ANIM_ACCENT_FADEOUT)
            if self.extraTextAccentTimer <= 0 then
                self.extraTextAccentAlpha = 0
                self.extraTextAccentPhase = "done"
                self.extraTextAccentTimer = 0
            end
        end

        -- Extra-text block height + alpha animation. Eased exponentially toward
        -- xtTargetH (set each frame in draw() based on current numExtra). The decay
        -- rate is asymmetric: slower for expand (150ms), snappier for retract (100ms).
        -- xtDisplayAlpha rides alongside on the same envelope so text and separator
        -- fade in/out in lockstep with the height. Same self-correcting structure as
        -- the per-action shiftOffset animation, so a target change mid-flight (e.g.
        -- 1->2 texts while still expanding) gracefully redirects without snapping.
        do
            local diff = self.xtTargetH - self.xtBlockH
            if math.abs(diff) > 0.0001 then
                local decay = (diff > 0) and XT_HEIGHT_DECAY_IN or XT_HEIGHT_DECAY_OUT
                self.xtBlockH = self.xtBlockH + diff * (1 - math.exp(-decay * dt))
                if math.abs(self.xtTargetH - self.xtBlockH) < 0.0001 then
                    self.xtBlockH = self.xtTargetH
                end
            end
            local alphaTarget = (self.xtTargetH > 0) and 1 or 0
            local adiff = alphaTarget - self.xtDisplayAlpha
            if math.abs(adiff) > 0.001 then
                local adecay = (adiff > 0) and XT_HEIGHT_DECAY_IN or XT_HEIGHT_DECAY_OUT
                self.xtDisplayAlpha = self.xtDisplayAlpha + adiff * (1 - math.exp(-adecay * dt))
                if math.abs(alphaTarget - self.xtDisplayAlpha) < 0.001 then
                    self.xtDisplayAlpha = alphaTarget
                end
            end
        end

        -- Detect context changes every frame so the display updates within one
        -- frame of the switch rather than waiting up to 500ms for the timer.
        local currentCtx = g_inputBinding ~= nil
            and g_inputBinding:getContextName() or "PLAYER"
        if currentCtx ~= self.lastKnownCtx then
            self.lastKnownCtx = currentCtx
            self:rebuild()
            self.refreshTimer = REFRESH_INTERVAL
            -- Note: silentRebuild + warmupTimer for context switches are set
            -- centrally in handlePrevActiveOnSwitch (called from rebuild()).
        else
            self.refreshTimer = self.refreshTimer - dt
            if self.refreshTimer <= 0 then
                self.refreshTimer = REFRESH_INTERVAL
                self:rebuild()
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Rendering Helpers
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:setColor(col, a)
    setTextColor(col[1], col[2], col[3], a or col[4] or 1)
end

-- Renders right-aligned text anchored at x (text extends leftward from x).
function EnhancedHelpMenu:textRight(x, y, size, str, col, a)
    str = tostring(str or "")
    if setTextAlignment ~= nil and RenderText ~= nil then
        setTextAlignment(RenderText.ALIGN_RIGHT)
        self:setColor(col or COL_WHITE, a)
        renderText(x, y, size, str)
        setTextColor(1, 1, 1, 1)
        if RenderText.ALIGN_LEFT ~= nil then setTextAlignment(RenderText.ALIGN_LEFT) end
    else
        self:setColor(col or COL_WHITE, a)
        renderText(x, y, size, str)
        setTextColor(1, 1, 1, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Overlay Init — deferred to first draw() to guarantee rendering pipeline ready
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:initOverlays()
    if self.overlaysDone then return end
    self.overlaysDone = true

    if createImageOverlay == nil then
        warn("initOverlays: createImageOverlay not available — falling back to flat rects")
        return
    end

    local rowTex  = MOD_DIR .. "textures/ehm_row_bg.dds"
    local pillTex = MOD_DIR .. "textures/ehm_pill_bg.dds"
    dbg("initOverlays texture paths: rowTex=%s pillTex=%s", rowTex, pillTex)

    -- Row: 3-strip
    self.ovRowL = createImageOverlay(rowTex)
    self.ovRowC = createImageOverlay(rowTex)
    self.ovRowR = createImageOverlay(rowTex)
    -- Pill: 3-strip
    self.ovKeyL = createImageOverlay(pillTex)
    self.ovKeyC = createImageOverlay(pillTex)
    self.ovKeyR = createImageOverlay(pillTex)
    -- Header: 9-slice using the row texture so corners are pixel-perfect at any
    -- header height. 4 corners (fixed size) + 4 edges (stretch one axis) +
    -- drawFilledRect center. Replaces the old single-texture 3-strip approach
    -- which caused corners to grow when the header expanded (filter open).
    self.ovHdrTL = createImageOverlay(rowTex)  -- top-left  corner
    self.ovHdrTC = createImageOverlay(rowTex)  -- top       edge
    self.ovHdrTR = createImageOverlay(rowTex)  -- top-right corner
    self.ovHdrML = createImageOverlay(rowTex)  -- left      edge
    self.ovHdrMR = createImageOverlay(rowTex)  -- right     edge
    self.ovHdrBL = createImageOverlay(rowTex)  -- bot-left  corner
    self.ovHdrBC = createImageOverlay(rowTex)  -- bot       edge
    self.ovHdrBR = createImageOverlay(rowTex)  -- bot-right corner

    dbg("initOverlays IDs: rowL=%s rowC=%s rowR=%s keyL=%s keyC=%s keyR=%s hdrTL=%s",
        tostring(self.ovRowL), tostring(self.ovRowC), tostring(self.ovRowR),
        tostring(self.ovKeyL), tostring(self.ovKeyC), tostring(self.ovKeyR),
        tostring(self.ovHdrTL))

    if self.ovRowL and self.ovRowC and self.ovRowR
    and self.ovKeyL and self.ovKeyC and self.ovKeyR
    and self.ovHdrTL and self.ovHdrTC and self.ovHdrTR
    and self.ovHdrML and self.ovHdrMR
    and self.ovHdrBL and self.ovHdrBC and self.ovHdrBR then
        -- Row bg (256×32): native 6px end cap → UV cap = 6/256 = 0.023438
        setOverlayUVs(self.ovRowL, 0.0,      0.0, 0.0,      1.0, 0.023438, 0.0, 0.023438, 1.0)
        setOverlayUVs(self.ovRowC, 0.023438, 0.0, 0.023438, 1.0, 0.976562, 0.0, 0.976562, 1.0)
        setOverlayUVs(self.ovRowR, 0.976562, 0.0, 0.976562, 1.0, 1.0,      0.0, 1.0,      1.0)
        -- Key pill (64×32): native 6px end cap → UV cap = 6/64 = 0.093750
        setOverlayUVs(self.ovKeyL, 0.0,      0.0, 0.0,      1.0, 0.093750, 0.0, 0.093750, 1.0)
        setOverlayUVs(self.ovKeyC, 0.093750, 0.0, 0.093750, 1.0, 0.906250, 0.0, 0.906250, 1.0)
        setOverlayUVs(self.ovKeyR, 0.906250, 0.0, 0.906250, 1.0, 1.0,      0.0, 1.0,      1.0)
        -- Header 9-slice using the row texture (256×32, radius=8px).
        -- UV x split: 8/256 = 0.031250. UV y split: 8/32 = 0.250000.
        -- Corner pieces: fixed size in both axes.
        -- Edge pieces: stretch in one axis only. Center: drawFilledRect.
        -- Format: setOverlayUVs(id, bl_u,bl_v, tl_u,tl_v, br_u,br_v, tr_u,tr_v)
        local ux, uy = ROW_UV_X, ROW_UV_Y
        -- TL corner (UV: x=0..ux, y=(1-uy)..1)
        setOverlayUVs(self.ovHdrTL, 0,    1-uy, 0,    1,    ux,   1-uy, ux,   1   )
        -- TC top edge (UV: x=ux..(1-ux), y=(1-uy)..1)
        setOverlayUVs(self.ovHdrTC, ux,   1-uy, ux,   1,    1-ux, 1-uy, 1-ux, 1   )
        -- TR corner (UV: x=(1-ux)..1, y=(1-uy)..1)
        setOverlayUVs(self.ovHdrTR, 1-ux, 1-uy, 1-ux, 1,    1,    1-uy, 1,    1   )
        -- ML left edge (UV: x=0..ux, y=uy..(1-uy))
        setOverlayUVs(self.ovHdrML, 0,    uy,   0,    1-uy, ux,   uy,   ux,   1-uy)
        -- MR right edge (UV: x=(1-ux)..1, y=uy..(1-uy))
        setOverlayUVs(self.ovHdrMR, 1-ux, uy,   1-ux, 1-uy, 1,    uy,   1,    1-uy)
        -- BL corner (UV: x=0..ux, y=0..uy)
        setOverlayUVs(self.ovHdrBL, 0,    0,    0,    uy,   ux,   0,    ux,   uy  )
        -- BC bottom edge (UV: x=ux..(1-ux), y=0..uy)
        setOverlayUVs(self.ovHdrBC, ux,   0,    ux,   uy,   1-ux, 0,    1-ux, uy  )
        -- BR corner (UV: x=(1-ux)..1, y=0..uy)
        setOverlayUVs(self.ovHdrBR, 1-ux, 0,    1-ux, uy,   1,    0,    1,    uy  )
        self.overlaysReady = true
        log("initOverlays: SUCCESS — rounded corners active")
    else
        warn("initOverlays: FAILED — one or more overlay IDs are nil, falling back to flat rects")
    end

    -- Eye icons (Stage 2 hide/un-hide UI). Loaded independently of the slice
    -- overlays above — they don't need UV setup, and the panel still works if
    -- they fail to load. The row-draw code nil-checks ovEyeOpen / ovEyeHidden
    -- before rendering, so a load failure simply means no icons in filter mode.
    local eyeOpenTex   = MOD_DIR .. "textures/ehm_eye_open.dds"
    local eyeHiddenTex = MOD_DIR .. "textures/ehm_eye_hidden.dds"
    self.ovEyeOpen   = createImageOverlay(eyeOpenTex)
    self.ovEyeHidden = createImageOverlay(eyeHiddenTex)
    log("initOverlays: eye icons %s",
        (self.ovEyeOpen ~= nil and self.ovEyeHidden ~= nil) and "loaded" or "FAILED")
end

-- ---------------------------------------------------------------------------
-- Sprite Renderers — rounded rows and key pills using gui.png atlas
-- Falls back to drawFilledRect if overlays aren't available.
-- ---------------------------------------------------------------------------

-- Snap a horizontal/vertical normalized distance to the nearest reference-
-- pixel boundary (1 pixel = PX horizontally, PY vertically). The 3-strip /
-- 9-slice rendering paths sample texture pixels through a normalized UV; a
-- non-integer pixel cap (e.g. ROW_CAP_W * 1.25 = 7.5px) makes the bilinear
-- sampler blur across the cap-to-center seam, producing thin vertical /
-- horizontal lines visible at the panel edges when many rows stack. Snapping
-- the cap width keeps the seam on an integer pixel and eliminates the bleed.
local function snapPX(v)
    return math.floor(v / PX + 0.5) * PX
end
local function snapPY(v)
    return math.floor(v / PY + 0.5) * PY
end

function EnhancedHelpMenu:renderRow(x, y, w, h, r, g, b, a)
    local scale = self.uiScale or 1
    if self.overlaysReady then
        local c = snapPX(ROW_CAP_W * scale)
        setOverlayColor(self.ovRowL, r,g,b,a); renderOverlay(self.ovRowL, x,     y, c,     h)
        setOverlayColor(self.ovRowC, r,g,b,a); renderOverlay(self.ovRowC, x+c,   y, w-c*2, h)
        setOverlayColor(self.ovRowR, r,g,b,a); renderOverlay(self.ovRowR, x+w-c, y, c,     h)
    else
        -- Fallback: 3-rect approximate rounded rectangle
        local R = math.min(CORNER_R * scale, h * 0.45)
        drawFilledRect(x+R,   y,   w-R*2, h,     r, g, b, a)
        drawFilledRect(x,     y+R, R,     h-R*2, r, g, b, a)
        drawFilledRect(x+w-R, y+R, R,     h-R*2, r, g, b, a)
    end
end

function EnhancedHelpMenu:renderKey(x, y, w, h, r, g, b, a)
    local scale = self.uiScale or 1
    if self.overlaysReady then
        local c = snapPX(KEY_CAP_W * scale)
        setOverlayColor(self.ovKeyL, r,g,b,a); renderOverlay(self.ovKeyL, x,     y, c,     h)
        setOverlayColor(self.ovKeyC, r,g,b,a); renderOverlay(self.ovKeyC, x+c,   y, w-c*2, h)
        setOverlayColor(self.ovKeyR, r,g,b,a); renderOverlay(self.ovKeyR, x+w-c, y, c,     h)
    else
        local R = math.min(PILL_R * scale, h * 0.45)
        drawFilledRect(x+R,   y,   w-R*2, h,     r, g, b, a)
        drawFilledRect(x,     y+R, R,     h-R*2, r, g, b, a)
        drawFilledRect(x+w-R, y+R, R,     h-R*2, r, g, b, a)
    end
end

-- Header: true 9-slice so corner radius stays constant regardless of header height.
-- 4 corner pieces (fixed c × ch), 4 edge pieces (stretch one axis), 1 center fill.
function EnhancedHelpMenu:renderHeader(x, y, w, h, r, g, b, a)
    local scale = self.uiScale or 1
    if self.overlaysReady then
        local c  = snapPX(ROW_CAP_W * scale)  -- horizontal cap (~8px @ 1.0 scale), snapped
        local ch = snapPY(HDR_CAP_H * scale)  -- vertical cap (~6px @ 1.0 scale), snapped
        local function rc(ov) setOverlayColor(ov, r, g, b, a) end
        -- Corners (fixed size)
        rc(self.ovHdrTL); renderOverlay(self.ovHdrTL, x,       y+h-ch, c,     ch    )
        rc(self.ovHdrTR); renderOverlay(self.ovHdrTR, x+w-c,   y+h-ch, c,     ch    )
        rc(self.ovHdrBL); renderOverlay(self.ovHdrBL, x,       y,      c,     ch    )
        rc(self.ovHdrBR); renderOverlay(self.ovHdrBR, x+w-c,   y,      c,     ch    )
        -- Edges (stretch one axis)
        rc(self.ovHdrTC); renderOverlay(self.ovHdrTC, x+c,     y+h-ch, w-c*2, ch    )
        rc(self.ovHdrBC); renderOverlay(self.ovHdrBC, x+c,     y,      w-c*2, ch    )
        rc(self.ovHdrML); renderOverlay(self.ovHdrML, x,       y+ch,   c,     h-ch*2)
        rc(self.ovHdrMR); renderOverlay(self.ovHdrMR, x+w-c,   y+ch,   c,     h-ch*2)
        -- Center fill (opaque, same color)
        drawFilledRect(x+c, y+ch, w-c*2, h-ch*2, r, g, b, a)
    else
        -- Fallback: simple rounded rect approximation
        local R = math.min(CORNER_R * scale, h * 0.45)
        drawFilledRect(x+R,   y,   w-R*2, h,     r,g,b,a)
        drawFilledRect(x,     y+R, R,     h-R*2, r,g,b,a)
        drawFilledRect(x+w-R, y+R, R,     h-R*2, r,g,b,a)
    end
end

-- ---------------------------------------------------------------------------
-- Key Pill Helpers
-- ---------------------------------------------------------------------------

-- Returns the approximate rendered width of a string at given size.
local function safeTextWidth(size, str)
    if getTextWidth ~= nil then return getTextWidth(size, str) end
    return size * #str * 0.55
end

-- (v1.12.0.0 introduced a getVanillaPlusOverlay() helper that pulled
-- vanilla's bitmap "+" glyph from g_inputDisplayManager.plusOverlay
-- for use in drawBindingPills. Reverted in v1.12.0.1 -- the bitmap
-- visually dominated the row and clashed with EHM's flat-pill
-- aesthetic. Bold text "+" is the current approach. See
-- version_logs/1.12.0.0.md if the vanilla-overlay idea ever needs to
-- be revisited.)

-- Draws a single key pill with left edge at lx, bottom at botY.
-- Returns the right edge x of the drawn pill.
--
-- Reads self.uiScale (set by draw() each frame) and scales every geometry
-- constant the body uses. Same pattern in drawPillRight / drawHeaderPill /
-- drawBindingPills / measureBindingWidth -- the helpers can't see draw()'s
-- shadowed locals, so each one shadows them locally from the same single
-- scale source.
function EnhancedHelpMenu:drawPill(lx, botY, text, alpha)
    alpha = alpha or 1.0
    local scale = self.uiScale or 1
    local ROW_H, SIZE_TEXT, KEY_PAD_X, KEY_CAP_W, TEXT_OY =
        ROW_H * scale, SIZE_TEXT * scale, KEY_PAD_X * scale, KEY_CAP_W * scale, TEXT_OY * scale
    local pillH = ROW_H
    local tw    = safeTextWidth(SIZE_TEXT, text)
    local pillW = math.max(tw + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    self:renderKey(lx, botY, pillW, pillH,
        COL_BG_KEY[1], COL_BG_KEY[2], COL_BG_KEY[3], COL_BG_KEY[4] * alpha)
    self:setColor(COL_WHITE, alpha)
    renderText(lx + KEY_PAD_X, botY + TEXT_OY, SIZE_TEXT, text)
    if setTextBold ~= nil then setTextBold(false) end
    return lx + pillW
end

-- Draws a key pill right-anchored at rx. Returns the left edge x.
function EnhancedHelpMenu:drawPillRight(rx, botY, text, alpha)
    local scale = self.uiScale or 1
    local SIZE_TEXT, KEY_PAD_X, KEY_CAP_W =
        SIZE_TEXT * scale, KEY_PAD_X * scale, KEY_CAP_W * scale
    local tw    = safeTextWidth(SIZE_TEXT, text)
    local pillW = math.max(tw + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    self:drawPill(rx - pillW, botY, text, alpha)
    return rx - pillW
end

-- Draws a single header key pill (bold, white text) left-anchored at lx.
-- Returns the right edge x. isSelected = lighter white fill (device name pill, FILTER when open).
function EnhancedHelpMenu:drawHeaderPill(lx, botY, text, isSelected)
    local scale = self.uiScale or 1
    local ROW_H, SIZE_TEXT, KEY_PAD_X, KEY_CAP_W, TEXT_OY =
        ROW_H * scale, SIZE_TEXT * scale, KEY_PAD_X * scale, KEY_CAP_W * scale, TEXT_OY * scale
    local pillH = ROW_H
    local tw    = safeTextWidth(SIZE_TEXT, text)
    local pillW = math.max(tw + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    if isSelected then
        self:renderKey(lx, botY, pillW, pillH,
            COL_SEL_PILL[1], COL_SEL_PILL[2], COL_SEL_PILL[3], COL_SEL_PILL[4])
    else
        self:renderKey(lx, botY, pillW, pillH,
            COL_BG_KEY[1], COL_BG_KEY[2], COL_BG_KEY[3], COL_BG_KEY[4])
    end
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(lx + KEY_PAD_X, botY + TEXT_OY, SIZE_TEXT, text)
    if setTextBold ~= nil then setTextBold(false) end
    return lx + pillW
end

-- Splits a binding string into groups of keys.
-- "LSHIFT + TAB" → {{"LSHIFT","TAB"}}
-- "1  |  2"      → {{"1"},{"2"}}
-- "LSHIFT + F  |  BTN 5" → {{"LSHIFT","F"},{"BTN 5"}}
local function splitBinding(binding)
    local groups = {}
    -- split on "  |  " (alternate bindings)
    local s = binding
    while true do
        local i = s:find("  |  ", 1, true)
        if i then
            table.insert(groups, s:sub(1, i-1))
            s = s:sub(i + 5)
        else
            table.insert(groups, s)
            break
        end
    end
    -- split each group on " + " (combo keys)
    local result = {}
    for _, g in ipairs(groups) do
        local keys = {}
        local gs = g
        while true do
            local j = gs:find(" + ", 1, true)
            if j then
                table.insert(keys, gs:sub(1, j-1))
                gs = gs:sub(j + 3)
            else
                table.insert(keys, gs)
                break
            end
        end
        table.insert(result, keys)
    end
    return result
end

-- Draws all binding pills for an action row, right-anchored at rx.
-- Handles combos (LSHIFT + TAB) and alternates (1  |  2).
function EnhancedHelpMenu:drawBindingPills(rx, botY, binding, alpha)
    alpha = alpha or 1.0
    local scale = self.uiScale or 1
    local SIZE_TEXT, SEP_PAD, ROW_H, TEXT_OY =
        SIZE_TEXT * scale, SEP_PAD * scale, ROW_H * scale, TEXT_OY * scale
    local groups = splitBinding(binding)
    -- Separator flow widths -- visible element + symmetric padding on each
    -- side. v1.12.0.2 refactor: previously sepW used `safeTextWidth("|")`
    -- as part of the flow even though we draw a custom 2px line instead
    -- of rendering the "|" character, which made the centering math
    -- depend on a glyph-shape width that wasn't actually being drawn.
    -- The drawn line is now centered in exactly `lineW + SEP_PAD * 2`,
    -- guaranteeing equal padding on both sides.
    --
    -- Both separators use SEP_PAD * 2 (one full pad per side) for a bit
    -- of breathing room against the adjacent pills.
    local sepLineW = math.max(2 * PX, 0.000521 * 2)        -- ~2px wide
    local sepLineH = ROW_H * 0.70                           -- 70% of row height
    local sepW     = sepLineW + SEP_PAD * 2
    -- Chord "+" rendered as bold text (since v1.12.0.1). Vanilla's bitmap
    -- icon (v1.12.0.0 attempt) clashed with EHM's flat-pill aesthetic.
    if setTextBold ~= nil then setTextBold(true) end
    local plusTextW = safeTextWidth(SIZE_TEXT, "+")
    if setTextBold ~= nil then setTextBold(false) end
    local plusW = plusTextW + SEP_PAD * 2
    local cx = rx
    -- draw right-to-left
    for gi = #groups, 1, -1 do
        local keys = groups[gi]
        for ki = #keys, 1, -1 do
            cx = self:drawPillRight(cx, botY, keys[ki], alpha)
            if ki > 1 then
                -- "+" between chord keys -- bold, full alpha, vertically
                -- centered. Left-padded by SEP_PAD inside the plusW flow
                -- so the glyph sits with symmetric breathing room.
                cx = cx - plusW
                if setTextBold ~= nil then setTextBold(true) end
                self:setColor(COL_SEP_PLUS, COL_SEP_PLUS[4] * alpha)
                renderText(cx + SEP_PAD, botY + TEXT_OY, SIZE_TEXT, "+")
                if setTextBold ~= nil then setTextBold(false) end
            end
        end
        if gi > 1 then
            -- "|" between binding groups -- 2px drawn line, 70% row
            -- height, 0.65 alpha (alpha back to original after the
            -- 0.85 of v1.12.0.0 read as too stark; size bumps kept).
            cx = cx - sepW
            local lineX = cx + SEP_PAD                          -- exactly SEP_PAD on each side
            local lineY = botY + (ROW_H - sepLineH) * 0.5       -- vertically centered in row
            drawFilledRect(lineX, lineY, sepLineW, sepLineH,
                COL_SEP_LINE[1], COL_SEP_LINE[2], COL_SEP_LINE[3], COL_SEP_LINE[4] * alpha)
        end
    end
end

-- Reconstructs a binding string from a list of group tables.
-- Inverse of splitBinding — produces a string that splitBinding will parse back
-- to the same groups. Used to pass partial group lists to drawBindingPills.
local function groupsToBinding(groups)
    local parts = {}
    for _, keys in ipairs(groups) do
        table.insert(parts, table.concat(keys, " + "))
    end
    return table.concat(parts, "  |  ")
end

-- Returns the largest byte index <= n at which `s` can be cut without splitting
-- a multi-byte UTF-8 character. UTF-8 continuation bytes are 0x80-0xBF; if the
-- byte just past the cut is one, the cut is mid-character, so back up.
local function utf8SafeCut(s, n)
    if n >= #s then return #s end
    while n > 0 do
        local b = s:byte(n + 1)
        if b == nil or b < 128 or b >= 192 then break end
        n = n - 1
    end
    return n
end

-- Truncates labelText so it fits within maxW, appending "..." using binary
-- search. The cut is snapped to a UTF-8 character boundary so a multi-byte
-- character (e.g. a German umlaut) is never split into a garbled glyph.
--
-- Reads EnhancedHelpMenu.uiScale (set by draw() each frame). Local-function
-- helpers can't take `self`, so they pull the live scale from the module
-- global. Same pattern in drawStrikeThrough / computeRowLayout below.
local function truncateLabel(labelText, maxW)
    local scale = (EnhancedHelpMenu and EnhancedHelpMenu.uiScale) or 1
    local SIZE_TEXT = SIZE_TEXT * scale
    local ellipsis = "..."
    local ellW = safeTextWidth(SIZE_TEXT, ellipsis)
    local lo, hi = 0, #labelText
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if safeTextWidth(SIZE_TEXT, string.sub(labelText, 1, mid)) + ellW <= maxW then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return string.sub(labelText, 1, utf8SafeCut(labelText, lo)) .. ellipsis
end

-- Draws a thin horizontal strike-through line over uppercase label text.
-- baselineY is the renderText y-coordinate (text baseline). The line is placed
-- 30% of SIZE_TEXT above the baseline, which lands through the visual middle
-- of cap-height letters. Width matches the rendered label width exactly so the
-- line stops at the last character (or at the trailing ellipsis on truncated labels).
-- Used to mark hidden rows in filter mode.
local function drawStrikeThrough(leftX, baselineY, text, alpha)
    local scale = (EnhancedHelpMenu and EnhancedHelpMenu.uiScale) or 1
    local SIZE_TEXT = SIZE_TEXT * scale
    local w = safeTextWidth(SIZE_TEXT, text)
    drawFilledRect(leftX, baselineY + SIZE_TEXT * 0.30,
        w, 1 * PY,
        COL_WHITE[1], COL_WHITE[2], COL_WHITE[3], alpha)
end

-- Computes the row layout descriptor for a single action item.
-- Called once per action per rebuild cycle; results are cached in rowLayoutCache.
--
-- Single row (isDouble=false):
--   { labelText, displayBinding }
--
-- Double row (isDouble=true): label on row 1, pills split across rows 1 and 2.
--   { labelText, row1Binding, row2Binding }
--   row1Binding: pills beside the label on row 1 (may be nil if none fit)
--   row2Binding: remaining pills on row 2, right-anchored (may be nil)
local function computeRowLayout(item, contentW, ehm)
    local scale = (ehm and ehm.uiScale) or 1
    local SIZE_TEXT, LABEL_GAP, SEP_PAD =
        SIZE_TEXT * scale, LABEL_GAP * scale, SEP_PAD * scale
    local labelText = string.upper(item.label)
    local labelW    = safeTextWidth(SIZE_TEXT, labelText)

    local displayBinding = item.binding
    local bindW  = displayBinding ~= nil and ehm:measureBindingWidth(displayBinding) or 0
    local totalW = labelW + LABEL_GAP + bindW

    -- Fast path: everything fits on one row
    if totalW <= contentW then
        return { isDouble=false, labelText=labelText,
                 displayBinding=displayBinding }
    end

    -- Overflow — needs two rows.
    -- Greedily fill row 1 with complete binding groups alongside label.
    -- Groups that don't fit move to row 2. A group is never split mid-combo.
    local groups = displayBinding ~= nil and splitBinding(displayBinding) or {}
    local sepW   = safeTextWidth(SIZE_TEXT, "|") + SEP_PAD
    local r1G, r2G = {}, {}
    local r1W, r1Available = 0, contentW - labelW - LABEL_GAP
    for gi, keys in ipairs(groups) do
        local gW   = ehm:measureBindingWidth(table.concat(keys, " + "))
        local cost = r1W > 0 and (sepW + gW) or gW  -- separator only from 2nd group
        if r1W + cost <= r1Available then
            table.insert(r1G, keys)
            r1W = r1W + cost
        else
            for j = gi, #groups do table.insert(r2G, groups[j]) end
            break
        end
    end

    if labelW > contentW then labelText = truncateLabel(labelText, contentW) end

    return {
        isDouble    = true,
        labelText   = labelText,
        row1Binding = #r1G > 0 and groupsToBinding(r1G) or nil,
        row2Binding = #r2G > 0 and groupsToBinding(r2G) or nil,
    }
end
function EnhancedHelpMenu:measureBindingWidth(binding)
    if binding == nil then return 0 end
    local scale = self.uiScale or 1
    local SIZE_TEXT, SEP_PAD, KEY_PAD_X, KEY_CAP_W =
        SIZE_TEXT * scale, SEP_PAD * scale, KEY_PAD_X * scale, KEY_CAP_W * scale
    local groups = splitBinding(binding)
    -- Match drawBindingPills's flow widths: visible element + 2*SEP_PAD.
    local sepLineW = math.max(2 * PX, 0.000521 * 2)
    local sepW  = sepLineW + SEP_PAD * 2
    if setTextBold ~= nil then setTextBold(true) end
    local plusW = safeTextWidth(SIZE_TEXT, "+") + SEP_PAD * 2
    if setTextBold ~= nil then setTextBold(false) end
    local total = 0
    for gi, keys in ipairs(groups) do
        for ki, key in ipairs(keys) do
            local tw    = safeTextWidth(SIZE_TEXT, key)
            local pillW = math.max(tw + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
            total = total + pillW
            if ki > 1 then total = total + plusW end
        end
        if gi > 1 then total = total + sepW end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Work-mode status
--
-- Surfaces the current work mode of any attached implement (the `WorkMode`
-- vehicle specialization) as status text. Native F1 shows this as a "MODE: ..."
-- row via a HUD help-extension; EHM instead reads the spec state directly and
-- feeds it into the extra-text block — it is status text, not a key binding,
-- so it belongs with the extra-text block, not the action-row list.
--
-- Current mode = spec_workMode.workModes[spec_workMode.state].name; `.name` is
-- already l10n-resolved. All FS25 access is pcall-wrapped.
-- Returns a list of status strings, or nil if there is none.
-- ---------------------------------------------------------------------------
function EnhancedHelpMenu:getWorkModeStatus()
    local lines = nil
    pcall(function()
        if g_currentMission == nil then return end
        local ih = g_currentMission.hud and g_currentMission.hud.inputHelp
        local vehicle = ih ~= nil and ih.vehicle or nil
        if vehicle == nil then return end

        -- Walk the controlled vehicle + every implement in its attach tree.
        local chain = {}
        local function collect(v, depth)
            if v == nil or depth > 8 then return end
            chain[#chain + 1] = v
            if v.getAttachedImplements ~= nil then
                for _, impl in ipairs(v:getAttachedImplements()) do
                    if impl.object ~= nil then collect(impl.object, depth + 1) end
                end
            end
        end
        collect(vehicle, 0)

        for _, v in ipairs(chain) do
            local spec = v.spec_workMode
            if spec ~= nil and spec.state ~= nil and spec.workModes ~= nil
               and (spec.stateMax or 0) > 0 then
                local mode = spec.workModes[spec.state]
                if mode ~= nil and mode.name ~= nil and mode.name ~= "" then
                    lines = lines or {}
                    -- action_workModeSelected is itself a format string ("Mode: %s") --
                    -- substitute the mode name into it, do not treat it as a plain label.
                    lines[#lines + 1] = string.format(l10n("action_workModeSelected", "Mode: %s"), mode.name)
                end
            end
        end
    end)
    return lines
end

-- ---------------------------------------------------------------------------
-- AI-mode status
--
-- Surfaces the current AI mode (`AIModeSelection` specialization) as status
-- text, the same way getWorkModeStatus does for work modes. The mode is an
-- integer constant; its localized name comes from the game's `ai_modeWorker` /
-- `ai_modeSteeringAssist` l10n keys, formatted with `action_aiModeSelected`
-- ("Mode: %s").
--
-- When a worker job is actually running, the worker's live state is appended
-- to the line ("Mode: AI Worker — Blocked"), so the status block also surfaces
-- what native's AI HUD extension shows. State comes from `spec_aiFieldWorker`
-- (field work) and `spec_aiDrivable` (navigation) — see the inline notes.
--
-- Returns two values: the status string and the hold-key binding (the key that,
-- HELD, opens the AI Settings dialog — `TOGGLE_AI`, device-filtered). Either may
-- be nil — nil binding simply means no pill is drawn. pcall-wrapped.
-- ---------------------------------------------------------------------------
function EnhancedHelpMenu:getAIModeStatus()
    local line, binding = nil, nil
    pcall(function()
        if g_currentMission == nil then return end
        local ih = g_currentMission.hud and g_currentMission.hud.inputHelp
        local vehicle = ih ~= nil and ih.vehicle or nil
        if vehicle == nil or vehicle.getAIModeSelection == nil then return end
        local MODE = AIModeSelection ~= nil and AIModeSelection.MODE or nil
        if MODE == nil then return end

        local cur = vehicle:getAIModeSelection()
        local modeKey
        if     cur == MODE.WORKER          then modeKey = "ai_modeWorker"
        elseif cur == MODE.STEERING_ASSIST then modeKey = "ai_modeSteeringAssist" end
        if modeKey == nil then return end   -- unknown / future mode

        local modeName = l10n(modeKey, modeKey)
        line = string.format(l10n("action_aiModeSelected", "Mode: %s"), modeName)

        -- When a worker job is actually running, append its live state to the
        -- mode line (e.g. "Mode: AI Worker — Working"). Four persistent states:
        --   blocked = aiFieldWorker.isBlocked (field work) OR
        --             aiDrivable.lastIsBlocked (driving to the field)
        --   turning = aiFieldWorker.isTurning — a headland turn
        --   working = aiFieldWorker.isActive — doing field work (straight run)
        --   driving = the default — driving TO the field (no field work yet)
        -- aiFieldWorker.isTurning / .isBlocked read stale-true during the
        -- drive-TO-field phase, so they are trusted only when isActive (the
        -- worker is genuinely doing field work). The navigation phase was
        -- probed: it only ever yields Driving plus a transient TARGET_REACHED
        -- on arrival — nothing extra worth a state, so Planning is not shown.
        -- "Turning"/"Working" have no game l10n keys (native folds both into
        -- Driving) — EHM supplies its own EHM_UI_TURNING / EHM_UI_WORKING.
        if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() then
            local fw = vehicle.spec_aiFieldWorker
            local dr = vehicle.spec_aiDrivable
            local fieldworking = fw ~= nil and fw.isActive == true
            local blocked = (fieldworking and fw.isBlocked == true)
                         or (dr ~= nil and dr.lastIsBlocked == true)
            local turning = fieldworking and fw.isTurning == true
            local stateName
            if     blocked      then stateName = l10n("ai_stateBlocked", "Blocked")
            elseif turning      then stateName = l10n("EHM_UI_TURNING",  "Turning")
            elseif fieldworking then stateName = l10n("EHM_UI_WORKING",  "Working")
            else                     stateName = l10n("ai_stateDriving", "Driving") end
            line = line .. " — " .. stateName
        end

        -- The AI mode is changed by HOLDING the TOGGLE_AI key (a long press opens
        -- the AI Settings dialog; a short tap toggles the worker). Surface that
        -- hold-key as a pill on the status line, matching native's AI HUD
        -- extension. Device-filtered; nil if unbound — then no pill is drawn.
        binding = self:getBindings("TOGGLE_AI")
    end)
    return line, binding
end

-- ---------------------------------------------------------------------------
-- Captured native HUD help extensions
--
-- captureHelpExtension is fed by the addHelpExtension hook installed in
-- loadMap: every native HUD help extension a vehicle spec registers (each
-- frame) is captured here instead of reaching the native InputHelpDisplay.
-- The list is cleared on the first capture of each new frame (detected via
-- g_time), so capturedExtensions always holds one complete frame's worth —
-- never a partial set — regardless of whether EHM's draw() runs before or
-- after the vehicle specs' onDraw. getReHostExtensions() then filters it.
-- ---------------------------------------------------------------------------
function EnhancedHelpMenu:captureHelpExtension(extension)
    if extension == nil then return end
    local now = g_time or 0
    if now ~= self.captureFrameTime then
        self.captureFrameTime   = now
        self.capturedExtensions = {}
    end
    self.capturedExtensions[#self.capturedExtensions + 1] = extension
end

-- Returns every captured help extension for re-hosting. EHM does NOT try to
-- identify extension types (the game exposes no reliable way to — class-name
-- lookup and metatable comparison both fail at runtime). Instead it re-hosts
-- them all and lets the draw decide: an extension EHM already mirrors
-- (WorkMode / AIMode) draws nothing when re-hosted and so consumes zero band
-- height; Precision Farming widgets draw real content and get space. The
-- band is sized by measured draw output, not by identity — see draw().
function EnhancedHelpMenu:getReHostExtensions()
    return self.capturedExtensions or {}
end

-- ---------------------------------------------------------------------------
-- Draw
--
-- FS25 coordinate system: Y=1.0 is top of screen, Y=0.0 is bottom.
-- drawFilledRect(x, y, w, h) — x,y is BOTTOM-LEFT corner.
-- renderText(x, y, size, str) — x,y is text BASELINE position.
--
-- Baseline vertical centering formula:
--   textY = panelBottomY + (panelHeight * 0.5) - (fontSize * 0.35)
--   The 0.35 factor approximates the baseline-to-cap-height ratio.
--
-- Layout (top to bottom):
--   [ SCHEMA ROW — native compact vehicle indicator (VEHICLE context only) ]
--   [ HEADER ROW 1 — action count + page left, device right               ]
--   [ HEADER ROW 2 — hint labels + key pills left, FILTER right           ]
--   [ FILTER STRIP — category toggles (when UI mode open)                 ]
--   [ EXTRA TEXTS — from addExtraPrintText() (when present)               ]
--   [ ACTION ROW 1 — label left, binding pills right                      ]
--   [ ACTION ROW 2 … up to pageSize rows (player-adjustable)              ]
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:draw()
    -- Lazy overlay init — deferred from loadMap to guarantee render pipeline ready
    self:initOverlays()

    -- Always clear extraPrintTexts regardless of visibility.
    local extraTexts     = self.extraPrintTexts
    self.extraPrintTexts = {}
    local numExtra       = #extraTexts

    if not self.isVisible then return end

    -- (No separate gate for the "Show base game F1 menu" setting here — the
    -- setting drives the cycle in onF1Changed, which drives isVisible. When
    -- the setting is ON and the cycle is at state 0, isVisible is false and
    -- the early return above catches it; native draws alone with no overlap.)

    -- ---- UI SCALE -----------------------------------------------------------
    -- Read the master HUD scale once per frame and shadow every scalable
    -- geometry constant with a scaled local of the same name. The rest of
    -- draw() then references those locals as if nothing changed, so the
    -- panel grows / shrinks alongside the player's vanilla HUD scale setting
    -- (Settings -> Display -> UI Scale) without any per-call multiplication
    -- scattered through the body. Anchors (PANEL_X, PANEL_TOP_Y) are NOT
    -- scaled -- the panel still pins to its top-left screen anchor and
    -- grows down + right, matching how native HUDs behave under scale.
    --
    -- self.uiScale is also set so the sub-renderers (renderRow / renderKey /
    -- renderHeader) can read it for their cap widths without us having to
    -- thread it through every call site.
    --
    -- Cache invalidation: rowLayoutCache entries depend on contentW, which
    -- depends on scaled PADDING_X. When the scale changes (player adjusts
    -- the setting), the cached layouts are stale -- clear them so the next
    -- pre-pass recomputes wrap / pill placement at the new width.
    local uiScale = currentUIScale()
    if uiScale ~= self.lastUIScale then
        self.rowLayoutCache = {}
        self.lastUIScale = uiScale
    end
    self.uiScale = uiScale

    local SIZE_TEXT     = SIZE_TEXT     * uiScale
    local ROW_H         = ROW_H         * uiScale
    local ROW_GAP       = ROW_GAP       * uiScale
    local TEXT_OY       = TEXT_OY       * uiScale
    local HDR_PAD       = HDR_PAD       * uiScale
    local PADDING_X     = PADDING_X     * uiScale
    local KEY_PAD_X     = KEY_PAD_X     * uiScale
    local ROW_CAP_W     = ROW_CAP_W     * uiScale
    local KEY_CAP_W     = KEY_CAP_W     * uiScale
    local CORNER_R      = CORNER_R      * uiScale
    local PILL_R        = PILL_R        * uiScale
    local HDR_CAP_H     = HDR_CAP_H     * uiScale
    local STRIP_GAP     = STRIP_GAP     * uiScale
    local SEP_PAD       = SEP_PAD       * uiScale
    local LABEL_GAP     = LABEL_GAP     * uiScale
    local ACCENT_BAR_W  = ACCENT_BAR_W  * uiScale
    local ICON_W        = ICON_W        * uiScale
    local ICON_H        = ICON_H        * uiScale
    local ICON_GAP      = ICON_GAP      * uiScale
    local PAD_TOP       = PAD_TOP       * uiScale
    local PAD_BOTTOM    = PAD_BOTTOM    * uiScale
    local INNER_ROW_GAP = INNER_ROW_GAP * uiScale
    -- ---- END UI SCALE -------------------------------------------------------

    if setTextBold ~= nil then setTextBold(false) end

    -- Work-mode status (B1): append the current work mode of any attached
    -- implement to the extra-text list, so the extra-text block surfaces it the
    -- same way native F1 does. Status text, not a key binding — which is why it
    -- joins the extra-text block here rather than the action-row list.
    local workModeStatus = self:getWorkModeStatus()
    if workModeStatus ~= nil then
        for _, line in ipairs(workModeStatus) do
            extraTexts[#extraTexts + 1] = line
        end
        numExtra = #extraTexts
    end

    -- AI-mode status — same idea, but the AI mode line carries an interactive
    -- key: HOLD the TOGGLE_AI key to open AI Settings. extraTextPills maps a
    -- row's text to its pill spec; the extra-text block renders it as a
    -- "HOLD <key>" pill (native parity). Rebuilt fresh each frame so a stale
    -- pill never lingers after the AI mode line disappears.
    self.extraTextPills = {}
    local aiModeStatus, aiModeBinding = self:getAIModeStatus()
    if aiModeStatus ~= nil then
        extraTexts[#extraTexts + 1] = aiModeStatus
        numExtra = #extraTexts
        if aiModeBinding ~= nil then
            self.extraTextPills[aiModeStatus] = {
                hold    = l10n("EHM_UI_HOLD", "HOLD"),
                binding = aiModeBinding,
            }
        end
    end

    -- Detect new OR changed extra text while visible and not in warmup.
    -- Content-based: triggers when any string appears in the set that was not
    -- there last frame — so a brand-new line (chainsaw pickup) AND a changed
    -- line (a work-mode toggle swapping "MODE: SHALLOW" → "MODE: DEEP") both
    -- flash the accent bar. Suppressed during warmupTimer (same window as
    -- new-action detection) so texts already present at spawn don't false-flash.
    -- prevExtraTexts holds the set shown last frame — captured BEFORE updating
    -- so the trigger can save it as "what existed before the new text arrived".
    local prevSet = self.prevExtraTexts or {}
    local curSet  = {}
    for _, t in ipairs(extraTexts) do curSet[t] = true end

    -- Any current string not present last frame counts as new/changed content.
    local hasNewText = false
    for t in pairs(curSet) do
        if not prevSet[t] then hasNewText = true; break end
    end

    local xtInWarmup = self.currentContextName == "PLAYER" and (self.warmupTimer or 0) > 0
    if hasNewText
       and not xtInWarmup
       and not self.silentRebuild
       and self.extraTextAccentPhase == "done" then
        -- Capture texts that existed BEFORE this trigger so the render loop
        -- can identify which rows are genuinely new by content comparison.
        self.extraTextBaseSet     = prevSet
        self.extraTextAccentPhase = "delay"
        self.extraTextAccentTimer = ANIM_ACCENT_DELAY
        self.extraTextAccentAlpha = 0
        log("Extra text: new/changed content — accent bar triggered")
    end

    self.prevExtraTexts = curSet
    self.prevExtraCount = numExtra

    -- Extra-text hide (filter-mode toggle, mirrors action-row hide UX).
    -- Match rule: exact text OR normalized stem (see isExtraTextHidden).
    --   Normal mode: drop hidden rows from extraTexts entirely so the band
    --     shrinks accordingly and they don't render.
    --   Filter mode: keep ALL rows but flag the hidden ones via
    --     extraTextHiddenSet so the renderer can dim them and swap the
    --     accent bar for the eye icon, letting the user un-hide.
    -- New-content detection above runs on the FULL set, so changes to
    -- hidden rows don't false-trigger the accent bar.
    local extraTextHiddenSet = {}
    if self.hiddenExtraTexts ~= nil and #self.hiddenExtraTexts > 0 then
        if not self.uiMode then
            local kept = {}
            for _, t in ipairs(extraTexts) do
                if not isExtraTextHidden(self.hiddenExtraTexts, t) then
                    kept[#kept + 1] = t
                end
            end
            extraTexts = kept
            numExtra   = #extraTexts
        else
            for _, t in ipairs(extraTexts) do
                if isExtraTextHidden(self.hiddenExtraTexts, t) then
                    extraTextHiddenSet[t] = true
                end
            end
        end
    end

    local x      = PANEL_X
    local topY   = PANEL_TOP_Y
    local width  = currentPanelWidth() * uiScale  -- scale panel width alongside everything else
    local leftX  = x + PADDING_X
    local rightX = x + width - PADDING_X

    local total = #self.actions

    -- In filter mode, every action row gets an eye icon column to the left of
    -- the label. iconShift is the extra horizontal space the column consumes;
    -- labelLeftX is where the label actually starts. contentW shrinks accordingly
    -- so the layout pre-pass knows the label-and-pill area is narrower in filter
    -- mode. F4 toggle clears rowLayoutCache via silentRebuild (see onUIModeEnter
    -- and onUIModeExit), so cached layouts never carry stale width assumptions.
    local iconShift  = self.uiMode and (ICON_W + ICON_GAP) or 0
    local labelLeftX = leftX + iconShift
    local contentW   = rightX - labelLeftX  -- usable width for label + pills

    -- Live page size: read once per frame so all four page-math sites and the
    -- panel-height calc see the same value, even if a settings change lands
    -- mid-frame.
    local pageSize = currentPageSize()

    -- Pre-pass: compute (or retrieve cached) row layout for every action.
    -- Double-height rows count as 2 slots against pageSize so the panel never overflows.
    -- Cache is cleared by rebuild() so layouts are always fresh after a data change.
    local layouts = {}
    for i = 1, total do
        local item = self.actions[i]
        if self.rowLayoutCache[item.name] == nil then
            self.rowLayoutCache[item.name] = computeRowLayout(item, contentW, self)
        end
        layouts[i] = self.rowLayoutCache[item.name]
    end

    -- Slot-based pagination: single row = 1 slot, double row = 2 slots.
    local totalSlots = 0
    for i = 1, total do
        totalSlots = totalSlots + (layouts[i].isDouble and 2 or 1)
    end
    local totalPages = math.max(1, math.ceil(totalSlots / pageSize))
    self.cachedTotalPages = totalPages  -- shared with onPageNext/Prev
    if self.page < 1          then self.page = 1          end
    if self.page > totalPages then self.page = totalPages end

    -- Find the first action on the current page.
    local skipSlots = (self.page - 1) * pageSize
    local startIdx  = total + 1  -- sentinel: nothing to show
    local slotsSoFar = 0
    for i = 1, total do
        if slotsSoFar >= skipSlots then startIdx = i; break end
        slotsSoFar = slotsSoFar + (layouts[i].isDouble and 2 or 1)
    end

    -- Find the last action on the current page (stop when slot budget exhausted).
    local endIdx = startIdx - 1
    local slotsOnPage = 0
    for i = startIdx, total do
        local s = layouts[i].isDouble and 2 or 1
        if slotsOnPage + s > pageSize then break end
        endIdx = i
        slotsOnPage = slotsOnPage + s
    end

    -- -------------------------------------------------------------------------
    -- Compute filter strip row layout (inside header when uiMode)
    -- -------------------------------------------------------------------------
    -- STRIP_GAP is a module-level constant (pixel-based), no local needed here
    local availW    = width - PADDING_X * 2
    local stripRows = {}
    local curRow, curW = {}, 0
    for i = 1, #EHM_CATEGORIES do
        local tw = safeTextWidth(SIZE_TEXT, l10n(EHM_CATEGORIES[i].abbrKey, EHM_CATEGORIES[i].abbr)) + KEY_PAD_X * 2
        if curW + tw + STRIP_GAP > availW and #curRow > 0 then
            table.insert(stripRows, curRow)
            curRow, curW = {}, 0
        end
        table.insert(curRow, {idx = i, w = tw})
        curW = curW + tw + STRIP_GAP
    end
    if #curRow > 0 then table.insert(stripRows, curRow) end

    local numStripRows = self.uiMode and #stripRows or 0

    -- Update the extra-text block target height every frame from the current numExtra.
    -- Snapshot the live texts whenever there's content to display, so the retraction
    -- phase has something to render after the game stops calling addExtraPrintText.
    -- (Once numExtra goes to 0, xtLastTexts retains the last visible content until the
    -- block fully retracts, then the next show will overwrite it.)
    if numExtra > 0 then
        self.xtTargetH   = ROW_GAP * 1.75 + numExtra * (ROW_H + ROW_GAP * 0.3)
        self.xtLastTexts = extraTexts
    else
        self.xtTargetH = 0
    end

    -- Vehicle schema row: shown at the top of the header when in any vehicle context.
    local inVehicle    = self.currentContextName ~= nil and self.currentContextName ~= "PLAYER"
    -- The native vehicle schema renders for ANY controlled vehicle — including
    -- one with no attachments. Both its presence and its height come straight
    -- from the drawVehicleSchema hook: a captured height > 0 means native is
    -- drawing a schema this frame. (The earlier check on the vehicle's
    -- selectable-object chain missed lone vehicles — they have an empty chain
    -- but still get a schema, so EHM reserved nothing and it overlapped.)
    -- SCHEMA_GAP is the gap between the native schema and EHM's header. It is
    -- smaller than ROW_GAP because the native schema already pads itself
    -- internally — adding our own full ROW_GAP on top doubled the visible gap.
    local nativeSchemaH = self.nativeSchemaHeight
    local hasSchema  = inVehicle
                   and type(nativeSchemaH) == "number"
                   and nativeSchemaH > 0
    local SCHEMA_GAP = 2 * PY
    local schemaRowH = hasSchema and (nativeSchemaH + SCHEMA_GAP) or 0

    -- Re-hosted help extensions (Precision Farming widgets): EHM draws them
    -- itself, stacked directly below the native schema. extBandH reserves
    -- their vertical space. It is the height the extensions ACTUALLY consumed
    -- last frame (measured from their draw output in the re-host loop below) —
    -- not getHeight(), because extensions EHM already mirrors draw nothing when
    -- re-hosted yet still report a non-zero getHeight(), which produced a
    -- phantom gap. One-frame lag is invisible for a steady panel. topBandH is
    -- the total band above EHM's header (native schema + re-hosted extensions),
    -- where EHM draws no background of its own (each element brings its own).
    local reHostExts = self:getReHostExtensions()
    local extBandH   = (#reHostExts > 0) and (self.measuredExtBandH or 0) or 0
    local topBandH   = schemaRowH + extBandH

    -- -------------------------------------------------------------------------
    -- Header height: schema/extension band + base (2 rows) + filter + extras
    -- -------------------------------------------------------------------------
    local headerH = HDR_PAD
                  + topBandH                     -- native schema + re-hosted extensions
                  + ROW_H + ROW_GAP              -- row 1: actions/page + device
                  + ROW_H                        -- row 2: hints + filter
                  + (numStripRows > 0
                      and (ROW_GAP + numStripRows * (ROW_H + ROW_GAP) + ROW_GAP * 0.5)
                      or 0)
                  + self.xtBlockH                -- eased extra-text block (0 when none)
                  + HDR_PAD * 0.5               -- bottom padding slightly tighter than top

    -- -------------------------------------------------------------------------
    -- Panel total height
    -- -------------------------------------------------------------------------
    local height    = headerH
                    + PAD_TOP
                    + pageSize * ROW_H
                    + math.max(0, pageSize - 1) * ROW_GAP
                    + PAD_BOTTOM

    -- -------------------------------------------------------------------------
    -- Background panels — full-screen dim overlay and panel alpha boost
    -- were removed in an earlier redesign; DOF blur on the game world provides the
    -- modal focus effect instead.
    -- -------------------------------------------------------------------------
    local headerBgTop = (topBandH > 0) and (topY - topBandH) or topY
    local headerBgH   = headerH - topBandH
    local panelAlpha  = 0.65
    -- v1.13.0.3: snap top/bottom to pixel boundaries. Same class of fix as
    -- the v1.10.0.1 snapPX on cap widths inside renderRow / renderKey /
    -- renderHeader, but for the renderHeader bounding-box itself. Without
    -- this, at non-integer UI scale, scaled topBandH subtracted from the
    -- unscaled PANEL_TOP_Y anchor lands on a fractional reference pixel,
    -- and the 9-slice TOP corner / TOP-center pieces blur across half a
    -- pixel on the top edge -- visible as a thin horizontal seam line
    -- (reported at UI Scale = 125% during the v1.13.0.2 test pass).
    -- Snapping both top and bottom keeps the height as close to the
    -- intended scaled value as possible while landing both edges on
    -- clean pixel boundaries. Visual cost: header height shifts by up to
    -- 1 reference pixel per scale change -- invisible per the v1.10.0.1
    -- precedent.
    local headerTop_snap = snapPY(headerBgTop)
    local headerBot_snap = snapPY(headerBgTop - headerBgH)
    self:renderHeader(x, headerBot_snap, width, headerTop_snap - headerBot_snap,
        COL_BG_HEADER[1], COL_BG_HEADER[2], COL_BG_HEADER[3], panelAlpha)

    -- Re-hosted help extensions: drawn directly below the native schema.
    -- exY advances ONLY for an extension that actually consumed height — one
    -- EHM already mirrors (WorkMode / AIMode) draws nothing and must not push
    -- the next element down. The total consumed height is stored in
    -- measuredExtBandH and reserved as extBandH on the next frame, so the
    -- header/rows flow below without a phantom gap. pcall-wrapped per
    -- extension — a finicky native draw must never take down EHM's rendering.
    do
        local rih = g_currentMission and g_currentMission.hud
                    and g_currentMission.hud.inputHelp or nil
        local bandTop = topY - schemaRowH   -- just below the native schema
        local exY     = bandTop
        -- PF re-hosting: was temporarily disabled during the Quit-to-Menu leak
        -- probe (now resolved -- root cause was FocusManager:loadElementFromCustomValues
        -- and deleteStaleScope, NOT this path). Re-enabled now.
        if rih ~= nil then
            for _, ext in ipairs(reHostExts) do
                pcall(function()
                    if ext.setEventHelpElements ~= nil then
                        ext:setEventHelpElements(rih, {})
                    end
                    local newY = ext:draw(rih, x, exY)
                    if type(newY) == "number" and newY < exY - 0.0001 then
                        exY = newY - ROW_GAP   -- consumed real height → add a gap
                    end
                end)
            end
        end
        self.measuredExtBandH = math.max(0, bandTop - exY)
    end

    -- Key bindings and device label — used across both header rows.
    -- (keyToggle for the F1 pill was removed in v1.13.0.6; F1 is universal.)
    local keyDevice   = self:getBindings("EHM_CYCLE_DEVICE") or "?"
    local keyPrev     = self:getBindings("EHM_PAGE_PREV")    or "?"
    local keyNext     = self:getBindings("EHM_PAGE_NEXT")    or "?"
    local keyFilter   = self:getBindings("EHM_UI_MODE")      or "?"
    local device      = self.deviceModes[self.deviceModeIndex]
    local deviceLabel = device ~= nil and string.upper(device.label) or "?"

    -- -------------------------------------------------------------------------
    -- Schema row (VEHICLE context only): space reserved for native compact
    -- vehicle indicator. With PANEL_TOP_Y = ih.y (0.9722) it renders naturally
    -- inside our header. Background blends because both use #010101 @ 65%.
    -- -------------------------------------------------------------------------

    -- -------------------------------------------------------------------------
    -- Header row 1: page counter (left) | DEVICE [F10] [KB/MOUSE] (right)
    -- Bold white "x/y" only on the left; device block right-anchored.
    -- r1BotY shifts down by topBandH (native schema + re-hosted extensions).
    -- (Header cleanup history: action count removed in v1.13.0.7, "PAGE"
    -- label removed in v1.13.0.8 because row 2's "PAGE [PgUp/PgDn]" pill
    -- already carries the word and the duplication read as noise. The
    -- bare "x/y" is unambiguous in context. EHM_UI_PAGE translation key
    -- stays -- still used by row 2.)
    -- -------------------------------------------------------------------------
    local r1BotY = topY - HDR_PAD - topBandH - ROW_H
    local textY1 = r1BotY + TEXT_OY

    -- Left: "1/3" — bold white, no label
    local hx1 = leftX
    local pageStr = string.format("%d/%d", self.page, totalPages)
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(hx1, textY1, SIZE_TEXT, pageStr)

    -- Right: DEVICE [F10] [KB/MOUSE] — three-part block, right-anchored
    -- Draw right-to-left: selected pill → key pill → label
    local devPillGap = 3 * PX
    local devNameW   = math.max(safeTextWidth(SIZE_TEXT, deviceLabel) + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    local devKeyW    = math.max(safeTextWidth(SIZE_TEXT, keyDevice)   + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    local deviceLbl  = l10n("EHM_UI_DEVICE", "DEVICE")
    local devLblW    = safeTextWidth(SIZE_TEXT, deviceLbl)

    -- [KB/MOUSE] selected pill (rightmost) — clickable in filter mode to cycle device
    local selPillLx = rightX - devNameW
    self:renderKey(selPillLx, r1BotY, devNameW, ROW_H,
        COL_SEL_PILL[1], COL_SEL_PILL[2], COL_SEL_PILL[3], COL_SEL_PILL[4])
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(selPillLx + KEY_PAD_X, textY1, SIZE_TEXT, deviceLabel)
    local devPillRect = {x=selPillLx, y=r1BotY, w=devNameW}

    -- [F10] standard key pill
    local keyPillLx = selPillLx - devPillGap - devKeyW
    self:renderKey(keyPillLx, r1BotY, devKeyW, ROW_H,
        COL_BG_KEY[1], COL_BG_KEY[2], COL_BG_KEY[3], COL_BG_KEY[4])
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(keyPillLx + KEY_PAD_X, textY1, SIZE_TEXT, keyDevice)

    -- "DEVICE" dim label (leftmost of the device block)
    if setTextBold ~= nil then setTextBold(false) end
    self:setColor(COL_HINT_LBL)
    renderText(keyPillLx - devPillGap - devLblW, textY1, SIZE_TEXT, deviceLbl)

    -- -------------------------------------------------------------------------
    -- Header row 2: hint labels + key pills (left) | FILTER [F4] (right)
    -- Hint labels dim, not bold. DEVICE removed (consolidated into row 1).
    -- FILTER label and pill: dim/standard when closed, white/selected when open.
    -- -------------------------------------------------------------------------
    local r2BotY = r1BotY - ROW_GAP - ROW_H
    local textY2 = r2BotY + TEXT_OY

    -- Left: PAGE [PgUp/PgDn]
    -- (TOGGLE [F1] removed in v1.13.0.6 — F1 is a universal "open help"
    -- mnemonic and dedicating header real estate to it was redundant.
    -- The TOGGLE_HELP_TEXT row in the main action list still surfaces F1
    -- via the standard rendering path. The remaining pills (PAGE, FILTER,
    -- DEVICE) are MORE useful since v1.13.0.5 because their defaults are
    -- now ALT-prefixed combos that aren't universally known.)
    local hx2 = leftX
    local hintPairs = {
        {l10n("EHM_UI_PAGE", "PAGE"), keyPrev .. "/" .. keyNext},
    }
    for _, hp in ipairs(hintPairs) do
        local lbl, key = hp[1], hp[2]
        if setTextBold ~= nil then setTextBold(false) end
        self:setColor(COL_HINT_LBL)
        renderText(hx2, textY2, SIZE_TEXT, lbl)
        hx2 = hx2 + safeTextWidth(SIZE_TEXT, lbl) + 3 * PX
        hx2 = self:drawHeaderPill(hx2, r2BotY, key, false) + 5 * PX
    end

    -- Right: FILTER [F4] — label dim when closed, white when open; pill selected when open
    local rx2  = rightX
    local f4W  = math.max(safeTextWidth(SIZE_TEXT, keyFilter) + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    local f4Lx = rx2 - f4W
    self:drawHeaderPill(f4Lx, r2BotY, keyFilter, self.uiMode)
    local f4PillRect = {x=f4Lx, y=r2BotY, w=f4W}
    rx2 = f4Lx - 3 * PX
    local filterLbl = l10n("EHM_UI_FILTER", "FILTER")
    local flblW = safeTextWidth(SIZE_TEXT, filterLbl)
    if setTextBold ~= nil then setTextBold(self.uiMode) end
    self:setColor(self.uiMode and COL_WHITE or COL_HINT_LBL)
    renderText(rx2 - flblW, textY2, SIZE_TEXT, filterLbl)

    -- SELECT ALL / DESELECT ALL button — only when filter mode open, left of FILTER block.
    -- SELECT ALL (active style)  — shown when any category is OFF → clicking turns all ON.
    -- DESELECT ALL (inactive style) — shown when all ON → clicking turns all OFF.
    self.hoveredAllToggle = false
    if self.uiMode then
        local allOn = true
        for i = 1, #EHM_CATEGORIES do
            if self.filterEnabled[i] == false then allOn = false; break end
        end
        local allLabel = allOn and l10n("EHM_UI_DESELECT_ALL", "DESELECT ALL") or l10n("EHM_UI_SELECT_ALL", "SELECT ALL")
        local isSelectAll = not allOn

        local allW   = math.max(safeTextWidth(SIZE_TEXT, allLabel) + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
        local allRx  = rx2 - flblW - 6 * PX       -- right edge of button
        local allLx  = allRx - allW                -- left edge of button

        local isHovAll = self.uiModeMouseX >= allLx and self.uiModeMouseX <= allLx + allW
                     and self.uiModeMouseY >= r2BotY and self.uiModeMouseY <= r2BotY + ROW_H
        self.hoveredAllToggle = isHovAll
        self.allBtnRect = {x=allLx, y=r2BotY, w=allW}

        if isSelectAll then
            -- Active style: white-tinted bg + bold white text
            self:renderKey(allLx, r2BotY, allW, ROW_H,
                COL_SEL_PILL[1], COL_SEL_PILL[2], COL_SEL_PILL[3],
                isHovAll and 0.28 or COL_SEL_PILL[4])
            if setTextBold ~= nil then setTextBold(true) end
            self:setColor(COL_WHITE)
        else
            -- Inactive style: dim dark bg + dim text
            self:renderKey(allLx, r2BotY, allW, ROW_H,
                COL_BG_KEY[1], COL_BG_KEY[2], COL_BG_KEY[3],
                isHovAll and 0.65 or 0.45)
            if setTextBold ~= nil then setTextBold(false) end
            self:setColor(COL_HINT_LBL)
        end
        renderText(allLx + KEY_PAD_X, textY2, SIZE_TEXT, allLabel)
        if setTextBold ~= nil then setTextBold(false) end
    end

    -- -------------------------------------------------------------------------
    -- Filter strip inside header (only when uiMode)
    -- -------------------------------------------------------------------------
    local curHdrY = r2BotY  -- tracks bottom of last header row
    self.hoveredToggle = nil
    local mx = self.uiModeMouseX
    local my = self.uiModeMouseY

    if self.uiMode then
        curHdrY = curHdrY - ROW_GAP
        for _, rowItems in ipairs(stripRows) do
            local rowBotY = curHdrY - ROW_H
            local tx = leftX
            for _, item in ipairs(rowItems) do
                local catIdx = item.idx
                local tw     = item.w
                local cat    = EHM_CATEGORIES[catIdx]
                local isOn   = self.filterEnabled[catIdx] ~= false
                local isHov  = (mx >= tx and mx <= tx + tw
                                and my >= rowBotY and my <= rowBotY + ROW_H)
                if isHov then self.hoveredToggle = catIdx end

                -- Toggle button — monochrome: white bg when ON, dark when OFF
                if isOn then
                    self:renderRow(tx, rowBotY, tw, ROW_H,
                        COL_CAT_ON_BG[1], COL_CAT_ON_BG[2], COL_CAT_ON_BG[3], COL_CAT_ON_BG[4])
                else
                    self:renderRow(tx, rowBotY, tw, ROW_H,
                        COL_BG_KEY[1], COL_BG_KEY[2], COL_BG_KEY[3], isHov and 0.65 or 0.45)
                end

                -- Text: white bold when ON, dim grey when OFF (no more green)
                local textCol = isOn and COL_WHITE or COL_CAT_OFF_TEXT
                if setTextBold ~= nil then setTextBold(isOn) end
                self:setColor(textCol)
                renderText(tx + KEY_PAD_X, rowBotY + TEXT_OY, SIZE_TEXT, l10n(cat.abbrKey, cat.abbr))
                if setTextBold ~= nil then setTextBold(false) end

                tx = tx + tw + STRIP_GAP
            end
            curHdrY = rowBotY
            curHdrY = curHdrY - ROW_GAP
        end

        -- Click handling — explicit rect checks for all targets, in priority order.
        if self.uiModeClicked then
            self.uiModeClicked = false
            local cmx = self.uiModeMouseX
            local cmy = self.uiModeMouseY
            -- KB/MOUSE pill — cycle device (same as F10)
            if cmx >= devPillRect.x and cmx <= devPillRect.x + devPillRect.w
            and cmy >= devPillRect.y and cmy <= devPillRect.y + ROW_H then
                self:onCycleDevice()
            -- F4 pill — close filter mode. Small left padding makes it easier to hit.
            elseif cmx >= f4PillRect.x - 4 * PX and cmx <= f4PillRect.x + f4PillRect.w
            and cmy >= f4PillRect.y and cmy <= f4PillRect.y + ROW_H then
                self:onUIMode()
            -- SELECT ALL / DESELECT ALL — explicit rect, not flag-based
            elseif self.allBtnRect ~= nil
            and cmx >= self.allBtnRect.x and cmx <= self.allBtnRect.x + self.allBtnRect.w
            and cmy >= self.allBtnRect.y and cmy <= self.allBtnRect.y + ROW_H then
                local allOn = true
                for i = 1, #EHM_CATEGORIES do
                    if self.filterEnabled[i] == false then allOn = false; break end
                end
                for i = 1, #EHM_CATEGORIES do
                    self.filterEnabled[i] = not allOn
                end
                self.silentRebuild = true
                self:rebuild()
                self.silentRebuild = false
                EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions, self.hiddenExtraTexts, self.settings)
                log("Filter: %s all categories", allOn and "deselected" or "selected")
            -- Individual category toggle
            elseif self.hoveredToggle ~= nil then
                self.filterEnabled[self.hoveredToggle] =
                    not (self.filterEnabled[self.hoveredToggle] ~= false)
                self.silentRebuild = true
                self:rebuild()
                self.silentRebuild = false
            -- Action row click — toggle hide/un-hide for the row under the cursor.
            -- Whole-row hit test: spans the full panel width (icon + label + pills),
            -- and for double-height rows the full two-line block. Walks the visible
            -- page in the same order the action draw loop will, so the click bounds
            -- line up exactly with what's about to be rendered. Save fires on F4 exit,
            -- not here — matches the design doc and keeps clicks responsive.
            --
            -- Extra-text rows (header band) take priority: they sit above the
            -- action rows in screen order, so we hit-test them first and only
            -- fall through to the action-row loop on a miss. Persist happens
            -- inline via toggleExtraTextHidden -- no rebuild call needed
            -- because draw() recomputes the band from scratch every frame.
            else
                local handledExtra = false
                if self.xtBlockH > 0.0001 then
                    local rt = (numExtra > 0) and extraTexts or self.xtLastTexts
                    if rt ~= nil and #rt > 0 then
                        local sepY = curHdrY - ROW_GAP
                        local exY  = sepY - ROW_GAP * 0.75
                        for _, etext in ipairs(rt) do
                            exY = exY - ROW_H
                            if cmx >= x and cmx <= x + width
                            and cmy >= exY and cmy <= exY + ROW_H then
                                self:toggleExtraTextHidden(etext)
                                handledExtra = true
                                break
                            end
                            exY = exY - ROW_GAP * 0.3
                        end
                    end
                end

                if not handledExtra then
                    local rowY = topY - headerH - PAD_TOP
                    for i = startIdx, endIdx do
                        local item   = self.actions[i]
                        local layout = layouts[i]
                        if item ~= nil and layout ~= nil then
                            local rowH = layout.isDouble and (ROW_H * 2 + INNER_ROW_GAP) or ROW_H
                            rowY = rowY - rowH
                            if cmx >= x and cmx <= x + width
                            and cmy >= rowY and cmy <= rowY + rowH then
                                -- Toggle: nil <-> true. Storing nil (not false) keeps the
                                -- set sparse so EHM_SETTINGS.save iterates only entries that
                                -- are actually hidden, never writing false placeholders.
                                local nowHidden = not (self.hiddenActions[item.name] == true)
                                self.hiddenActions[item.name] = nowHidden and true or nil
                                log("Hidden toggle: %s -> %s", item.name, tostring(nowHidden))
                                self.silentRebuild = true
                                self:rebuild()
                                self.silentRebuild = false
                                break
                            end
                            rowY = rowY - ROW_GAP
                        end
                    end
                end
            end
        end

        -- No solid dim overlay — action rows render at full opacity in all modes
    end

    -- -------------------------------------------------------------------------
    -- Extra print texts -- inside header, below filter strip (or hints if closed).
    -- Each row has a permanent grey left bar (same spec as action accent bars).
    -- Bar turns green using the same animation phases when text appears from nothing.
    -- Text uses hint-label style (dim white, not bold) to sit apart from controls.
    -- Renders whenever xtBlockH has any height -- covers the expand/hold/retract
    -- envelope so retraction can fade text out as the block shrinks. During retraction
    -- numExtra is 0 but xtLastTexts holds the most recently shown texts.
    -- -------------------------------------------------------------------------
    if self.xtBlockH > 0.0001 then
        -- Pick whichever list is currently driving the block: live texts when the
        -- game is still pushing them, last-known texts during retraction.
        local renderTexts = (numExtra > 0) and extraTexts or self.xtLastTexts
        local renderCount = #renderTexts
        local xtAlpha     = self.xtDisplayAlpha

        if renderCount > 0 then
            -- Thin separator line -- full ROW_GAP above it, half ROW_GAP below it
            local sepY = curHdrY - ROW_GAP
            drawFilledRect(x, sepY - PY, width, PY, 1.0, 1.0, 1.0, 0.08 * xtAlpha)

            -- Determine whether animation is active -- used per-row for green overlay
            local animActive = self.extraTextAccentPhase ~= "done" and self.extraTextAccentAlpha > 0
            local baseSet    = self.extraTextBaseSet or {}

            local exY    = sepY - ROW_GAP * 0.75
            local barPad = 3 * PY  -- vertical inset matching action row accent bars
            -- In filter mode, swap the accent bar for the eye-icon column at
            -- the same left edge action rows use. xtIconShift mirrors action
            -- rows' iconShift so the label aligns identically.
            local xtIconShift = self.uiMode and (ICON_W + ICON_GAP) or 0
            for _, etext in ipairs(renderTexts) do
                exY = exY - ROW_H
                -- Row is new when animation is active AND its content wasn't in the base set
                local isNewRow = animActive and (baseSet[etext] == nil)
                -- Hidden-row dim. In normal mode hidden rows don't reach the
                -- renderer (they were filtered out earlier); the multiplier
                -- only kicks in during filter mode, where hidden rows are
                -- kept visible at HIDDEN_DIM_ALPHA so the user can un-hide.
                local isHidden = extraTextHiddenSet[etext] == true
                local rowDim   = isHidden and HIDDEN_DIM_ALPHA or 1.0
                local rowAlpha = xtAlpha * rowDim

                if self.uiMode then
                    -- Filter mode: eye icon replaces the accent bar. Open
                    -- eye = visible (click to hide), slashed = hidden (click
                    -- to un-hide). Same texture pair the action rows use.
                    local iconOv = isHidden and self.ovEyeHidden or self.ovEyeOpen
                    if iconOv ~= nil then
                        local iconY = exY + (ROW_H - ICON_H) * 0.5
                        setOverlayColor(iconOv, 1, 1, 1, rowAlpha)
                        renderOverlay(iconOv, leftX, iconY, ICON_W, ICON_H)
                    end
                else
                    -- Normal mode: grey baseline accent bar.
                    drawFilledRect(x + ROW_CAP_W, exY + barPad, ACCENT_BAR_W, ROW_H - barPad * 2,
                        COL_XT_BAR[1], COL_XT_BAR[2], COL_XT_BAR[3], COL_XT_BAR[4] * rowAlpha)
                    -- Green bar -- drawn on top of grey when animation is active.
                    if isNewRow then
                        drawFilledRect(x + ROW_CAP_W, exY + barPad, ACCENT_BAR_W, ROW_H - barPad * 2,
                            COL_BG_KEY_NEW[1], COL_BG_KEY_NEW[2], COL_BG_KEY_NEW[3],
                            self.extraTextAccentAlpha * ANIM_ACCENT_OPACITY * rowAlpha)
                    end
                end

                -- Text -- white, not bold, uppercase (same weight as action row labels)
                if setTextBold ~= nil then setTextBold(false) end
                self:setColor(COL_WHITE, rowAlpha)
                local safe = etext and string.upper(etext) or ""
                renderText(leftX + xtIconShift, exY + TEXT_OY, SIZE_TEXT, safe)

                -- Optional key pill (e.g. the AI mode line's HOLD-key hint).
                -- extraTextPills is keyed by row text; drawn right-anchored with
                -- the same renderer the action rows use, preceded by a HOLD
                -- prefix in the dimmer COL_HOLD weight.
                local pill = self.extraTextPills and self.extraTextPills[etext]
                if pill ~= nil and pill.binding ~= nil then
                    local rx     = x + width
                    local holdTx = pill.hold and (pill.hold .. " ") or nil
                    local hpfxW  = holdTx and safeTextWidth(SIZE_TEXT, holdTx) or 0
                    local pillsW = self:measureBindingWidth(pill.binding)
                    if holdTx ~= nil then
                        self:setColor(COL_HOLD, COL_HOLD[4] * rowAlpha)
                        renderText(rx - hpfxW - pillsW, exY + TEXT_OY, SIZE_TEXT, holdTx)
                    end
                    self:drawBindingPills(rx, exY, pill.binding, rowAlpha)
                end
                exY = exY - ROW_GAP * 0.3
            end
        end
    end

    -- -------------------------------------------------------------------------
    -- Action rows
    -- -------------------------------------------------------------------------
    -- actionTop: Y coordinate of the top edge of the first action row.
    -- actY advances downward each row: subtract rowH to get the bottom of each row,
    -- then subtract ROW_GAP after rendering.
    local actionTop = topY - headerH - PAD_TOP
    local actY      = actionTop
    local barPadY   = 3 * PY  -- vertical inset for accent bar

    local bindRx = x + width  -- right edge for pill anchoring (constant)

    for i = startIdx, endIdx do
        local item   = self.actions[i]
        local layout = layouts[i]
        if item ~= nil and layout ~= nil then
            local rowH = layout.isDouble and (ROW_H * 2 + INNER_ROW_GAP) or ROW_H
            actY = actY - rowH  -- actY is now the bottom of this row

            -- dimAlpha drops to HIDDEN_DIM_ALPHA for hidden rows (only ever visible
            -- in filter mode; rebuild() drops them entirely from the normal panel).
            -- It multiplies into every visible element of the row — background, accent
            -- bar, label text, HOLD prefix, binding pill alpha, and the strike-through
            -- line. fadeAlpha rides on top so newly-inserted rows still fade in cleanly.
            local dimAlpha  = item.isHidden and HIDDEN_DIM_ALPHA or 1.0
            local rowAlpha  = 0.65
            local anim      = self.animState[item.name]
            local shiftOff  = anim and anim.shiftOffset or 0
            local fadeAlpha = anim and anim.fadeAlpha   or 1.0
            local accentA   = anim and anim.accentAlpha or 0
            local rowY = actY + shiftOff

            -- Row background — one unified rounded rect for single and double rows
            self:renderRow(x, rowY, width, rowH,
                COL_BG_PANEL[1], COL_BG_PANEL[2], COL_BG_PANEL[3],
                COL_BG_PANEL[4] * fadeAlpha * rowAlpha * dimAlpha)

            -- Left accent bar — spans full row height on double rows.
            -- Multiplied by dimAlpha as defence-in-depth: rebuild() never creates
            -- animState for hidden actions, so accentA should always be 0 for them,
            -- but if a stale animState ever lingers (e.g. a click toggles isHidden
            -- mid-animation in Step 4) this keeps the bar dimmed in lockstep.
            if accentA > 0 then
                drawFilledRect(
                    x + ROW_CAP_W, rowY + barPadY,
                    ACCENT_BAR_W,  rowH - barPadY * 2,
                    COL_BG_KEY_NEW[1], COL_BG_KEY_NEW[2], COL_BG_KEY_NEW[3],
                    accentA * ANIM_ACCENT_OPACITY * dimAlpha)
            end

            if setTextBold ~= nil then setTextBold(false) end

            -- r1Y is the baseline row of the top line (label, eye icon, strike-through).
            -- For single rows it equals the row's bottom; for double rows it's the
            -- bottom of the upper sub-row. Hoisted out of the if/else below so the
            -- eye icon can render once before branching on layout type.
            local r1Y = layout.isDouble and (rowY + ROW_H + INNER_ROW_GAP) or rowY

            -- Filter-mode eye icon — open eye for visible rows, slashed eye for
            -- hidden ones. The PNG is white-on-transparent; setOverlayColor
            -- multiplies the row's dimAlpha and fadeAlpha so the icon dims in
            -- lockstep with the label (and fades in cleanly on newly-inserted rows).
            -- ovEyeOpen / ovEyeHidden are nil-checked individually so a texture
            -- load failure simply hides the icon — the rest of the row still renders.
            if self.uiMode then
                local iconOv = item.isHidden and self.ovEyeHidden or self.ovEyeOpen
                if iconOv ~= nil then
                    local iconY = r1Y + (ROW_H - ICON_H) * 0.5
                    setOverlayColor(iconOv, 1, 1, 1, dimAlpha * fadeAlpha)
                    renderOverlay(iconOv, leftX, iconY, ICON_W, ICON_H)
                end
            end

            if layout.isDouble then
                -- ── Double row ──────────────────────────────────────────────
                -- Row 1 (top):  label left + any groups that fit right
                -- Row 2 (bottom): remaining groups right-anchored (+ HOLD prefix)
                local r2Y = rowY                           -- bottom of the bottom line

                -- Label (row 1)
                self:setColor(COL_WHITE, dimAlpha * fadeAlpha)
                renderText(labelLeftX, r1Y + TEXT_OY, SIZE_TEXT, layout.labelText)
                if item.isHidden then
                    drawStrikeThrough(labelLeftX, r1Y + TEXT_OY, layout.labelText, dimAlpha * fadeAlpha)
                end

                -- Pills on row 1 (right-anchored, may be nil)
                if layout.row1Binding ~= nil then
                    self:drawBindingPills(bindRx, r1Y, layout.row1Binding, dimAlpha * fadeAlpha)
                end

                -- Pills on row 2 (right-anchored)
                if layout.row2Binding ~= nil then
                    self:drawBindingPills(bindRx, r2Y, layout.row2Binding, dimAlpha * fadeAlpha)
                end
            else
                -- ── Single row (common case) ─────────────────────────────────
                self:setColor(COL_WHITE, dimAlpha * fadeAlpha)
                renderText(labelLeftX, r1Y + TEXT_OY, SIZE_TEXT, layout.labelText)
                if item.isHidden then
                    drawStrikeThrough(labelLeftX, r1Y + TEXT_OY, layout.labelText, dimAlpha * fadeAlpha)
                end

                if layout.displayBinding ~= nil then
                    self:drawBindingPills(bindRx, r1Y, layout.displayBinding, dimAlpha * fadeAlpha)
                end
            end

            actY = actY - ROW_GAP
        end
    end

    setTextColor(1, 1, 1, 1)
    if setTextBold ~= nil then setTextBold(false) end
end

-- ---------------------------------------------------------------------------
-- Diagnostic: overlay-leak dump (temporary, for tracking the Quit-to-Menu
-- crash). Wraps the vanilla FindOverlayLeaks class (a built-in FS25 diagnostic
-- that tracks undeleted overlays) as a console command. Invoke with
-- "ehmOverlayLeaks" from the dev console. Output goes to log.txt.
-- ---------------------------------------------------------------------------
function EnhancedHelpMenu.consoleCommandOverlayLeaks()
    if FindOverlayLeaks == nil then
        return "FindOverlayLeaks class not available"
    end
    if type(FindOverlayLeaks.printUndeletedOverlays) ~= "function" then
        return "FindOverlayLeaks.printUndeletedOverlays is not a function"
    end
    local ok, err = pcall(function() FindOverlayLeaks:printUndeletedOverlays() end)
    if not ok then
        return ("FindOverlayLeaks:printUndeletedOverlays() threw: %s"):format(tostring(err))
    end
    return "FindOverlayLeaks:printUndeletedOverlays() invoked - check log.txt"
end

if type(addConsoleCommand) == "function" then
    addConsoleCommand(
        "ehmOverlayLeaks",
        "Dump undeleted overlays via vanilla FindOverlayLeaks (diagnostic)",
        "consoleCommandOverlayLeaks",
        EnhancedHelpMenu
    )
end

-- ---------------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------------
addModEventListener(EnhancedHelpMenu)