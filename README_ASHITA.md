# questmarks — Ashita v4 port

Ashita v4 port **v0.6.0** by **Semil** of **questmarks 1.0.0** by **DrNefarius** (Windower 4).
Quest/mission logic, data and icons are the original's; only the platform layer changed.

## Install
Either download the release zip, or clone this branch straight into your Ashita addons folder:

```
git clone -b ashita https://github.com/jimm0thy/questmarks Ashita/addons/questmarks
```

The folder must be named `questmarks`, with `questmarks.lua` directly inside it. Then in game:
`/addon load questmarks`. Commands are `/qm` or `/questmarks` (Windower's `//qm` became `/qm`); `/qm` alone lists them all.

Notes for the repository checkout:
- `tools/`, `bgwiki-rest-cache/` and the build pipeline are the original's developer tooling for Windower. The Ashita
  port does not use them.
- `build/rendered/` and `build/authored/` are read by the **questmarks-ui** port to show quest descriptions and step
  notes; a checkout includes them, so those features work.

Requires Ashita v4's bundled `d3d8`, `imgui`, `ffi` and `bit` modules (all stock).

## How it was ported
`compat.lua` is a Windower-shaped facade over Ashita's memory manager, so the ~2000 lines of
logic in `questmarks.lua` and `core/` are unchanged. Platform-specific parts:

| File | Job |
|---|---|
| `compat.lua` | `windower.ffxi.*` shims, scheduler, login/zone/job detection (polled per frame) |
| `qm_packets.lua` | decoders for 0x056 (quest/mission log), 0x055 (key items), 0x02D, 0x028 |
| `render/camera.lua` | reads view/projection matrices from the D3D8 device each frame |
| `render/backend.lua` | loads PNGs with `D3DXCreateTextureFromFileA`, draws them with ImGui `AddImage` |
| `render/project.lua`, `render/markers.lua` | original projection/marker code, re-pointed at the above |

## What has and has not been verified
Tested in game on **HorizonXI** (Ashita v4): the markers draw above quest NPCs, `/qm selftest` shows over your head,
`/qm axes 1 2 3` is correct (now the default), textures load, and the quest state follows the server's 0x056 packets.
Also run headlessly against mocks (packets → state → NPC scan → projection → draw calls).

Not verified, so the first things to check if something looks off on another build or server:
- **Camera matrices** — taken from `GetTransform` at `d3d_present`; the accessor is probed at runtime. `/qm probe` shows what was captured, the draw list used and any draw errors.
- **"Spawned" test** — `/qm visible` uses render flag 0x200; if no markers show at all try `/qm visible off`.
- **Packet layouts 0x02D / 0x028** (kill tracking) were written from memory; 0x056/0x055 follow the original's documented layout.
- **Not available on Ashita:** Mog House detection and menu-open detection (treated as false).
- Equipped-item detection (container Flags==5) is a guess; the `/qm hook pre|post` option is now a no-op (Ashita has one render event).

## Debugging
`/qm probe` (camera, viewport, axes, candidates) · `/qm selftest` (tag over your own head) ·
`/qm axes` · `/qm visible off` · `/qm lag 0` · `/qm diag` (full dump, also written to `questmarks.log`).

## Tests
`texlua tests/smoke_headless.lua` (or any Lua 5.3+) from this folder runs the mock-Ashita smoke test.

## License
Code: MIT (see `LICENSE`). Bundled quest data: CC BY-NC-SA 3.0 from BG Wiki (`LICENSE-DATA`);
`data/dat_names.lua` contains Square Enix content (`NOTICE`). Original author credit: DrNefarius.
