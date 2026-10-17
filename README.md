# Slides video assets

Each folder in `video-assets/` is a self-contained reference package for one
training video. It contains the original MP4, lossless per-frame PNG exports,
`frames/frame_index.json` (timing and frame properties), and `metadata.json`
(container and stream information from FFprobe).

Large PNG and MP4 assets are stored with Git LFS. Run `git lfs pull` after
cloning to download their contents.
