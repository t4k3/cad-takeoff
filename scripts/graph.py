#!/usr/bin/env python3
"""Task graph for Claude <-> Codex cooperation.

Source of truth: docs/graph/tasks.json. Every change also appends to docs/COLLAB.md
and re-renders docs/graph/GRAPH.md (Mermaid), so the log and the picture never drift.

Commands:
  status                         table of all tasks
  next [--agent A]               tasks ready to start (deps done, not claimed)
  claim ID AGENT                 take a task (fails on owner/path conflicts)
  done ID [--note TEXT]          mark finished
  handoff ID [--note TEXT]       release a task in progress, back to todo, with notes
  block ID --note TEXT           mark blocked (needs user decision)
  add ID TITLE --deps A,B --paths p1,p2 [--agent A] [--phase P]
  assign ID AGENT --by WHO [--note TEXT]   change the suggested agent of a task
  deps ID A,B --by WHO                     change prerequisites
  paths ID p1,p2 --by WHO                  change the files a task owns
  log AGENT TYPE TEXT            free entry in COLLAB.md (TYPE: NOTA|DECISIONE|CONFLITTO|DOMANDA)
  render                         regenerate GRAPH.md
  validate                       check ids, deps, cycles
"""
import argparse
import datetime as dt
import fcntl
import json
import sys
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TASKS = ROOT / "docs/graph/tasks.json"
GRAPH_MD = ROOT / "docs/graph/GRAPH.md"
COLLAB = ROOT / "docs/COLLAB.md"
LOCK = ROOT / "docs/graph/.lock"
AGENTS = {"claude", "codex", "user"}
STATUSES = ["todo", "in_progress", "blocked", "done"]


