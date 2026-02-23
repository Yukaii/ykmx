# ykmx Docs

This is the documentation table of contents for implementation, architecture, and refactoring.

## Getting Started

- `usage.md`: user and operator workflows (`ykmx`, `ykmx ctl`, config, keybindings).
- `compatibility.md`: compatibility matrix and smoke/soak validation notes.

## Architecture and Internals

- `architecture.md`: high-level system architecture and runtime phase model.
- `module-map.md`: module ownership and responsibilities across `src/`.
- `runtime-flow.md`: end-to-end runtime loop flow and critical state transitions.

## Refactoring and Maintenance

- `refactor-log.md`: extraction history and behavior-preserving notes.
- `plan.md`: long-form strategy and product context.

## Examples

- `examples/config.toml`: reference configuration.
- `examples/plugins.d/*`: plugin examples (layout, panels, theme, command palette, Python runtime).
