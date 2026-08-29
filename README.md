# Mirage

Mirage puts **Wallpaper Engine wallpapers on your Mac**. It runs as a menu bar app and draws
animated wallpapers behind your desktop icons.

Wallpaper Engine is Windows only, but its Workshop content is just files. Mirage reads those files
directly: "scene" wallpapers (`scene.pkg`) are rendered by a Metal reimplementation of Wallpaper
Engine's renderer, web wallpapers run in a web view, and video, image and GIF wallpapers play
natively.

## What it does

* Renders **scene wallpapers**: layered artwork with effect chains (blur, bloom-style glows,
  water ripples, scrolling, perspective, colour grading, and so on), particle systems (rain, snow,
  dust, fireflies), text layers, scripted values (working clocks, day and night cycles, scripted
  animation), sprite sheet animation, embedded video textures, blend modes, mouse parallax, and the
  wallpaper's own user properties, and bloom.
* Plays a scene wallpaper's **sound layers**, with the app's mute and volume.
* **Audio reactive wallpapers move with whatever your Mac is playing.** macOS asks for Audio Capture
  permission the first time such a wallpaper runs; nothing is recorded.
* Runs **web wallpapers** in a web view, with their user properties and cursor tracking.
* Plays **video wallpapers** (`.mp4`, `.mov`, `.m4v`) with gapless looping, and **image / GIF**
  wallpapers.
* **One wallpaper per display**, remembered across restarts.
* **Pause rules** so it does not waste battery: pause when a window covers the screen, pause on
  battery power, pause after an idle timeout, and a frame rate cap.
* **Edit a wallpaper's own options**: the sliders, toggles, colour wells and dropdowns its author
  defined, applied straight away and remembered.
* Mute or set the volume, and launch at login.

## Requirements

* macOS 14 or later, Apple Silicon.
* [Homebrew](https://brew.sh) packages used by the shader compiler:
  ```sh
  brew install glslang spirv-cross spirv-tools
  ```
* **Wallpaper Engine's `assets` folder.** Scene wallpapers reference built in shaders, models and
  materials that are not packed into the wallpaper itself, so you need the folder that ships with
  Wallpaper Engine. You need a Steam account that owns Wallpaper Engine:
  ```sh
  brew install --cask steamcmd
  steamcmd +@sSteamCmdForcePlatformType windows +login YOUR_STEAM_ACCOUNT \
           +app_update 431960 validate +quit
  ```
  That places it at
  `~/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets`, where Mirage
  looks for it. Video, image and GIF wallpapers work without it.

## Install

Download the latest build from [Releases](../../releases), unzip it, and drag `Mirage.app` to
`/Applications`.

The app is signed ad hoc rather than notarized, so the first launch needs one extra step:
right click `Mirage.app`, choose **Open**, then confirm. Alternatively:

```sh
xattr -dr com.apple.quarantine /Applications/Mirage.app
```

### Building from source

```sh
git clone https://github.com/maxxu123456/mirage.git
cd mirage
./scripts/build-app.sh          # produces build/Mirage.app
open build/Mirage.app
```

## Getting wallpapers

Mirage reads ordinary Wallpaper Engine Workshop folders, each containing a `project.json`.

If you already own Wallpaper Engine, download the items you are subscribed to with SteamCMD:

```sh
steamcmd +login YOUR_STEAM_ACCOUNT +workshop_download_item 431960 WORKSHOP_ITEM_ID +quit
```

They land in `~/Library/Application Support/Steam/steamapps/workshop/content/431960/`, which Mirage
scans automatically. You can also point it at any folder of wallpapers, or at a folder of loose
video and image files.

## Using it

1. Launch Mirage. A sparkle icon appears in the menu bar and the library window opens.
2. If your wallpapers are somewhere unusual, click **+** in the toolbar and pick the folder.
   You can also drag folders or files onto the window.
3. Double click a wallpaper to set it on every display, or right click it to choose one display.
4. Use the menu bar icon to pause, remove the wallpaper, or open settings.

Settings are split into **General** (login item, audio, library folders), **Performance** (pause
rules and the frame rate cap) and **Displays** (what is showing where).

## What is not supported yet

Scene wallpapers are complex, and some parts of the format are not implemented. The image layers
and their effects render; these do not:

| Not implemented | What you notice |
|---|---|
| Media integration | A wallpaper that shows the song you are playing shows its idle layout instead |
| Rope particles | Rope and rope trail emitters draw as ordinary sprites |

Particles, text layers, embedded video textures, sound and scripts all work, so clocks show the real
time and scripted animation runs.

Heavy wallpapers are slow. A simple one runs at 45 frames per second, but a busy 40 layer scene
authored at 5K manages about 5, well under the default 30 frame cap. **Settings > Performance >
Render at display resolution** draws such a wallpaper at your screen's size instead of the much
larger size its author chose, which is noticeably faster and slightly softer.

## Development

```sh
swift build
swift test
```

`wetool` is a command line companion for inspecting wallpapers and debugging the renderer:

```sh
.build/debug/wetool info      "/path/to/wallpaper"          # project and object list
.build/debug/wetool ls        "/path/to/wallpaper"          # scene.pkg contents
.build/debug/wetool tex       "/path/to/wallpaper" bg out.png
.build/debug/wetool shader    "/path/to/wallpaper" genericimage2 SPRITESHEET=1 --msl
.build/debug/wetool pipelines "/path/to/wallpaper"          # compile every shader variant
.build/debug/wetool render    "/path/to/wallpaper" out.png --time 2 --size 1280x720
.build/debug/wetool scripts   "/path/to/wallpaper"          # run its scripts, with no renderer
.build/debug/wetool sound     "/path/to/wallpaper"          # play its sound objects
```

`CLAUDE.md` is the deep technical reference: the file formats, the shader translation pipeline, the
renderer's conventions, and implementation specs for the parts that are still missing.

## How it works, briefly

Wallpaper Engine's shaders are a loose GLSL dialect written against HLSL rules. Mirage preprocesses
them, compiles them with **glslang**, cross compiles the result to Metal Shading Language with
**SPIRV-Cross**, and repairs the HLSL specific constructs that strict GLSL rejects by reading
glslang's own error diagnostics and applying one targeted edit at a time.

Each wallpaper layer is then drawn through the same pass chain Wallpaper Engine uses: the layer
texture is rendered into a composite framebuffer, each effect ping pongs between two framebuffers,
and the final pass composites the layer into the scene.

## Credits and license

Mirage is released under the [MIT license](LICENSE).

Wallpaper Engine is a product of Kristjan Skutta. Mirage is not affiliated with or endorsed by
Wallpaper Engine, and it ships none of its assets. The renderer's behaviour was worked out by
studying the open source
[linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) and
[wallpaper-scene-renderer](https://github.com/catsout/wallpaper-scene-renderer) projects, and the
official [Wallpaper Engine documentation](https://docs.wallpaperengine.io).
