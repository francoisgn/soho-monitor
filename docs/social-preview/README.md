# Social preview

Source of `docs/images/social-preview.png`, the GitHub social preview (1280 × 640, under 1 MB), shown at the top of
the README too. It reuses the card images of `docs/images/` (generic labels, no personal data) and
`disk-source.png` (the disk card alone).

Render it with headless Chrome, from the repository root:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1 --window-size=1280,640 \
  --screenshot="$PWD/docs/images/social-preview.png" "file://$PWD/docs/social-preview/index.html"
```

Then upload it in the repository's Settings › General › Social preview (GitHub has no API for it).
