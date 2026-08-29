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
.build/debug/wetool render      "<project-dir>" out.png --time 2 --size 1280x720 [--frames 30]
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
| `Resources/WEAssets/` | The few WE built-ins that ship as no file at all, currently `shaders/commands/copy.{vert,frag}`, used by effect passes declared as `{"command":"copy"}`. |
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
`LibraryView`, `SettingsView`, `Settings` (plus `PowerState`), and `WebWallpaperView`, which is
written and compiles but is not wired up yet.

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
  sprite-sheet animation, trails and `instanceoverride`. Verified against `Cozy, LoFi Shop`, whose
  rain now matches its preview.
* **Text layers**: CoreText rasterisation into an r8 coverage texture, fed through the normal image
  pass chain so effects and colour blending apply. Fonts load from inside `scene.pkg`. Verified
  against `Cozy, LoFi Shop` and `Pixel Pokemon`, where the clock and date sit where the preview puts
  them (showing their placeholder strings until scripts are wired, see below).
* **Video textures**: a `TEXB0004` `.tex` whose payload is an MP4 decodes on a background queue
  through `AVAssetReader` and `CVMetalTextureCache`, and the current frame is swapped in as the
  scene clock advances. `Pixel Pokemon`'s animated background now renders.
* **Sound**: a wallpaper's `sound` objects play, in `loop` or `random` mode, with the start delay,
  the `startsilent` fade, and the app's mute and volume. Clips are extracted from `scene.pkg` once
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
| **Puppet warp** (`.mdl`) | 1 | The skinned layer draws as a static quad. `Sources/WEKit/PuppetModel.swift` parses the format and computes bone matrices, but the renderer does not yet emit the `SKINNING` / `BONECOUNT` combos, the skinned vertex layout or `g_Bones`. |
| **Bloom** (`general.bloom`) | 0 | - |
| **Lights / `shape`** | 0 | `PerformLighting_V1` is stubbed to return black. |
| **Web wallpapers** | - | `Sources/Mirage/WebWallpaperView.swift` is written and compiles (WKWebView plus the Wallpaper Engine JS shim) but `WallpaperController` still reports "not supported yet" instead of using it. |
| **Audio visualiser** | - | `g_AudioSpectrum*` are zeros, so audio-reactive layers stay flat. Needs system-audio capture, which needs a screen-recording permission. |
| **Rope particle renderers** | 5 of 69 | `rope` and `ropetrail` fall back to sprites; they need `genericropeparticle` and a Catmull-Rom spline. |

Other limitations:

* **Effect `visible` and combos resolve once at load.** Toggling a user property that gates an effect
  (or changes a combo) needs the wallpaper reloaded. Object `visible`, colour, alpha,
  origin/scale/angles and shader constants *are* re-evaluated every frame.
* **Property controls in the UI are read-only.** `PropertyStore` already drives live bindings; the
  detail panel lists properties instead of offering sliders, toggles and colour wells.
* **`_rt_MipMappedFrameBuffer` is aliased to the scene target with no mip chain**, so shaders that
  sample it by LOD (rough reflections) always read level 0.
* **Multi-image animated textures** upload only image 0.
* `instance` / `instanceoverride` on *image* objects are ignored (they matter mainly for particles).
* `camerashake`, `camerafade`, `camerapreview` are ignored, they are editor conveniences.
* Multi-display is implemented but has only been tested on a single display.
* Particle **child systems** (`children`) and audio-driven emitter rates are not implemented.
* Text **background** passes (`opaquebackground`, `padding`) are not drawn; only the glyphs are.
* `RenderContext`'s pipeline and library caches are never evicted, so memory grows slowly across
  many wallpaper switches within one session (bounded by the number of distinct shader variants used).

### Performance (measured, debug build, Apple Silicon, rendering at 3008×1692)

| Wallpaper | Layers | Setup | Steady state |
|---|---|---|---|
| Letter | 4 | 0.09 s | 25 ms/frame (40 fps) |
| Sunset Cat | 33 | 6.2 s cold, 0.7 s warm | 35 ms/frame (29 fps) |
| Purple Bedroom | 35 | 0.7 s | 46 ms/frame (22 fps) |
| Pixel City | 38 | 1.2 s | 97 ms/frame (10 fps) |

This is **too slow** and is the main engineering problem after the missing features. Likely causes in
order of impact:

