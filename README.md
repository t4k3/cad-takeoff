# CAD Takeoff

**Free, open-source parametric CAD for the Mac** — solid modelling, sheet metal, assemblies and
3D printing, with an AI design assistant. Licensed under the AGPL-3.0: free to use, study, change
and share, forever.

Professional CAD should not be locked behind subscriptions and proprietary file formats.
CAD Takeoff is a native macOS app (Swift, SwiftUI, Metal) with its own geometry kernel, built in
the open so that anyone — makers, workshops, schools, small companies — can design real parts
without paying rent on their own work.

> **Status: early alpha.** Usable for simple parts and sheet metal; expect missing features and
> breaking changes. Feedback and contributions are very welcome.

## What it does today

- **Sketches** on XY/XZ/YZ, offset planes or any planar face: lines, rectangles, circles,
  polygons, slots; snapping to endpoints, midpoints and centres; projected face edges.
- **Solids** with a real feature timeline (edit, suppress, roll back, undo/redo): box, cylinder,
  prism, extrude with join / cut / intersect, holes (simple, counterbore, countersink, M2–M12
  clearance, tapping or heat-set inserts), fillets and chamfers with drag arrows, rectangular and
  circular patterns, mirror, split by plane.
- **Own B-rep/CSG kernel** (`Packages/CADCore`, pure Swift, fully tested): stable face and edge
  identities, watertight booleans, planar/cylindrical/conical/toroidal surfaces.
- **Sheet metal** with press-brake rules: material table (DC01, DX51D, S235, AISI 304/316,
  5754, 6082, brass, copper) with stock thicknesses, V-die, inside radius and K-factor
  (DIN 6935); flanges on all sides, open or **closed box corners with relief**, flat pattern with
  unfolded holes, **DXF** export for laser/punch.
- **Assemblies**: components linked to part files, positions, bill of materials (CSV).
- **3D printing**: STL and coloured, multi-part **3MF** export; split parts larger than the bed.
- **Import**: STL/OBJ/3MF meshes, and a Fusion 360 add-in that exports your existing designs.
- **AI assistant** (optional, bring your own Anthropic or OpenAI key, stored in your Keychain):
  describe a part in words and it builds it with the same tools you use. Also works as an
  **MCP server** for Claude Desktop and other MCP clients.

## Build

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
scripts/build.sh                          # xcodegen + xcodebuild (Debug)
open build/DerivedData/Build/Products/Debug/FusionTakeoff.app
```

`project.yml` signs with the maintainer's Apple team (needed for the App Group shared with the
bundled `ftk-mcp` bridge): set `DEVELOPMENT_TEAM` to your own team, or remove it and sign
locally, before building.

## Tests

```bash
swift test --package-path Packages/CADCore   # geometry kernel
scripts/ci.sh                                # everything: kernel, assistant tools, MCP, 3MF, sheet metal, app build
```

## Project layout

| Path | What |
|---|---|
| `Packages/CADCore` | Geometry kernel and document model (no UI, testable) |
| `App/Sources` | macOS app: viewport, sketcher, commands, assistant, MCP host |
| `Tools/ftk-mcp` | Sandboxed MCP bridge shipped inside the app |
| `Tests/` | Integration runners (assistant tools, MCP, 3MF, sheet metal, Fusion add-in) |
| `docs/` | Roadmap, requirements, architecture notes (mostly in Italian) |

This project is developed with the help of AI coding agents (Claude and Codex); `AGENTS.md` and
`CLAUDE.md` describe how they coordinate.

## Contributing

Issues and pull requests are welcome — bug reports with a `.ftk` file attached are gold.
Please run `scripts/ci.sh` before opening a PR. By contributing you agree that your work is
released under the AGPL-3.0.

## License

[GNU Affero General Public License v3.0](LICENSE). You may use, modify and redistribute CAD
Takeoff freely; if you distribute a modified version, or offer it as a network service, you must
publish your source code under the same license.

Autodesk and Fusion 360 are trademarks of Autodesk, Inc. CAD Takeoff is an independent project,
not affiliated with or endorsed by Autodesk; the Fusion 360 add-in only exports your own designs.

---

## In italiano

**CAD Takeoff** è un CAD parametrico gratuito e open source per Mac: solidi, lamiera, assiemi e
stampa 3D, con un assistente AI opzionale. Nasce per dare a tutti — officine, maker, scuole,
piccole aziende — uno strumento professionale senza abbonamenti né formati chiusi.
Licenza AGPL-3.0: libero per sempre, e chi lo modifica e lo ridistribuisce deve restare libero.
