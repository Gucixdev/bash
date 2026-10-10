# Ideas

Not built yet. Kept short on purpose.

- **morph** - `mv` for file formats: `morph a.png b.webp`, backend picked by
  extension (ffmpeg, ImageMagick, assimp for 3D models, FreeType for fonts).
- **fixmedia** - repair broken media files by re-muxing/re-encoding through
  ffmpeg or ImageMagick, original untouched.
- **findfat** - find big files and directories: `-dir`, `-file`.
- **lazytui** - key hints bar always on the bottom line, `raw` and `select`
  modes, actions declared as `key = command`. A C/ANSI version of the
  library is planned; the shell one stays as the reference.
- **dspq** - download queue, sequential or parallel (`lib/dspq` is the start).
