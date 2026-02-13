# ykwm - Plan Document

A custom terminal multiplexer designed for experimental UX with floating popups, tiled scrollable windows, and modern terminal features.

## Context & Motivation

### The Problem with Current Solutions

**Tmux Limitations:**
- OSC 133 (semantic prompt/shell integration) sequences are consumed by tmux and not passed through to the parent terminal
- This breaks Ghostty's click-to-move cursor feature and other modern terminal capabilities
- Maintainer has explicitly rejected requests for configurable passthrough (Issue #3618)

**Existing Alternatives:**
- **zmx**: Excellent for session persistence but explicitly does NOT provide windows/tabs/splits
- **dvtm**: Provides tiling but no floating popups, limited extensibility
- **abduco**: Session persistence only, no window management

**The Gap:**
No existing solution provides:
1. Session persistence without breaking OSC 133 passthrough
2. Floating popup windows (like tmux popup)
3. Experimental tiled scrollable UX
4. Deep integration with modern terminal emulators (Ghostty)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Ghostty Terminal (GPU accelerated, OSC 133 support)         │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ zmx session (session persistence layer)                 │ │
│ │ ┌─────────────────────────────────────────────────────┐ │ │
│ │ │ ykwm (custom multiplexer)                           │ │ │
│ │ │                                                     │ │ │
│ │ │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │ │ │
│ │ │  │ Window 1 │  │ Window 2 │  │ Window 3 │           │ │ │
│ │ │  │ (scroll) │  │ (scroll) │  │ (scroll) │           │ │ │
│ │ │  └──────────┘  └──────────┘  └──────────┘           │ │ │
│ │ │                                                     │ │ │
│ │ │  ╔══════════════╗                                   │ │ │
│ │ │  ║ Popup (fzf)  ║ ← floating overlay                │ │ │
│ │ │  ╚══════════════╝                                   │ │ │
│ │ └─────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **Ghostty sees one terminal session** - No OSC 133 passthrough issues
2. **zmx handles persistence** - Detach/reattach with full state restoration
3. **ykwm handles all windowing** - Complete control over UX
4. **Shell integration works** - Click-to-move, semantic prompts in the root session

## Core Features

### 1. Window Management

**Tiling Layouts:**
- Vertical stack (master on left, tiles on right)
- Horizontal stack (master on top, tiles below)
- Grid layout (equal distribution)
- Fullscreen (single window)

**Navigation:**
- Directional navigation (vim-style: h/j/k/l)
- Window numbers (1-9)
- Jump to last active window

**Window Operations:**
- Create new window (spawn shell or command)
- Close window
- Zoom window to master area
- Swap windows
- Move windows between layouts

### 2. Popup System

**Floating Windows:**
- Absolute positioning (x, y coordinates)
- Z-index layering
- Modal mode (captures all input) or non-modal
- Animation support (fade, slide)

**Popup Types:**
- Command popup (fzf, picker, etc.)
- Notification popup (transient)
- Persistent popup (stays open)
- Nested popups (tree structure)

**Popup Management:**
- Parent-child relationships
- Auto-close on selection
- Escape key handling
- Focus management

### 3. Scrollable Tiled Windows (Experimental)

**Synchronized Scrolling:**
- All visible tiles scroll together
- View history across multiple panes simultaneously
- Timeline view of command outputs

**Scrollback Features:**
- Independent scrollback per window
- Shared scrollback search
- Scroll position indicators
- Mini-map of scrollback

**Experimental UX:**
- Inline expandable sections (fold/unfold output)
- Contextual popups that follow cursor
- Zoom transitions between tile and fullscreen
- Preview panes (hover to see full output)

### 4. Modern Terminal Support

**Ghostty Integration:**
- Native scrollback handling
- Clipboard integration (OSC 52)
- Hyperlink support (OSC 8)
- Image support (Kitty graphics protocol)
- Mouse event handling

**OSC 133 (Semantic Prompts):**
- Click-to-move cursor within prompt
- Prompt/output/command region detection
- Jump to previous/next prompt
- Triple-click to select command output

### 5. Tabs / Workspaces

**Workspace Model:**
- Multiple tabs (workspaces), each with independent window tree and layout state
- Fast tab switching without destroying PTYs
- Optional per-tab default layout

**Tab Operations:**
- Create/close tab
- Rename tab
- Next/previous tab cycling
- Move window between tabs
- Jump directly to tab by index

**State Rules:**
- Active tab owns input focus and visible rendering
- Inactive tabs keep PTYs alive and continue buffering output
- Optional lazy render for inactive tabs to reduce frame cost

## Technical Design

### Core Components

```
src/
├── main.zig              # Entry point, CLI parsing
├── multiplexer.zig       # Main event loop, window management
├── window.zig            # Window structure and operations
├── workspace.zig         # Tab/workspace manager and active workspace state
├── layout.zig            # Layout engine interface + shared types
├── layout_native.zig     # Native tiling algorithms (direct implementation)
├── layout_opentui.zig    # OpenTUI-backed layout adapter (optional)
├── popup.zig             # Popup/floating window management
├── renderer.zig          # Terminal rendering and output
├── pty.zig               # PTY management and I/O
├── vt.zig                # Terminal emulation (ghostty-vt integration)
├── scrollback.zig        # Scrollback buffer management
├── input.zig             # Keyboard and mouse input handling
├── config.zig            # Configuration parsing
└── ipc.zig               # Inter-process communication (zmx integration)
```

### Data Structures

**Window:**
```zig
const Window = struct {
    id: u32,
    pty: Pty,
    vt: ghostty_vt.Terminal,
    scrollback: ScrollbackBuffer,
    layout: Rect,
    floating: bool,
    visible: bool,
    focused: bool,
    title: []const u8,
    // Window state
    cursor_position: Position,
    scroll_offset: usize,
    // Relationships
    parent: ?*Window,
    children: ArrayList(*Window),
};
```

**Popup:**
```zig
const Popup = struct {
    window: Window,
    modal: bool,
    position: Position,      // Absolute or relative
    size: Size,
    z_index: u32,
    animation: Animation,
    parent: ?*Window,
    auto_close: bool,
};
```

**Layout:**
```zig
const Layout = struct {
    type: LayoutType,        // vertical, horizontal, grid, fullscreen
    master_area: Rect,
    tile_area: Rect,
    master_count: u32,
    gap: u32,
    // Layout-specific data
    windows: ArrayList(*Window),
};
```

### Rendering Pipeline

**Overview:**

Each window owns a `ghostty_vt.Terminal` instance. PTY output is fed into the VT
instance via `vtStream().nextSlice()`. The renderer reads cell data from each VT
instance's active screen and composites them into a single output stream written
to stdout.

**1. Layout Calculation:**
- Calculate `Rect` (row, col, width, height) for each window based on current layout
- Sort floating windows (popups) by z-index
- Account for gaps and borders (1-cell borders, configurable gaps)

**2. VT State Update:**
- `poll()` all PTY file descriptors for readable data
- For each PTY with data: read into buffer, feed via `vt_stream.nextSlice(buf[0..n])`
- Each VT instance independently tracks cursor, scrollback, alternate screen, etc.
- Mark windows with new data as "dirty" for rendering

**3. Screen Composition (cell-by-cell):**

```
For each frame:
  1. Allocate a screen buffer: cells[total_rows][total_cols]
  2. For each tiled window (back to front):
     - For each row in window.layout.height:
       - For each col in window.layout.width:
         - Read cell from window.vt.screens.active at (col, row + scroll_offset)
         - Write cell to screen buffer at (window.layout.x + col, window.layout.y + row)
  3. Draw borders between windows (box-drawing characters)
  4. For each popup (sorted by z_index, low to high):
     - Same cell-by-cell copy, overwriting screen buffer
     - Draw popup border/shadow
  5. Diff against previous frame's screen buffer
  6. Emit only changed cells as escape sequences
```

**Cell Representation:**
```zig
const Cell = struct {
    char: u21,              // Unicode codepoint (or 0 for empty)
    fg: Color,              // Foreground color (indexed, RGB, or default)
    bg: Color,              // Background color
    flags: StyleFlags,      // Bold, italic, underline, etc.
    wide: bool,             // Part of a wide character
};
```

**4. Diff-Based Output:**

Rather than redrawing the entire screen every frame, maintain a `prev_buffer` and
`curr_buffer`. On each frame:
- Compare cell-by-cell between prev and curr
- For contiguous runs of changed cells, emit:
  - `CSI row;col H` (cursor position)
  - `CSI 38;2;r;g;b m` (fg color) / `CSI 48;2;r;g;b m` (bg color) as needed
  - Character data
- Swap prev/curr buffers
- This keeps output minimal and avoids flicker

**5. Cursor Handling:**
- Only one window has focus; only that window's cursor is visible
- After compositing, position the real terminal cursor at the focused window's
  cursor position (translated to absolute screen coordinates)
- Hide cursor during rendering (`CSI ?25l`), show after (`CSI ?25h`)

**6. Performance Targets:**
- Frame budget: <16ms (60fps) for smooth interaction
- Only re-render when at least one window is dirty (PTY output or user input)
- Batch PTY reads: drain all available data per poll cycle before rendering
- Coalesce rapid updates: if multiple PTY reads happen within one poll cycle,
  only render once

**Alternate Screen Handling:**
- Programs like vim/less use the alternate screen buffer
- `ghostty_vt.Terminal` tracks this automatically via `screens.active`
- When a window switches to alternate screen, its scrollback is preserved
  in the primary screen; rendering reads from whichever screen is active

**Terminal Resize:**
- On SIGWINCH: get new terminal size, recalculate all layouts
- For each window: call `term.resize(alloc, new_cols, new_rows)` with the
  window's new dimensions (not the full terminal size)
- Send `TIOCSWINSZ` ioctl to each child PTY with its new dimensions
- Re-render full frame (mark all windows dirty)

### Input Handling

**Key Bindings:**
- All commands prefixed with modifier (default: Ctrl+G, configurable)
- Modal editing support for popups
- Mouse support (click to focus, drag to resize)

**Input Routing:**
- If popup is modal: route to popup
- If popup is non-modal: route to focused window
- Special keys (prefix): handle by multiplexer
- Mouse events: determine target window by position

## Integration with Existing Tools

### zmx Integration

**Goal:** Seamless integration with zmx for session persistence

**How zmx Works (key insight from source):**

zmx's ghostty-vt instance sits **outside** the active data path. The daemon
reads PTY output, sends it to all connected clients, and **also** feeds it to
a ghostty-vt `Terminal` via `vtStream().nextSlice()`. The VT instance is only
used for state snapshots when a client reconnects — it does not sit between
the PTY and the client during normal operation.

```
zmx daemon architecture:
  PTY output ──┬──► client sockets (live data)
               └──► ghostty-vt Terminal (state tracking for reconnect)
```

**VT Instance Architecture (N+1 model):**

When ykwm runs inside zmx, there are N+1 ghostty-vt instances:
- **1 instance in zmx daemon**: Tracks the *composed* output that ykwm writes to stdout.
  This is what zmx uses to restore the screen when a client reconnects.
- **N instances in ykwm**: One per window, tracking each child PTY's state independently.

This is correct and intentional. zmx's VT instance sees ykwm's final rendered output
(escape sequences for the composed screen), not the raw per-window PTY data. On zmx
reconnect, zmx replays ykwm's last rendered frame — which is exactly what the user
should see.

```
┌─ zmx daemon ──────────────────────────────────────┐
│                                                    │
│  ykwm stdout ──┬──► client sockets                │
│                └──► zmx's ghostty-vt (1 instance)  │
│                                                    │
│  ┌─ ykwm process ──────────────────────────────┐   │
│  │  PTY 1 ──► ghostty-vt #1 ──┐               │   │
│  │  PTY 2 ──► ghostty-vt #2 ──┤ compositor    │   │
│  │  PTY 3 ──► ghostty-vt #3 ──┘ ──► stdout    │   │
│  └─────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────┘
```

**State Restoration on zmx Reconnect:**

When a client reconnects to zmx, zmx replays the last rendered frame. This
restores the *visual* state but not ykwm's internal state (window layout,
scroll positions, focus). Two strategies:

