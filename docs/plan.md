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

## Technical Design

### Core Components

```
src/
├── main.zig              # Entry point, CLI parsing
├── multiplexer.zig       # Main event loop, window management
├── window.zig            # Window structure and operations
├── layout.zig            # Layout engine (tiling algorithms)
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

1. **Layout Calculation:**
   - Calculate positions for all windows based on current layout
   - Handle floating windows (popups) with z-index sorting
   - Account for gaps and borders

2. **VT State Update:**
   - Read output from each PTY
   - Update terminal state in ghostty-vt
   - Capture scrollback

3. **Screen Composition:**
   - Render each window to its allocated region
   - Apply scroll offsets
   - Overlay popups on top
   - Draw borders and decorations

4. **Output:**
   - Generate terminal escape sequences
   - Send to stdout
   - Handle terminal resize events

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

**Key Requirements:**
- [ ] Spawn as command within zmx session: `zmx attach <name> ykwm`
- [ ] Proper PTY handoff between zmx and ykwm
- [ ] State restoration on reattach (scrollback, window layout)
- [ ] Coordinate with zmx's `libghostty-vt` for terminal state
- [ ] Handle zmx's Unix socket protocol for client communication
- [ ] Graceful detach/reattach without losing window state

**Integration Points:**
- Use zmx's socket directory (`$ZMX_DIR` or `$XDG_RUNTIME_DIR/zmx`)
- Compatible with zmx's scrollback restoration via ghostty-vt
- Work with zmx's `attach`, `detach`, `history` commands
- Support multiple clients viewing same session

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

### Phase 1: Foundation (Weeks 1-2)

**Goals:**
- Basic window management
- Single layout (vertical stack)
- PTY spawning and I/O
- Basic rendering
- **Study dvtm codebase for layout algorithms**

**Deliverables:**
- [ ] Project structure and build system
- [ ] PTY management (create, read, write)
- [ ] Window data structure
- [ ] Basic rendering loop
- [ ] Input handling framework
- [ ] Vertical stack layout

**Testing:**
- Spawn multiple shells
- Switch between windows
- Basic navigation works

### Phase 2: Core Features (Weeks 3-4)

**Goals:**
- Multiple layouts
- Window lifecycle management
- Configuration system
- Better rendering

**Deliverables:**
- [ ] Horizontal stack layout
- [ ] Grid layout
- [ ] Fullscreen zoom
- [ ] Window creation/closing
- [ ] Configuration file support
- [ ] Window titles
- [ ] Status bar

**Testing:**
- Create/close windows dynamically
- Switch layouts
- Configuration reload

### Phase 3: Popup System (Weeks 5-6)

**Goals:**
- Floating windows
- Popup commands
- Modal/non-modal modes

**Deliverables:**
- [ ] Floating window support
- [ ] Popup spawning API
- [ ] Z-index management
- [ ] Modal input capture
- [ ] Popup animations
- [ ] Fzf integration example

**Testing:**
- Open fzf in popup
- Modal mode blocks input
- Popup closes correctly

### Phase 4: Scrollback & Experimental UX (Weeks 7-8)

**Goals:**
- Scrollback buffers
- Synchronized scrolling
- Experimental features

**Deliverables:**
- [ ] Scrollback buffer implementation
- [ ] Scroll navigation
- [ ] Search functionality
- [ ] Synchronized scroll mode
- [ ] Inline expandable sections
- [ ] Contextual popups

**Testing:**
- Scroll through history
- Sync scroll multiple windows
- Expand/collapse output sections

### Phase 5: Polish & zmx Integration (Weeks 9-10)

**Goals:**
- Full zmx integration
- Mouse support
- Performance optimization
- Documentation

**Deliverables:**
- [ ] zmx session attachment: `zmx attach <session> ykwm`
- [ ] State serialization for zmx restoration
- [ ] Coordinate scrollback with zmx's ghostty-vt instance
- [ ] Unix socket protocol for zmx client communication
- [ ] Mouse event handling
- [ ] Performance benchmarks
- [ ] User documentation
- [ ] Example configurations (including zmx workflow)
- [ ] Shell completions

**Testing:**
- `zmx attach dev ykwm` - starts ykwm in zmx session
- Detach with `MOD+\`, reattach with `zmx attach dev`
- Window layout and scrollback restored correctly
- Multiple clients can view same ykwm session via zmx
- Mouse clicks work
- Performance is acceptable (<16ms frame time)

### Phase 6: Advanced Features (Ongoing)

**Future Enhancements:**
- [ ] Tree-style popup management
- [ ] AI-powered contextual popups
- [ ] Plugin system
- [ ] Remote session support
- [ ] Collaborative editing

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
- Fast, GPU-accelerated
- Modern feature support
- Same codebase as Ghostty terminal

### Layout Strategy

**Tiling First:**
- Start with proven dwm-style tiling
- Floating windows as secondary concern
- Popups built on floating window infrastructure

**Configuration:**
- Static config at compile time (like dwm/dvtm) for simplicity
- Runtime config file for user preferences
- Hot-reload for development

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
```

## Comparison with Existing Tools

| Feature | ykwm | tmux | dvtm | zmx |
|---------|------|------|------|-----|
| Session Persistence | ✓ (via zmx) | ✓ | ✗ (use abduco) | ✓ |
| OSC 133 Support | ✓ | ✗ | ✓ | ✓ |
| Floating Popups | ✓ | ✓ | ✗ | ✗ |
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
| Performance issues | Medium | Profile early, optimize rendering |
| Complex input handling | Medium | Start simple, add features gradually |
| Scope creep | High | Strict phase milestones |

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

*Document Version: 1.0*
*Last Updated: 2026-02-13*
*Status: Planning Phase*
