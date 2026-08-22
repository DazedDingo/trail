#!/usr/bin/env node
//
// Regenerates `assets/maptiles/protomaps-dark.json` — the bundled
// MapLibre style for archives in the **Protomaps basemap** schema
// (layers `roads`, `places`, `earth`, …). The OpenMapTiles-schema
// archives keep rendering with `assets/maptiles/style.json` (OSM
// Liberty); `TrailStyle.loadForServer` picks between the two off the
// served archives' `vector_layers` (see `lib/services/tiles/tile_schema.dart`).
//
// The emitted style keeps Trail's placeholders instead of real URLs —
// the loopback tile server binds a random port at every launch, so
// `TrailStyle.substituteTileServer` rewrites them at runtime:
//   pmtiles://__TRAIL_ACTIVE_REGION__ → http://127.0.0.1:<port>/{z}/{x}/{y}.pbf
//   __TRAIL_GLYPHS__                  → http://127.0.0.1:<port>/glyphs
//   __TRAIL_SPRITES__                 → http://127.0.0.1:<port>/sprites
//
// Re-run (Node 20+, needs network for the npm install only):
//
//   mkdir -p /tmp/pmbasemaps
//   npm --prefix /tmp/pmbasemaps install @protomaps/basemaps@5.7.2
//   BASEMAPS_DIR=/tmp/pmbasemaps node tools/style/gen_protomaps_style.mjs
//
// Bump BASEMAPS_VERSION below when you bump the package, and re-check
// the font stacks (`grep -o '"text-font"[^]]*]' … | sort -u`) — every
// stack the style names needs its glyph ranges under
// `assets/maptiles/glyphs/<stack>/`, and every new glyph dir needs a
// line in pubspec.yaml. Sprites come from the matching
// https://protomaps.github.io/basemaps-assets/sprites/v4/dark* files.

import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const BASEMAPS_VERSION = "5.7.2";

/// The package is ESM-only and normally lives outside this repo (we do
/// not vendor a node_modules tree), so allow an out-of-tree install dir
/// via BASEMAPS_DIR and fall back to plain resolution.
async function loadBasemaps() {
  const dir = process.env.BASEMAPS_DIR;
  if (!dir) return import("@protomaps/basemaps");
  const entry = resolve(
    dir,
    "node_modules/@protomaps/basemaps/dist/esm/index.js",
  );
  return import(pathToFileURL(entry).href);
}

const { layers, namedFlavor } = await loadBasemaps();

const style = {
  version: 8,
  name: "Trail · Protomaps dark",
  glyphs: "__TRAIL_GLYPHS__/{fontstack}/{range}.pbf",
  sprite: "__TRAIL_SPRITES__/protomaps-dark",
  sources: {
    protomaps: {
      type: "vector",
      tiles: ["pmtiles://__TRAIL_ACTIVE_REGION__"],
      minzoom: 0,
      maxzoom: 15,
      attribution: "© OpenStreetMap contributors",
    },
  },
  layers: layers("protomaps", namedFlavor("dark"), { lang: "en" }),
};

// 1-space indent: the layer list is ~4 200 lines either way, and a
// wider indent only makes the diffs harder to read.
const out =
  process.argv[2] ??
  new URL("../../assets/maptiles/protomaps-dark.json", import.meta.url);
writeFileSync(out, `${JSON.stringify(style, null, 1)}\n`);
console.log(
  `wrote ${out} — @protomaps/basemaps ${BASEMAPS_VERSION}, ` +
    `${style.layers.length} layers`,
);
