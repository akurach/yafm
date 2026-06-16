# yafm User Guide

*Yet Another File Manager for macOS — v0.9.6* · [Русская версия](USER_GUIDE.ru.md)

---

## 1. What is yafm

yafm is a fast, keyboard-driven, native (Swift/SwiftUI) file manager for macOS, built as a daily-driver alternative to Finder. It gives you a **dual-pane** layout with real **tabs**, **Total Commander-style** keyboard navigation, real **macOS tags**, flexible **color coding**, and its own visible file-operation engine. Its defining promise: **it never freezes silently.** Every folder read is asynchronous, so instead of staring at a blank window (Finder's habit on external disks), you always see an honest *"Reading…"* state telling you exactly what's happening.

---

## 2. Installing & first run

yafm ships as a **DMG**. It is **not notarized yet** (notarization needs a paid Apple Developer ID), so macOS Gatekeeper will warn you the first time you launch it.

### Open it the first time

Open the DMG, drag **yafm.app** into your **Applications** folder, then use any one of these once:

- **Right-click** `yafm.app` → **Open** → click **Open** in the dialog, or
- Open **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway**, or
- Run `xattr -dr com.apple.quarantine /Applications/yafm.app` in Terminal.

After the first successful launch, yafm opens normally like any other app.

### Grant Full Disk Access

On first run yafm shows a short **welcome sheet** explaining why it asks for access. macOS hides some protected folders (Mail, Safari, and others) until you grant **Full Disk Access**. yafm only reads files you actually open — but without access, those folders would look empty with no explanation, which violates the "never lie" principle.

From the welcome sheet, click **Open System Settings…**, enable yafm under **Privacy & Security ▸ Full Disk Access**, then **relaunch yafm** so it can see the newly available folders. You can skip this and use yafm in the available scope — you'll just see a non-intrusive **"Limited access"** banner with a button to enable it later. Even after you dismiss that banner, you can manage access any time from **Settings ▸ General ▸ Full Disk Access**, which shows the current status and offers **Open System Settings…** and **Re-check** buttons.

Removable and network volumes prompt for access the first time you open them. That system dialog is normal — allow it.

---

## 3. The interface

yafm's window is laid out for two-handed, keyboard-first work:

- **Two panes, side by side.** The **active pane** is marked with a colored top bar and a faint tint. Most actions (copy, move, navigate) act on the active pane; copy/move send files *to the other pane*.
- **Tab bar** (top of each pane). Each pane has its own tabs. Click a tab to switch, the **+** button to open a new one, or the **×** to close it.
- **Path bar + breadcrumbs.** Below the tabs, the current path is shown as clickable breadcrumbs — click any component to jump there. Click the **pencil** to type a path directly.
- **File table.** Columns are **Name · Size · Modified · Kind**, plus a **Git** column when you're inside a git repository, plus any columns added by plugins. Click a column header to sort; click again to reverse. **Name** is always shown; **Size / Modified / Kind / Git** can each be shown or hidden — right-click the column header, or click the **options button** (slider icon) in the path bar, and toggle them.
- **Sidebar** (left). Sections for **Favorites** (your bookmarks), **Locations** (Computer, Home), **Devices** (mounted/USB drives with a capacity bar and **eject** button), **Network** (network shares), and **Tags** (the tag cloud — every tag with its color and file count; click to filter). **Drag to reorder:** grab a Favorites item (system folder or bookmark) to move it within Favorites, or grab a whole section header to reorder the sections themselves — the block you're dragging follows the cursor while its neighbors slide into place, and the order is saved. **Collapse sections:** click a section header to fold it away (a caret shows the state); a tap collapses while a grab-and-drag still reorders. Collapsed state is remembered. **Collapse sidebar:** press **⌘⌥S** or click the sidebar-toggle button (top-right corner of the sidebar) to collapse the whole sidebar to a narrow icon-only strip; press again to expand.
- **Function-key bar** (bottom). A clickable Total Commander-style strip: **F2** Rename · **F3** View · **F4** Edit · **F5** Copy · **F6** Move · **F7** New Folder · **F8** Delete.
- **Inspector / preview panel** (right). Toggle between **Info** (kind, size, dates, permissions, location, and a tag editor) and **Preview** (a live QuickLook of the selected file).
- **Operation queue.** Whenever a copy/move/delete is running, a queue appears showing each task's progress with a **cancel** button.
- **Status bar.** Item count, and selected count + size when you have a selection.

### The "Reading…" state — the never-freeze design

When a folder is loading, a floating **"Reading… (n)"** badge appears over the list and the count climbs as entries stream in. The table never goes blank and never jerks. If a folder can't be opened, you get a clear **"Can't open folder"** message instead of an empty window. This is the core of yafm: it always tells you the truth about what it's doing.

---

## 4. Keyboard-first basics

yafm follows the **Total Commander** model. With a pane focused:

| Key | What it does |
|-----|--------------|
| **↑ / ↓** | Move the cursor up/down one row |
| **→** | Go *into* the folder under the cursor; on an app, either show its contents or launch it (your choice in Settings); (also opens files only if you turn that on in Settings) |
| **←** | Go *up* to the parent folder |
| **Enter** | Open — enter a folder, open a file in its default app, or **launch** an app |
| **Backspace** | Go up to the parent folder |
| **Tab** | Switch the active pane (left ⇄ right) |
| **⇧ + ↑ / ↓** | Extend the selection (multi-select) |
| **Space** | Quick Look the file under the cursor (preview follows the cursor as you move) |

Click a row to select it instantly; double-click to open (or **launch**, for an app). Selecting a row no longer scroll-centers the list — your place stays put. Right-click any row (or the empty area) for the full context menu.

---

## 5. Finding things fast

### ⌘K — Command palette (the hero)

Press **⌘K** to open the command palette: a single fuzzy-search box that jumps you to *anything*. Start typing and it filters across:

- **Every command** — Copy, Move, Rename, Search, Toggle Hidden Files, New Folder, and the rest.
- **Your Favorites** — e.g. type "Downloads" to *Go to: Downloads*.
- **Subfolders of the current directory** — jump straight into a folder without arrowing to it.

Use **↑ / ↓** to move through results, **Enter** to run the highlighted item, and **Esc** to close. This is the keyboard-first centerpiece — when in doubt, press ⌘K and type what you want.

### Type-to-filter

While a pane is focused, just **start typing letters or numbers** to live-filter the current folder by name. The list narrows as you type. **Backspace** edits the filter, **Esc** clears it, and the arrows/Enter still navigate the filtered list normally. It's the fastest way to pick one file out of a crowded folder.

### ⌘F — Search within a folder

Press **⌘F** to open the **find bar** under the path bar (it's inline — it won't cover the list or steal your place). Toggle between:

- **Name** — find files by name. Uses Spotlight (`mdfind`) with yafm's own name-scan fallback.
- **Contents** — *grep-in-files*: find files that contain a piece of text.

Hits stream in as they're found, with a live **"Searching… N"** count, and show up as a listing you can act on like any folder. Content search is **bounded** (it skips files over 8 MB and binary files) and **cancellable** — press **Esc**, hit **⌘F** again, or start a new query to stop it. A long search never freezes the app, and an empty result says so rather than showing a blank pane.

Press **⌘F** again or **Esc** to close the bar.

---

### Connect to a server (SMB)

Press **⌘⇧K** (or run *Connect to Server…* from ⌘K) and type an address like `smb://nas.local/Media`. yafm mounts the share **natively** — macOS handles the SMB protocol and your credentials (stored in the Keychain) — and opens it in the active pane like any folder. Because the mount is async and the listing streams, a slow or unreachable share shows a **loading** state or a clear **error**, never a frozen window. Browse, copy, tag, and search it exactly like a local folder.

---

## 6. Working with files

yafm has its **own file-operation engine** with a visible queue — every operation shows progress and can be cancelled. Nothing happens behind your back.

### Function keys (TC-style)

| Key | Action |
|-----|--------|
| **F5** | Copy selection to the *other* pane |
| **F6** | Move selection to the *other* pane |
| **F7** | New folder |
| **F8** | Delete (permanent — see Settings) |
| **F2** | Rename |
| **F3** | View (Quick Look) |
| **F4** | Edit (open in editor) |

### Clipboard

- **⌘C** Copy and **⌘X** Cut into yafm's internal clipboard, then **⌘V** Paste into the target folder.

### Drag & drop

Drag any row to move files around the way you'd expect:

- **Onto the other pane** (empty area) — copies into that pane's current folder.
- **Onto a folder row** — copies into that folder. The folder lights up with an accent ring while you hover.
- **Out to Finder or another app** — copies the file there.
- **In from Finder** — drop files onto a pane to copy them in.

Hold **⌘** while dropping to **move** instead of copy. Every drop still runs through the visible operation queue — nothing happens silently.

### The operation queue

Long copies/moves/deletes appear in the queue with a label, a progress bar, bytes done + percentage, and a **×** to cancel. Cancelling actually interrupts the running operation.

### Collisions

When a copy or move hits a file that already exists, yafm follows your default collision policy — **Keep both**, **Skip**, or **Replace** (set in Settings ▸ Operations).

### More row actions (right-click)

- **Open** / **Open With…** (pick an app, or *Other…*). On an **app**, **Open** *launches* it and **Show Package Contents** browses inside the bundle as a folder.
- **Quick Look**
- **Reveal in Finder**
- **Get Info** (**⌘I**) and **Copy Path**
- **Share** — AirDrop and the macOS share services, on a file or your whole selection
- **Add to Favorites** (folders)
- **Tags** — a quick submenu with colored dots: toggle any tag you already use, pick a standard color, or **New Tag…**, all without a modal. (You can also open the full inline tag editor from the **Info** inspector.) The Tags menu is hidden for **apps** — macOS App Management blocks writing tags to `.app` bundles.

---

## 7. Tags & color coding

yafm uses **native macOS tags** (stored in extended attributes), so they stay fully compatible with Finder — tags you set in yafm show up in Finder and vice versa. On top of that, yafm keeps its own fast **index** and gives tags a proper UI.

- **Tag a file** from the row's **Tags** quick menu or the **Info** inspector. Pick from the 7 standard Finder colors or type a new named tag.
- **Tag cloud** in the sidebar lists every known tag with its color and file count. Click a tag to show all files carrying it.
- **Color coding** tints file/folder icons by rules — by type, by tag, or custom rules — so you can read a folder at a glance.

Manage all tags in **Settings ▸ Tags**: recolor, rename across every file, or remove a tag from all files, plus rescan/rebuild the index (useful if you tagged files outside yafm).

### File-type tiles

Instead of the same generic document icon for everything, yafm can draw a small **colored chip** showing the file's extension — recognised for around **250 known types**: source code, 3D/CAD, RAW photo, design files, and the **project files** of audio/video tools (Premiere, DaVinci Resolve, Final Cut, Ableton, FL Studio, Logic, Reaper), soundfonts/VST, fonts, and binaries. Tiles are drawn and cached, and adapt to **light and dark** appearance. Folders and unknown extensions keep their real macOS icon. Turn tiles on or off in **Settings ▸ Appearance ▸ File-Type Tiles**.

A single **type → color palette** drives both the tile *and* an optional **"Tint file names by type"** toggle, so a file's tile and its name always share the same color. In **Settings ▸ Appearance** you'll find:

- **Type Colors** — per-category color pickers.
- **Type Browser** — a searchable list of every known extension with its category. Override a type's category, or add your own.

---

## 8. Tabs & panes

Each pane keeps its own set of tabs, so you can browse several folders per side.

| Action | Shortcut |
|--------|----------|
| New tab | **⌘T** |
| Close tab | **⌘W** |
| Next tab | **⌃Tab** |
| Previous tab | **⌃⇧Tab** |
| Jump to tab 1–9 | **⌘1 … ⌘9** |
| Switch active *pane* | **Tab** |

The dual-pane workflow is the heart of yafm: browse the source in one pane, the destination in the other, then **F5** to copy or **F6** to move between them. Open a folder, drive, or favorite **in a new tab** from its right-click menu.

---

## 9. Settings

Open Settings with **⌘,**. Settings appears as a floating card *inside* the main window over a dimmed backdrop (it can't be dragged off as a separate window); a pill switcher glides between tabs, and clicking the backdrop, the ✕, or pressing **Esc** dismisses it. The tabs:

- **General** — *Start folder* (Home / Last used / a specific folder); quick toggles for **Theme** (Light / Dark / System), **Density** (Compact / Cozy / Comfortable — how many rows fit on screen), and **Motion** (animate selection & navigation, or keep it instant); *Right arrow opens files* (off by default: → only enters folders, Enter always opens); **Navigation ▸ "Right arrow on apps"** (Show contents — browse the bundle — or Launch; default *Show contents*); *Show hidden files in new tabs*; **Full Disk Access** (status + **Open System Settings…** + **Re-check**); **Language** (System / English / Русский — applies after you quit and reopen yafm).
- **Appearance** — **Accent color**; the **file-type tile** system: **File-Type Tiles** toggle, **Tint file names by type** toggle, per-category **Type Colors**, and the searchable **Type Browser** (see section 7).
- **Operations** — *Confirm before deleting* (on by default; note delete is **permanent**, not Trash); *Copy/Move collisions* default (Keep both / Skip / Replace).
- **Tags** — the full tag manager (recolor, rename, delete across files) plus *Rescan* / *Clear index*.
- **Plugins** — open the plugins folder, reload plugins, and see what's loaded (with any errors).
- **Updates** — **Check for Updates** (queries GitHub Releases and, if newer, links you to the download — no silent auto-install) and shows your current version.

---

## 10. Plugins

yafm supports **JavaScript plugins** via JavaScriptCore — the "drop a file, it works" model. In v0.4 plugins add **table columns** (for example, custom metadata next to Name/Size/Kind).

- Open the plugins folder from **Settings ▸ Plugins ▸ Open Plugins Folder** and drop a `.js` file in.
- A small editable example (`example-kind.js`) is seeded on first run so you can see the shape of a column plugin.
- Click **Reload Plugins** to pick up changes; loaded plugins and any errors are listed right there.

Plugins run **sandboxed** — no filesystem, network, or process access, only yafm's host API — so a column plugin can only see a path-free snapshot of each file. (The git-status column is a built-in native feature that appears in the same registry.)

### Capabilities & manifests (v0.8)

A plugin can do more than draw a column if it ships a **manifest** — a sidecar `<plugin>.json` next to the `.js` — declaring what it needs. A bare `.js` with no manifest stays **compute-only** (just columns).

In **Settings ▸ Plugins ▸ Installed** every plugin appears with an **enable/disable** switch, its declared **capabilities**, and a **trust badge** (Signed / Author / Unsigned). Capabilities you grant by enabling:

- **contribute:command** — adds commands to the pane (right-click empty space) menu.
- **contribute:menu** — adds items to the file right-click menu.
- **read:cwd** — lets the plugin read text files **inside the folder you're viewing** (e.g. `.git/HEAD`). The host resolves every read against that folder, refuses anything that tries to escape it, follows no symlinks, and caps the read size. The plugin gets an opaque handle, never a real path.

You're asked to confirm when you enable a plugin that wants a sensitive capability — **consent happens in Settings, never from the plugin**. A bundled **Git Branch** plugin (shows a repo folder's branch via `read:cwd`) ships disabled; enable it to see the capability flow.

### Browsing archives (v0.8)

Open a **`.zip`** (Enter or double-click) to browse it **read-only**, like any folder — yafm lists it natively behind the same routing layer as network shares, streamed so a big archive never freezes the window.

---

## 11. Full keyboard shortcut reference

### Navigation

| Action | Shortcut |
|--------|----------|
| Move cursor up / down | ↑ / ↓ |
| Into folder (open file if enabled); on an app, show contents or launch | → |
| Up to parent folder | ← |
| Up to parent folder | Backspace |
| Open (folder or file); launch an app | Enter |
| Switch active pane | Tab |
| Extend selection | ⇧ + ↑ / ↓ |
| Quick Look | Space |

### Files & operations

| Action | Shortcut |
|--------|----------|
| Copy to other pane | F5 |
| Move to other pane | F6 |
| New Folder | F7 |
| Delete (permanent) | F8 |
| Rename | F2 |
| View (Quick Look) | F3 |
| Edit (open in editor) | F4 |
| Copy (clipboard) | ⌘C |
| Cut (clipboard) | ⌘X |
| Paste | ⌘V |
| Get Info | ⌘I |
| Refresh | ⌘R |

### View

| Action | Shortcut |
|--------|----------|
| Toggle hidden files | ⌘⇧. |
| Toggle preview panel | ⌘⇧P |
| Quick Look | Space |
| Settings | ⌘, |

### Tabs

| Action | Shortcut |
|--------|----------|
| New tab | ⌘T |
| Close tab | ⌘W |
| Next tab | ⌃Tab |
| Previous tab | ⌃⇧Tab |
| Jump to tab 1–9 | ⌘1 … ⌘9 |

### Search & palette

| Action | Shortcut |
|--------|----------|
| Command palette | ⌘K |
| Type-to-filter | start typing in a pane |
| Search within folder | ⌘F |
| Shortcut cheat sheet | ⌘/ |

> Tip: forgot a shortcut? Press **⌘/** for the on-screen cheat sheet, or **⌘K** and search by name.

---

## 12. Troubleshooting

**A "Limited access — some folders are hidden" banner appears.**
macOS is blocking yafm from protected folders. Click **Enable Full Disk Access** in the banner (or go to System Settings ▸ Privacy & Security ▸ Full Disk Access), turn yafm on, and **relaunch** the app. yafm keeps working in the folders it *can* see — the banner is a hint, not a wall.

**macOS won't open yafm ("can't be opened because it is from an unidentified developer").**
yafm isn't notarized yet. **Right-click** the app → **Open** → **Open**, or use System Settings ▸ Privacy & Security ▸ **Open Anyway**. You only need to do this once. (See section 2.)

**An external disk shows "Reading…" for a long time.**
That's the never-freeze design doing its job — yafm is genuinely reading the disk and showing you the live count, rather than freezing on a blank window like Finder. Slow or sleeping external/network drives simply take time to wake and enumerate; the badge updates as entries arrive, and you can switch tabs or panes while it loads. Even very large folders stream in without freezing the window.

**A folder I tagged outside yafm doesn't show its tags in the sidebar cloud.**
The tag cloud is built from yafm's index. Open **Settings ▸ Tags** and click **Rescan now** (or **Clear index** to rebuild from scratch).
