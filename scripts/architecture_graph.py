#!/usr/bin/env python3
"""Build/check an explicitly exploratory architecture map. Never resolves Swift symbols."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/architecture"
SPEC = OUT / "graph-spec.json"
SOURCE_ROOTS = ["App/Sources", "Packages/CADCore/Sources/CADCore", "Tools/ftk-mcp"]
STATES = {"RESOLVED", "SYNTACTIC", "INFERRED", "AMBIGUOUS", "RUNTIME/EXTERNAL"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def tracked_inputs():
    files = {p for folder in SOURCE_ROOTS for p in (ROOT / folder).rglob("*")
             if p.suffix in {".swift", ".metal", ".m", ".mm", ".h", ".cpp", ".c"}}
    files.update((ROOT / "Packages/CADCore/Tests").rglob("*.swift"))
    files.update((ROOT / "Tests").rglob("*.swift"))
    files.update([ROOT / "project.yml", ROOT / "FusionTakeoff.xcodeproj/project.pbxproj",
                  ROOT / "App/Info.plist", ROOT / "Packages/CADCore/Package.swift", SPEC,
                  Path(__file__).resolve(), OUT / "viewer-template.html"])
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}


def evidence(item):
    path = ROOT / item["file"]
    lines = path.read_text().splitlines()
    hits = [i + 1 for i, line in enumerate(lines) if item["anchor"] in line]
    occurrence = item.get("occurrence")
    if not hits or (occurrence is None and len(hits) != 1):
        raise ValueError(f"Anchor assente/ambiguo: {item['file']} :: {item['anchor']} ({len(hits)})")
    line = hits[(occurrence or 1) - 1]
    return {"file": item["file"], "line": line, "endLine": line,
            "excerpt": lines[line - 1].strip(), "sha256": digest(path)}


def build():
    before = tracked_inputs()
    spec = json.loads(SPEC.read_text())
    nodes = []
    for original in spec["nodes"]:
        n = dict(original)
        if "anchor" in n:
            n["source"] = evidence(n)
            del n["anchor"]
            n.pop("occurrence", None)
        nodes.append(n)
    ids = [n["id"] for n in nodes]
    if len(ids) != len(set(ids)):
        raise ValueError("ID nodo duplicato")
    edges = []
    for item in spec["edges"]:
        edge = dict(item)
        if edge["source"] not in ids or edge["target"] not in ids:
            raise ValueError(f"Nodo inesistente: {edge['id']}")
        if edge["semanticStatus"] not in STATES or edge["semanticStatus"] == "RESOLVED":
            raise ValueError("Questo estrattore manuale non può creare archi RESOLVED")
        edge["evidence"] = [evidence(x) for x in item["evidence"]]
        edge["provenance"] = {"method": "MANUAL_TEXTUAL", "reviewer": "Codex", "extraction": "ANCHOR_VERIFIED"}
        edge["configuration"] = "Debug / macOS / arm64 (snapshot; no compiler resolution)"
        edge["ambiguity"] = edge.get("ambiguity", "Destinazioni e overload non risolti dal compilatore.")
        edges.append(edge)
    if len({e["id"] for e in edges}) != len(edges):
        raise ValueError("ID arco duplicato")
    sources = [p for p in before if any(p.startswith(r + "/") for r in SOURCE_ROOTS)]
    mapped = sorted({n["source"]["file"] for n in nodes if "source" in n})
    inventory = []
    patterns = {"observation": r"@(?:Observable|State|Bindable|Environment)\b", "combine": r"\b(?:sink|assign|Publisher)\b",
                "concurrency": r"\b(?:Task|await|async)\b", "mainActor": r"@MainActor",
                "selectors": r"#selector|@objc", "delegate": r"\bdelegate\s*=",
                "representableWitness": r"func (?:makeNSView|updateNSView)\b"}
    for p in sources:
        text = (ROOT / p).read_text()
        inventory.append({"file": p, "sha256": before[p], "lines": len(text.splitlines()),
                          "target": "FusionTakeoff" if p.startswith("App/") else ("FTKMCP" if p.startswith("Tools/") else "CADCore"),
                          "mapped": p in mapped,
                          "literalSites": {k: len(re.findall(v, text)) for k, v in patterns.items()}})
    graph = {
        "schemaVersion": 1,
        "title": "Fusion Takeoff — mappa architetturale esplorativa",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "method": "MANUAL_TEXTUAL", "coverageState": "PARTIAL_EXPLORATORY",
        "identity": {"checkout": str(ROOT), "branch": run("git", "branch", "--show-current"),
                     "commit": run("git", "rev-parse", "HEAD"), "dirtyStatus": run("git", "status", "--short"),
                     "project": "FusionTakeoff.xcodeproj", "scheme": "FusionTakeoff", "configuration": "Debug",
                     "sdk": "macosx", "architecture": "arm64", "xcode": run("xcodebuild", "-version"),
                     "swift": run("swift", "--version"), "python": sys.version.split()[0]},
        "coverage": {"sourceFilesFound": len(sources), "sourceFilesInventoried": len(inventory),
                     "sourceFilesWithMappedSymbols": len(mapped), "sourceFilesParsedSemantically": 0,
                     "unmappedFiles": sorted(set(sources) - set(mapped)),
                     "parseErrors": None, "parseNote": "Nessun parser AST o semantico eseguito.",
                     "nodes": len(nodes), "edges": len(edges),
                     "edgesByState": dict(Counter(e["semanticStatus"] for e in edges)),
                     "edgesByRelation": dict(Counter(e["relation"] for e in edges)),
                     "excluded": ["archive/codex-seed: storico non attivo", "test: hash per freshness, chiamate non mappate",
                                  "macro generate Observation/SwiftUI", "internals framework Apple e runtime GPU",
                                  "Release, Intel x86_64 e altre configurazioni non verificate"]},
        "inventory": inventory, "inputHashes": before, "nodes": nodes, "edges": edges,
        "limitations": spec["limitations"], "probes": spec["probes"]}
    if tracked_inputs() != before:
        raise ValueError("Sorgenti cambiati durante la generazione: ripetere dopo la scrittura concorrente.")
    return graph


def mermaid(graph):
    lines = ["# Mappa architetturale esplorativa", "", "Generata dal dataset `graph.json`. Metodo manuale/testuale; nessun arco RESOLVED.",
             "", "```mermaid", "flowchart LR"]
    for n in graph["nodes"]:
        label = n["name"].replace('"', "'")
        lines.append(f'  {n["id"]}["{label}"]')
    for e in graph["edges"]:
        lines.append(f'  {e["source"]} -->|"{e["relation"]} · {e["semanticStatus"]}"| {e["target"]}')
    lines += ["```", "", "## Evidenze", "", "| Arco | Relazione | Stato | File e riga |", "|---|---|---|---|"]
    for e in graph["edges"]:
        refs = ", ".join(f'`{x["file"]}:{x["line"]}`' for x in e["evidence"])
        lines.append(f'| {e["source"]} → {e["target"]} | {e["relation"]} | {e["semanticStatus"]} | {refs} |')
    return "\n".join(lines) + "\n"


def render(graph):
    payload = json.dumps(graph, ensure_ascii=False, indent=2)
    (OUT / "graph.json").write_text(payload + "\n")
    template = (OUT / "viewer-template.html").read_text()
    # Escape '<' to prevent a source string from ending the inert JSON script block.
    (OUT / "index.html").write_text(template.replace("__GRAPH_JSON__", payload.replace("<", "\\u003c")))
    (OUT / "MAP.md").write_text(mermaid(graph))


def check():
    graph = json.loads((OUT / "graph.json").read_text())
    current = tracked_inputs()
    expected = graph["inputHashes"]
    changes = sorted(p for p in set(current) | set(expected) if current.get(p) != expected.get(p))
    if graph["identity"]["checkout"] != str(ROOT):
        changes.append("checkout diverso: rigenerare nello stesso worktree")
    if changes:
        print("STALE — rigenerare dopo revisione della spec:\n" + "\n".join(changes))
        return 1
    # Revalidate anchors and edge classifications too, without rewriting artifacts.
    rebuilt = build()
    if rebuilt["nodes"] != graph["nodes"] or rebuilt["edges"] != graph["edges"]:
        print("STALE — dataset diverso dalla spec")
        return 1
    payload = json.dumps(graph, ensure_ascii=False, indent=2).replace("<", "\\u003c")
    if (OUT / "index.html").read_text() != (OUT / "viewer-template.html").read_text().replace("__GRAPH_JSON__", payload):
        print("STALE — HTML diverso dal dataset")
        return 1
    if (OUT / "MAP.md").read_text() != mermaid(graph):
        print("STALE — Mermaid diverso dal dataset")
        return 1
    print(f'FRESH_EXPLORATORY — {len(graph["nodes"])} nodi, {len(graph["edges"])} archi; 0 risolti semanticamente')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "check"])
    args = parser.parse_args()
    try:
        if args.command == "check":
            return check()
        graph = build()
        render(graph)
        print(json.dumps(graph["coverage"], ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, KeyError, IndexError) as error:
        print(f"ERRORE: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
