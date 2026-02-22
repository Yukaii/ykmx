import { isCommandEvent, isPluginConfigEvent, readEvents, writeAction } from "./helpers";

const ENABLE_COMMAND = "theme.windows31.enable";
const DISABLE_COMMAND = "theme.windows31.disable";
let enabledOnStart = true;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

async function applyWindows31Theme(): Promise<void> {
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
    action: "set_chrome_style",
    active_title_sgr: "1;37;44",
    inactive_title_sgr: "1;30;46",
    active_border_sgr: "37;44",
    inactive_border_sgr: "30;46",
    active_buttons_sgr: "1;33;44",
    inactive_buttons_sgr: "33;46",
  });

  await writeAction({
    v: 1,
    action: "set_ui_bars",
    toolbar_line: " Program Manager | File  Options  Window  Help ",
    tab_line: " [Desktop] [Main] [Tools] ",
    status_line: " windows31 decoration theme active ",
  });
}

async function clearTheme(): Promise<void> {
  await writeAction({ v: 1, action: "reset_chrome_theme" });
  await writeAction({
    v: 1,
    action: "set_chrome_style",
    active_title_sgr: "0",
    inactive_title_sgr: "0",
    active_border_sgr: "0",
    inactive_border_sgr: "0",
    active_buttons_sgr: "0",
    inactive_buttons_sgr: "0",
  });
  await writeAction({ v: 1, action: "clear_ui_bars" });
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev) && ev.key === "enabled_on_start") {
      enabledOnStart = parseBoolLike(ev.value);
      continue;
    }

    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: ENABLE_COMMAND });
      await writeAction({ v: 1, action: "register_command", command: DISABLE_COMMAND });
      if (enabledOnStart) await applyWindows31Theme();
      continue;
    }

    if (!isCommandEvent(ev)) {
      if (ev.event === "on_shutdown") {
        await clearTheme();
      }
      continue;
    }

    if (ev.command === ENABLE_COMMAND) {
      await applyWindows31Theme();
    } else if (ev.command === DISABLE_COMMAND) {
      await clearTheme();
    }
  }
}

main().catch(() => {});
