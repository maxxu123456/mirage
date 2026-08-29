# Mirage, Wallpaper Engine wallpapers on macOS

Mirage is a native macOS menu-bar app that renders **Wallpaper Engine** wallpapers behind the desktop
icons: `scene.pkg` "scene" wallpapers through a Metal reimplementation of WE's renderer, plus video,
image and GIF wallpapers.

This file is the **single source of truth** for the project: architecture, formats, conventions,
current state, and the specs for the parts that are not built yet. `README.md` is the short,
user-facing version; everything else lives here.

---

## 1. Build and run

```sh
swift build                       # all targets
swift test                        # 43 unit tests
./scripts/build-app.sh            # release bundle → build/Mirage.app
./scripts/build-app.sh debug      # faster, for iteration
open build/Mirage.app             # menu-bar icon appears; the library window opens
```

`build-app.sh` assembles what SwiftPM cannot: `Contents/{MacOS,Resources,Frameworks}`, an
`Info.plist` with `LSUIElement` (menu-bar app, no Dock icon), the Homebrew **glslang** and
**SPIRV-Tools** dylibs copied into `Frameworks` with their install names rewritten to `@rpath`, and an
ad-hoc code signature. The result runs on a Mac without Homebrew.

**Requirements**

* macOS 14+, Apple Silicon (BC texture formats are used when the GPU supports them).
  Note: a bundle built on a Mac whose Homebrew glslang/SPIRV-Tools were compiled for a newer
  macOS inherits that requirement at runtime, even though the SwiftPM platform is 14. Build on
  the oldest macOS you intend to support, or rebuild those formulae for it.
* `brew install glslang spirv-cross spirv-tools`, needed to build, and bundled into the app.
* The Wallpaper Engine **assets folder**, which holds the built-in shaders, models and materials that
  wallpapers reference but never pack. Expected at
  `~/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets`, fetched with a Steam
  account that owns Wallpaper Engine:
  ```sh
  brew install --cask steamcmd
  steamcmd +@sSteamCmdForcePlatformType windows +login <steam-account> +app_update 431960 validate +quit
  ```
  Workshop items: `steamcmd +login <account> +workshop_download_item 431960 <id> +quit`, which lands
  them in `~/Library/Application Support/Steam/steamapps/workshop/content/431960/<id>/`.
  Never redistribute the assets folder, locate it at runtime via
  `AssetLocator.defaultAssetsDirectories()`.

**Developer CLI** (`wetool`), the fastest way to debug anything:

```sh
.build/debug/wetool ls          "<project-dir>"                    # list scene.pkg contents
.build/debug/wetool info        "<project-dir>"                    # project.json + object list
.build/debug/wetool tex         "<project-dir>" <material> out.png # decode a .tex to png
.build/debug/wetool shader      "<project-dir>" genericimage2 SPRITESHEET=1 [--msl]
.build/debug/wetool compile-all "<project-dir>"                    # every shader variant → GLSL/MSL
.build/debug/wetool pipelines   "<project-dir>" [--verbose]        # …→ MTLRenderPipelineState
.build/debug/wetool render      "<project-dir>" out.png --time 2 --size 1280x720 [--frames 30] [--display-res]
.build/debug/wetool sound       "<project-dir>" [--seconds N]       # play its sound objects
.build/debug/wetool scripts     "<project-dir>" [--frames N] [--object NAME]  # SceneScript, no Metal
MIRAGE_DEBUG=1 .build/debug/wetool render …                        # log every encoded pass
rm -rf ~/Library/Caches/Mirage/shaders                             # clear the shader cache
```

App state lives in `defaults read com.mirage.wallpaper` (`library.searchPaths`, and
`wallpaper.assignments` keyed by `display-<CGDirectDisplayID>`); `defaults delete
com.mirage.wallpaper` resets it. Run `build/Mirage.app/Contents/MacOS/Mirage` directly to see
`NSLog` output. On first launch macOS asks for **Documents** access if the wallpaper folder is there.

---

## 2. Repository layout

| Path | What |
|---|---|
| `Sources/WEKit/` | Pure-Swift Wallpaper Engine formats. No Metal, no AppKit, parsing lives here and is cheap to test. |
| `Sources/MirageRender/` | The Metal renderer and the GLSL→MSL shader compiler. |
| `Sources/Mirage/` | The app: menu bar, desktop windows, library, settings. |
| `Sources/wetool/` | Developer CLI. |
| `Sources/CShaderTools/` | System-library shim exposing glslang's and SPIRV-Cross's C APIs to Swift. |
| `Resources/WEAssets/` | The few WE built-ins that ship as no file at all: `shaders/commands/copy.{vert,frag}` for effect passes declared as `{"command":"copy"}`, and `models/mirage/bloomlayer.json`, the full-screen model the synthetic bloom chain hangs off. |
| `Tests/` | `WEKitTests` (formats, preprocessing, scripting) and `MirageRenderTests` (geometry/uniform invariants). |
| `scripts/build-app.sh` | Bundle assembly. Set `MIRAGE_VERSION` to stamp a version. |
| `.github/workflows/` | `ci.yml` builds, tests and assembles the bundle on every push. `release.yml` publishes a zipped `Mirage.app` when a `v*` tag is pushed. |

**WEKit**: `ScriptEngine` (JavaScriptCore host for SceneScript) and `ScriptRuntime` (registration and
per-frame evaluation), `Noise` (Perlin and curl noise plus a seeded PRNG, used by particle turbulence),
`ParticleModel` (typed `particles/*.json`), `PuppetModel` (`.mdl` meshes, bones and animations, parsed
but not yet rendered), `JSON` (dynamic tree, WE stores vectors as `"1 0.5 0"` strings), `WEPackage`
(`scene.pkg`), `WETexture` (`.tex` decode), `BlockCompression` (CPU BC1/2/3 fallback), `WEProject`
(`project.json` + user properties), `DynamicValue` (`PropertyStore`, `ScriptValues`, `{"user":…}` / `{"script":…}`
bindings and a small JS-like condition evaluator), `SceneModel` (scene/objects/effects/materials/
models), `AssetLocator` (pkg → project dir → WE assets → bundled fallback), `ShaderPreprocessor`
(WE-GLSL → GLSL 450), `ShaderRepair` (HLSL-ism repair driven by glslang diagnostics).

