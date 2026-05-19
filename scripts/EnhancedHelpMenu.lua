-- =============================================================================
-- EnhancedHelpMenu — FS25 Mod
-- Version: 0.9.0
--
-- PURPOSE:
--   Displays all currently active input actions and their key bindings in a
--   clean overlay panel. Acts as a smarter, more complete alternative to the
--   game's built-in F1 hint menu — showing ALL active actions across all
--   devices, not just the ones the game chooses to highlight.
--
-- CONTROLS (all remappable in the in-game Controls menu):
--   F1    — Cycle display state: EHM only → F1 only → both hidden (game's own toggle key)
--   F4    — Open/close filter mode (click categories to filter list, click rows to hide them)
--   F6    — Previous page
--   F7    — Next page
--   F10   — Cycle device filter (Keyboard/Mouse, Joystick, etc.)
--
-- ARCHITECTURE OVERVIEW:
--   - Rebuilds action list every 500ms from g_inputBinding.actionEvents
--   - Uses PlayerInputComponent hooks for key registration (works in all contexts)
--   - New actions animate in (fade + left accent bar) and stay pinned at top
--     until something newer arrives, then re-sort to their natural position
--   - Filter mode (F4) blurs the game world via the DOF manager and lets the
--     player click rows to hide them from the normal panel (un-hide in same UI)
--   - Extra-text block (mod help text via addExtraPrintText) eases its height
--     and opacity in/out smoothly so it doesn't pop on/off
--   - G-press detection: when a vehicle's selectable changes, returning actions
--     on the new selectable get the full new-action highlight
--   - Overflow rows (label + binding too wide) expand to two lines automatically;
--     the label stays on line 1, binding pills wrap to line 2
--   - Supports multiple input devices with per-device binding display
--   - Always-on session log at modSettings/EHM_debug.log;
--     set DEBUG = true for rebuild-level detail
--
-- FS25 LUA GOTCHAS (learned the hard way):
--   - goto is not supported — use boolean flags instead
--   - os.date() does not exist — use getDate("%d/%m/%Y %H:%M")
--   - getDate() requires a format string argument
--   - InputAction constants only work when mod has a hash (must run as ZIP)
--   - PageUp/PageDown consumed by developer console at engine level — use F6/F7
--   - registerActionEvent needs beginActionEventsModification(contextName) wrapper
--   - PlayerInputComponent.registerGlobalPlayerActionEvents fires on EVERY context switch
--   - Actions can be isActive=false but isVisible=true (e.g. ENTER near vehicle)
--   - FS25 stores key names in US keyboard layout regardless of actual keyboard
--   - setClipRect/removeClipRect are nil in the sandbox — no text clipping available
--   - setOverlayColor sets global GL state — never call on shared native overlay IDs
--   - vehicle exit doesn't fire registerGlobalPlayerActionEvents — poll getContextName() each frame
--   - io.open is blocked for .xml — use the XMLFile/XMLSchema engine API
--   - callbackState == 2 means hold-type action (confirmed via probe — not 1)
--   - ih:drawVehicleSchema() crashes when called outside the native draw() path
--   - camera look axes oscillate +2/-2 when filter mode toggles — disabled in UI mode and filtered out of the list
--   - setTextBold can be nil — always guard: if setTextBold ~= nil then
-- =============================================================================

-- Capture mod directory at load time — g_currentModDirectory is nil at draw() time.
local MOD_DIR = g_currentModDirectory or ""

EnhancedHelpMenu = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 500  -- ms between data rebuilds
local PAGE_SIZE        = 12   -- action rows shown per page

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
local PANEL_WIDTH = 0.264     -- 20% narrower than original 0.330 (264px @1920 reference)

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
local COL_SEP_PLUS    = { 1.0,   1.0,   1.0,   0.75 }  -- "+" chord key separator
local COL_SEP_LINE    = { 1.0,   1.0,   1.0,   0.65 }  -- "|" binding group separator line

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
-- Two-tier system:
--
--   log()  — Always on. Important events: context switches, new actions,
--             warnings, setup, state changes. Written to file AND game log.txt
--             so critical events survive crashes that close the file early.
--
--   dbg()  — Verbose, requires DEBUG = true. Rebuild-level detail: every
--             rebuild start/end, per-action lists, overlay IDs. File only
--             (no print) so game log.txt stays clean.
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
        EHM_LOG.file:write(string.format("Version: 0.9.0  |  Started: %s  |  DEBUG: %s\n\n",
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

-- Always-on: important events. Written to file and mirrored to game log.txt.
local function log(msg, ...)
    if EHM_LOG.file then
        local line = string.format(msg, ...)
        EHM_LOG.file:write(line .. "\n")
        EHM_LOG.file:flush()
        print("[EHM] " .. line)
    end
end

-- Verbose: rebuild-level detail. Written to file only (no game log noise).
-- No-op unless DEBUG = true.
local function dbg(msg, ...)
    if DEBUG and EHM_LOG.file then
        EHM_LOG.file:write("[D] " .. string.format(msg, ...) .. "\n")
        EHM_LOG.file:flush()
    end
end

-- =============================================================================
-- CATEGORY SYSTEM
-- Base game categories identified by $l10n_inputCategory_ prefix.
-- All other displayCategory values are bucketed under MODS.
-- =============================================================================

-- Ordered list of base game categories with display abbreviations.
-- Order determines left-to-right display in the filter strip.
local EHM_CATEGORIES = {
    { key = "$l10n_inputCategory_CAMERA",             abbr = "CAM",     label = "Camera"             },
    { key = "$l10n_inputCategory_CONSTRUCTION",       abbr = "BUILD",   label = "Construction"       },
    { key = "$l10n_inputCategory_CRANE",              abbr = "CRANE",   label = "Crane"              },
    { key = "$l10n_inputCategory_GAME",               abbr = "GAME",    label = "Game"               },
    { key = "$l10n_inputCategory_PLAYER_INTERACTIVE", abbr = "PLR INT", label = "Player Interactive" },
    { key = "$l10n_inputCategory_PLAYER_MOVEMENT",    abbr = "PLR MOV", label = "Player Movement"    },
    { key = "$l10n_inputCategory_RADIO",              abbr = "RADIO",   label = "Radio"              },
    { key = "$l10n_inputCategory_VEHICLE",            abbr = "VEHICLE", label = "Vehicle"            },
    { key = "$l10n_inputCategory_VEHICLE_DRIVING",    abbr = "DRIVING", label = "Driving"            },
    { key = "$l10n_inputCategory_VEHICLE_GEARBOX",    abbr = "GEARBOX", label = "Gearbox"            },
    { key = "$l10n_inputCategory_VEHICLE_LIGHTS",     abbr = "LIGHTS",  label = "Lights"             },
    { key = "$l10n_inputCategory_VEHICLE_WORK",       abbr = "WORK",    label = "Work"               },
    { key = "MODS",                                   abbr = "MODS",    label = "Mods"               },
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
function EHM_SETTINGS.load(filterEnabled, hiddenActions)
    for i = 1, #EHM_CATEGORIES do filterEnabled[i] = true end

    local xmlFile = XMLFile.loadIfExists("EHM_Settings", EHM_SETTINGS.getPath(), EHM_SETTINGS_getSchema())
    if xmlFile == nil then
        return nil, false  -- file does not exist → first-ever run
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

    xmlFile:delete()
    return savedState, true
end

-- Saves all settings. Works from any context (deleteMap, onUIModeExit, etc.)
-- because XMLFile.create uses the engine's own file system, not raw io.
-- hiddenActions is optional; pass nil to skip writing the <hidden> block.
function EHM_SETTINGS.save(filterEnabled, toggleState, hiddenActions)
    local dir = getUserProfileAppPath() .. "modSettings/"
    createFolder(dir)

    local xmlFile = XMLFile.create("EHM_Settings", EHM_SETTINGS.getPath(), "EHM", EHM_SETTINGS_getSchema())
    if xmlFile == nil then return end

    for i = 1, #EHM_CATEGORIES do
        xmlFile:setValue(string.format("EHM.filter#cat%d", i), filterEnabled[i] ~= false)
    end
    xmlFile:setValue("EHM.ui#state", toggleState or 0)

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

    xmlFile:save()
    xmlFile:delete()
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
    local ok, savedToggleState, settingsExisted = pcall(function()
        return EHM_SETTINGS.load(self.filterEnabled, self.hiddenActions)
    end)
    if not ok then
        for i = 1, #EHM_CATEGORIES do self.filterEnabled[i] = true end
        self.hiddenActions = {}
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
        log("WARNING: all categories were disabled in saved settings — reset to all enabled")
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
        log("WARNING: could not hook addExtraPrintText (mission or method not found)")
    end

    -- Toggle state is determined after the player spawns (see f1InitFrames in update()).
    -- We hide EHM during that brief init window; correct state is set once settled.
    self.toggleState     = 0
    self.isVisible       = false  -- hidden until post-spawn init completes
    self.handlingToggle  = false
    self.cachedF1Key     = nil    -- TOGGLE_HELP binding cached during rebuild
    self.ignoreF1Changes = true   -- suppress hook until post-spawn init is done
    self.f1InitFrames    = nil    -- set in onRegisterGlobalActionEvents
    self.lastKnownCtx    = nil    -- tracks context for immediate rebuild on change
    self.postInitCooldown = 0     -- ms; suppresses F1 hooks briefly after post-init
                                  -- to absorb spurious game initialization calls

    -- Hook setInputHelpVisible on the HUD (catches game initialization calls)
    -- AND setVisible on inputHelp directly (catches user-triggered F1 presses).
    -- Both paths call onF1Changed; ignoreF1Changes + handlingToggle guards prevent
    -- false triggers during init or from our own override calls.
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        g_currentMission.hud.setInputHelpVisible = Utils.appendedFunction(
            g_currentMission.hud.setInputHelpVisible,
            function(_, f1Visible)
                if not EnhancedHelpMenu.handlingToggle
                   and not EnhancedHelpMenu.ignoreF1Changes
                   and EnhancedHelpMenu.postInitCooldown <= 0 then
                    EnhancedHelpMenu:onF1Changed(f1Visible)
                end
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
                -- Guard must be set BEFORE advancing state and calling origSetVisible.
                -- setInputHelpVisible (also hooked) calls setVisible internally, so
                -- without this guard its appendedFunction would fire onF1Changed a
                -- second time after we return, double-advancing the state machine.
                -- pcall ensures handlingToggle is ALWAYS reset even if onF1Changed
                -- throws (e.g. a failed I/O call), so the toggle never gets stuck.
                EnhancedHelpMenu.handlingToggle = true
                pcall(EnhancedHelpMenu.onF1Changed, EnhancedHelpMenu, visible)
                EnhancedHelpMenu.handlingToggle = false
                local desiredF1 = (EnhancedHelpMenu.toggleState == 1)
                local result = origSetVisible(hiSelf, desiredF1)
                return result
            end
            log("inputHelp.setVisible override installed")
        else
            log("WARNING: hud.inputHelp is nil — inputHelp hook not installed")
        end
    else
        log("WARNING: could not hook setInputHelpVisible")
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

    -- Overlay creation is deferred to first draw() call to ensure the
    -- rendering pipeline is fully initialised before createImageOverlay runs.
    self.overlaysReady  = false
    self.overlaysDone   = false  -- set true once we've attempted creation

    log("loadMap complete")
end

function EnhancedHelpMenu:deleteMap()
    -- Exit UI mode cleanly if active when map unloads
    if self.uiMode then
        pcall(function() g_inputBinding:setShowMouseCursor(false) end)
        self.uiMode = false
    end
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions)
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
    end

    -- Wrap in context modification so keys work in the correct input context
    local currentContextName = g_inputBinding:getContextName()
    local newContextName     = contextName or currentContextName
    if currentContextName ~= newContextName then
        g_inputBinding:beginActionEventsModification(newContextName)
    end

    local function reg(actionName, callback)
        local action = InputAction[actionName]
        if action == nil then
            log("WARNING: InputAction.%s not found — mod may need a hash (run as ZIP)", actionName)
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

    if currentContextName ~= newContextName then
        g_inputBinding:beginActionEventsModification(currentContextName)
    end
end

function EnhancedHelpMenu.onUnregisterActionEvents(playerInputComponent)
    if playerInputComponent.player == nil or not playerInputComponent.player.isOwner then return end
    g_inputBinding:removeActionEventsByTarget(EnhancedHelpMenu)
end

function EnhancedHelpMenu:onF1Changed(f1Visible)
    -- Advance the three-state cycle: EHM only → F1 only → Both off → EHM only.
    -- The caller (inputHelp.setVisible override) passes the desired F1 state
    -- directly to origSetVisible, so we don't need to call setVisible here.
    self.toggleState = (self.toggleState + 1) % 3
    local eihOn = (self.toggleState == 0)
    self.isVisible = eihOn
    if eihOn then
        -- Establish a silent baseline so actions visible when EHM turns on
        -- don't falsely flash green. They were already there — the player
        -- just had EHM hidden. rebuild() clears silentRebuild when done.
        self.silentRebuild = true
        self:rebuild()
    end
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
    EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions)
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

function EnhancedHelpMenu:onPagePrev()
    if not self.isVisible then return end
    self.page = math.max(1, self.page - 1)
end

function EnhancedHelpMenu:onPageNext()
    if not self.isVisible then return end
    self.page = math.min(self.cachedTotalPages, self.page + 1)
end

-- ---------------------------------------------------------------------------
-- Device Filter
--
-- FS25 stores bindings per device. We enumerate connected devices from active
-- bindings and let the user cycle through them with F10.
-- Phantom devices (saved in inputBinding.xml but no longer connected) are
-- skipped by checking the device registry (devicesByInternalId).
-- ---------------------------------------------------------------------------

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
                if name == "KB_MOUSE_DEFAULT" then return "Keyboard / Mouse" end
                return name
            end
        end

        -- Secondary: match by deviceId string (for bindings without internalDeviceId)
        local bindingDevId = tostring(binding.deviceId or "")
        if bindingDevId ~= "" then
            for _, device in pairs(g_inputBinding.devicesByInternalId) do
                if type(device) == "table" and tostring(device.deviceId) == bindingDevId then
                    local name = tostring(device.deviceName)
                    if name == "KB_MOUSE_DEFAULT" then return "Keyboard / Mouse" end
                    return name
                end
            end
        end

        -- No registry match — device not connected, skip phantom binding
        if binding.isGamepad == true then return nil end
    end

    if binding.isKeyboard == true or binding.isMouse == true then
        return "Keyboard / Mouse"
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
            EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions)
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
    -- Cache the toggle-display key for the header, filtered for the current device.
    -- Always assign (even nil) so switching devices clears a stale binding from
    -- a previous device rather than leaving the old value stuck in the header.
    self.cachedF1Key = self:getBindings("TOGGLE_HELP_TEXT")
                    or self:getBindings("TOGGLE_HELP")

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
                                        -- callbackState 2 = hold-type action (confirmed via probe).
                                        -- 0=press, 1=axis/release, -1=axis/always-active.
                                        isHold    = event.callbackState == 2,
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
                    self.animState[name].shiftOffset =
                        (self.animState[name].shiftOffset or 0) + moved * (ROW_H + ROW_GAP)
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

            self.toggleState = desiredState
            self.isVisible   = (desiredState == 0)

            -- Sync the game's F1 visibility to match our desired state.
            -- handlingToggle suppresses our own hooks so we don't re-enter onF1Changed.
            local wantF1 = (desiredState == 1)
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
            if desiredState == 0 then
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
        log("initOverlays: createImageOverlay not available — falling back to flat rects")
        return
    end

    local rowTex  = MOD_DIR .. "ehm_row_bg.dds"
    local pillTex = MOD_DIR .. "ehm_pill_bg.dds"
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
        log("initOverlays: FAILED — one or more overlay IDs are nil, falling back to flat rects")
    end

    -- Eye icons (Stage 2 hide/un-hide UI). Loaded independently of the slice
    -- overlays above — they don't need UV setup, and the panel still works if
    -- they fail to load. The row-draw code nil-checks ovEyeOpen / ovEyeHidden
    -- before rendering, so a load failure simply means no icons in filter mode.
    local eyeOpenTex   = MOD_DIR .. "ehm_eye_open.dds"
    local eyeHiddenTex = MOD_DIR .. "ehm_eye_hidden.dds"
    self.ovEyeOpen   = createImageOverlay(eyeOpenTex)
    self.ovEyeHidden = createImageOverlay(eyeHiddenTex)
    log("initOverlays: eye icons %s",
        (self.ovEyeOpen ~= nil and self.ovEyeHidden ~= nil) and "loaded" or "FAILED")
end

-- ---------------------------------------------------------------------------
-- Sprite Renderers — rounded rows and key pills using gui.png atlas
-- Falls back to drawFilledRect if overlays aren't available.
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:renderRow(x, y, w, h, r, g, b, a)
    if self.overlaysReady then
        local c = ROW_CAP_W
        setOverlayColor(self.ovRowL, r,g,b,a); renderOverlay(self.ovRowL, x,     y, c,     h)
        setOverlayColor(self.ovRowC, r,g,b,a); renderOverlay(self.ovRowC, x+c,   y, w-c*2, h)
        setOverlayColor(self.ovRowR, r,g,b,a); renderOverlay(self.ovRowR, x+w-c, y, c,     h)
    else
        -- Fallback: 3-rect approximate rounded rectangle
        local R = math.min(CORNER_R, h * 0.45)
        drawFilledRect(x+R,   y,   w-R*2, h,     r, g, b, a)
        drawFilledRect(x,     y+R, R,     h-R*2, r, g, b, a)
        drawFilledRect(x+w-R, y+R, R,     h-R*2, r, g, b, a)
    end
end

function EnhancedHelpMenu:renderKey(x, y, w, h, r, g, b, a)
    if self.overlaysReady then
        local c = KEY_CAP_W
        setOverlayColor(self.ovKeyL, r,g,b,a); renderOverlay(self.ovKeyL, x,     y, c,     h)
        setOverlayColor(self.ovKeyC, r,g,b,a); renderOverlay(self.ovKeyC, x+c,   y, w-c*2, h)
        setOverlayColor(self.ovKeyR, r,g,b,a); renderOverlay(self.ovKeyR, x+w-c, y, c,     h)
    else
        local R = math.min(PILL_R, h * 0.45)
        drawFilledRect(x+R,   y,   w-R*2, h,     r, g, b, a)
        drawFilledRect(x,     y+R, R,     h-R*2, r, g, b, a)
        drawFilledRect(x+w-R, y+R, R,     h-R*2, r, g, b, a)
    end
end

-- Header: true 9-slice so corner radius stays constant regardless of header height.
-- 4 corner pieces (fixed c × ch), 4 edge pieces (stretch one axis), 1 center fill.
function EnhancedHelpMenu:renderHeader(x, y, w, h, r, g, b, a)
    if self.overlaysReady then
        local c  = ROW_CAP_W  -- horizontal cap (~8px)
        local ch = HDR_CAP_H  -- vertical cap (~6px, from row texture proportions)
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
        local R = math.min(CORNER_R, h * 0.45)
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

-- Draws a single key pill with left edge at lx, bottom at botY.
-- Returns the right edge x of the drawn pill.
function EnhancedHelpMenu:drawPill(lx, botY, text, alpha)
    alpha = alpha or 1.0
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
    local tw    = safeTextWidth(SIZE_TEXT, text)
    local pillW = math.max(tw + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    self:drawPill(rx - pillW, botY, text, alpha)
    return rx - pillW
end

-- Draws a single header key pill (bold, white text) left-anchored at lx.
-- Returns the right edge x. isSelected = lighter white fill (device name pill, FILTER when open).
function EnhancedHelpMenu:drawHeaderPill(lx, botY, text, isSelected)
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
    local groups = splitBinding(binding)
    local sepW  = safeTextWidth(SIZE_TEXT, "|") + SEP_PAD
    local plusW = safeTextWidth(SIZE_TEXT, "+") + SEP_PAD
    local cx = rx
    -- draw right-to-left
    for gi = #groups, 1, -1 do
        local keys = groups[gi]
        for ki = #keys, 1, -1 do
            cx = self:drawPillRight(cx, botY, keys[ki], alpha)
            if ki > 1 then
                -- "+" between chord keys — bright white text, vertically centered
                cx = cx - plusW
                if setTextBold ~= nil then setTextBold(false) end
                self:setColor(COL_SEP_PLUS, COL_SEP_PLUS[4] * alpha)
                renderText(cx + SEP_PAD * 0.5, botY + TEXT_OY, SIZE_TEXT, "+")
            end
        end
        if gi > 1 then
            -- "|" between binding groups — thin drawn line matching native FS25 style
            cx = cx - sepW
            local lineW = math.max(1 * PX, 0.000521)  -- ~1px wide
            local lineH = ROW_H * 0.55                 -- 55% of row height
            local lineX = cx + (sepW - lineW) * 0.5    -- horizontally centered in gap
            local lineY = botY + (ROW_H - lineH) * 0.5 -- vertically centered in row
            drawFilledRect(lineX, lineY, lineW, lineH,
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

-- Truncates labelText so it fits within maxW, appending "..." using binary search.
local function truncateLabel(labelText, maxW)
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
    return string.sub(labelText, 1, lo) .. ellipsis
end

-- Draws a thin horizontal strike-through line over uppercase label text.
-- baselineY is the renderText y-coordinate (text baseline). The line is placed
-- 30% of SIZE_TEXT above the baseline, which lands through the visual middle
-- of cap-height letters. Width matches the rendered label width exactly so the
-- line stops at the last character (or at the trailing ellipsis on truncated labels).
-- Used to mark hidden rows in filter mode.
local function drawStrikeThrough(leftX, baselineY, text, alpha)
    local w = safeTextWidth(SIZE_TEXT, text)
    drawFilledRect(leftX, baselineY + SIZE_TEXT * 0.30,
        w, 1 * PY,
        COL_WHITE[1], COL_WHITE[2], COL_WHITE[3], alpha)
end

-- Computes the row layout descriptor for a single action item.
-- Called once per action per rebuild cycle; results are cached in rowLayoutCache.
--
-- Single row (isDouble=false):
--   { labelText, displayBinding, holdPfx }
--
-- Double row (isDouble=true): label on row 1, pills split across rows 1 and 2.
--   { labelText, row1Binding, row2Binding, holdPfx }
--   row1Binding: pills beside the label on row 1 (may be nil if none fit)
--   row2Binding: remaining pills on row 2, right-anchored (may be nil)
--   holdPfx:     for HOLD actions, shown on row 2 before its pill
local function computeRowLayout(item, contentW, ehm)
    local labelText = string.upper(item.label)
    local labelW    = safeTextWidth(SIZE_TEXT, labelText)

    -- HOLD actions display first group only (native FS25 behaviour).
    -- Resolve displayBinding first so holdPfx can check it — HOLD prefix is
    -- only shown when there is actually a key to pair it with. An unbound
    -- hold-type action shows just the label, not orphaned "HOLD" text.
    local displayBinding = item.binding
    if item.isHold and displayBinding ~= nil then
        local g = splitBinding(displayBinding)
        if #g > 0 then displayBinding = table.concat(g[1], " + ") end
    end
    local holdPfx  = (item.isHold and displayBinding ~= nil) and "HOLD " or nil
    local holdPfxW = holdPfx and safeTextWidth(SIZE_TEXT, holdPfx) or 0

    local bindW  = displayBinding ~= nil and ehm:measureBindingWidth(displayBinding) or 0
    local totalW = labelW + LABEL_GAP + holdPfxW + bindW

    -- Fast path: everything fits on one row
    if totalW <= contentW then
        return { isDouble=false, labelText=labelText,
                 displayBinding=displayBinding, holdPfx=holdPfx }
    end

    -- Overflow — needs two rows.
    -- HOLD: label on row 1, HOLD+pill on row 2 (prefix stays with its pill).
    if holdPfx ~= nil then
        if labelW > contentW then labelText = truncateLabel(labelText, contentW) end
        return { isDouble=true, labelText=labelText,
                 row1Binding=nil, row2Binding=displayBinding, holdPfx=holdPfx }
    end

    -- Non-HOLD: greedily fill row 1 with complete binding groups alongside label.
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
        holdPfx     = nil,
    }
end
function EnhancedHelpMenu:measureBindingWidth(binding)
    if binding == nil then return 0 end
    local groups = splitBinding(binding)
    local sepW  = safeTextWidth(SIZE_TEXT, "|") + SEP_PAD
    local plusW = safeTextWidth(SIZE_TEXT, "+") + SEP_PAD
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

-- Returns true if we are in a vehicle context with a non-empty selectable object chain,
-- meaning the native compact vehicle indicator will be rendering at PANEL_TOP_Y.
-- Used by draw() to reserve schema row space in the header and skip the double-background
-- render in that area. Actual icon drawing is handled by the native FS25 renderer.
function EnhancedHelpMenu:getSchemaIcons()
    if g_currentMission == nil then return nil end
    local ih = g_currentMission.hud and g_currentMission.hud.inputHelp
    if ih == nil then return nil end
    local v = ih.vehicle
    if v == nil then return nil end
    local so = v.selectableObjects
    if so == nil or #so == 0 then return nil end
    -- Return a non-nil value so hasSchema=true triggers the schema row
    return true
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
--   [ ACTION ROW 2 … up to PAGE_SIZE rows                                 ]
-- ---------------------------------------------------------------------------

function EnhancedHelpMenu:draw()
    -- Lazy overlay init — deferred from loadMap to guarantee render pipeline ready
    self:initOverlays()

    -- Always clear extraPrintTexts regardless of visibility.
    local extraTexts     = self.extraPrintTexts
    self.extraPrintTexts = {}
    local numExtra       = #extraTexts

    if not self.isVisible then return end
    if setTextBold ~= nil then setTextBold(false) end

    -- Detect extra text appearing or increasing while visible and not in warmup.
    -- Triggers on ANY count increase (0→1, 1→2 etc.) so new texts on chainsaw
    -- pickup etc. also animate, not just the first-ever appearance.
    -- Suppressed during warmupTimer (same window as new-action detection) so
    -- texts already present at spawn don't falsely flash green.
    -- Build a set of current text strings for comparison.
    -- prevExtraTexts holds what was shown last frame — captured BEFORE updating
    -- so the trigger can save it as "what existed before new texts arrived".
    local prevSet = self.prevExtraTexts or {}
    local curSet  = {}
    for _, t in ipairs(extraTexts) do curSet[t] = true end

    local xtInWarmup = self.currentContextName == "PLAYER" and (self.warmupTimer or 0) > 0
    if numExtra > self.prevExtraCount
       and not xtInWarmup
       and not self.silentRebuild
       and self.extraTextAccentPhase == "done" then
        -- Capture texts that existed BEFORE this trigger so the render loop
        -- can identify which rows are genuinely new by content comparison.
        self.extraTextBaseSet     = prevSet
        self.extraTextAccentPhase = "delay"
        self.extraTextAccentTimer = ANIM_ACCENT_DELAY
        self.extraTextAccentAlpha = 0
        log("Extra text: count %d→%d — accent bar triggered", self.prevExtraCount, numExtra)
    end

    self.prevExtraTexts = curSet
    self.prevExtraCount = numExtra

    local x      = PANEL_X
    local topY   = PANEL_TOP_Y
    local width  = PANEL_WIDTH
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

    -- Pre-pass: compute (or retrieve cached) row layout for every action.
    -- Double-height rows count as 2 slots against PAGE_SIZE so the panel never overflows.
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
    local totalPages = math.max(1, math.ceil(totalSlots / PAGE_SIZE))
    self.cachedTotalPages = totalPages  -- shared with onPageNext/Prev
    if self.page < 1          then self.page = 1          end
    if self.page > totalPages then self.page = totalPages end

    -- Find the first action on the current page.
    local skipSlots = (self.page - 1) * PAGE_SIZE
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
        if slotsOnPage + s > PAGE_SIZE then break end
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
        local tw = safeTextWidth(SIZE_TEXT, EHM_CATEGORIES[i].abbr) + KEY_PAD_X * 2
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
    local schemaIcons  = inVehicle and self:getSchemaIcons() or nil
    local hasSchema    = schemaIcons ~= nil
    local schemaRowH   = hasSchema and (ROW_H + ROW_GAP) or 0

    -- -------------------------------------------------------------------------
    -- Header height: schema row + base (2 rows) + filter strip + extra texts
    -- -------------------------------------------------------------------------
    local headerH = HDR_PAD
                  + schemaRowH                   -- vehicle schema row (VEHICLE ctx only)
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
                    + PAGE_SIZE * ROW_H
                    + math.max(0, PAGE_SIZE - 1) * ROW_GAP
                    + PAD_BOTTOM

    -- -------------------------------------------------------------------------
    -- Background panels — full-screen dim overlay and panel alpha boost
    -- were removed in Session 14; DOF blur on the game world provides the
    -- modal focus effect instead.
    -- -------------------------------------------------------------------------
    local headerBgTop = hasSchema and (topY - schemaRowH) or topY
    local headerBgH   = headerH - (hasSchema and schemaRowH or 0)
    local panelAlpha  = 0.65
    self:renderHeader(x, headerBgTop - headerBgH, width, headerBgH,
        COL_BG_HEADER[1], COL_BG_HEADER[2], COL_BG_HEADER[3], panelAlpha)

    -- Key bindings and device label — used across both header rows
    local keyToggle   = self.cachedF1Key                      or "?"
    local keyDevice   = self:getBindings("EHM_CYCLE_DEVICE") or "?"
    local keyPrev     = self:getBindings("EHM_PAGE_PREV")    or "?"
    local keyNext     = self:getBindings("EHM_PAGE_NEXT")    or "?"
    local keyFilter   = self:getBindings("EHM_UI_MODE")      or "?"
    local device      = self.deviceModes[self.deviceModeIndex]
    local deviceLabel = device ~= nil and string.upper(device.label) or "?"
    deviceLabel = deviceLabel:gsub("KEYBOARD / MOUSE", "KB/MOUSE")

    -- -------------------------------------------------------------------------
    -- Schema row (VEHICLE context only): space reserved for native compact
    -- vehicle indicator. With PANEL_TOP_Y = ih.y (0.9722) it renders naturally
    -- inside our header. Background blends because both use #010101 @ 65%.
    -- -------------------------------------------------------------------------

    -- -------------------------------------------------------------------------
    -- Header row 1: action count + page (left) | DEVICE [F10] [KB/MOUSE] (right)
    -- Numbers bold white; label words dim. Device block consolidated right-anchored.
    -- r1BotY shifts down by schemaRowH when the schema row is present.
    -- -------------------------------------------------------------------------
    local r1BotY = topY - HDR_PAD - schemaRowH - ROW_H
    local textY1 = r1BotY + TEXT_OY

    -- Left: "27 ACTIONS  |  PAGE 1/3" — numbers bold, labels dim
    local hx1 = leftX
    local countStr = tostring(total)
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(hx1, textY1, SIZE_TEXT, countStr)
    hx1 = hx1 + safeTextWidth(SIZE_TEXT, countStr)
    if setTextBold ~= nil then setTextBold(false) end
    self:setColor(COL_HINT_LBL)
    local midLbl = " ACTIONS  |  PAGE "
    renderText(hx1, textY1, SIZE_TEXT, midLbl)
    hx1 = hx1 + safeTextWidth(SIZE_TEXT, midLbl)
    local pageStr = string.format("%d/%d", self.page, totalPages)
    if setTextBold ~= nil then setTextBold(true) end
    self:setColor(COL_WHITE)
    renderText(hx1, textY1, SIZE_TEXT, pageStr)

    -- Right: DEVICE [F10] [KB/MOUSE] — three-part block, right-anchored
    -- Draw right-to-left: selected pill → key pill → label
    local devPillGap = 3 * PX
    local devNameW   = math.max(safeTextWidth(SIZE_TEXT, deviceLabel) + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    local devKeyW    = math.max(safeTextWidth(SIZE_TEXT, keyDevice)   + KEY_PAD_X * 2, KEY_CAP_W * 2 + PX)
    local devLblW    = safeTextWidth(SIZE_TEXT, "DEVICE")

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
    renderText(keyPillLx - devPillGap - devLblW, textY1, SIZE_TEXT, "DEVICE")

    -- -------------------------------------------------------------------------
    -- Header row 2: hint labels + key pills (left) | FILTER [F4] (right)
    -- Hint labels dim, not bold. DEVICE removed (consolidated into row 1).
    -- FILTER label and pill: dim/standard when closed, white/selected when open.
    -- -------------------------------------------------------------------------
    local r2BotY = r1BotY - ROW_GAP - ROW_H
    local textY2 = r2BotY + TEXT_OY

    -- Left: TOGGLE [F1]  PAGE [F6/F7]
    local hx2 = leftX
    local hintPairs = {
        {"TOGGLE", keyToggle},
        {"PAGE",   keyPrev .. "/" .. keyNext},
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
    local flblW = safeTextWidth(SIZE_TEXT, "FILTER")
    if setTextBold ~= nil then setTextBold(self.uiMode) end
    self:setColor(self.uiMode and COL_WHITE or COL_HINT_LBL)
    renderText(rx2 - flblW, textY2, SIZE_TEXT, "FILTER")

    -- SELECT ALL / DESELECT ALL button — only when filter mode open, left of FILTER block.
    -- SELECT ALL (active style)  — shown when any category is OFF → clicking turns all ON.
    -- DESELECT ALL (inactive style) — shown when all ON → clicking turns all OFF.
    self.hoveredAllToggle = false
    if self.uiMode then
        local allOn = true
        for i = 1, #EHM_CATEGORIES do
            if self.filterEnabled[i] == false then allOn = false; break end
        end
        local allLabel = allOn and "DESELECT ALL" or "SELECT ALL"
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
                renderText(tx + KEY_PAD_X, rowBotY + TEXT_OY, SIZE_TEXT, cat.abbr)
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
                EHM_SETTINGS.save(self.filterEnabled, self.toggleState, self.hiddenActions)
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
            else
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
            for _, etext in ipairs(renderTexts) do
                exY = exY - ROW_H
                -- Row is new when animation is active AND its content wasn't in the base set
                local isNewRow = animActive and (baseSet[etext] == nil)
                -- Grey bar -- always drawn, provides the constant baseline
                drawFilledRect(x + ROW_CAP_W, exY + barPad, ACCENT_BAR_W, ROW_H - barPad * 2,
                    COL_XT_BAR[1], COL_XT_BAR[2], COL_XT_BAR[3], COL_XT_BAR[4] * xtAlpha)
                -- Green bar -- drawn on top of grey when animation is active, fades in/out
                if isNewRow then
                    drawFilledRect(x + ROW_CAP_W, exY + barPad, ACCENT_BAR_W, ROW_H - barPad * 2,
                        COL_BG_KEY_NEW[1], COL_BG_KEY_NEW[2], COL_BG_KEY_NEW[3],
                        self.extraTextAccentAlpha * ANIM_ACCENT_OPACITY * xtAlpha)
                end
                -- Text -- white, not bold, uppercase (same weight as action row labels)
                if setTextBold ~= nil then setTextBold(false) end
                self:setColor(COL_WHITE, xtAlpha)
                local safe = etext and string.upper(etext) or ""
                renderText(leftX, exY + TEXT_OY, SIZE_TEXT, safe)
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
                if layout.holdPfx ~= nil then
                    -- HOLD prefix + pill right-anchored as a unit
                    local hpfxW  = safeTextWidth(SIZE_TEXT, layout.holdPfx)
                    local pillsW = layout.row2Binding and self:measureBindingWidth(layout.row2Binding) or 0
                    self:setColor(COL_HOLD, COL_HOLD[4] * dimAlpha * fadeAlpha)
                    renderText(bindRx - hpfxW - pillsW, r2Y + TEXT_OY, SIZE_TEXT, layout.holdPfx)
                    if layout.row2Binding ~= nil then
                        self:drawBindingPills(bindRx, r2Y, layout.row2Binding, dimAlpha * fadeAlpha)
                    end
                elseif layout.row2Binding ~= nil then
                    self:drawBindingPills(bindRx, r2Y, layout.row2Binding, dimAlpha * fadeAlpha)
                end
            else
                -- ── Single row (common case) ─────────────────────────────────
                self:setColor(COL_WHITE, dimAlpha * fadeAlpha)
                renderText(labelLeftX, r1Y + TEXT_OY, SIZE_TEXT, layout.labelText)
                if item.isHidden then
                    drawStrikeThrough(labelLeftX, r1Y + TEXT_OY, layout.labelText, dimAlpha * fadeAlpha)
                end

                if layout.holdPfx ~= nil then
                    local hpfxW  = safeTextWidth(SIZE_TEXT, layout.holdPfx)
                    local pillsW = layout.displayBinding and self:measureBindingWidth(layout.displayBinding) or 0
                    self:setColor(COL_HOLD, COL_HOLD[4] * dimAlpha * fadeAlpha)
                    renderText(bindRx - hpfxW - pillsW, r1Y + TEXT_OY, SIZE_TEXT, layout.holdPfx)
                    if layout.displayBinding ~= nil then
                        self:drawBindingPills(bindRx, r1Y, layout.displayBinding, dimAlpha * fadeAlpha)
                    end
                elseif layout.displayBinding ~= nil then
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
-- Register
-- ---------------------------------------------------------------------------
addModEventListener(EnhancedHelpMenu)