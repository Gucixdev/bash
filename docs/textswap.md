# textswap: OCR in a container

`textswap` needs a `tesseract` binary on PATH, or a `--boxes FILE` of word boxes.
On Arch: `pacman -S tesseract tesseract-data-eng` (add `tesseract-data-pol` and so on for other languages).

If you would rather not install it on the host, a throwaway podman image does the job. Nothing here is built or
pulled by textswap itself; run it by hand.

```Containerfile
FROM docker.io/library/debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-eng tesseract-ocr-pol \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["tesseract"]
```

```sh
podman build -t tess -f Containerfile .
cat > ~/.local/bin/tesseract-podman <<'SH'
#!/bin/sh
# same command line as tesseract: IMG - tsv; the picture folder is mounted read-only
d=$(dirname "$1"); f=$(basename "$1"); shift
exec podman run --rm --network none -v "$d":/w:ro,Z -w /w tess "$f" "$@"
SH
chmod +x ~/.local/bin/tesseract-podman
TEXTSWAP_TESSERACT=tesseract-podman textswap shot.png
```

`--network none` keeps the picture local. For video, frames live in a temp folder; the wrapper mounts that folder
per frame, which is slow (one container start per frame at the default 2 fps); install tesseract on the host for clips.

Fonts: `pacman -S noto-fonts-cjk` (or `wqy-zenhei`), or `--font /path/to/font.ttc`.