1. **Visual-only restore (simpler, Phase 5 MVP):**
   - zmx replays the last frame → user sees the composed screen
   - ykwm is still running, so it immediately re-renders the next frame
   - User sees a brief flash but state is fully intact
   - This works because ykwm doesn't need to serialize anything — it stays alive

2. **Full state restore (future, if ykwm itself needs to restart):**
   - Serialize ykwm state to a file: window layout, scroll positions, focus,
     per-window VT state (via `TerminalFormatter`)
   - On restart, deserialize and reconstruct windows
   - Requires a state file format (JSON or binary)
   - Not needed for zmx integration since zmx keeps ykwm alive

**Key Requirements:**
- [x] Spawn as command within zmx session: `zmx attach <name> ykwm`
- [x] Proper PTY handoff between zmx and ykwm
- [x] Handle zmx detach/reattach gracefully (ykwm stays alive, re-renders on reattach)
- [x] Handle terminal resize on reattach (zmx sends SIGWINCH)
- [x] Graceful shutdown on zmx kill (SIGHUP/SIGTERM handling)

**Integration Points:**
- Use zmx's socket directory (`$ZMX_DIR` or `$XDG_RUNTIME_DIR/zmx`) for any
  ykwm-specific IPC if needed (e.g., `ykwm-ctl` commands)
