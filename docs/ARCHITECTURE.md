# Architecture

This document describes how QuickFind works internally. For features and usage see the [README](../README.md).

## Overview

QuickFind keeps the names and metadata of every file and folder in a compact in-memory index, searches it with
plain byte scans on all cores and keeps it current with FSEvents. The approach mirrors *Everything* on Windows:

| Everything (Windows/NTFS) | QuickFind (macOS/APFS) |
|---|---|
| reads the NTFS MFT directly | parallel directory enumeration with `getattrlistbulk(2)`, the fastest public way (APFS metadata cannot be read directly without root or a kernel extension) |
| USN journal for live changes | FSEvents stream (directory-level events) |
| USN journal replay after a restart | FSEvents event ID replay (`sinceWhen`): changes made while the app was not running are caught up, no rescan needed |
| `Everything.db` | binary snapshot in `~/Library/Application Support/QuickFind/index.qfi` |
| compact in-memory index | struct of arrays with one shared name buffer |
| linear search over all names | `memmem` over the folded name buffer, in parallel on all cores |
| presorted indexes | precomputed global name order, so sorting by name is O(n) |

The code is split into three targets:

```text
QuickFindCore (library, no UI)
├─ Primitives.swift      Buffer<T>, RWLock, Mutex, CancelToken, case folding, parallel sort
├─ FileIndex.swift       the index: storage, tree, paths, lookups, folder sizes, name order
├─ Collation.swift       Finder-like sort keys (diacritics, natural number order)
├─ Scanner.swift         getattrlistbulk lister and multi-threaded tree walker
├─ FSWatcher.swift       FSEvents stream wrapper with event ID replay
├─ IndexManager.swift    lifecycle: load or scan, live updates, volumes, periodic saving
├─ Persistence.swift     binary snapshot format
├─ Query.swift           parser for the Everything-style search syntax
├─ SearchEngine.swift    parallel search, folder browsing and sorting
├─ Cleanup.swift         clean-up assistant: candidates, protection rules, duplicate hashing
├─ Localization.swift    L("…") lookup of UI texts
└─ Testing.swift         end-to-end self-tests (run with `qf selftest`)
QuickFind (AppKit app)   windows, result table, sidebar, settings, clean-up UI, hot key, menu bar
qf (command line)        scan / search / bench / watch / selftest
```

## The index (`FileIndex`)

Every file and folder is one entry with a stable `Int32` ID. Storage is **struct of arrays**: instead of one object
per entry there is one array per attribute, all indexed by ID.

| Array | Type | Content |
|---|---|---|
| `names` | bytes | all names as UTF-8, NUL-separated |
| `folds` | bytes | the same names case-folded (Unicode NFC + lowercase) for case-insensitive search |
| `nameOff`, `foldOff` | `UInt32` | start offsets into the two byte buffers |
| `parents` | `Int32` | parent ID |
| `firstChild`, `nextSibling` | `Int32` | the tree as linked lists, so path lookups need no hash maps |
| `sizes` | `Int64` | logical size; for folders the sum of their contents |
| `allocs` | `Int64` | space actually used on disk (sparse files, APFS compression, cloud placeholders) |
| `mtimes`, `ctimes` | `Int64` | modification and creation date |
| `flags` | `UInt8` | directory, symlink, mount point, online-only cloud file, … |

Together with the name order (below) this comes to roughly 100 bytes per entry, depending on name lengths.

Properties the rest of the code relies on:

- **Parent ID < child ID.** Scans append children after their parents, and the snapshot is renumbered in the same
  order. Folder sizes can therefore be recomputed in one backwards pass.
- **IDs are stable while the app runs.** Deleted entries are tombstoned and only dropped when the snapshot is saved.
- **Folder sizes are aggregated.** A size change is propagated to all ancestors, so every folder always shows the
  total of its contents.
- **Memory comes from `mmap`.** `Buffer<T>` allocates large arrays directly from the kernel: untouched capacity
  costs nothing and freed buffers return to the system immediately. After loading or scanning, `compactStorage`
  gives back the growth slack.
- **One reader/writer lock** guards the whole index. Searches take the read lock and work on a raw `IndexView` of
  the arrays; scans and live updates take the write lock in batches.

### Name order and collation

For sorting by name, QuickFind computes a global order of all entries once (`nameOrder`) plus the rank of each entry
(`nameRank`). Sorting a result by name is then a bitmap pass over the global order, O(n) instead of O(k log k).
The order is rebuilt in the background after scans and larger changes.

`Collation` builds a byte key per name that sorts like the Finder: diacritics are ignored on the primary level
(“Ärger” sorts with “A”) and digit runs compare numerically (“File2” before “File10”). Sorting itself is plain
`memcmp` on these keys.

## Scanning (`Scanner`)

`BulkLister` lists a directory with `getattrlistbulk(2)`, which returns name, type, dates, sizes, BSD flags and
mount status of many entries per system call. One 256 KB buffer is reused for all calls.

`ParallelScanner` walks the tree with one worker per core. Workers take directories from a shared LIFO queue, list
them into a local batch and commit the batch to the index under a single write lock. Path computation and exclusion
checks happen outside the lock. Mount points and symlinks are recorded but not descended into; other volumes are
added as separate roots. Typical speed is about 350,000 entries per second on the data volume.

While a full scan runs, a marker file (`index.qfi.scanning`) exists. If the app quits mid-scan, the next start sees
the marker and rebuilds the index instead of trusting an incomplete snapshot.

