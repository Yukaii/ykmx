import { isPluginConfigEvent, readEvents, writeAction } from "./helpers";

let enabled = true;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

async function applyTheme(): Promise<void> {
  await writeAction({
    v: 1,
    action: "set_chrome_theme",
    window_minimize_char: "-",
    window_maximize_char: "#",
    window_close_char: "x",
    focus_marker: "=",
    border_horizontal: "=",
    border_vertical: "|",
    border_corner_tl: "+",
    border_corner_tr: "+",
    border_corner_bl: "+",
    border_corner_br: "+",
    border_tee_top: "+",
    border_tee_bottom: "+",
    border_tee_left: "+",
    border_tee_right: "+",
    border_cross: "+",
  });

  await writeAction({
    v: 1,
    action: "set_ui_bars",
    toolbar_line: " Program Manager | File  Options  Window  Help ",
    tab_line: " [Desktop] [Main] [Tools] ",
    status_line: " ykmx retro mode | Alt+Tab vibes | plugin chrome active ",
  });
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev) && ev.key === "enabled") {
      enabled = parseBoolLike(ev.value);
      if (!enabled) {
        await writeAction({ v: 1, action: "reset_chrome_theme" });
        await writeAction({ v: 1, action: "clear_ui_bars" });
      }
      continue;
    }

    if (ev.event === "on_start") {
      if (enabled) await applyTheme();
      continue;
    }

    if (ev.event === "on_shutdown") {
      await writeAction({ v: 1, action: "reset_chrome_theme" });
      await writeAction({ v: 1, action: "clear_ui_bars" });
      continue;
    }
  }
}

main().catch(() => {});