- Detect `$ZMX_SESSION` env var to know we're inside zmx
- Work with zmx's `attach`, `detach`, `history` commands
- Support multiple clients viewing same session (zmx handles this transparently)

### dvtm Inspiration

**Lessons from dvtm:**
- Tiling layouts: vertical stack, bottom stack, grid
- Tag-based workspaces (views)
- External editor for copy mode (pipe scrollback to `$EDITOR`)
- Minimal configuration at compile time
- Unix philosophy: do one thing well

**What ykwm adds beyond dvtm:**
- Floating popup windows (dvtm limitation)
- Session persistence via zmx (dvtm delegates to abduco)
- Synchronized scrolling across tiles
- Experimental UX features

**Reference Implementation:**
Study dvtm's (~4000 lines of C):
- `dvtm.c`: Main event loop and window management
- `vt.c`: Terminal emulation (contrast with ghostty-vt approach)
- Layout algorithms in `tile.c`, `bstack.c`, `grid.c`

## Implementation Phases

### Phase 0: Proof of Concept (Week 0)

**Goals:**
- Validate ghostty-vt cell-level API access
- Validate basic compositing approach

**Deliverables:**
- [x] Minimal Zig project that depends on ghostty-vt
- [x] Create two `ghostty_vt.Terminal` instances, feed sample data
- [x] Read individual cells from `term.screens.active` and write composed output to stdout
- [x] Verify cell attributes (fg, bg, style) are accessible

**Exit Criteria:**
- Can read cell-by-cell from ghostty-vt screen grid
- Can render two VT instances side-by-side to stdout
- If cell access is not available, document alternative approach before proceeding

### Phase 0.5: Layout Spike (Week 1, parallel to early Foundation)

**Goals:**
- Evaluate OpenTUI as a layout engine candidate for tiling math
- Avoid hard-coupling the multiplexer to one layout implementation

**Deliverables:**
- [x] Define a `LayoutEngine` interface (`computeLayout`, `resize`, `setMasterCount`, etc.)
- [x] Implement one native vertical-stack layout through the interface
- [x] Implement one OpenTUI adapter for the same vertical-stack layout
- [ ] Compare outputs for identical inputs (golden tests)
- [ ] Benchmark both paths under resize + create/close window churn

