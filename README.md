# Single-letter folder fix

Counter-Strike: Source on Linux cannot load map assets packed under a folder whose
name is one character long. `materials/z/lightpost.vtf` never loads, and the client
console fills with lines like:

```
##### CTexture::LoadTextureBitsFromFile couldn't find materials//lightpost.vtf
```

Note the double slash. The `z` has not been misspelled or case-folded, it has been
deleted. The engine drops one-character components while resolving a texture path
and leaves an empty one behind.

## This is not the case-folding bug

It looks like the well-known Linux casing problem, and it isn't. In `bhop_avantasia`
the pakfile contains `materials/z/lightpost.vtf` and its VMT reads:

```
"$basetexture" "z/lightpost"
```

That matches the packed path exactly, same case, and it still fails. Every path with
a one-character folder breaks, not just the ones whose case differs.

That also means [lbspcfw](https://github.com/scorpius2k1/linux-bsp-casefolding-workaround)
cannot fix it. Its approach is to extract a map's packed assets to disk and symlink
the exact-case name a map asks for onto whatever the real filename turned out to be.
Here there is no misspelled name to link against, because the component is gone.

The bug is client-side. A dedicated server never loads a VTF, so it logs nothing and
no server-side detour can reach it.

## The fix

POSIX collapses the double slash. `materials//lightpost.vtf` and
`materials/lightpost.vtf` are the same path to `open()`, so a copy of the file at the
flattened path answers the engine's own broken lookup.

```
materials/z/lightpost.vtf   ->   materials/lightpost.vtf
```

The copy has to be a loose file on disk. It cannot live in the BSP, because inside a
zip `materials//lightpost.vtf` is a literal name that matches nothing.

This is not a repair. The lookup is still broken; we are putting a file where the
broken lookup already points.

## What is here

**`addons/sourcemod/scripting/casefoldfix.sp`** does it on demand. On map start it
reads the map's own pakfile, copies anything under a one-letter folder to the
flattened path, and adds it to the downloads table so clients pull it down. There is
nothing to prepare and new maps look after themselves.

Pure SourcePawn. No extensions, no external processes.

```
casefoldfix_max_files   1500   cap per map, 0 disables the plugin
casefoldfix_extract        1   0 queues only, for when something else stocks fastdl
```

Set these in `cfg/sourcemod/plugin.casefoldfix.cfg`. `AutoExecConfig` re-runs on every
map change, so a value set from the console will not survive.

**`casefold-flatten.py`** does the same walk offline over a whole maps folder. Python
3, standard library only.

```
./casefold-flatten.py --server ~/serverfiles/cstrike
./casefold-flatten.py --maps <maps dir> --bz2-out <fastdl root>
```

`--bz2-out` writes bzip2 copies straight into a fastdl root, which is roughly half the
bytes on the wire. A state file keyed on size and mtime means a rerun only touches
maps whose BSP changed, so it drops into a cron or a map-sync hook. `--undo` removes
exactly what a previous run wrote.

The two overlap on purpose. The plugin checks for `<path>` or `<path>.bz2` before
extracting anything, so it stays quiet on whatever the script already covered.

## Limits

The plugin can only copy entries stored uncompressed in the pakfile. Anything deflated
or LZMA'd needs a decompressor SourcePawn does not have, and it is skipped and logged.
Across 47,116 maps that is 8.7% of affected files:

```
fully fixed by the plugin     87.3% of affected maps
partially fixed                3.9%
not fixed at all               8.9%
```

The script handles those, so run it if you want full coverage.

SourceMod sandboxes file paths to the game folder, so the plugin can only ever write
there. If your fastdl is a separate directory you need the script, or your own sync.

Where two maps flatten onto the same path the first writer wins. In practice this is
per-map cubemaps under a one-letter map name, and the cost is a slightly wrong
reflection.

## How common is this

Measured against the packed file lists in
[srcwr/maps-cstrike-more](https://github.com/srcwr/maps-cstrike-more), covering 47,116
of the 58,838 maps in the public fastdl index:

```
affected maps         1,604   3.4%
files to fix         24,985
payload                2.96 GiB raw, about 1.5 GiB as bz2
```

Per affected map the median is 4 files and 0.33 MiB. Two thirds sit between 100 KiB
and 1 MiB, and only ten maps in the whole corpus exceed 50 MiB.

Community map pools are hit much harder than official ones:

```
ze    9.6%      bhop  9.0%      surf  8.6%
ba    5.7%      mg    3.0%      zm    2.5%
de    1.4%      cs    1.0%
```

The single biggest source is `materials/RealWorldTextures/newer/{0,1,2,3}`, one widely
copied texture pack with numeric subfolders.
