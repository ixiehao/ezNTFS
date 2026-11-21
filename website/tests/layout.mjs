import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit } from "playwright";

const directory = fileURLToPath(new URL("../../dist/website/", import.meta.url));
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png" };
const server = createServer(async (request, response) => {
  try {
    const requestPath = new URL(request.url, "http://localhost").pathname;
    const sitePath = decodeURIComponent(requestPath.replace(/^\/ezNTFS\//, ""));
    const file = resolve(directory, sitePath.endsWith("/") || !sitePath ? sitePath + "index.html" : sitePath);
    assert(requestPath.startsWith("/ezNTFS/") && file.startsWith(resolve(directory) + sep));
    const content = await readFile(file);
    response.writeHead(200, { "Content-Type": types[extname(file)] || "application/octet-stream" });
    response.end(content);
  } catch {
    response.writeHead(404).end();
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = "http://127.0.0.1:" + server.address().port + "/ezNTFS/";
const site = "https://ixiehao.github.io/ezNTFS/";
const locales = [["", "en"], ["zh/", "zh-CN"], ["ja/", "ja"]];
const alternatePages = Object.fromEntries(locales.map(([path, locale]) => [locale, site + path]));
alternatePages["x-default"] = site;
const browserTypes = { chromium, webkit };

try {
  for (const name of (process.env.EZNTFS_BROWSERS ?? "chromium,webkit").split(",")) {
    const browser = await browserTypes[name].launch();
    try {
      for (const [path, locale] of locales) {
        for (const width of [320, 768, 1440]) {
          const page = await browser.newPage({ viewport: { width, height: 1000 }, javaScriptEnabled: false });
          try {
            assert.equal((await page.goto(base + path)).status(), 200);
            assert.equal(await page.locator("html").getAttribute("lang"), locale);
            assert.equal(await page.locator("link[rel=canonical]").getAttribute("href"), site + path);
            assert.deepEqual(
              await page.locator('link[rel="alternate"][hreflang]').evaluateAll((links) =>
                Object.fromEntries(links.map((link) => [link.hreflang, link.href]))),
              alternatePages,
            );
            assert.equal(await page.locator(".languages [aria-current=page]").count(), 1);
            assert(await page.locator("h1").isVisible());
            assert.equal(await page.locator(".workflow article").count(), 3);
            assert.equal(await page.locator(".installation li").count(), 3);
            await page.locator('.hero-actions a[href="#download"]').click();
            assert.equal(page.url(), base + path + "#download");
            assert.equal(await page.locator("#download .download-card").count(), 2);
            const pkg = await page.locator("[data-download]").getAttribute("href");
            const stable = pkg.match(/^https:\/\/github\.com\/ixiehao\/ezNTFS\/releases\/download\/v([\d.]+)\/ezNTFS-\1-arm64\.pkg$/);
            assert(stable);
            const app = JSON.parse(await page.locator('script[type="application/ld+json"]').textContent());
            const preview = page.locator("[data-intel-preview]");
            assert(await preview.isVisible());
            const intel = (await preview.getAttribute("href")).match(/^https:\/\/github\.com\/ixiehao\/ezNTFS\/releases\/download\/v([\d.]+-intel\.\d+)\/ezNTFS-\1-x86_64\.pkg$/);
            assert(intel);
            assert.equal(await page.locator("[data-intel-release]").getAttribute("href"),
              `https://github.com/ixiehao/ezNTFS/releases/tag/v${intel[1]}`);
            assert.equal(app.softwareVersion, stable[1]);
            assert.match(app.operatingSystem, /Apple Silicon/);
            const screenshotLanguage = locale === "zh-CN" ? "zh-Hans" : locale;
            for (const step of ["mount", "copy", "eject"]) {
              const screenshot = page.locator(`.step-shot img[src$="/guide/${step}-${screenshotLanguage}.png"]`);
              await screenshot.scrollIntoViewIfNeeded();
              await screenshot.evaluate((img) => img.decode());
              assert(await screenshot.getAttribute("alt"));
              assert.equal(await screenshot.locator("..").getAttribute("href"), await screenshot.getAttribute("src"));
            }
            const description = await page.locator('meta[name="description"]').getAttribute("content");
            assert.match(description, /NTFS/);
            assert.equal(await page.locator('meta[property="og:title"]').getAttribute("content"), await page.title());
            assert.equal(await page.locator('meta[property="og:description"]').getAttribute("content"), description);
            assert.equal(app.description, description);
            assert.equal(app.inLanguage, locale);
            assert.equal(app.url, site + path);
            assert.equal(app.downloadUrl, pkg);
            const metrics = await page.evaluate(() => ({
              overflow: document.documentElement.scrollWidth - innerWidth,
              photo: document.querySelector(".app-preview img").naturalWidth,
              css: getComputedStyle(document.querySelector(".hero-inner")).display,
            }));
            assert(metrics.overflow <= 1, name + " " + locale + " at " + width + "px overflows");
            assert(metrics.photo > 0);
            assert.equal(metrics.css, "grid");
            const dependency = page.locator(".depend-install");
            const macfuseLink = dependency.locator("a");
            assert(!(await macfuseLink.isVisible()));
            await dependency.locator("summary").press("Enter");
            assert(await macfuseLink.isVisible());
            assert.match(await macfuseLink.getAttribute("href"), /^https:\/\/github\.com\/macfuse\/macfuse\/releases\/tag\/macfuse-[\d.]+$/);
            const faq = page.locator("#faq details").first();
            await faq.locator("summary").press("Enter");
            assert(await faq.locator("p").isVisible());
            if (process.env.EZNTFS_SCREENSHOT && name === "chromium" && locale === "en" && width === 1440) {
              await page.screenshot({ path: process.env.EZNTFS_SCREENSHOT, fullPage: true });
            }
            await page.locator(".languages a").filter({ hasText: locale === "en" ? "日本語" : "English" }).click();
            assert.equal(page.url(), base + (locale === "en" ? "ja/" : ""));
            console.log(name + " · " + locale + " · " + width + "px");
          } finally {
            await page.close();
          }
        }
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  server.close();
}