@contextmanager
def locked():
    """Exclusive file lock so two agents can't write tasks.json at the same instant."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def now():
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M")


def load():
    return json.loads(TASKS.read_text())


def save(data):
    TASKS.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    render(data)


def by_id(data):
    return {t["id"]: t for t in data["tasks"]}


def get(data, tid):
    t = by_id(data).get(tid)
    if not t:
        sys.exit(f"Task {tid} inesistente")
    return t


def append_log(agent, kind, text, task=None):
    tag = f" `{task}`" if task else ""
    with open(COLLAB, "a") as fh:
        fh.write(f"\n### {now()} · {agent} · {kind}{tag}\n{text.strip()}\n")


def paths_overlap(a, b):
    a, b = a.rstrip("/*"), b.rstrip("/*")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def ready(data):
    ids = by_id(data)
    return [t for t in data["tasks"]
            if t["status"] == "todo" and all(ids[d]["status"] == "done" for d in t["deps"])]


def validate(data, quiet=False):
    ids = by_id(data)
    errors = []
    for t in data["tasks"]:
        for d in t["deps"]:
            if d not in ids:
                errors.append(f"{t['id']}: dipendenza sconosciuta {d}")
        if t["status"] not in STATUSES:
            errors.append(f"{t['id']}: stato non valido {t['status']}")
    state = {}

    def visit(tid, stack):
        if state.get(tid) == 1:
            errors.append("ciclo: " + " -> ".join(stack + [tid]))
            return
        if state.get(tid) == 2 or tid not in ids:
            return
        state[tid] = 1
        for d in ids[tid]["deps"]:
            visit(d, stack + [tid])
        state[tid] = 2

    for tid in ids:
        visit(tid, [])
    if errors:
        sys.exit("\n".join(errors))
    if not quiet:
        print(f"OK: {len(ids)} task, nessun ciclo")


def render(data):
    colors = {"done": "#2e7d32", "in_progress": "#f9a825", "blocked": "#c62828", "todo": "#546e7a"}
    lines = ["# Grafo dei task", "",
             f"_Generato da `scripts/graph.py` — {now()}. Non modificare a mano._", "",
             "Legenda: verde = done · giallo = in corso · rosso = bloccato · grigio = da fare. "
             "Etichetta: `ID · titolo · agente`.", "", "```mermaid", "flowchart LR"]
    phases = {}
    for t in data["tasks"]:
        phases.setdefault(t.get("phase", "Altro"), []).append(t)
    for i, (phase, tasks) in enumerate(phases.items()):
        lines.append(f'  subgraph P{i}["{phase}"]')
        for t in tasks:
            who = t.get("owner") or t.get("suggested") or "?"
            title = t["title"].replace('"', "'")
            lines.append(f'    {t["id"]}["{t["id"]} · {title}<br/><i>{who}</i>"]:::{t["status"]}')
        lines.append("  end")
    for t in data["tasks"]:
        for d in t["deps"]:
            lines.append(f"  {d} --> {t['id']}")
    for s, c in colors.items():
        lines.append(f"  classDef {s} fill:{c},color:#fff,stroke:#222")
    lines += ["```", "", "## Pronti da iniziare", ""]
    r = ready(data)
    lines += [f"- **{t['id']}** {t['title']} — suggerito: {t.get('suggested', '-')}" for t in r] or ["- (nessuno)"]
    lines += ["", "## Tabella", "", "| ID | Titolo | Stato | Agente | Dipende da | File |", "|---|---|---|---|---|---|"]
    for t in data["tasks"]:
        lines.append(f"| {t['id']} | {t['title']} | {t['status']} | {t.get('owner') or t.get('suggested', '')} | "
                     f"{', '.join(t['deps']) or '—'} | {'<br>'.join(t.get('paths', []))} |")
    GRAPH_MD.write_text("\n".join(lines) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    n = sub.add_parser("next"); n.add_argument("--agent")
    c = sub.add_parser("claim"); c.add_argument("id"); c.add_argument("agent", choices=sorted(AGENTS))
    for name in ("done", "handoff", "block"):
        s = sub.add_parser(name); s.add_argument("id"); s.add_argument("--note", default="")
    a = sub.add_parser("add")
    a.add_argument("id"); a.add_argument("title")
    a.add_argument("--deps", default=""); a.add_argument("--paths", default="")
    a.add_argument("--agent", default=""); a.add_argument("--phase", default="Altro")
    s = sub.add_parser("assign"); s.add_argument("id"); s.add_argument("agent", choices=sorted(AGENTS | {"any"}))
    s.add_argument("--by", required=True, choices=sorted(AGENTS)); s.add_argument("--note", default="")
    s = sub.add_parser("deps"); s.add_argument("id"); s.add_argument("deps")
    s.add_argument("--by", required=True, choices=sorted(AGENTS))
    s = sub.add_parser("paths"); s.add_argument("id"); s.add_argument("paths")
    s.add_argument("--by", required=True, choices=sorted(AGENTS))
    l = sub.add_parser("log"); l.add_argument("agent"); l.add_argument("type"); l.add_argument("text")
    sub.add_parser("render"); sub.add_parser("validate")
    args = p.parse_args()

    with locked():
        data = load()
        if args.cmd == "status":
            for t in data["tasks"]:
                who = t.get("owner") or f"({t.get('suggested', '-')})"
                print(f"{t['id']:5} {t['status']:12} {who:10} {t['title']}  <- {','.join(t['deps']) or '-'}")
        elif args.cmd == "next":
            for t in ready(data):
                if not args.agent or t.get("suggested") in (args.agent, "any", None, ""):
                    print(f"{t['id']:5} [{t.get('suggested', '-')}] {t['title']}  paths: {', '.join(t.get('paths', []))}")
        elif args.cmd == "claim":
            t = get(data, args.id)
            ids = by_id(data)
            if t["status"] != "todo":
                sys.exit(f"{t['id']} è {t['status']} (owner: {t.get('owner')})")
            missing = [d for d in t["deps"] if ids[d]["status"] != "done"]
            if missing:
                sys.exit(f"Prerequisiti non completati: {', '.join(missing)}")
            for o in data["tasks"]:
                if o["status"] == "in_progress" and o.get("owner") != args.agent:
                    clash = [(x, y) for x in t.get("paths", []) for y in o.get("paths", []) if paths_overlap(x, y)]
                    if clash:
                        sys.exit(f"Conflitto file con {o['id']} ({o['owner']}): {clash}")
            t.update(status="in_progress", owner=args.agent, started=now())
            save(data)
            append_log(args.agent, "CLAIM", f"Inizio **{t['title']}**. File: {', '.join(t.get('paths', []))}", t["id"])
            print(f"{t['id']} assegnato a {args.agent}")
        elif args.cmd in ("done", "handoff", "block"):
            t = get(data, args.id)
            if args.cmd == "block" and not args.note:
                sys.exit("block richiede --note")
            who = t.get("owner") or "?"
            if args.cmd == "done":
                t.update(status="done", finished=now())
            elif args.cmd == "handoff":
                t.update(status="todo", owner=None)
            else:
                t.update(status="blocked")
            if args.note:
                t.setdefault("notes", []).append(f"{now()} {who}: {args.note}")
            save(data)
            append_log(who, args.cmd.upper(), f"**{t['title']}** — {args.note or 'completato'}", t["id"])
            print(f"{t['id']} -> {t['status']}")
        elif args.cmd == "add":
            if args.id in by_id(data):
                sys.exit(f"{args.id} esiste già")
            data["tasks"].append({
                "id": args.id, "title": args.title, "phase": args.phase, "status": "todo",
                "deps": [d for d in args.deps.split(",") if d], "paths": [x for x in args.paths.split(",") if x],
                "suggested": args.agent, "owner": None,
            })
            validate(data, quiet=True)
            save(data)
            append_log(args.agent or "?", "NUOVO TASK", f"{args.title} (dipende da {args.deps or '—'})", args.id)
        elif args.cmd == "assign":
            t = get(data, args.id)
            if t["status"] == "in_progress" and t.get("owner") != args.agent:
                sys.exit(f"{t['id']} è in corso da {t['owner']}: prima serve un handoff")
            old = t.get("suggested")
            t["suggested"] = args.agent
            save(data)
            append_log(args.by, "RIASSEGNATO", f"**{t['title']}**: {old} → {args.agent}. {args.note}", t["id"])
        elif args.cmd == "deps":
            t = get(data, args.id)
            t["deps"] = [x for x in args.deps.split(",") if x]
            validate(data, quiet=True)
            save(data)
            append_log(args.by, "DIPENDENZE", f"**{t['title']}** dipende da: {', '.join(t['deps']) or '—'}", t["id"])
        elif args.cmd == "paths":
            t = get(data, args.id)
            t["paths"] = [x for x in args.paths.split(",") if x]
            save(data)
            append_log(args.by, "PATHS", f"**{t['title']}** ora tocca: {', '.join(t['paths'])}", t["id"])
        elif args.cmd == "log":
            append_log(args.agent, args.type.upper(), args.text)
        elif args.cmd == "render":
            render(data); print(f"Scritto {GRAPH_MD.relative_to(ROOT)}")
        elif args.cmd == "validate":
            validate(data)


if __name__ == "__main__":
    main()