**Status (2026-02-13):**
- Golden parity harness added in `src/layout_opentui.zig` for vertical-stack cases (single window, many windows, tiny sizes, non-zero gaps, master-count variation); currently `SkipZigTest` until OpenTUI adapter is fully integrated (`error.OpenTUINotIntegratedYet`).
- Layout churn benchmark added via `ykwm --benchmark-layout [N]` with resize + window-count churn simulation and avg/p95/max reporting.
- Sample run (`N=500`): `native avg=0.014ms p95=0.019ms max=0.043ms`; `opentui=unavailable`.
- Interim decision: keep `native` as active backend; retain `LayoutEngine` boundary and keep OpenTUI behind adapter until integration is complete.

**Decision Criteria (go/no-go):**
- Correctness: identical or intentionally equivalent tile rectangles
- Performance: no meaningful regression under target interaction patterns
- Complexity: adapter maintenance cost is acceptable for future layouts/popups

**Exit Criteria:**
- Clear decision documented: `native`, `opentui`, or `hybrid`
- Interface retained so decision can be revisited without renderer rewrite

### Phase 1: Foundation (Weeks 1-2)

**Goals:**
- Basic window management
- Single layout (vertical stack)
- PTY spawning and I/O
- Basic rendering
- Layout engine abstraction in place (selected backend from Phase 0.5)
- **Study dvtm codebase for layout algorithms**

**Deliverables:**
- [x] Project structure and build system
- [x] PTY management (create, read, write) — true PTY backend (`forkpty`) and resize ioctl path in place
- [x] Window data structure
- [x] Basic rendering loop
- [x] Input handling framework — basic prefix router + focused-window forwarding implemented
- [x] Vertical stack layout via `LayoutEngine`
- [x] Backend selection wiring (`layout_native` or `layout_opentui`)

**Testing:**
- Spawn multiple shells
- Switch between windows
- Basic navigation works

### Current Progress (2026-02-13)

Implemented in repository:
- `src/main.zig`: ghostty-vt POC render + workspace/layout POC output
- `src/main.zig`: interactive runtime loop (alternate screen, raw input, live pane rendering, tab/status lines)
- `src/layout.zig`: layout interface/types (`LayoutEngine`, `LayoutParams`, `Rect`)
- `src/layout_native.zig`: native layout implementations (vertical/horizontal/grid/fullscreen) + unit tests
- `src/layout_opentui.zig`: OpenTUI adapter placeholder for backend wiring
- `src/popup.zig`: popup manager (floating rects, z-index ordering, modal focus state, close/cycle operations)
- `src/window.zig`: window model
- `src/workspace.zig`: tab/workspace manager with tab close/switch, window move between tabs, per-tab layout cycling
- `src/pty.zig`: true PTY backend (`forkpty`), nonblocking master I/O, resize via `TIOCSWINSZ`, PTY tests
- `src/multiplexer.zig`: window->PTY routing, poll loop, output buffer per window, layout/tab/popup command handling, popup animation tick + auto-close on command exit, routing + resize propagation tests
- `src/input.zig`: prefix-key router (`Ctrl+G`) for command-vs-forwarded input decisions, layout/tab/popup command parsing (`MOD+p`, `MOD+Escape`, `MOD+Tab`)
- `src/input.zig`: prefix router + ESC/CSI sequence parser + SGR mouse metadata extraction
- `src/config.zig`: startup config loading + parser (`$XDG_CONFIG_HOME/ykwm/config[.zig]`, fallback `$HOME/.config/ykwm/config[.zig]`)
- `src/status.zig`: tab bar + status line formatters (active-tab marker, layout/window/focus summary)
- `src/scrollback.zig`: per-window scrollback buffer (line retention, page/half-page navigation, forward/backward search)
- `src/benchmark.zig`: frame-time benchmark harness (avg/p95/max ms)
- `src/zmx.zig`: ZMX environment/session detection (`$ZMX_SESSION`, `$ZMX_DIR`, `$XDG_RUNTIME_DIR/zmx`)
- `src/zmx.zig`: ZMX environment/session detection + detach command execution helper (`zmx detach <session>`)
- `src/zmx.zig`: ZMX attach command argv harness helper for attach flow validation
- `src/zmx.zig`: attach round-trip smoke helper (`zmx attach <session> ...` + cleanup)
- `src/signal.zig`: signal handler scaffold for `SIGWINCH`, `SIGHUP`, `SIGTERM` with drainable atomic flags
- Multiplexer runtime tick behavior: `SIGWINCH` => resize + redraw hint, `SIGHUP`/`SIGTERM` => graceful PTY shutdown path
- Dirty-window tracking and focused-window query APIs for renderer integration
- Input command actions wired: create/close window, create/close/switch tab, move focused window to next tab, layout cycle, next/prev focused window, detach request flag
- Popup command actions wired: open popup, close focused popup, cycle popup focus; modal popup input capture routes forwarded bytes to focused popup PTY
- Scrollback actions wired: `MOD+u` page-up and `MOD+d` page-down on focused window scrollback
- Multiplexer search API wired: forward/backward query over focused scrollback with jump-to-match behavior
- CLI utilities wired: `--help`, `--version`, `--benchmark [N]`, `--smoke-zmx [session]`
- User docs added: `docs/usage.md`, `docs/examples/config`, `docs/completions/ykwm.bash`, `docs/completions/_ykwm`
- Popup animation hooks implemented (fade-in/fade-out state + animation tick processing in runtime loop)
- FZF popup integration example implemented (`openFzfPopup` with auto-close semantics and fallback if `fzf` is unavailable)
- Detach request is surfaced by multiplexer tick and can invoke `zmx detach` when running in a zmx session
- Mouse coordinate path wired for click-to-focus (layout rect hit-test -> focused window update)
- Basic drag-to-resize support for vertical stack (divider hit-test + master ratio update + PTY resize propagation)
- Reattach path explicitly implemented and tested (`handleReattach`: resize + mark active windows dirty + redraw=true)
- `build.zig`: `run` and `test` steps wired
- Live runtime now renders pane content from per-window `ghostty-vt` state (control sequences parsed correctly)
- Live runtime now emits per-cell VT styles/colors from `ghostty-vt` (`style_id` + background-only cell colors), so shell prompts/output preserve ANSI colors in panes
- Live runtime now positions the terminal cursor to the focused pane's VT cursor location after each composed frame
- Live runtime now uses diff-based frame flushing with a cached frame model (changed cells only; no full-screen clear each redraw)
- Popup overlay rendering now respects z-order and topmost precedence during composition (base panes no longer mask popup cells)
- Popup focus now raises z-index (`cycle popup` + mouse click on popup), and modal popups capture click focus from underlying panes
- Popup toggle/close behavior is stable (`MOD+p` toggle, `MOD+Escape` immediate close)
- Child process exit is isolated: exiting pane/popup process now closes only that pane/popup, not the whole `ykwm` runtime
- Focus switch redraw is immediate (cursor/focus updates without waiting for next PTY output)
- Mouse support is now compositor-driven: click-to-focus + drag-to-resize work, mouse CSI is consumed by compositor and no longer injected into pane PTYs
- New-tab flow is now interactive by default: `MOD+t` creates/switches tab and spawns a shell immediately, with resize + redraw hooks
- Close/teardown paths are non-blocking across window/popup/tab/runtime shutdown paths (`deinitNoWait`), eliminating intermittent UI freezes on close
- Topology-change relayout is immediate: when a pane/popup process exits, surviving panes are resized/redrawn without requiring manual layout cycle
- Runtime VT ingest now has chunk-boundary guards (incomplete UTF-8/CSI tails are carried across reads) to reduce sequence-fragment artifacts in TUI apps
- Terminal-query compatibility expanded: DA (`CSI c`) and CPR (`CSI 6n`) replies are handled in multiplexer path, improving startup/render readiness for fish/zoxide/fzf-style flows

