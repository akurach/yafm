# yafm Plugin API (`apiVersion 1.0`)

yafm plugins are **JavaScript**, run through macOS's built-in JavaScriptCore — the
Obsidian / Chrome model: drop a `.js` file in the plugins folder and it works. No
build step, no install, no `npm`.

> **Status — frozen at `apiVersion 1.0`.** The public surface is stable and will not
> change until the marketplace work. It covers: **table columns**, **commands**
> (command palette), **context-menu items**, **scoped reads** (`read:cwd`, `read:exif`),
> and **actions** (open-in-app, clipboard). Capabilities beyond columns require a sidecar
> `<plugin>.json` manifest declaring them. Toolbar buttons, custom previewers, and virtual
> filesystems are **post-1.0** (`apiVersion 2.0`) — they don't fit the synchronous,
> snapshot-based contract. Heavy first-party features (git status, SMB) are **native** yet
> appear in the same registry — see [VISION.md](../VISION.md).

## Where plugins live

```
~/Library/Application Support/yafm/plugins/*.js
```

Open it from **Settings ▸ Plugins ▸ Open Plugins Folder**. yafm seeds an editable
`example-kind.js` there on first run. Add or edit files, then **Reload Plugins**
(or relaunch). Each `.js` file is loaded in its own isolated context.

## Writing a column plugin

A plugin registers one or more columns. Each column has an `id`, a `title`, and a
`value(entry)` function the host calls once per visible row:

```js
yafm.registerColumn({
  id: "wordish",
  title: "Name length",
  value: function (entry) {
    return entry.name.length;        // number, string, or null
  }
});
```

`value` may return:

| Return                     | Shown as            |
|----------------------------|---------------------|
| a string                   | the text            |
| a number                   | the number          |
| `null` / `undefined`       | an empty cell       |
| (throws)                   | an empty cell (the error is contained, never a crash) |

### The `entry` snapshot

`value(entry)` receives a **read-only, path-free** snapshot:

```ts
{
  name: string,          // "report.pdf"
  ext: string,           // "pdf"  (no dot, original case)
  isDirectory: boolean,
  isHidden: boolean,
  size?: number,         // bytes, absent for folders / unknown
  modified?: number,     // epoch milliseconds, absent if unknown
  tags: string[]         // native macOS tag names
}
```

There is **no `url` and no absolute path** — by design (see Sandbox below).

### The `yafm` host object

| Member                   | What it does                                  |
|--------------------------|-----------------------------------------------|
| `yafm.registerColumn(spec)` | Register a `{ id, title, value }` column.  |
| `yafm.log(...)`          | No-op sink (safe to call; reserved).          |
| `yafm.version`           | Host API version string (`"1.0"`).            |

## Sandbox — what a plugin can and cannot do

Plugins can only do what the host exposes. **Withheld:** filesystem, network,
`Process`/shell, `require`/modules, timers, and any absolute path. **Available:**
the pure-compute JavaScriptCore globals (`Math`, `JSON`, `Date`, `String`, …) and
the `yafm` object above.

- Each plugin file gets its **own `JSContext`** (its own global scope) — one
  plugin can't read or clobber another's globals.
- `value(entry)` runs **synchronously on the main thread** while the table builds a
  row, so a plugin can't corrupt state or escape its snapshot. To keep the "never
  freezes" guarantee even for hostile code, each context's JS execution is **time-limited**
  (`JSContextGroupSetExecutionTimeLimit`): an infinite loop is aborted and the cell renders
  empty rather than hanging the app.
- Widening the surface (scoped FS reads, a vetted git/exec capability) happens in
  exactly one place — `JSPluginHost.snapshot(of:in:)` and `PluginContext.resolve`
  in `Core` — so new capability is reviewed once, not sprinkled across the host.

This is why git status is **native**: running `git` is precisely the kind
of capability the sandbox refuses to hand untrusted JavaScript. It is registered
as a column through the same registry, so to the table it's just another column.

## Troubleshooting

**Settings ▸ Plugins** lists what loaded and shows a red line per file that failed
(syntax error, didn't register anything, …). A plugin that registers nothing or
throws on load is skipped; the rest still load.

## Roadmap

- Context-menu items and commands contributed from JS.
- A vetted, scoped-filesystem capability (read files a plugin is granted, via
  `PluginContext`) — enabling a real JS git plugin and richer community plugins.
- Per-plugin enable/disable and plugin manifests in Settings.