1. One `MTLRenderCommandEncoder` per pass, Pixel City runs roughly 90 passes per frame. Consecutive
   passes sharing a destination should share an encoder.
2. Every layer allocates two full-size composite targets; Pixel City's scene is 5120×2160, so the
   working set is large and the frame is bandwidth-bound.
3. Uniform buffers are re-packed from a dictionary for every pass every frame (`ShaderValueBag` →
   `UniformWriter`). Cache a per-pass byte buffer and patch only what changes.
4. Setup time is dominated by the first shader compile; the disk cache in
   `~/Library/Caches/Mirage/shaders` makes warm starts about ten times faster.

The app caps at 30 fps by default, so the 22-29 ms wallpapers are usable today and Pixel City is not.

---

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

* Rope renderers fall back to sprites. Real support needs the `genericropeparticle` shader, a
  Catmull-Rom spline through the particle history and the 104 byte rope vertex layout.
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

The `JSContext` is built on the scene loader queue and then used from the render thread. That is
safe only because the handoff is strictly ordered (the view is installed after the scene finishes
building) and nothing touches the context concurrently. Keep it that way.

What is stubbed: no puppet animation (`getAnimationLayer` and friends answer, inertly), no media
integration beyond a single "nothing is playing" event, no cursor events, and no execution timeout
(JSC's is private API), so a runaway script would hang the render thread. Scripts that throw are
disabled after five failures, keeping their last good value rather than snapping back to the
stored default. An effect's `visible` is registered and evaluated but still only *applied* at load,
like every other effect combo.

`wetool scripts <dir> [--frames N] [--object NAME]` runs the whole scripting layer with no Metal and
no renderer, which is how you tell a broken script from a broken pass chain.

### 7.4 Sound: built, plus bloom and puppets

*Sound*: `WallpaperSoundPlayer` extracts `sounds/*` from the pkg into
`~/Library/Caches/Mirage/audio` once, then plays them with `AVAudioPlayer` in `loop` or `random`
mode after `rand(mintime, maxtime)`, at `object.volume × appVolume × (muted ? 0 : 1)`.
`SceneWallpaperView` owns one per wallpaper and drives it from the same clock the renderer gets, so
delays and the `startsilent` fade stay in step with the visuals and stop when the wallpaper pauses.
`wetool sound <dir>` plays a scene's audio with no renderer.


*Bloom*: when `general.bloom`, append a synthetic full-screen chain, downsample ¼ → ⅛, blur,
`_rt_Bloom`, combine, using `_rt_4FrameBuffer` and `_rt_8FrameBuffer`.
*Puppet warp*: `.mdl` (`MDLV0021` / `MDLV0023`) carries a skinned mesh, bones and animations; the
vertex shader wants `SKINNING=1`, `BONECOUNT=n`, `g_Bones[]` (`mat4x3`) and the `a_BlendIndices` /
`a_BlendWeights` attributes.

---

### 7.5 Where to pick up

In priority order, with everything needed already on disk:

1. **Wire web wallpapers.** `WebWallpaperView` exists. Replace the `case .web` branch in
   `WallpaperController.show` that sets `lastError` with it, and feed it the project's user
   properties as plain `Any` values, unwrapped (the view wraps them itself). It has no per-frame
   hook, so `updatePointer` needs a timer, and `teardownViews(for:)` must call `stop()` the way it
   does for video.
2. **Performance.** This is now the largest user-visible problem: `Pixel City` still runs at about
   10 fps. The list in section 3 is unchanged and still ordered by expected impact.
3. **Puppet warp.** `PuppetModel` parses the mesh and computes bone matrices. The renderer needs a
   skinned vertex layout, `SKINNING` / `BONECOUNT` combos and a `g_Bones` uniform array. Its bind
   transforms are read column-major, which no synthetic test can falsify: if the first real puppet
   renders inside out, transpose there before looking anywhere else. The scripting layer's
   animation stubs become real at the same time.
4. **Live property edits.** `PropertyStore` drives bindings already, and
   `ScriptRuntime.userPropertiesChanged` re-delivers them to scripts, but nothing calls it: the
   settings UI still lists properties instead of offering controls.
5. **Bloom**, then the **audio visualiser** (needs ScreenCaptureKit audio capture and the matching
   permission), then **rope particles**.

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
