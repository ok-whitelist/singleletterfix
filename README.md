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

## Just fix it

Download **[bhop-singleletterfix.zip](../../releases/latest)** and copy `materials/`,
`models/` and `sound/` into your `cstrike` folder:

```
.../Steam/steamapps/common/Counter-Strike Source/cstrike/
```

That is it. No plugin, no launch option, nothing needed from the server. It covers
every affected bhop map on [fastdl.me](https://fastdl.me) and works anywhere you play.

Windows players do not need this. The bug is Linux-only.

The zip ships `singleletterfix-files.txt` listing every file it adds, so you can
delete exactly those to undo it.

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

## Why a copy works

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

## Doing it yourself

Most people want the zip. These exist if you would rather generate it, or serve the
files from your own fastdl so clients pull only what the map needs.

**`casefold-flatten.py`** walks a maps folder, reads each BSP's pakfile and writes the
flattened copies. Python 3, standard library only.

```
./casefold-flatten.py --server ~/serverfiles/cstrike
./casefold-flatten.py --maps <maps dir> --bz2-out <fastdl root>
```

`--bz2-out` writes bzip2 copies straight into a fastdl root, roughly half the bytes on
the wire. A state file keyed on size and mtime means a rerun only touches maps whose
BSP changed. `--undo` removes exactly what a previous run wrote.

**`addons/sourcemod/scripting/casefoldfix.sp`** does the same on demand. On map start
it reads the map's pakfile, writes the flattened copies and adds them to the downloads
table. Pure SourcePawn, no extensions.

```
casefoldfix_max_files   1500   cap per map, 0 disables the plugin
casefoldfix_extract        1   0 queues only, for when something else stocks fastdl
```

Set these in `cfg/sourcemod/plugin.casefoldfix.cfg`. `AutoExecConfig` re-runs on every
map change, so a value set from the console will not survive.

The plugin can only copy entries stored uncompressed in the pakfile; anything deflated
or LZMA'd needs a decompressor SourcePawn does not have, and is skipped and logged.
Across 47,116 maps that is 8.7% of affected files, which is why the script exists.

## How common is this

Measured against the packed file lists in
[srcwr/maps-cstrike-more](https://github.com/srcwr/maps-cstrike-more), covering 47,116
of the 58,838 maps in the public fastdl index:

```
affected maps         1,604   3.4%
files to fix         24,985
payload                2.96 GiB raw, about 1.5 GiB as bz2
```

Community map pools are hit much harder than official ones:

```
ze    9.6%      bhop  9.0%      surf  8.6%
ba    5.7%      mg    3.0%      zm    2.5%
de    1.4%      cs    1.0%
```

The single biggest source is `materials/RealWorldTextures/newer/{0,1,2,3}`, one widely
copied texture pack with numeric subfolders.

The bhop release above is 574 maps, 3,144 files, 199 MiB. Flattening collapses the
duplicated texture packs onto shared paths, which is why it is not the 732 MiB those
files occupy inside the maps.
