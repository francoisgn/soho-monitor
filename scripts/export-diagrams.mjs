// Exports Excalidraw scenes (`docs/diagrams/*.excalidraw`) to SVG with Excalidraw's own `exportToSvg`, fonts
// embedded, in headless Chrome. Run through `scripts/export-diagrams.sh`, which installs the pinned tooling outside the
// repository and bundles the library; not an app dependency.
//
//   node export-diagrams.mjs --bundle <bundle.js> --assets <@excalidraw/excalidraw/dist/prod> --chrome <binary>
//        [--png <dir>] <scene.excalidraw>...
//
// Each scene is written next to itself as `<name>.svg` (white background, so it reads in light and dark themes);
// `--png` also renders each SVG to `<dir>/<name>.png` at 2x, to look at the result. Nothing leaves the machine: the
// page is served from local files and every other request is refused.
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import puppeteer from "puppeteer-core";

const ORIGIN = "http://excalidraw.local/";

function parseArgs(argv) {
  const options = { scenes: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (["--bundle", "--assets", "--chrome", "--png"].includes(arg)) options[arg.slice(2)] = argv[(i += 1)];
    else options.scenes.push(arg);
  }
  for (const key of ["bundle", "assets", "chrome"]) {
    if (!options[key]) throw new Error(`missing --${key}`);
  }
  if (options.scenes.length === 0) throw new Error("no .excalidraw file given");
  return options;
}

/** Opens a blank page where `window.ExcalidrawLib` is loaded and fonts are served from the package's assets. */
export async function openExcalidrawPage({ bundle, assets, chrome }) {
  const browser = await puppeteer.launch({ executablePath: chrome, headless: true, args: ["--no-first-run"] });
  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on("request", async (request) => {
    if (request.url().startsWith("data:")) return request.continue();
    const url = new URL(request.url());
    if (url.origin + "/" !== ORIGIN) return request.abort();
    try {
      if (url.pathname === "/") {
        const html = `<!doctype html><meta charset="utf-8"><script>window.EXCALIDRAW_ASSET_PATH = "${ORIGIN}";</script>
          <script src="${ORIGIN}bundle.js"></script><body></body>`;
        return request.respond({ contentType: "text/html", body: html });
      }
      if (url.pathname === "/bundle.js") {
        return request.respond({ contentType: "text/javascript", body: await readFile(bundle) });
      }
      const root = path.resolve(assets);
      const file = path.join(root, decodeURIComponent(url.pathname));
      if (!file.startsWith(root + path.sep)) return request.abort();
      const contentType = file.endsWith(".woff2") ? "font/woff2" : "application/octet-stream";
      return request.respond({ contentType, body: await readFile(file) });
    } catch {
      return request.abort();
    }
  });
  page.on("pageerror", (error) => console.error(`page error: ${error.message}`));
  if (process.env.DEBUG_EXPORT) page.on("console", (message) => console.error(`console: ${message.text()}`));
  await page.goto(ORIGIN);
  await page.waitForFunction(() => window.ExcalidrawLib !== undefined);
  return { browser, page };
}

/** The scene as an SVG string, fonts inlined (Excalidraw subsets them to the glyphs used). */
export async function sceneToSvg(page, scene) {
  return page.evaluate(async (data) => {
    const { exportToSvg, restore } = window.ExcalidrawLib;
    const { elements, files } = restore(data, null, null);
    const svg = await exportToSvg({
      elements: elements.filter((element) => !element.isDeleted),
      files,
      appState: { exportBackground: true, viewBackgroundColor: "#ffffff", exportWithDarkMode: false },
      exportPadding: 24,
    });
    return svg.outerHTML;
  }, scene);
}

async function svgToPng(page, svg, file) {
  const preview = await page.browser().newPage();
  await preview.setViewport({ width: 800, height: 600, deviceScaleFactor: 2 });
  await preview.setContent(`<body style="margin:0">${svg}</body>`);
  await preview.evaluate(() => document.fonts.ready);
  const element = await preview.$("svg");
  await element.screenshot({ path: file });
  await preview.close();
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const { browser, page } = await openExcalidrawPage(options);
  try {
    for (const scenePath of options.scenes) {
      const scene = JSON.parse(await readFile(scenePath, "utf8"));
      const svg = await sceneToSvg(page, scene);
      // Excalidraw falls back to a CDN URL when it cannot read a font: refuse it, the SVG must stand alone.
      if (!svg.includes("url(data:font/woff2;base64,") || svg.includes("url(http")) {
        throw new Error(`${scenePath}: fonts not embedded in the SVG (DEBUG_EXPORT=1 shows the page's console)`);
      }
      const svgPath = scenePath.replace(/\.excalidraw$/, ".svg");
      await writeFile(svgPath, `${svg}\n`);
      console.log(`ok    ${svgPath} (${Math.round(svg.length / 1024)} KB)`);
      if (options.png) {
        const pngPath = path.join(options.png, `${path.basename(scenePath, ".excalidraw")}.png`);
        await svgToPng(page, svg, pngPath);
        console.log(`ok    ${pngPath}`);
      }
    }
  } finally {
    await browser.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(`ko    ${error.message}`);
    process.exit(1);
  });
}
