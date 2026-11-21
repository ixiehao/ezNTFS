import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

const installer = new URL("./installer/", import.meta.url);
const source = readFileSync(new URL("Distribution.xml.in", installer), "utf8");
const program = source.match(/<!\[CDATA\[([\s\S]*?)\]\]>/)[1].replaceAll("@MACFUSE_VERSION@", "5.5.0");
const check = source.match(/<installation-check script="([^"]+)"/)[1].replaceAll("&amp;", "&");
const path = "/Library/Filesystems/macfuse.fs";
const components = [
  path + "/Contents/Resources/mount_macfuse",
  path + "/Contents/Frameworks/MFMount.framework/Versions/A/MFMount",
  "/usr/local/lib/libfuse.2.dylib",
];
const receipt = "/Library/Application Support/ezNTFS/Driver/installed.plist";

for (const lang of ["en", "zh-Hans", "ja"]) {
  const catalog = JSON.parse(execFileSync("/usr/bin/plutil", [
    "-convert", "json", "-o", "-",
    fileURLToPath(new URL("Resources/" + lang + ".lproj/Localizable.strings", installer)),
  ], { encoding: "utf8" }));

  function preflight({ files, version, unreadable = false, busy = false }) {
    const my = { result: {} };
    const system = {
      files: {
        fileExistsAtPath: (name) => files.includes(name),
        plistAtPath(name) {
          assert.equal(name, path + "/Contents/Info.plist");
          if (unreadable) throw Error("Unreadable test plist");
          return version ? { CFBundleShortVersionString: version } : null;
        },
      },
      ioregistry: {
        matchingClass: () => busy ? [{
          "BSD Name": "disk4s1", Open: 1, Whole: 0, Leaf: 1,
          "Protocol Characteristics": { "Physical Interconnect Location": "External" },
        }] : [],
        parentsOf: () => [],
      },
      localizedString: (key) => catalog[key],
      log() {},
    };
    const allowed = runInNewContext(program + "\n" + check, { my, system });
    return { allowed, ...my.result };
  }

  test(lang + " compatible install skips the download prompt", () => {
    assert.deepEqual(preflight({ files: [path, ...components], version: "5.5.0" }), { allowed: true });
  });

  test(lang + " absent macFUSE gives the pinned official release link", () => {
    const outcome = preflight({ files: [] });
    assert.equal(outcome.allowed, false);
    assert.equal(outcome.type, "Fatal");
    assert.equal(outcome.title, catalog["macFUSE.missingTitle"]);
    assert.match(outcome.message, /https:\/\/github\.com\/macfuse\/macfuse\/releases\/tag\/macfuse-5\.5\.0/);
    assert.doesNotMatch(outcome.message, /\{[a-z]+\}/);
  });

  test(lang + " incompatible macFUSE shows both versions", () => {
    const outcome = preflight({ files: [path, ...components], version: "5.4.0" });
    assert.equal(outcome.allowed, false);
    assert.equal(outcome.title, catalog["macFUSE.incompatibleTitle"]);
    assert.match(outcome.message, /5\.4\.0/);
    assert.match(outcome.message, /5\.5\.0/);
    assert.doesNotMatch(outcome.message, /\{[a-z]+\}|https:\/\//);
  });

  test(lang + " broken macFUSE distinguishes missing components or unreadable info", () => {
    for (const outcome of [
      preflight({ files: [path, components[0]], version: "5.5.0" }),
      preflight({ files: [path, ...components], unreadable: true }),
    ]) {
      assert.equal(outcome.allowed, false);
      assert.equal(outcome.title, catalog["macFUSE.incompleteTitle"]);
    }
  });

  test(lang + " check still blocks upgrades when an external disk is in use", () => {
    const outcome = preflight({ files: [path, ...components, receipt], version: "5.5.0", busy: true });
    assert.equal(outcome.allowed, false);
    assert.equal(outcome.title, catalog["externalDisks.title"]);
  });
}
