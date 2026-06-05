# yafm User Guide

*Yet Another File Manager for macOS — v0.4.0*

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

From the welcome sheet, click **Open System Settings…**, enable yafm under **Privacy & Security ▸ Full Disk Access**, then **relaunch yafm** so it can see the newly available folders. You can skip this and use yafm in the available scope — you'll just see a non-intrusive **"Limited access"** banner with a button to enable it later.

Removable and network volumes prompt for access the first time you open them. That system dialog is normal — allow it.

---

## 3. The interface

yafm's window is laid out for two-handed, keyboard-first work:

- **Two panes, side by side.** The **active pane** is marked with a colored top bar and a faint tint. Most actions (copy, move, navigate) act on the active pane; copy/move send files *to the other pane*.
- **Tab bar** (top of each pane). Each pane has its own tabs. Click a tab to switch, the **+** button to open a new one, or the **×** to close it.
- **Path bar + breadcrumbs.** Below the tabs, the current path is shown as clickable breadcrumbs — click any component to jump there. Click the **pencil** to type a path directly.
- **File table.** Columns are **Name · Size · Modified · Kind**, plus a **Git** column when you're inside a git repository, plus any columns added by plugins. Click a column header to sort; click again to reverse.
- **Sidebar** (left). Sections for **Favorites** (your bookmarks), **Locations** (Computer, Home), **Devices** (mounted/USB drives with a capacity bar and **eject** button), **Network** (network shares), and **Tags** (the tag cloud — every tag with its color and file count; click to filter).
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
| **→** | Go *into* the folder under the cursor (also opens files only if you turn that on in Settings) |
| **←** | Go *up* to the parent folder |
| **Enter** | Open — enter a folder, or open a file in its default app |
| **Backspace** | Go up to the parent folder |
| **Tab** | Switch the active pane (left ⇄ right) |
| **⇧ + ↑ / ↓** | Extend the selection (multi-select) |
| **Space** | Quick Look the file under the cursor (preview follows the cursor as you move) |

Click a row to select it instantly; double-click to open. Right-click any row (or the empty area) for the full context menu.

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

- **Open** / **Open With…** (pick an app, or *Other…*)
- **Quick Look**
- **Reveal in Finder**
- **Get Info** (**⌘I**) and **Copy Path**
- **Share** — AirDrop and the macOS share services, on a file or your whole selection
- **Add to Favorites** (folders)
- **Tags…** — open the inline tag editor

---

## 7. Tags & color coding

yafm uses **native macOS tags** (stored in extended attributes), so they stay fully compatible with Finder — tags you set in yafm show up in Finder and vice versa. On top of that, yafm keeps its own fast **index** and gives tags a proper UI.

- **Tag a file** from the row's **Tags…** menu or the **Info** inspector. Pick from the 7 standard Finder colors or type a new named tag.
- **Tag cloud** in the sidebar lists every known tag with its color and file count. Click a tag to show all files carrying it.
- **Color coding** tints file/folder icons by rules — by type, by tag, or custom rules — so you can read a folder at a glance.

Manage all tags in **Settings ▸ Tags**: recolor, rename across every file, or remove a tag from all files, plus rescan/rebuild the index (useful if you tagged files outside yafm).

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

Open Settings with **⌘,**. The window has six tabs:

- **General** — *Start folder* (Home / Last used / a specific folder); *Right arrow opens files* (off by default: → only enters folders, Enter always opens); *Show hidden files in new tabs*; **Language** (System / English / Русский — applies after you quit and reopen yafm).
- **Appearance** — theme **Light / Dark / System**; **Density** (Compact / Cozy / Comfortable — how many rows fit on screen); **Motion** (animate selection & navigation, or keep it instant).
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

---

## 11. Full keyboard shortcut reference

### Navigation

| Action | Shortcut |
|--------|----------|
| Move cursor up / down | ↑ / ↓ |
| Into folder (open file if enabled) | → |
| Up to parent folder | ← |
| Up to parent folder | Backspace |
| Open (folder or file) | Enter |
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
That's the never-freeze design doing its job — yafm is genuinely reading the disk and showing you the live count, rather than freezing on a blank window like Finder. Slow or sleeping external/network drives simply take time to wake and enumerate; the badge updates as entries arrive, and you can switch tabs or panes while it loads.

**A folder I tagged outside yafm doesn't show its tags in the sidebar cloud.**
The tag cloud is built from yafm's index. Open **Settings ▸ Tags** and click **Rescan now** (or **Clear index** to rebuild from scratch).