Validated locally:
- `zig build test` passes
- `zig build run` passes

Next implementation focus:
- Close out runtime compatibility soak for TUI-heavy apps (fzf/zoxide/fish) and keep targeted parser/query fixes small and test-backed.
- Then start Phase 6 synchronized scrolling and experimental interaction models.

### Next Milestone (Immediate)

- **Milestone:** Production-ready live renderer baseline
- **Scope:**
  - [x] Per-cell color/style output from `ghostty-vt` attributes
  - [x] Cursor placement for focused pane
  - [x] Diff-based frame flush (no full-screen clear each frame)
  - [x] Runtime smoke test: two shells, colored prompt/output, cursor/focus updates, popup layering/focus, resize + reattach preserved, and child-exit isolation
- **Exit Criteria:**
  - Colored shell prompts/output render correctly in both panes
  - No raw ANSI/control-sequence artifacts in pane content
  - Acceptable redraw smoothness during continuous output

### Execution Order (Next)

1. **Phase 0.5 closure (correctness first)**
   - [x] Add golden tests comparing `layout_native` and `layout_opentui` rect outputs for identical inputs (`vertical stack` first).
   - [x] Include edge cases: 1 window, many windows, tiny terminal sizes, non-zero gaps, master count changes.
   - Done when OpenTUI integration is complete and parity tests run without `SkipZigTest`.

2. **Phase 0.5 closure (performance second)**
   - [x] Add benchmark path for layout churn: repeated resize + create/close window cycles for both backends.
   - [x] Capture avg/p95/max timings and document backend decision (`native`, `opentui`, or `hybrid`) in this plan.
   - Done when OpenTUI benchmark data is available (currently reported as unavailable) and decision can be revisited.

3. **Runtime compatibility soak hardening**
   - [ ] Run targeted manual soak scenarios for `fish`, `fzf`, and `zoxide` flows in live runtime.
   - [ ] Keep parser/query compatibility fixes narrow and add regression tests per fix.
   - Done when no reproducible raw-sequence/render corruption remains in those scenarios.

4. **Phase 6 start (incremental slice)**
   - [ ] Implement synchronized scroll mode toggle (`MOD+s`) for visible tiled windows only.
   - [ ] Define clear state model (global sync-scroll flag + per-window offset source-of-truth).
   - [ ] Add tests for scroll propagation, focus changes, and tab boundaries.
   - Done when sync-scroll is stable enough to mark the first Phase 6 deliverable complete.

5. **Phase 6 follow-ons**
   - [ ] Inline fold/unfold output sections.
   - [ ] Cursor-following contextual popups.
   - [ ] Hover preview panes.
   - [ ] Tile/fullscreen zoom transitions.
   - Order these by implementation risk and testability after sync-scroll lands.