**MirageRender**: `ParticleLayer` (CPU particle simulation and its draw), `TextRasterizer` (CoreText
to an r8 coverage texture), `VideoTexture` (`AVAssetReader` to `CVMetalTextureCache`),
`ShaderCompiler` (glslang to SPIR-V to SPIRV-Cross MSL, plus reflection and a disk cache),
`RenderContext` (device, pipeline/sampler caches, blit-and-present MSL), `TextureStore`
(`WETexture` → `MTLTexture`), `RenderTargetPool`, `UniformWriter` (reflection-driven constant-buffer
packing + matrix helpers), `SceneGeometry` (transforms, quads, projection), `ImageLayer` (pass chain
and ping-pong wiring), `SceneRenderer` (scene build, frame loop, present, offscreen render), `SoundPlayer`
(`WallpaperSoundPlayer`, extraction and playback of a scene's `sound` objects).

**Mirage**: `MirageApp` (`@main`, `MenuBarExtra` + library `Window` + `Settings`), `WallpaperWindow`
(desktop-level `NSWindow`; `SceneWallpaperView` = MTKView → `SceneRenderer`; `VideoWallpaperView` =
`AVQueuePlayer` + `AVPlayerLooper`; `ImageWallpaperView`), `Library` (folder scanning →
`WallpaperItem`), `WallpaperController` (per-display assignment, persistence, pause rules),
`WebWallpaperView` (WKWebView plus the WE JavaScript shim), `LibraryView`, `SettingsView`, `Settings`
(plus `PowerState`).

---

## 3. Current state

### Works

* **Scene wallpapers render correctly**, verified against each wallpaper's own `preview.gif`:
  multi-layer composition, per-object transforms and alignment, effect chains with ping-pong
  composites and named render targets, sprite-sheet animation, POT-padding UVs, blend modes,
  user-property bindings, parallax, and passthrough / compose / fullscreen / solid layers.
* **All 243 shader variants** used by the 12-wallpaper sample corpus compile through
  GLSL → SPIR-V → MSL → `MTLRenderPipelineState` with **zero failures**.
* **The app runs**: one borderless window per screen at `kCGDesktopWindowLevel` (behind the icons),
  library grid, per-display assignment that persists, pause rules, FPS cap, mute/volume, launch at
  login, and video / image / GIF playback.
* Texture decode: RGBA8, RGB888, DXT1/3/5 (GPU-native with a CPU fallback), RG88, R8, embedded
  PNG/JPEG, LZ4 blocks, sprite-sheet frame tables.
* **Particles**: a CPU simulation feeding `genericparticle`. Both emitter shapes, all eight
  initializers, and the ten operators the corpus uses (movement, alphafade, sizechange, the three
  oscillators, turbulence over curl noise, vortex, controlpointattract, colorchange), plus
  sprite-sheet animation, trails, ribbons (`rope` and `ropetrail`), `instanceoverride`, and child
  systems (a raindrop's splash, a
  firework's sparks, the glow that follows a shooting star). Verified against `Cozy, LoFi Shop`,
  whose rain now matches its preview and whose splash droplets are the children.
* **Text layers**: CoreText rasterisation into an r8 coverage texture, fed through the normal image
  pass chain so effects and colour blending apply. Fonts load from inside `scene.pkg`. Verified
  against `Cozy, LoFi Shop` and `Pixel Pokemon`, where the clock and date sit where the preview puts
  them (showing their placeholder strings until scripts are wired, see below).
* **Video textures**: a `TEXB0004` `.tex` whose payload is an MP4 decodes on a background queue
  through `AVAssetReader` and `CVMetalTextureCache`, and the current frame is swapped in as the
  scene clock advances. `Pixel Pokemon`'s animated background now renders.
* **Web wallpapers**: `type: "web"` items render in a `WKWebView` behind the icons, with the
  Wallpaper Engine JS shim: user properties reach `wallpaperPropertyListener`, the cursor reaches
  `wallpaperMouseX/Y` and a synthesised `mousemove`, `wallpaperRegisterAudioListener` gets its 128
  bins (silent, since there is no capture), and pausing holds `requestAnimationFrame` and the media.
* **Puppet warp**: a layer whose model names a `.mdl` draws as the skinned mesh it is, with its
  animations. See section 7.4 for the two things that make it work and are easy to get wrong.
* **Audio visualiser**: a Core Audio process tap feeds `g_AudioSpectrum{16,32,64}{Left,Right}`, so
  audio reactive layers move with whatever the Mac is playing. See section 7.6.
* **Bloom**: `general.bloom` renders, through the same four stock materials Wallpaper Engine uses.
  Two corpus wallpapers enable it by default (`Pixel Pokemon`, `Spring City`), and its strength and
  threshold stay bound to their user properties.
* **Sound**: a wallpaper's `sound` objects play, in `loop` or `random` mode, with the start delay,
  the `startsilent` fade, the app's mute and volume, and a per-object volume that is re-resolved
  every frame so a user property or a script can drive it. Clips are extracted from `scene.pkg` once
  into `~/Library/Caches/Mirage/audio`.
* **Scripts (SceneScript)**: one `JSContext` per wallpaper running every `{"script": …}` value.
  All **118 scripted values** in the corpus register and run with **zero diagnostics**. Clocks and
  dates show the real time, the Zelda wallpaper's day/night cycle follows the system clock, and
  scripted transforms, colours and visibility animate. Verified against `Pixel Pokemon`,
  `Cozy, LoFi Shop`, `4k Outset Island` and `Spring City`.

### Not implemented

Counted over the 12-wallpaper corpus, where 201 image objects render and the rest do not:

| Missing | In corpus | Effect |
|---|---|---|
| **Media integration** | 1 | `mediaPlaybackChanged` is told once that nothing is playing, which is the truth, but a now-playing title, artist or album art never arrives, so a media wallpaper shows its idle layout. |
| **Lights / `shape`** | 0 | `PerformLighting_V1` is stubbed to return black. |

Other limitations:

* **Effect `visible` and combos resolve once at load.** Toggling a user property that gates an effect
  (or changes a combo) needs the wallpaper reloaded. Object `visible`, colour, alpha,
  origin/scale/angles and shader constants *are* re-evaluated every frame.
* **A wallpaper's own properties are editable.** The library's detail panel offers the control each
  property's type asks for (toggle, slider, colour well, combo, text), hides one whose `condition`
  is false, and writes the edit into `UserDefaults` under `wallpaper.properties` keyed by item id.
  A scene already on screen takes the new value without reloading: `SceneRenderer.setUserProperty`
  leaves it in a lock-guarded mailbox that the render thread drains at the top of the next frame, so
  an edit lands on a frame boundary rather than mid-frame, and scripts are re-told at the same
  point. `wetool render --property name=value` does the same thing without the app.
  What still needs a reload is an effect that is *gated* by a property, since the set of passes is
  resolved at load.
* **`_rt_MipMappedFrameBuffer` is aliased to the scene target with no mip chain**, so shaders that
  sample it by LOD (rough reflections) always read level 0.
* **Multi-image animated textures** upload only image 0.
* An image object's **material `instance`** is applied (it replaces material texture slots per
  object, which is how a layer points itself at another layer's composite), and an object whose
  composite something else samples is built and filled even when it is invisible. Without both,
  `Pixel City` drew a white square where its day/night cross-fade should be.
* `camerashake`, `camerafade`, `camerapreview` are ignored, they are editor conveniences.
* Multi-display is implemented but has only been tested on a single display.
* Particle **child systems** (`children`) run: a parent's births and deaths seed the child, and a
  `eventfollow` child is re-seated on the live parent particles each frame. An emitter whose
  `audioprocessingmode` is set follows the music, scaling its rate by the spectrum average over its
  own frequency range, remapped through `audioprocessingbounds` and its exponent. Silence leaves the
  rate alone rather than stopping emission, so a muted or unpermitted Mac still gets its particles.
* Text **background** passes (`opaquebackground`, `padding`) are not drawn; only the glyphs are.
* `RenderContext`'s pipeline and library caches are never evicted, so memory grows slowly across
  many wallpaper switches within one session (bounded by the number of distinct shader variants used).

### Performance

Release build, Apple Silicon, presented at 3008x1692, measured with
`wetool render --frames 40` (which reads the frame back only once, so the numbers are the frame
itself). "display res" is the optional setting described below.

| Wallpaper | Layers | Scene size | Native | Display res |
|---|---|---|---|---|
| Letter | 6 | 3840x2160 | 22 ms (45 fps) | 18 ms (54 fps) |
| Cozy, LoFi Shop | 20 | 3840x2160 | 63 ms (16 fps) | 50 ms (20 fps) |
| Sunset Cat | 36 | 3840x2160 | 65 ms (15 fps) | 55 ms (18 fps) |
| Purple Bedroom | 37 | 3840x2160 | 128 ms (8 fps) | 95 ms (11 fps) |
| Pixel City | 38 | 5120x2160 | 183 ms (5 fps) | 121 ms (8 fps) |

**This is GPU bound, not CPU bound**, which contradicts what this file used to say. `wetool render`
reports GPU time alongside wall time, and on Pixel City the GPU accounts for 180 ms of the 183. So
merging the per-pass command encoders, long assumed to be the first thing to fix, would buy almost
nothing. The cost is pixels: roughly 90 passes, most of them reading and writing a full-size
composite, on a 5120x2160 scene.

What has been done:

* The offscreen path no longer allocates a 20 MB target and reads it back on every frame, which was
  most of what the old numbers in this table were measuring.
* **Render at display resolution** (`AppSettings.renderAtDisplayResolution`, off by default;
  `wetool render --display-res`). A wallpaper is authored at its own resolution and every pass costs
  that many pixels no matter how large the display is. The setting scales every render target by
  `max(outputW / sceneW, outputH / sceneH)`, capped at 1. `max`, not `min`, because `present` covers
  the target and crops the axis whose aspect differs, so the surviving axis is the one that needs
  the pixels. Geometry stays in scene units, so only the targets shrink. It is **off by default
  because it is visibly softer**: every layer's composite is resampled at the smaller size and the
  detail is gone by the time it reaches the screen, which is obvious on pixel art. Compare a crop of
  `wetool render` with and without it before assuming it is free.

What is left, in the order worth trying:

1. **Fewer passes.** A pass whose material is a plain `passthrough` with no effect could be elided
   into its consumer instead of round-tripping a full-size composite.
2. **Smaller composites.** A layer whose content occupies a fraction of its target still pays for
   the whole thing, and both composites are allocated for every layer whether or not the chain
   ping-pongs.
3. Uniform buffers are still re-packed from a dictionary for every pass every frame
   (`ShaderValueBag` -> `UniformWriter`). This is CPU work, so it only matters once the GPU is not
   the wall.

## 4. Wallpaper Engine formats

### 4.1 Project layout

A workshop item is a folder (named `<title> [<id>]` by convention here) containing `project.json`,
`preview.{gif,jpg}`, and either a media file or `scene.pkg`.

`project.json`: `type` (`scene` | `video` | `web`, case-insensitive), `file` (`scene.json` or the
mp4/html), `title`, `preview`, `description`, `tags`, `workshopid`, and
`general.properties{ name: { type, text, value, min, max, step, options[{label,value}], condition,
order } }`, plus `general.supportsaudioprocessing`. Property types: `bool`, `slider`, `color`,
`combo`, `text`, `textinput`, `scenetexture`, `file`, `directory`, `group`, `usershortcut`.

### 4.2 `scene.pkg`

```
u32 len, char[len] version        // "PKGV0001" … "PKGV0023"; only the "PKGV" prefix is checked
u32 fileCount
fileCount × { u32 len, char[len] name; u32 offset; u32 length }
<file data>                       // offsets are relative to the byte after the table
```

No compression, no directory entries. Holds `scene.json`, `materials/**/*.json` and `*.tex`,
`models/*.json`, `effects/**/effect.json`, `particles/*.json`, `shaders/**`, `sounds/`, `fonts/`.

**Not packed**, these come from the WE assets folder: `genericimage2/3/4`, `genericparticle`,
`common*.h`, `models/util/*.json`, `materials/util/*` (`white`, `black`, `noise`…),
`effects/<stock>/effect.json`, `effects/waterripplenormal.tex`, `particle/*` textures. Stock effects
live at `assets/effects/<name>/{materials,shaders}/effects/<file>` but are referenced as
`materials/effects/<file>`, so `AssetLocator` builds an index for them. Workshop shaders named
`workshop/<id>/<name>` may be superseded by `assets/zcompat/scene/shaders/<id>/<name>`.

### 4.3 `.tex` textures

```
char[9]  "TEXV0005\0"
char[9]  "TEXI0001\0"
u32 format, u32 flags, u32 textureW, u32 textureH, u32 imageW, u32 imageH, u32 unknown
char[9]  "TEXB0001".."TEXB0004"
u32 imageCount
[TEXB0003+]  i32 freeImageFormat     // -1 = raw pixels, 13 = PNG, 2 = JPEG
[TEXB0004]   u32 isVideoMp4          // 1 → the mip payload is an MP4 file
per image:   u32 mipCount
  per mip:   u32 w, u32 h,
             [TEXB0002+] u32 compression (1 = LZ4 block), i32 uncompressedSize,
             i32 size, u8[size]
if flags & 4 (animated):
  char[9] "TEXS0001".."TEXS0003", u32 frameCount,
  [TEXS0003] u32 gifW, u32 gifH,
  frames × { u32 imageIndex, f32 frametime, f32 x, f32 y,
             f32 xAxis.x, f32 xAxis.y, f32 yAxis.x, f32 yAxis.y }   // pixels
```

Formats: `0` RGBA8 (byte order R,G,B,A), `1` RGB888, `2` RGB565, `4` DXT5, `6` DXT3, `7` DXT1,
`8` RG88, `9` R8, `10` RG16F, `11` R16F, `12` BC7, `13` RGBA1010102, `14`/`15` float.
Flags: `1` no interpolation (nearest), `2` clamp UVs, `4` animated, `8` clamp to border, `32` video,
`0x80000` alpha-channel priority.

`textureW/H` is the (power-of-two padded) storage size and `imageW/H` the real content, so the
content occupies `u ∈ [0, imageW/textureW]`, `v ∈ [0, imageH/textureH]`. For "free image" payloads
(PNG/JPEG) the mip is stored at the *content* size, so that ratio is 1.
`g_TextureNResolution = (gpuW, gpuH, contentW, contentH)`; for animated textures the `zw` pair is the
sprite (gif) size. LZ4 blocks decode with `COMPRESSION_LZ4_RAW` from `libcompression`, no
third-party LZ4 dependency.

### 4.4 `scene.json`

```jsonc
{
  "camera": { "eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0" },
  "general": { "orthogonalprojection": { "width": 3840, "height": 2160 },   // or {"auto": true}
               "clearcolor": "0.1 0.1 0.1", "clearenabled": true,
               "ambientcolor": …, "skylightcolor": …,
               "bloom": false, "bloomstrength": 2, "bloomthreshold": 0.65,
               "cameraparallax": true, "cameraparallaxamount": 1,
               "cameraparallaxdelay": 0.1, "cameraparallaxmouseinfluence": 1,
               "camerashake": …, "camerafade": …, "zoom": 1, "hdr": false,
               "nearz": 0.01, "farz": 10000, "fov": 50 },
  "objects": [ … ],
  "version": 1
}
```

An object is an **image** when it has `image` (a `models/*.json` path), else **particle**
(`particle`), **sound** (`sound`, an array), **text** (`text`), **light**, else a group.
Common fields: `id`, `name`, `parent`, `dependencies[]`, `origin "x y z"`, `scale`, `angles`
(**radians**), `size "w h"`, `visible`, `alpha`, `color`, `brightness`, `parallaxDepth "x y"`,
`colorBlendMode`, `alignment` / `horizontalalign`, `locktransforms` (editor-only, ignore),
`effects[{file, id, name, visible, passes[{combos, constantshadervalues, textures}]}]`,
`instanceoverride`, `animationlayers`, `config.passthrough`.

**Any leaf value may be a binding**: `{"user":"prop","value":v}`,
`{"user":{"name":"prop","condition":"1"},"value":v}` (the value becomes `property == condition`), or
`{"script":"…","value":v}`. `DynamicValue` handles all three, and `ConditionEvaluator` parses the
JS-ish `condition` expressions (`bloom.value == true`, `amount > 0.5 && showclock`).

### 4.4b `.mdl` puppet models

```
char[9] "MDLV00xx"        13, 16, 21 and 23 seen
i32     flag              low byte 9 marks a rig the editor never finished
i32, i32                  both 1 in every file seen
char[]  material path     NUL-terminated, NOT length-prefixed
i32     0
<vertex layout, vertices, indices>
char[9] "MDLS00xx"        bones, then in v>1 an extras block
char[9] "MDLA00xx"        animations
```

**Strings are NUL-terminated C strings**, unlike `scene.pkg`, which length-prefixes its names. This
one difference made `PuppetModel.parse` return nil for every real file: it read the first four
characters of `materials/...` as a length.

The **MDLS extras block** begins with one matrix per bone, and that is the **local rest pose**, which
is what the animation tracks are expressed against. The bone records hold something else; using them
displaces the mesh. A skinning matrix is therefore
`poseWorld[i] * inverse(restWorld[i])`, accumulating both down the parent chain, which is the
identity at rest. That is verified: across nine real models the deviation from the identity at rest
is below 1e-4, and for the record-player arm frame 0 of its "Reference" animation reproduces it too.

An **MDLA v3 animation trailer** is a u32 event count, then a flag byte saying whether per-bone alpha
curves follow, and if so one curve per track (`u32 boneId, u32 byteCount, bytes`, one float per
frame). Skipping a single byte there leaves the cursor inside the count and every later animation in
the file is read as garbage: the arm yielded 1 animation instead of 4.

`animationlayers[].animation` in `scene.json` is the animation's **id**, not its index.

A mesh's positions are pixels about its own centre with y up, and they map **linearly onto the
layer's texture coordinates**: a least-squares fit over real models is exact to 5 decimals, and
recovers an extent equal to the layer's own size. So the mesh-to-scene matrix is the quad's placement
written as a matrix, with a negative y scale for the mirrored scene space (which also reverses the
winding, so that draw must not cull).

`wetool puppet <dir>` parses a wallpaper's models, prints bones and animations, and reports how far
the rest pose is from the identity.

### 4.5 Models, materials, effects

**Model** (`models/*.json`): `material` (required), `width`/`height`, `fullscreen`, `passthrough`,
`solidlayer`, `autosize` (unimplemented in every renderer; always paired with `cropoffset`, both
ignorable), `nopadding`, `puppet`. Stock models: `models/util/composelayer.json` = passthrough +
shader `composelayer` + texture `_rt_FullFrameBuffer`; `fullscreenlayer.json` = fullscreen +
passthrough + shader `passthrough`; `solidlayer.json` = shader `flat` (uses `g_Color`/`g_Alpha`, no
texture).

**Material** (`materials/*.json`): `passes[{ shader, blending: normal|translucent|additive|disabled,
cullmode, depthtest, depthwrite, textures[], usertextures[], combos{}, constantshadervalues{} }]`.
`usertextures` name *user properties* and frequently resolve to nothing, fall back to `textures`.

**Effect** (`effects/<name>/effect.json`): `passes[{ material, target, bind[{name, index}], combos,
constantshadervalues, textures, command:"copy", source }]`, `fbos[{ name, scale, format }]` (size =
layer size / scale; `format` and `unique` are ignored), `dependencies[]`.

The numeric `BLENDMODE` table used by `ApplyBlending` lives in `assets/shaders/common_blending.h`
(1 darken, 2 multiply, 6 lighten, 7 screen, 9 add, 11 overlay, 30 tint, 31 `A + B*opacity`, …).

---

## 5. Shader pipeline

Wallpaper Engine shaders are "loosely GLSL 1.20" authored against HLSL rules and compiled to HLSL on
Windows. Getting them onto Metal takes five stages:

1. **Load**, `AssetLocator.shaderSource(name, ext:)` resolves `shaders/<name>.vert|.frag` through
   pkg → project dir → assets, including the stock-effect index and `zcompat` overrides.
2. **Preprocess**, `ShaderPreprocessor.load` expands `#include` (the block goes *before the first
   function definition and outside any `#if`*, because the headers reference uniforms declared above
   them) and extracts `// [COMBO] {…}` declarations plus `uniform T name; // {json}` annotations
   (`material`, `default`, `combo`, `require`, `requireany`, `range`, `type`).
3. **Stage-1 GLSL**, `#version 450` + a prelude + `#define <COMBO> <value>` + fix-ups:
   * prelude: `mul(x,y) = (y)*(x)`, `lerp`, `frac`, `saturate`, `CAST2/3/4`, `CAST3X3`,
     `float2/3/4`, `texSample2D → texture`, `texSample2DLod → textureLod`, `atan2`, `fmod`, `log10`,
     `ddx`/`ddy`, `clip`, and HLSL-permissive overload sets `we_pow` / `we_max` / `we_min` /
     `we_step` / `we_smoothstep` / `we_mix` / `we_clamp`, `#define`d over the builtins so mixed
     scalar/vector calls compile.
   * fix-ups: reserved words (`sample`, `filter`, `input`, `buffer`, …) → `we_*`; a bare `texture`
     identifier → `we_texture`; junk preprocessor expressions
     (`#if g_Texture0Resolution.x < …`) → `#if 0`; `COMBO ? a : b` → `((COMBO) != 0) ? a : b`.
   * `#require LightingV1` is commented out and `PerformLighting_V1` stubbed to return black.
4. **glslang preprocess → `finalize`**, rewrites `attribute` → `layout(location = N) in`,
   `varying` → `out`/`in` with matching locations (arrays supported), reconciles stage-interface
   mismatches (the fragment stage takes the vertex's type plus a converting prologue; outputs the
   vertex never declared are added), `gl_FragColor` → `out_FragColor`, pins sampler bindings to the
   `g_TextureN` index, and hoists uniform-dependent global initialisers into `main()`.
5. **Compile**, glslang (relaxed Vulkan rules; default uniform block `WEUniforms` at set 0
   binding 0) → SPIR-V 1.3 → SPIRV-Cross MSL 2.3 with `FLIP_VERTEX_Y` and
   `MSL_ENABLE_DECORATION_BINDING`. Reflection yields the uniform block's members with std140
   offsets and strides, texture bindings and vertex inputs. The entry point is `main0`. Programs are
   cached in memory and on disk, keyed by a hash of the stage-1 source.

**`ShaderRepair`** closes the remaining gap. glslang reports
`ERROR: 0:<line>:<column>: '<token>' : <message>`; the compiler parses that, applies **one targeted
edit**, and recompiles (up to 24 times):

* `wrong operand types` on a binary operator → truncate the wider operand with a swizzle (HLSL
  truncates to the narrower operand), or promote the narrower base type.
* `%` with a float operand → cast both operands to `int` (GLSL has no float `%`).
* `cannot convert from A to B` on `=` / `assign` / `*=` … → wrap the right-hand side in `B(…)`;
  GLSL constructors truncate and splat, which is exactly HLSL's implicit-conversion rule.
* `function does not return a value: F` → append a zero `return` before `F`'s closing brace.

The repair pass exists *instead of* blanket regexes because a preemptive rewrite is dangerous: an
earlier "append `.x` to `float x = texSample2D(...)`" rule corrupted shaders that already had a
swizzle (`texSample2D(...).r` became `.x.r`). Let the compiler point at the problem.

**Combos** for a pass, lowest priority first (later wins): `// [COMBO]` defaults → sampler-annotation
combos → `TEX0FORMAT` (8 = RG88, 9 = R8, from the object's texture) → material `combos` →
effect-pass `combos` → effect-pass *override* `combos`. Sampler-annotation combos
(`uniform sampler2D g_Texture2; // {"combo":"MASK","require":{…}}`) emit `1` when that slot is
actually bound; otherwise the `require` / `requireany` rules decide.

---

## 6. Renderer design

These conventions come from linux-wallpaperengine's source and were **verified against real
wallpapers**. Four are counter-intuitive, and each one caused a visible bug:

1. **Scene space is pixels, origin bottom-left, y up.** (A comment in lwe's `CText.cpp` claims
   otherwise; the math in `CImage` is right. In `Sunset Cat` the bed sits at `origin.y = 317` and the
   curtain rail at `2102` of a 2160-high scene.) The renderer mirrors into a centred space with
   `y' = H/2 − y`, so **larger `y'` is lower on screen**.
2. **Do not pre-bake NDC into vertices.** Upload raw positions and the real matrices, as lwe does:
   `passthrough.vert` ignores the MVP entirely (its positions must already be NDC),
   `composelayer.vert` needs a real MVP to compute `v_ScreenCoord`, and `genericparticle.vert` builds
   its geometry from `g_ModelMatrix` / `g_ViewProjectionMatrix`. Baking double-transforms them.
3. **Metal clips z to `[0,1]`; OpenGL uses `[-1,1]`.** A `glOrtho`-style matrix sends WE's flat
   z = 0 geometry to z ≈ −1 and the rasteriser discards *every* triangle, the symptom is a scene
   that renders nothing but its clear colour. `Mat.ortho` emits the Metal convention and is always
   called with `near: -1, far: 1`; all WE quads are flat at z = 0 and nothing depth-tests.
4. **The present pass must not flip.** SPIRV-Cross's `FLIP_VERTEX_Y` already converts GL's bottom-up
   convention to Metal's top-left texture origin, so the scene target's row 0 *is* the top of the
   image. Flipping again renders every wallpaper upside down, and it looks plausible enough on
   screen that you must check against the wallpaper's own `preview.gif`, not against intuition.

`Tests/MirageRenderTests/GeometryTests.swift` pins all of this. Do not change the orientation
conventions without re-verifying against a preview.

### 6.1 Geometry

* **Size**: `fullscreen` → scene size (origin forced to the centre); else the material slot-0
  texture's *content* size; else `scene.json "size"`; else `(sceneW, sceneH)` for a `solidlayer`.
* **Quad**: `scaled = size * scale.xy`; `L/R = origin.x ∓ scaled.x/2`, `B/T = origin.y ∓ scaled.y/2`;
  then `alignment` (from `horizontalalign` ?? `alignment` ?? `"center"`, matched as a **substring**,
  so `"topleft"` shifts both axes) moves both edges of an axis by half the *scaled* size:
  `top` → −h/2, `bottom` → +h/2, `left` → +w/2, `right` → −w/2. Then `x −= W/2` and `y' = H/2 − y`.
* **Rotation**: `angles.z` in radians, `Rz(−angle)` about the quad centre (negated because the space
  is mirrored). `MVP_screen = P · T(c) · Rz(−angle) · T(−c) · T(parallax)`.
* **Camera**: `P = ortho(-W/2, W/2, -H/2, H/2)` with the extents divided by `general.zoom`. The view
  matrix is **identity**, `camera.eye` cancels between `ortho·translate(eye)` and `lookAt(eye,…)`
  in every real scene.
* **Parent chain**: `origin = parentOrigin + rotateCCW(childOrigin * parentScale.xy, parentAngle)`,
  `origin.z = parentOrigin.z + childOrigin.z * parentScale.z`, scales multiply, angles add, depth
  capped at 32.
* **Parallax**: once per scene per frame,
  `disp = mix(disp, (pointer − 0.5) * amount * mouseInfluence, clamp(delay * dt, 0, 1))`; then per
  object `((parallaxDepth + amount) * disp * sceneWidth)`, **scene width on both axes**, applied as
  a right-multiplied translation on the MVP.

**The three vertex buffers** (6 vertices, `.triangle`, no index buffer). The v-order is what keeps
images upright:

```
copy   (pass 0)  pos (0,h) (0,0) (w,h) (w,h) (0,0) (w,0)
                 uv  (0,ch)(0,0) (cw,ch)(cw,ch)(0,0)(cw,0)     cw/ch = content / gpu size
                 MVP = ortho(0,w,0,h)   ⇒ ortho y = 0 carries v = 0 = the image's TOP row
effect (1…n-1)   pos (-1,1)(-1,-1)(1,1)(1,1)(-1,-1)(1,-1)
                 uv  (0,1) (0,0)  (1,1)(1,1)(0,0)  (1,0)       MVP = identity
scene  (last)    pos (L,yHigh)(L,yLow)(R,yHigh)(R,yHigh)(L,yLow)(R,yLow)
                 uv  = the effect set, unless this is ALSO pass 0, then the copy set
                 MVP = MVP_screen
```

`cw`/`ch` are forced to 1 for animated textures, their frame rect arrives through
`g_Texture0Rotation` (`xAxis.x/texW, xAxis.y/texH, yAxis.x/texW, yAxis.y/texH`) and
`g_Texture0Translation` (`x/texW, y/texH`) instead. A `passthrough` model replaces the copy positions
with the scene-space rect and sets `MVP_copy = MVP_screen`; `passthrough && fullscreen` uses a
literal ±1 quad.

### 6.2 Pass chain

Per image object (`ImageLayer`), mirroring lwe's `CImage::setupPasses`:

* Passes = the material's passes, then for each **visible** effect its material passes (or a
  `commands/copy` pass for `{"command":"copy"}`), then one
  `materials/util/effectpassthrough.json` pass with `BLENDMODE = colorBlendMode` when that is > 0.
* With more than one pass, the **first pass's blending moves to the last pass** and the first becomes
  `normal` (an opaque copy).
* Passes ping-pong between `_rt_imageLayerComposite_<id>_a` and `_b`, both at layer size, registered
  scene-wide so other objects can sample them. A pass with a `target` renders into that effect FBO
  and does **not** swap; it opens a "target sequence" whose entry input is offered to later passes as
  `previous`.
* The last pass without a target draws into the scene framebuffer with `MVP_screen` and an
  **RGB-only write mask**, alpha is never written into the scene.
* **Texture slots**, highest priority first: `bind` > override `usertextures` > override `textures` >
  material `usertextures` > material `textures` > fragment sampler default > vertex sampler default.
  A `"previous"` bind or an exhausted chain resolves to `previousInput ?? input`; slot 0 defaults to
  the pass input. `_rt_*` / `_alias_*` names resolve through effect → object → scene scope. Anything
  unresolved binds a 1×1 white texture, transparent when the *object's own* texture is missing, so a
  failed load cannot blow out the scene.
* **Self-read protection**: if a bound texture is also the destination (e.g. sampling
  `_rt_FullFrameBuffer` while drawing into the scene), it is blitted to a scratch target first.
* Blending: `translucent` = `srcAlpha / 1-srcAlpha`, `additive` = `srcAlpha / one`,
  `normal` = `one / zero`, `disabled` = off. Straight (non-premultiplied) alpha throughout, and
  non-sRGB pixel formats, WE composites in gamma space.

### 6.3 Uniforms

Constants are written first (annotation defaults → material `constantshadervalues` → effect-pass
override), then the engine built-ins **overwrite** them, except `g_CompositeColor`. A constant key
matches the annotation's `material` name, falling back to the GLSL name minus its first two
characters (`g_Strength` ↔ `Strength`). The declared GLSL type decides coercion: a scalar broadcasts
into a vector, a vector truncates into a scalar.

Built-ins supplied: `g_Time`, `g_Daytime` / `g_DayTime` (`(hour*60 + minute)/1440`), `g_Frametime`,
`g_PointerPosition(+Last)` (x right, y down), `g_ParallaxPosition`, `g_TexelSize`, `g_TexelSizeHalf`,
`g_Screen`, `g_TextureReductionScale`, `g_Brightness`, `g_UserAlpha`, `g_Alpha`, `g_Color`,
`g_Color4 = vec4(color, alpha)`, `g_CompositeColor`, `g_LightAmbientColor`, `g_LightSkylightColor`,
`g_AudioSpectrum{16,32,64}{Left,Right}`, `g_TextureNResolution`, `g_TextureNRotation` /
`g_TextureNTranslation`, and the matrices: `g_ModelViewProjectionMatrix` (per pass kind -
`ortho(0,w,0,h)` for the copy pass, identity for effect passes, `MVP_screen` for the final pass),
`g_EffectModelViewProjectionMatrix` (an alias), `g_ModelViewProjectionMatrixInverse` (the honest
inverse), `g_ModelMatrix` = `g_EffectModelMatrix` = `ortho(0, layerW, 0, layerH)` (yes, an ortho
matrix in the "model" slot, WE really does that), `g_ModelMatrixInverse`, `g_ViewProjectionMatrix` =
identity, `g_NormalModelMatrix` = `mat3(1)`, `g_EffectTextureProjectionMatrix(+Inverse)` = identity.

`UniformWriter` packs these using SPIRV-Cross's reflected offsets, array strides and matrix strides,
so the layout always matches the generated MSL struct.

---

## 7. Remaining work

Condensed from a reverse-engineering pass over linux-wallpaperengine (`lwe`, C++/OpenGL,
authoritative) and catsout's wallpaper-scene-renderer (`wsr`, C++/Vulkan, cross-check). The long-form
versions are kept outside the repo at `~/Developer/we-macos-reference/renderer-spec/`.

### 7.1 Particles and text: built, with these gaps

Both are implemented (`Sources/MirageRender/ParticleLayer.swift`, `Sources/WEKit/ParticleModel.swift`,
`Sources/MirageRender/TextRasterizer.swift`). What is left:

* **Ribbons** (`rope`, `ropetrail`) draw through `genericropeparticle` under `THICKFORMAT`, whose
  no-geometry-shader branch declares exactly seven attributes in a 104 byte vertex. The shader draws
  one flat quad per sub-segment and works out the ribbon's width itself from the neighbouring spline
  points, so those travel with every vertex: `C1` carries the point before the segment and `C2` the
  point after, which is what makes a join smooth rather than a crease. The Catmull-Rom subdivision is
  therefore on the CPU. A `rope` threads one ribbon through the live particles in spawn order; a
  `ropetrail` gives each particle its own, sampling its position on a fixed cadence
  (`length / segments`) so the points are evenly spaced in time rather than per frame. That history
  lives in a flat array beside the particles and is moved when the live list is compacted, or trails
  would swap between particles as they die. The quad budget is clamped so a 16 bit index can address
  it, with a diagnostic when that bites.
* Particle `children` systems and audio-driven emitter rates are unimplemented.
* Text background passes (`materials/fonts/fontbackground.json`, inflated by `padding`) are not drawn.
* A text layer's composite targets are sized from its first rasterisation and only grow, so a layer
  whose string gets much longer reallocates them once.

### 7.2 Video textures: built

`TextureStore.uploadVideo` decodes a `TEXB0004` payload with `VideoTexture` and
`SceneRenderer.render` calls `textures.advanceVideoTextures(to:)` each frame. Ordinary
`type: "video"` wallpapers still use `AVPlayerLayer` in the app, which is cheaper.

Two things about it: the decoded texture is `.bgra8Unorm` and needs **no** swizzle, because a Metal
pixel format describes memory layout and sampling still returns RGBA (verified against
`Pixel Pokemon`'s palette, not just reasoned about); and the initialiser blocks on track loading, so
it must stay on the scene-loading queue and off the main thread.

### 7.3 Scripts: built

`ScriptEngine` (JavaScriptCore) runs the JavaScript; `ScriptRuntime` does the bookkeeping around it;
`DynamicValue` carries a `scriptID` so a scripted value can be registered once and looked up every
frame; `SceneRenderer.buildScripts()` walks the scene and `render` drives one `beginFrame`.

Four things about the design, each of which cost a debugging session:

* **Evaluate once per frame, up front, not lazily from `resolve`.** A scene value is resolved
  several times a frame (geometry, uniforms, the text rasteriser) and `update()` must run once.
  `ScriptRuntime.beginFrame` evaluates every handle and publishes into `ScriptValues`.
* **`update(value)` receives its own previous result**, not the stored default. That is what makes
  `return value + engine.frametime * speed` accumulate, which is how every rotating layer works.
  The caller keeps passing the stored default; the engine ignores it once the script has moved on.
* **`applyUserProperties` is not optional.** Real scripts do their layout there and leave `init`
  to look up layers, so a script that never receives it runs `update` against undefined state and
  throws on the first frame. WE's order is `init`, then the properties, then the first update.
* **Layer objects are seeded with the scene's real values** before anything registers, because a
  script reads the layer it drives and its neighbours (`thisScene.getLayer("x").origin`).
* **A script's writes are read back off the layer objects after every frame.** Controller scripts
  animate layers they do not drive (one script fades and moves a whole group by assigning
  `layer.alpha` and `layer.origin`), and those writes exist only in JavaScript until they are
  published into `ScriptValues` and consulted where the renderer resolves an object's transform,
  colour, alpha, brightness, visibility and text. The baseline for "what changed" is a read-back
  taken straight after seeding, not the seeded dictionary, because a layer object also carries
  defaults for properties the scene never set.

Two things to keep in mind when changing this:

* The `JSContext` is built on the scene loader queue and then used from the render thread. That is
  safe only because the handoff is strictly ordered (the view is installed after the scene finishes
  building) and nothing touches the context concurrently. Keep it that way.
* **Layers are keyed by name, so two objects sharing a name share one JavaScript layer**, and a
  script's write to it is published to both. Wallpaper Engine has the same ambiguity, since
  `thisScene.getLayer(name)` can only return one of them.

Only layers a script actually wrote to are read back: the layer objects' writable properties are
accessors that mark the layer dirty, because reading nine properties off every object every frame
costs more than the scripts do on a large scene.

What is stubbed: no puppet animation (`getAnimationLayer` and friends answer, inertly), no media
integration beyond a single "nothing is playing" event, no cursor events, and no execution timeout
(JSC's is private API), so a runaway script would hang the render thread. Scripts that throw are
disabled after five failures, keeping their last good value rather than snapping back to the
stored default. An effect's `visible` is registered and evaluated but still only *applied* at load,
like every other effect combo.

`wetool scripts <dir> [--frames N] [--object NAME]` runs the whole scripting layer with no Metal and
no renderer, which is how you tell a broken script from a broken pass chain.

### 7.4 Sound, web, bloom and puppets: built

*Sound*: `WallpaperSoundPlayer` extracts `sounds/*` from the pkg into
`~/Library/Caches/Mirage/audio` once, then plays them with `AVAudioPlayer` in `loop` or `random`
mode after `rand(mintime, maxtime)`, at `object.volume x appVolume x (muted ? 0 : 1)`.
`SceneWallpaperView` owns one per wallpaper and drives it from the same clock the renderer gets, so
delays and the `startsilent` fade stay in step with the visuals and stop when the wallpaper pauses.
`wetool sound <dir>` plays a scene's audio with no renderer.

*Web*: `WebWallpaperView` loads the wallpaper's `index.html` with read access scoped to its project
folder, and injects a shim providing `wallpaperPropertyListener`, `wallpaperRegisterAudioListener`,
`wallpaperMouseX/Y`, `wallpaperRequestRandomFileForProperty` and the pause events. It has no
per-frame hook the way an `MTKView` does, so it polls the cursor on a 30 Hz timer that stops with
the wallpaper. Known gaps: audio is silence, media integration is inert, and pausing holds
`requestAnimationFrame` and media but not CSS animations or `setInterval`.

*Bloom*: Wallpaper Engine implements bloom in engine code, not as an `effect.json`, so
`SceneRenderer.buildBloomLayer` manufactures one. A full-screen passthrough object with id `-1` is
appended after every other layer, carrying a four-pass effect over the stock materials:

```
passthrough                 -> _rt_imageLayerComposite_-1_a   (the scene, copied aside)
downsample_quarter_bloom    -> _rt_4FrameBuffer               (scene/4, thresholded)
downsample_eighth_blur_v    -> _rt_8FrameBuffer               (scene/8, blurred)
blur_h_bloom                -> _rt_Bloom                      (blurred on the other axis)
combine                     -> _rt_FullFrameBuffer            (copy + bloom, back into the scene)
```

The three engine framebuffers are registered scene-wide in `buildSceneTargets`, as WE has them. The
copy exists because the last pass writes back into the scene target and cannot read it at the same
time. `bloomstrength` / `bloomthreshold` / `bloomtint` travel as **raw JSON** into the effect pass's
`constantshadervalues`, so a value bound to a user property stays bound and is re-resolved every
frame; passing resolved numbers would freeze the sliders. The layer is built whenever `bloom` is
bound, even if it currently resolves false, so the toggle works without a reload; a scene that
hard-codes `"bloom": false` builds nothing.

Two things not done: the **HDR** bloom path (`general.hdr`, `bloomhdr*`) is a genuinely different
chain of iterative down/up-sampling and is not implemented, so an HDR scene gets the LDR
approximation; and the model is `Resources/WEAssets/models/mirage/bloomlayer.json` rather than the
stock `models/util/fullscreenlayer.json` because that one declares `translucent` blending, which
`relocateBlending` would move onto the combine pass. It happens to work (combine writes alpha 1) but
only by accident.

---

*Puppet warp*: a layer whose model names a `.mdl` uploads the mesh into real buffers (even the
smallest puppet is ten times Metal's inline vertex limit), draws it indexed with
`VertexLayout.puppet`, and gets `SKINNING=1` plus `BONECOUNT=n` on whichever pass draws the layer,
with the palette arriving as `ShaderValue.mat4x3Array`. Two things were not obvious and cost a day
between them:

* **Some shaders ignore `g_ModelViewProjectionMatrix`.** `genericimage4` with `LIGHTING` positions
  through `g_ViewProjectionMatrix * g_ModelMatrix`, exactly as `passthrough.vert` ignores the MVP
  (section 6, convention 2). Putting the puppet transform only in the MVP made those layers vanish
  while `genericimage2` layers were perfect. The transform now occupies the model slot too, and the
  view-projection stays the identity for image passes so the product is the same matrix.
* **The 80 byte vertex carries a normal and a signed tangent**, and a normal-mapped shader declares
  `a_Tangent4` at location 13. Uploading a constant normal and no tangent leaves the lighting with a
  zero tangent basis.

The bone palette is also what pushes a uniform block past Metal's 4 KiB inline limit: 64 bytes a
bone, so a rig of about sixty overflows. `UniformWriter` no longer truncates there, since dropping
the tail of `g_Bones` collapses the mesh; an oversized block is bound through a buffer instead, and
is still clamped at 64 KiB because a shader is third-party input.

`MIRAGE_NO_PUPPET=1` falls back to the flat quad. Enabling it changes nothing across the twelve
sample wallpapers, whose only puppet is hidden by default, which is why the workshop items fetched
with SteamCMD were needed to test it at all.

### 7.5 Where to pick up

In priority order, with everything needed already on disk:

1. **Effect visibility without a reload.** Only the *set* of passes depends on the store at load:
   `buildLayers` filters `object.effects` by `visible.resolveBool(store)`. Compiling every effect and
   re-running `relocateBlending()` + `wirePasses()` over a filtered subset would make a property that
   gates an effect live, and would make script-driven `effect.visible` work too. 46 effect `visible`
   values across the corpus are bound to user properties, and only 15 of 308 effects are hidden at
   default settings, so eager compilation costs about 5%.
2. **Performance.** This is now the largest user-visible problem: `Pixel City` still runs at about
   10 fps. The list in section 3 is unchanged and still ordered by expected impact.
3. **Script-driven puppet animation.** `ScriptEngine`'s animation layer stubs accept `blend` and
   `rate` writes and drop them, so a script that plays an animation on a puppet has no effect. The
   layer write-back machinery from section 7.3 is what this needs.

### 7.6 Audio visualiser: built

`SystemAudioCapture` opens a Core Audio **process tap**
(`CATapDescription(stereoGlobalTapButExcludeProcesses:)` plus a private aggregate device), not
ScreenCaptureKit. A tap asks for the "Audio Capture" permission, which is what this actually is;
ScreenCaptureKit would make a wallpaper app ask to record the *screen*, run a video pipeline whose
frames are thrown away, and on newer systems re-prompt periodically. Wallpaper Engine's own macOS
build takes the same route: its binary weak-links `AudioHardwareCreateProcessTap` and it declares
`NSAudioCaptureUsageDescription`, which `scripts/build-app.sh` now writes into the Info.plist too.

`SpectrumAnalyzer` does the DSP with Accelerate: a 2048 sample Hann window (42.7 ms and 23.4 Hz per
bin at 48 kHz, where 1024 would be too coarse for the bottom bands), a real-to-complex FFT, and 64
logarithmically spaced bands from 30 Hz to 16 kHz. Wallpaper Engine's documented contract is 64 bands
per channel with index 0 lowest and values "generally 0.00 to 1.00", so 64 is the native width and
the 32 and 16 wide uniforms are averaged down from it. Each band takes the **peak** of its bins, not
the mean, or a narrow tone in a wide high band averages away to nothing. `SpectrumSmoother` rises
instantly and falls gradually, which is what stops the bars flickering.

`AudioSpectrumProvider.shared` owns one tap for the whole app, reference counted, so the tap only
runs while a wallpaper that actually reads the spectrum is on screen, and the permission is only ever
asked for by such a wallpaper. `SceneRenderer.usesAudioSpectrum` decides that by looking for a
`g_AudioSpectrum` uniform in any compiled pass; scenes without one no longer box six arrays into the
uniform dictionary every frame either.

Two things to know:

* **An ad-hoc signature loses the permission on every rebuild.** TCC keys the grant to the code
  signature, and an ad-hoc bundle's designated requirement is its cdhash, which changes every build.
  Set `MIRAGE_SIGN_IDENTITY` to a self-signed certificate to keep the grant across builds.
* `wetool audio` prints the live spectrum as bars, which is how to tell a permission problem from a
  DSP one. Verified with a two tone signal: 80 Hz and 4 kHz land in the bands a 30 Hz to 16 kHz log
  sweep puts them in, at a level matching the signal's amplitude.

## 8. Conventions and gotchas

* **Verify visual changes against the wallpaper's own `preview.gif`**, never against reasoning alone.
  Two orientation bugs in this project looked completely plausible on screen.
* `Int(someFloat)` traps in Swift on NaN or infinity, always clamp values that come from wallpaper
  JSON before converting.
* Wallpaper files are third-party input and must be treated as hostile: parsers fail soft (return
  `nil`, record a diagnostic) rather than throwing or crashing. `SceneRenderer.diagnostics` and
  `AssetLocator.unresolvedPaths` collect what went wrong.
* Render targets and textures are `.private`; uploads go through a staging buffer and a blit.
* The renderer never uses sRGB pixel formats, WE composites in gamma space.
* `MIRAGE_DEBUG=1` logs every encoded pass with its destination, bound slots, blend mode and quad.
* Do not add AI or assistant attribution to code, comments or commits.

## 9. License

MIT (see `LICENSE`). Note that the renderer's behaviour was derived by studying
linux-wallpaperengine (GPL-3.0) and wallpaper-scene-renderer; no code from either is vendored or
copied here, but if that derivation ever matters to you, revisit the choice. The bundled Homebrew
dependencies keep their own licenses: glslang (BSD/Apache-2.0), SPIRV-Cross and SPIRV-Tools
(Apache-2.0).

## 10. Reference material

* **linux-wallpaperengine** (Almamu, C++/OpenGL) is the authoritative reference implementation and
  **wallpaper-scene-renderer** (catsout, C++/Vulkan) is the cross-check. Both are GPL-licensed, so
  their source is **not** vendored here, clone them separately if you need to re-check behaviour.
  Local mirrors and the long-form specs derived from them live outside the repo at
  `~/Developer/we-macos-reference/`.
* Official designer documentation: <https://docs.wallpaperengine.io> (scene → shaders, effects,
  particles, scripting).
* Sample wallpapers used for verification: `~/Documents/wallpaper-engine/` (12 scene items, 7 video
  items).
