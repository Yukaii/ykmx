import { isCommandEvent, isPluginConfigEvent, readEvents, writeAction } from "./helpers";

const DEFAULT_OPEN_COMMAND = "theme.palette.open";
const DEFAULT_PROMPT = "theme> ";

type ThemeEntry = { label: string; command: string };

let openCommand = DEFAULT_OPEN_COMMAND;
let popupWidth = 96;
let popupHeight = 24;
let popupX: number | null = null;
let popupY: number | null = null;
let popupCwd: string | null = null;
let fzfPrompt = DEFAULT_PROMPT;
let entries: ThemeEntry[] = [
  { label: "Windows 3.1 Theme", command: "theme.windows31.enable" },
  { label: "Reset To Default", command: "theme.windows31.disable" },
];

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function parseEntries(value: string): ThemeEntry[] {
  const parsed: ThemeEntry[] = [];
  const chunks = value.split(",");
  for (const chunk of chunks) {
    const item = chunk.trim();
    if (!item) continue;
    const sep = item.lastIndexOf("=");
    if (sep <= 0 || sep >= item.length - 1) continue;
    const label = item.slice(0, sep).trim();
    const command = item.slice(sep + 1).trim();
    if (!label || !command) continue;
    parsed.push({ label, command });
  }
  return parsed;
}

function popupScript(): string {
  const prompt = shellQuote(fzfPrompt);
  const rows = entries.map((entry) => shellQuote(`${entry.label}\t${entry.command}`)).join(" ");
  return [
    "if ! command -v ykmx >/dev/null 2>&1; then",
    "  printf 'ykmx not found in PATH\\n';",
    "  read -r _;",
    "  exit 1;",
    "fi",
    "if ! command -v fzf >/dev/null 2>&1; then",
    "  printf 'fzf is required for theme palette\\n';",
    "  read -r _;",
    "  exit 1;",
    "fi",
    `selection=$(printf '%s\\n' ${rows} | fzf --prompt=${prompt} --height=100% --layout=reverse --border) || exit 0`,
    "cmd=$(printf '%s\\n' \"$selection\" | awk -F '\\t' '{print $2}')",
    "[ -n \"$cmd\" ] || exit 0",
    "ykmx ctl command \"$cmd\"",
  ].join("\n");
}

async function runPalettePopup(): Promise<void> {
  const args = ["open-popup"];
  if (popupCwd) args.push("--cwd", popupCwd);
  if (popupX !== null && popupY !== null && popupWidth > 0 && popupHeight > 0) {
    args.push("--x", String(popupX), "--y", String(popupY), "--width", String(popupWidth), "--height", String(popupHeight));
  }
  args.push("--", "/bin/sh", "-lc", popupScript());
  const proc = Bun.spawn({ cmd: ["ykmx", "ctl", ...args], stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  await proc.exited;
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev)) {
      if (ev.key === "open_command") {
        openCommand = ev.value.trim() || DEFAULT_OPEN_COMMAND;
      } else if (ev.key === "popup_width") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) popupWidth = Math.max(20, n);
      } else if (ev.key === "popup_height") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) popupHeight = Math.max(8, n);
      } else if (ev.key === "popup_x") {
        const n = Number.parseInt(ev.value, 10);
        popupX = Number.isFinite(n) ? Math.max(0, n) : null;
      } else if (ev.key === "popup_y") {
        const n = Number.parseInt(ev.value, 10);
        popupY = Number.isFinite(n) ? Math.max(0, n) : null;
      } else if (ev.key === "cwd") {
        const v = ev.value.trim();
        popupCwd = v.length > 0 ? v : null;
      } else if (ev.key === "fzf_prompt") {
        const v = ev.value.trim();
        if (v.length > 0) fzfPrompt = v;
      } else if (ev.key === "entries") {
        const parsed = parseEntries(ev.value);
        if (parsed.length > 0) entries = parsed;
      }
      continue;
    }

    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: openCommand });
      continue;
    }

    if (!isCommandEvent(ev)) continue;
    if (ev.command !== openCommand) continue;
    await runPalettePopup();
  }
}

main().catch(() => {});