## Lifecycle and live updates (`IndexManager`)

At startup the manager loads the snapshot if its configuration key (excluded folders, external volumes, roots) and
the volume UUIDs still match; otherwise it runs a full scan. After loading, it starts an FSEvents stream **from the
event ID stored in the snapshot**, so macOS replays every change made since the last run.

Live updates work on directory level:

1. The FSEvents callback only collects and merges paths on its own queue. It is never blocked by a running scan, so
   macOS does not drop events.
2. A processing pass on the serial `work` queue lists each changed directory again and reconciles its children
   with the index: new entries are added (new folders are scanned), missing ones removed, changed ones updated.
3. If FSEvents reports that it lost track of a subtree (`MustScanSubDirs`), the manager compares the whole subtree
   with the disk instead of emptying and rescanning it, so the index stays complete in the meantime. The same path
   is reconciled at most every two minutes; further requests are postponed, not lost.

Mounted and unmounted volumes are added or removed as roots. The snapshot is saved every two minutes if something
changed and when the app quits, but never while a scan is filling in a subtree.

## Snapshot format (`Persistence`)

```text
magic "AQFX" | header length | JSON header (version, last event ID, config key, volume UUIDs, counts) | raw arrays
```

Saving compacts the index on the fly: tombstoned entries are skipped and IDs renumbered (parents before children).
The data is streamed in 1 MB chunks to a temporary file, which then replaces the old snapshot, so saving needs no
second copy of the index in memory. Loading reads the arrays straight into the buffers, which takes 20–350 ms for
1.5 million entries. A change of the format version or of the index settings triggers a full rescan.

## Search (`Query`, `SearchEngine`)

`QueryParser` turns the search text into an AND of groups, each group an OR of terms. A term is a substring,
wildcard pattern, regex or filter (`ext:`, `size:`, `dm:`, `dc:`, `file:`, `folder:`, `dupe:`) with modifiers such
as `case:`, `ww:`, `path:` or negation. Terms containing `/` automatically search the path.

The engine then:

1. Picks the best plain term to **drive** the scan and runs `memmem` over the folded name buffer, split into chunks
   across all cores. Hits are mapped back to entry IDs.
2. Checks the remaining terms only for those candidates. Terms are flattened into trivially copyable structs so the
   hot loop does no reference counting, which would otherwise serialise all cores.
3. Evaluates path terms in O(1) amortised per entry: an entry matches if its parent's path matches, or if the tail
   of the parent path plus its own name contains the needle. Results are memoised per entry.
4. Restricts the result to a folder if “This Folder” is active (memoised per entry as well).
5. Sorts: by name via the global name order, by size with folders first (like Everything), by path by ranking the
   distinct parent folders first.

Every search gets a `CancelToken`; typing another character cancels the running search. Typical searches over
1.5 million real entries take 1–15 ms including sorting.

The folder view uses the same engine: it lists the children of one folder from the index via the tree links and
sorts them, so browsing needs no disk access.

## Clean-up assistant (`Cleanup`)

Candidates come from the index, not from a separate disk walk. Each category (duplicates, large files, large
folders, old downloads, large old files, installers, empty folders, app caches) is a query over the entries below
the home folder.

**Protection rules** (`Cleanup.isProtected`) exclude the system, Applications, `~/Library` except
`~/Library/Caches/<app>` (never `com.apple.*`), hidden folders, the contents of app packages and media libraries,
tool folders such as `node_modules`, anything inside a Git, SVN or Mercurial project, online-only cloud files, and
top-level folders of the home folder as a whole.

**Duplicates** are found in three steps: same size → same hash of the first and last 64 KB → same SHA-256 of the
whole file. Hard links (same inode) are not treated as duplicates. The oldest file of each group is kept and can
never be selected.

Right before moving anything to the Trash, the UI checks again that each item still exists and is not protected,
and that every duplicate group keeps at least one existing, unselected copy. Items that fail the check are skipped.

## The app (`QuickFind` target)

- `AppDelegate`: menus, status item, global hot key (Carbon `RegisterEventHotKey`, needs no accessibility
  permission), onboarding for Full Disk Access. `Support.swift` holds preferences, formatting, the
  hot key and open at login via `SMAppService`.
- `MainWindowController`: search field, scope and filter controls, the result table (view-based, only visible rows
  are created, so millions of results cost nothing), folder browsing with history, file operations, Quick Look.
- `Sidebar`: favorites and volumes. `CleanupViewController`: the clean-up assistant.
  `SettingsWindowController`: settings and the search syntax help.
- Searches run on a dedicated serial queue with user-interactive priority; results are applied on the main thread.

## Localization

UI texts are written in German in the code and wrapped in `L("…")`. The German text is the key; translations live
in `Resources/<language>.lproj/Localizable.strings`, and a missing translation falls back to the German text.
Formatted texts use positional placeholders (`%1$@`, `%2$@`) so translations can reorder them. The longer search
syntax help exists as two separate texts in `HelpWindowController`.

The development region is English, so macOS shows the English interface for every system language except German.

## Tests

`Testing.swift` contains 77 end-to-end tests that build real folder trees in a temporary directory and check
scanning, the search syntax, sorting, persistence, live updates via FSEvents, folder sizes and the clean-up rules:

```bash
swift build && .build/debug/qf selftest
```

`qf bench --synthetic <n>` measures search speed on a synthetic index with `n` entries.