### Phase 2: Core Features (Weeks 3-4)

**Goals:**
- Multiple layouts
- Window lifecycle management
- Tab/workspace support
- Configuration system
- Better rendering

**Deliverables:**
- [x] Horizontal stack layout
- [x] Grid layout
- [x] Fullscreen zoom
- [x] Window creation/closing
- [x] Tab/workspace create/close/switch
- [x] Move window across tabs
- [x] Tab bar in status line (name + active marker)
- [x] Configuration file support
- [x] Window titles
- [x] Status bar

**Testing:**
- Create/close windows dynamically
- Switch layouts
- Switch tabs and preserve per-tab layout/focus
- Configuration reload

### Phase 3: Popup System (Weeks 5-6)

**Goals:**
- Floating windows
- Popup commands
- Modal/non-modal modes

**Deliverables:**
- [x] Floating window support
- [x] Popup spawning API
- [x] Z-index management
- [x] Modal input capture
- [x] Popup animations
- [x] Fzf integration example

**Testing:**
- Open fzf in popup
- Modal mode blocks input
- Popup closes correctly

### Phase 4: Scrollback (Weeks 7-8)

**Goals:**
- Scrollback buffers
- Scroll navigation
- Search

**Deliverables:**
- [x] Scrollback buffer implementation (per-window, currently PTY-fed; ghostty-vt-backed integration planned)
- [x] Scroll navigation (page up/down, half-page)
- [x] Search functionality (forward/backward search within scrollback)
- [x] Scroll position indicators (status bar shows scroll offset)

**Testing:**
- Scroll through history in a window
- Search finds text in scrollback
- Scroll indicators update correctly

### Phase 5: zmx Integration & Polish (Weeks 9-10)

**Goals:**
- Full zmx integration
- Mouse support
- Performance optimization

**Deliverables:**
- [x] Verify `zmx attach <session> ykwm` works correctly
- [x] Handle zmx detach/reattach (SIGWINCH, re-render)
- [x] Handle zmx kill (SIGHUP/SIGTERM graceful shutdown)
- [x] Mouse event handling (click to focus + drag to resize; compositor-consumed mouse CSI)
- [x] Performance benchmarks (<16ms frame time)
- [x] User documentation
- [x] Example configurations (including zmx workflow)
- [x] Shell completions

