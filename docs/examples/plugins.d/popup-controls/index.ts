import { isCommandEvent, readEvents, writeAction } from "./helpers";

async function main() {
  for await (const ev of readEvents()) {
    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: "open_popup" });
      await writeAction({ v: 1, action: "register_command", command: "close_popup" });
      await writeAction({ v: 1, action: "register_command", command: "cycle_popup" });
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === "open_popup") {
      await writeAction({ v: 1, action: "toggle_shell_popup" });
      continue;
    }
    if (ev.command === "close_popup") {
      await writeAction({ v: 1, action: "close_focused_popup" });
      continue;
    }
    if (ev.command === "cycle_popup") {
      await writeAction({ v: 1, action: "cycle_popup_focus" });
    }
  }
}

main().catch(() => {});
