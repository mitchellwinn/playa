# Playa

**Speed-draw timelapses for Aseprite, without screen recording.**

Playa quietly records every stroke you make and saves the recording inside
your `.aseprite` file. Open the file any time, even weeks later, and play the
whole drawing back or export it as a GIF, WebP, MP4 or PNG frames.

- **Nothing to set up.** Install it and draw. Recording starts on its own.
- **Lives in your file.** The recording is saved with the sprite, so it travels
  with the file. Files still open normally in Aseprite without the extension.
- **Clean output.** Only the canvas: no cursor, no zooming, no UI.
- **Every pixel, in order.** Strokes draw themselves in along the path you
  drew them, fills flood out from where you clicked, moved selections slide
  into place, and playback can run at your real drawing speed.
- **Mistakes optional.** Undone strokes can be left out of the timelapse, or
  kept in if you like showing the process.
- **Small.** Only the pixels that changed are stored, compressed. A typical
  piece adds a few hundred KB at most.

## Install

1. Download `playa.aseprite-extension` from the
   [latest release](https://github.com/mitchellwinn/playa/releases/latest).
2. Double-click it, or in Aseprite go to **Edit > Preferences > Extensions >
   Add Extension** and pick the file.

Requires Aseprite 1.3 or newer.

## Use

Everything is under **File > Playa**:

| Command | What it does |
| --- | --- |
| Record This Sprite | Turn recording on or off for the current sprite. |
| Play Timelapse... | Watch the recording, scrub through it, pick a speed. |
| Export Timelapse... | Save it as GIF, WebP, MP4 or numbered PNG frames. |
| Record Sprites Automatically | Record every sprite you draw on (on by default). |
| Delete Recording... | Remove the recording from this sprite. |

The recording is written into the file when you save, like any other change.

### Export settings

- **Detail**:
  - *Strokes*: each stroke appears at once.
  - *Pixels*: strokes draw in pixel by pixel, in the order you drew them.
  - *Real time*: strokes draw at the speed you drew them, and pauses are kept
    but shortened.
- **Length**: how long the timelapse runs. The drawing is spread evenly across it.
- **Frames/sec**: playback smoothness.
- **Hold end**: how long the finished piece stays on screen.
- **Scale**: whole-number pixel scaling, so pixels stay crisp.
- **Background**: a solid color, or transparent (GIF, WebP and PNG only).
- **Undone strokes**: leave them out, or keep them.

MP4 export needs [ffmpeg](https://ffmpeg.org) installed (`brew install ffmpeg`
on macOS). GIF, WebP and PNG work with nothing extra.

## How it works

Every edit in Aseprite fires a change event. Playa compares the canvas
before and after, keeps the rectangle of pixels that changed, and compresses
it (run-length encoding, then base64). The patches are stored as custom
properties on the sprite, which Aseprite saves inside the `.aseprite` file.
Undo and redo are recorded too, which is how undone strokes can be left out.

While you draw, Playa also follows the cursor and notes which tool or
command made each change. Playback uses that to rebuild how the pixels got
there:

- **Brushes and pencils** follow the path you drew, at the speed you drew it.
- **Bucket fills** flood out from where you clicked.
- **Lines and shapes** grow from where the drag started.
- **Gradients** sweep in the direction you dragged.
- **Moved pixels** (the Move tool, dragged selections) slide from where they
  were to where they landed.
- **Commands** such as Edit > Fill spread out from the middle.

Playback rebuilds the canvas patch by patch, so a timelapse can be rendered at
any length, speed or level of detail after the fact.

### Limits

- Strokes made before recording was turned on are not in the timelapse; the
  recording starts from the canvas as it was at that moment.
- The recording follows what you see: the visible layers of the frame you are
  working on. Hiding a layer shows up as a change.
- For animations, playback shows whichever frame you were editing at the time.
- Rotating or scaling a selection plays as the new pixels appearing, not as
  a turn or a stretch.
- Recordings made before 0.2 have no cursor paths. Their strokes still draw
  in pixel by pixel, but the order is worked out from each stroke's shape.

## Develop

```sh
scripts/test.sh    # headless tests, needs Aseprite installed
scripts/build.sh   # builds dist/playa.aseprite-extension
```

The code is plain Lua in `src/`:

| File | Role |
| --- | --- |
| `playa.lua` | Extension entry point: menus and event hooks. |
| `recorder.lua` | Change detection and storage in sprite properties. |
| `order.lua` | Works out the order a stroke's pixels were drawn in. |
| `codec.lua` | RLE + base64 pixel encoding. |
| `player.lua` | Rebuilds the canvas from the recording. |
| `export.lua` | GIF, WebP, PNG and MP4 output. |
| `ui.lua` | Playback and export dialogs. |

## License

MIT