**Testing:**
- `zmx attach dev ykwm` — starts ykwm in zmx session
- Detach with `ctrl+\`, reattach with `zmx attach dev`
- ykwm re-renders correctly on reattach
- Multiple clients can view same ykwm session via zmx
- Mouse clicks focus correct window
- Performance is acceptable (<16ms frame time)

### Phase 6: Experimental UX (Weeks 11-12)

**Goals:**
- Synchronized scrolling across tiles
- Experimental interaction patterns

**Deliverables:**
- [ ] Synchronized scroll mode (all visible tiles scroll together)
- [ ] Inline expandable sections (fold/unfold command output)
- [ ] Contextual popups that follow cursor
- [ ] Preview panes (hover to see full output)
- [ ] Zoom transitions between tile and fullscreen

**Testing:**
- Sync scroll multiple windows
- Expand/collapse output sections
- Contextual popups appear at correct positions

### Phase 7: Advanced Features (Ongoing)

**Future Enhancements:**
- [ ] Tree-style popup management
- [ ] AI-powered contextual popups
- [ ] Plugin system (long-term)
- [ ] Remote session support
- [ ] Collaborative editing

## Long-term Plugin Support

### Scope

Plugin support is a long-term goal and is not required for MVP phases.
Initial focus is core stability (PTY, layout, rendering, tabs, zmx integration).

### Plugin Capabilities (proposed)

- Custom commands (keybinding-triggered actions)
- Status bar widgets (read-only data surfaces)
- Popup providers (custom picker/content sources)
- Layout extensions (optional additional layout algorithms)

### Safety Model (proposed)

- Default-deny capability manifest per plugin (`pty`, `fs`, `network`, `ipc`)
- Explicit user consent for privileged capabilities
- Per-plugin crash isolation so plugin failures do not crash ykwm

### API Shape (proposed)

- Stable core plugin API with semantic versioning
- Event hooks: `on_start`, `on_key`, `on_window_open`, `on_layout_changed`, `on_tick`
- Command registration: `:plugin.command` namespace
- Structured request/response IPC boundary (JSON-RPC or messagepack)

### Runtime Strategy (proposed)

- Out-of-process plugin host as default for safety and isolation
- Optional in-process fast path only for trusted/built-in plugins
- Hot-reload for development; cold-restart for production by default

## Technical Decisions

### Language: Zig

**Pros:**
- Modern systems language
- Excellent C interop (ghostty-vt is in Zig/C)
- No garbage collection
- Compile-time code generation
- Cross-platform

**Cons:**
- Smaller ecosystem
- Learning curve
- Less mature than Rust/Go

### Terminal Emulation: ghostty-vt

**Why:**
- Already used by zmx
- Modern feature support (OSC 52, OSC 8, Kitty keyboard protocol, etc.)
- Same codebase as Ghostty terminal
- Proven serialization/restoration via `TerminalFormatter`

**Dependency Details:**

ghostty-vt is consumed as a Zig package dependency from the Ghostty monorepo. zmx's
`build.zig.zon` demonstrates the pattern:

```zig
.dependencies = .{
    .ghostty = .{
        .url = "git+https://github.com/ghostty-org/ghostty.git?ref=HEAD#<commit>",
        .hash = "ghostty-<version>",
    },
},
```

In `build.zig`, the module is imported via lazy dependency:

```zig
if (b.lazyDependency("ghostty", .{
    .target = target,
    .optimize = optimize,
})) |dep| {
    exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
}
```

**Key API Surface (used by zmx, needed by ykwm):**

| API | Purpose |
|-----|---------|
| `ghostty_vt.Terminal.init(alloc, .{ .cols, .rows, .max_scrollback })` | Create a VT instance |
| `term.vtStream()` / `vt_stream.nextSlice(data)` | Feed PTY output into VT state |
| `term.resize(alloc, cols, rows)` | Handle terminal resize |
| `term.screens.active.cursor` | Read cursor position (x, y, pending_wrap) |
| `ghostty_vt.formatter.TerminalFormatter.init(term, opts)` | Serialize VT state to escape sequences, plain text, or HTML |
| `term.deinit(alloc)` | Cleanup |

**ykwm additionally needs (for cell-by-cell rendering):**

| API | Purpose |
|-----|---------|
| `term.screens.active` | Access the active screen grid |
| Screen row/cell iteration | Read individual cells for compositing |
| Cell attributes (fg, bg, style flags) | Generate per-cell escape sequences |

**Risk:** The cell-level API for reading individual screen cells needs verification against the Ghostty source. zmx only uses the `TerminalFormatter` bulk serialization path. If direct cell access isn't exposed, ykwm would need to either: (a) use `TerminalFormatter` per-window and clip the output, or (b) contribute cell-access APIs upstream.

**Validation Step (Phase 0):** Before starting Phase 1, write a minimal proof-of-concept that creates a `ghostty_vt.Terminal`, feeds it sample data, and reads back individual cells from `term.screens.active`. This validates the rendering approach before building window management on top of it.

### Layout Engine Candidate: OpenTUI

OpenTUI is now a candidate because it is implemented in Zig and can be integrated
without crossing language boundaries.

**Proposed usage boundary:**
- Use OpenTUI for layout computation only (tile rect calculation)
- Keep terminal rendering/compositing in ykwm (ghostty-vt + custom renderer)
- Keep popup z-index/focus policy in ykwm even if popup rect math uses OpenTUI

**Non-goals for initial integration:**
- Replacing the VT layer
- Replacing the frame-diff renderer
- Replacing input routing policy

**Adoption strategy:**
- Start with a narrow adapter for one layout (vertical stack)
- Expand to grid/horizontal/fullscreen only if phase 0.5 metrics are good
- Keep native fallback implementation available during phases 1-2

### Layout Strategy

**Abstraction First:**
- Define layout types and `Rect` outputs independent of backend
- Implement tiling behavior first (vertical stack), backend-swappable
- Floating windows remain a secondary concern
- Popups build on floating window infrastructure, not on backend-specific APIs

**Configuration:**

Runtime config file only (no compile-time config). While dwm/dvtm use compile-time
configuration, this creates friction for iterating on an experimental UX project.

- **Config file:** `$XDG_CONFIG_HOME/ykwm/config.zig` or `$HOME/.config/ykwm/config.zig`
  parsed at startup (Zig-style config like Ghostty, or a simpler key=value format)
- **Defaults:** Sensible built-in defaults so ykwm works without a config file
- **No hot-reload in v1:** Config is read at startup. Restart to apply changes.
  Hot-reload can be added later if needed, but adds complexity for little initial gain.

## Keybindings (Default)

```
Modifier: Ctrl+G

Window Management:
  MOD + c          Create new window
  MOD + x          Close window
  MOD + j/k        Navigate windows
  MOD + 1-9        Jump to window N
  MOD + Enter      Zoom to master
  MOD + Space      Cycle layouts
  MOD + h/l        Resize master area
  MOD + i/d        Inc/dec master count

Popup Management:
  MOD + p          Open popup command
  MOD + Escape     Close popup
  MOD + Tab        Cycle popups

Scrolling:
  MOD + u/d        Page up/down
  MOD + Shift + j/k  Scroll window
  MOD + s          Toggle sync scroll

Session:
  MOD + \          Detach from session
  MOD + q          Quit

Tabs:
  MOD + t          New tab
  MOD + w          Close current tab
  MOD + ]/[        Next/previous tab
  MOD + Shift + 1-9  Jump to tab N
  MOD + m          Move focused window to next tab
```

## Comparison with Existing Tools

| Feature | ykwm | tmux | dvtm | zmx |
|---------|------|------|------|-----|
| Session Persistence | ✓ (via zmx) | ✓ | ✗ (use abduco) | ✓ |
| OSC 133 Support | ✓ | ✗ | ✓ | ✓ |
| Floating Popups | ✓ | ✓ | ✗ | ✗ |
| Tabs / Workspaces | ✓ | ✓ | ✓ (tags) | ✗ |
| Tiling Layouts | ✓ | ✓ | ✓ (inspired) | ✗ |
| Scrollback Sync | ✓ | ✗ | ✗ | ✗ |
| Native Terminal Features | ✓ | ✗ | ✓ | ✓ |
| Experimental UX | ✓ | ✗ | ✗ | ✗ |
| zmx Integration | ✓ | N/A | ✗ | N/A |

## Success Criteria

1. **Functionality:** All core features work reliably
2. **Performance:** <16ms frame time, smooth scrolling
3. **Compatibility:** Works with Ghostty, no OSC 133 issues
4. **Usability:** Familiar keybindings, good defaults
5. **Extensibility:** Clean architecture for experimental features

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Terminal emulation bugs | High | Use ghostty-vt, extensive testing |
| ghostty-vt cell API not exposed | High | Phase 0 validates this before committing to architecture |
| OpenTUI integration mismatch (APIs/perf) | Medium | Phase 0.5 spike + keep native fallback behind `LayoutEngine` |
| Plugin API instability (future) | Medium | Keep plugin API out of MVP; introduce after core API and event model stabilize |
| Performance issues | Medium | Profile early, optimize rendering |
| Complex input handling | Medium | Start simple, add features gradually |
| Scope creep | High | Strict phase milestones |

### Error Handling & Edge Cases

**Child PTY Death:**
- Monitor child processes via `waitpid()` (non-blocking, checked each poll cycle)
- When a child exits: mark window as "exited", display exit code in the window area
- User can close the dead window with `MOD+x` or it auto-closes (configurable)
- If the last window dies, ykwm exits cleanly

**Terminal Resize Propagation:**
- On `SIGWINCH`: recalculate all window layouts for the new terminal size
- For each window: compute its new dimensions from the layout engine
- Call `term.resize(alloc, new_cols, new_rows)` on each window's VT instance
- Send `TIOCSWINSZ` ioctl to each child PTY with its new per-window dimensions
- Force a full re-render (all windows dirty)

**Alternate Screen Programs (vim, less, htop):**
- `ghostty_vt.Terminal` handles alternate screen switching automatically
- When a program enters alternate screen, `term.screens.active` points to the
  alternate screen; rendering reads from whichever is active
- When a program exits alternate screen, the primary screen (with scrollback)
  is restored automatically
- No special handling needed in the compositor

**ykwm Crash Recovery:**
- Child PTYs survive ykwm crashing (they're separate processes)
- On crash, child processes receive SIGHUP and typically exit
- Future: write a state file periodically so a restarted ykwm could reattach
  to orphaned PTYs (not in initial scope)
- zmx keeps its own session alive regardless of ykwm state

**Signal Handling:**
- `SIGWINCH`: terminal resize (see above)
- `SIGHUP`: graceful shutdown (clean up PTYs, close sockets)
- `SIGTERM`: graceful shutdown (same as SIGHUP)
- `SIGINT`: ignored in multiplexer mode (passed to focused child)
- `SIGCHLD`: child process exited (mark window as dead)
- `SIGPIPE`: ignored (broken pipe to a dead client)

**Input Edge Cases:**
- Multi-byte UTF-8 sequences split across reads: buffer partial sequences
- Paste bracketing (`ESC [200~` ... `ESC [201~`): pass through to focused window
- Mouse escape sequences: parse and route to correct window by coordinates
- Kitty keyboard protocol: detect and pass through to focused window

## References

### Discussions
- Ghostty Discussion #5802: "cursor-click-to-move does not work in tmux"
- Ghostty Discussion #2353: "Scripting API for Ghostty"

### Issues
- tmux #3618: "Configurable passthrough of escape sequences" (rejected)
- tmux #3064: "OSC 133 support" (for internal use only)
- Ghostty #1966: "Support OSC 133's cl (click-move) option"

### Projects
- **zmx**: https://github.com/neurosnap/zmx - Session persistence
  - Integration target: spawn ykwm within zmx sessions
  - Uses `libghostty-vt` for terminal state restoration
  - Unix socket IPC for client-daemon communication
- **dvtm**: https://github.com/martanne/dvtm - Tiling window manager
  - Reference for layout algorithms (vertical/bottom stack, grid)
  - ~4000 lines of C, simple architecture
  - Tag-based workspace system
  - External editor integration for copy mode
- **abduco**: https://github.com/martanne/abduco - Session management

### Documentation
- OSC 133 Spec: https://gitlab.freedesktop.org/Per_Bothner/specifications/-/blob/master/proposals/semantic-prompts.md
- Ghostty Shell Integration: https://ghostty.org/docs/features/shell-integration

---

## Appendix: OSC 133 Summary

**The Problem:**
- OSC 133 marks semantic regions (prompt, output, command)
- Tmux consumes these for its own `previous-prompt`/`next-prompt` features
- Does NOT passthrough to parent terminal
- Breaks Ghostty's click-to-move and other features

**Standard Sequences:**
- `ESC ] 133 ; A ST` - Prompt start
- `ESC ] 133 ; B ST` - Prompt end
- `ESC ] 133 ; C ST` - Command start
- `ESC ] 133 ; D [; exit_code] ST` - Command end
- `ESC ] 133 ; E ; cmd ST` - Command line

**Kitty Extension (click_events):**
- `ESC ] 133 ; A ; click_events=1 ST` - Enable click-to-move

**Why ykwm Solves This:**
- Runs inside zmx session
- Ghostty sees single terminal
- Shell integration works in root session
- ykwm handles windowing, not terminal protocol

---

*Document Version: 1.3*
*Last Updated: 2026-02-13*
*Status: Planning Phase*
