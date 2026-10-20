#!/usr/bin/env python3
"""Fails when a Supabase migration creates a table in `public` without the Data API grants that go with it.

Supabase stops granting new tables in `public` to anon, authenticated and service_role automatically on 2026-10-30
(https://github.com/orgs/supabase/discussions/45329). After that, a table the migrations create without a GRANT can't
be reached through the Data API, and the API answers "permission denied". This happens on a new project, a preview
branch, a local reset or a rebuild. So every migration states its own grants. The rule this script enforces
(docs/security.md):

  * A migration that creates a table, a view or a sequence in `public` (`create table`, `create view`,
    `create materialized view`, `create sequence`, a `serial` column, or `alter ... set schema public`) has, in the
    same file, a GRANT on it to anon, authenticated, service_role or public;
  * or, when no API role may reach it, a REVOKE on it from anon and authenticated, plus a comment that says so:
        -- data-api: revoke-only public.<name>: <why no API role may reach it>
  * Tables created before the baseline migration (BASELINE) rely on Supabase's old defaults. The baseline grants
    them explicitly, so for those migrations a grant in the baseline counts.
  * No migration turns automatic grants back on (`alter default privileges ... grant` in `public`, or globally), and
    none grants "on all tables / sequences in schema public". Those would hand grants to tables nobody listed.

GRANT and REVOKE are read as plain SQL, including static SQL inside a DO block. A statement built with
`execute format(...)` can't be read, and a table created that way is reported, so write these statements in plain SQL.

Usage (from the repository root):
    python3 tools/supabase/check_migration_grants.py                    # supabase/migrations
    python3 tools/supabase/check_migration_grants.py --dir <folder>     # another folder (the tests use this)
"""
import os, re, sys

MIGRATIONS = "supabase/migrations"
# Restates the live grants of every table created before it (Supabase's 2026-10-30 change).
BASELINE = "20261020233000_explicit_data_api_grants.sql"
API_ROLES = {"anon", "authenticated", "service_role", "public"}

IDENT = r'(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)'
QNAME = rf'(?:{IDENT}\s*\.\s*)?{IDENT}'
# A name built at run time (format's %I or %s) instead of written out.
DYNAMIC = r'(?:[A-Za-z_0-9."]*%(?:\d+\$)?[IsL][A-Za-z_0-9."]*)'

CREATE_TABLE = re.compile(
    rf'\bcreate\s+(?:or\s+replace\s+)?(?:(?:global|local)\s+)?(?P<mod>temp|temporary|unlogged|foreign)?\s*table\s+'
    rf'(?:if\s+not\s+exists\s+)?(?P<name>{DYNAMIC}|{QNAME})', re.I)
CREATE_VIEW = re.compile(
    rf'\bcreate\s+(?:or\s+replace\s+)?(?P<mod>temp|temporary)?\s*(?:recursive\s+)?(?:materialized\s+)?view\s+'
    rf'(?:if\s+not\s+exists\s+)?(?P<name>{DYNAMIC}|{QNAME})', re.I)
CREATE_SEQUENCE = re.compile(
    rf'\bcreate\s+(?P<mod>temp|temporary|unlogged)?\s*sequence\s+(?:if\s+not\s+exists\s+)?(?P<name>{DYNAMIC}|{QNAME})',
    re.I)
SET_SCHEMA = re.compile(
    rf'\balter\s+(?P<kind>table|view|materialized\s+view|sequence|foreign\s+table)\s+(?:if\s+exists\s+)?'
    rf'(?P<name>{QNAME})\s+set\s+schema\s+(?P<schema>{IDENT})', re.I)
SERIAL_COLUMN = re.compile(rf'(?:^|[(,])\s*(?P<col>{IDENT})\s+(?:small|big)?serial[248]?\b', re.I)
MARKER = re.compile(rf'^\s*data-api:\s*revoke-only\s+(?P<name>{QNAME})\s*:\s*(?P<why>\S.*)$', re.I)


def ident(text):
    """The identifier as Postgres stores it: quoted names keep their case, others fold to lower case."""
    text = text.strip()
    if text.startswith('"'):
        return text[1:-1].replace('""', '"')
    return text.lower()


def qualified(text):
    """(schema, name). An unqualified name lands in `public`, the first schema that exists on the search path."""
    parts = re.findall(IDENT, text)
    return (ident(parts[0]), ident(parts[1])) if len(parts) == 2 else ("public", ident(parts[0]))


def strip_comments(sql):
    """The SQL with every comment blanked (newlines kept, so positions and line numbers stay), and the comments."""
    out, comments, i, n = list(sql), [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == "'" or c == '"':
            j = i + 1
            while j < n:
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            i = j + 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            comments.append((sql[i + 2:j], sql.count("\n", 0, i) + 1))
            for k in range(i, j):
                out[k] = " "
            i = j
        elif sql.startswith("/*", i):
            j, depth = i + 2, 1
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            comments.append((sql[i + 2:j - 2], sql.count("\n", 0, i) + 1))
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out), comments


def split_top(text):
    """Splits a comma-separated list, ignoring commas inside parentheses."""
    items, depth, start = [], 0, 0
    for i, c in enumerate(text):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            items.append(text[start:i])
            start = i + 1
    items.append(text[start:])
    return [x.strip() for x in items if x.strip()]


def statements(code, keyword):
    """(position, text up to the next semicolon) of each statement that starts with `keyword`."""
    for m in re.finditer(rf'\b{keyword}\b', code, re.I):
        end = code.find(";", m.start())
        yield m.start(), code[m.start(): len(code) if end < 0 else end]


def privilege_targets(stmt, verb):
    """For GRANT ... ON ... TO ... or REVOKE ... ON ... FROM ...: (object kind, [(schema, name)], roles, raw target)."""
    word = "to" if verb == "grant" else "from"
    m = re.match(rf'{verb}\s+(?:grant\s+option\s+for\s+)?(?P<privs>.+?)\s+on\s+(?P<target>.+?)\s+{word}\s+(?P<roles>.+)$',
                 " ".join(stmt.split()), re.I | re.S)
    if not m:
        return None
    target, kind = m["target"].strip(), "table"
    head = re.match(r'(table|sequence|all\s+tables\s+in\s+schema|all\s+sequences\s+in\s+schema|foreign\s+table)\s+',
                    target, re.I)
    if head:
        kind = " ".join(head.group(1).lower().split())
        target = target[head.end():]
    elif re.match(r'(function|procedure|routine|all\s+functions|all\s+procedures|all\s+routines|schema|database|'
                  r'domain|type|language|large\s+object|foreign\s+data\s+wrapper|foreign\s+server|tablespace|'
                  r'parameter|tables|sequences|functions|routines|types|schemas)\b', target, re.I):
        return None
    roles = {ident(r.split()[0]) for r in split_top(re.split(r'\s+(?:with|granted|cascade|restrict)\b', m["roles"],
                                                             flags=re.I)[0]) if r.split()}
    if kind.endswith("in schema"):
        return kind, [(ident(s), None) for s in split_top(target)], roles, m["target"]
    names = [qualified(t) for t in split_top(target) if re.fullmatch(QNAME, t.strip())]
    return kind, names, roles, m["target"]


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


class Migration:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        self.code, comments = strip_comments(raw)
        self.created = []          # (kind, (schema, name), line)
        self.dynamic = []          # (kind, line)
        self.granted = set()       # ("table" | "sequence", (schema, name)) granted to an API role
        self.revoked = {}          # same -> the roles it is revoked from
        self.wide = []             # (line, what): grants that reach tables nobody listed
        self.markers = {}          # (schema, name) -> (why, line)
        self.bad_markers = []      # (line, text)

        for text, line in comments:
            if re.match(r'\s*data-api:', text, re.I):
                m = MARKER.match(text)
                if m:
                    self.markers[qualified(m["name"])] = (m["why"].strip(), line)
                else:
                    self.bad_markers.append((line, text.strip()))

        for pattern, kind in ((CREATE_TABLE, "table"), (CREATE_VIEW, "view"), (CREATE_SEQUENCE, "sequence")):
            for m in pattern.finditer(self.code):
                if (m["mod"] or "").lower() in ("temp", "temporary"):
                    continue
                line = line_of(self.code, m.start())
                if "%" in m["name"]:
                    self.dynamic.append((kind, line))
                    continue
                name = qualified(m["name"])
                if name[0] != "public":
                    continue
                self.created.append((kind, name, line))
                if kind == "table":
                    for col in self.serial_columns(m.end()):
                        self.created.append(("sequence", ("public", f"{name[1]}_{col}_seq"), line))
        for m in SET_SCHEMA.finditer(self.code):
            if ident(m["schema"]) == "public":
                kind = "sequence" if m["kind"].lower() == "sequence" else ("view" if "view" in m["kind"].lower()
                                                                           else "table")
                self.created.append((kind, ("public", qualified(m["name"])[1]), line_of(self.code, m.start())))

        for pos, stmt in statements(self.code, "grant"):
            parsed = privilege_targets(stmt, "grant")
            if not parsed:
                continue
            kind, names, roles, target = parsed
            if kind.endswith("in schema"):
                if any(s == "public" for s, _ in names):
                    self.wide.append((line_of(self.code, pos), f"grant ... on {' '.join(target.split())}"))
                continue
            if roles & API_ROLES:
                key = "sequence" if kind == "sequence" else "table"
                self.granted |= {(key, n) for n in names}
        for pos, stmt in statements(self.code, "revoke"):
            parsed = privilege_targets(stmt, "revoke")
            if not parsed or parsed[0].endswith("in schema"):
                continue
            kind, names, roles, _ = parsed
            key = "sequence" if kind == "sequence" else "table"
            for n in names:
                self.revoked.setdefault((key, n), set()).update(roles)
        for pos, stmt in statements(self.code, "alter"):
            adp = re.match(r'alter default privileges\s+(?:for\s+(?:role|user)\s+.+?\s+)?'
                           r'(?:in\s+schema\s+(?P<schemas>.+?)\s+)?(?P<action>grant|revoke)\b', " ".join(stmt.split()),
                           re.I)
            if adp and adp["action"].lower() == "grant":
                if adp["schemas"] is None or "public" in {ident(s) for s in split_top(adp["schemas"])}:
                    self.wide.append((line_of(self.code, pos), "alter default privileges ... grant (automatic grants "
                                                               "for every new object)"))

    def serial_columns(self, after_name):
        """Columns of type serial in the CREATE TABLE whose name ends at `after_name` (its sequence needs a grant)."""
        rest = self.code[after_name:]
        open_paren = re.match(r'\s*\(', rest)
        if not open_paren:
            return []
        depth, start = 0, open_paren.end() - 1
        for i in range(start, len(rest)):
            depth += {"(": 1, ")": -1}.get(rest[i], 0)
            if depth == 0:
                body = rest[start:i + 1]
                return [ident(m["col"]) for m in SERIAL_COLUMN.finditer(body)]
        return []


def check(folder):
    """The problems found in the migrations in `folder`, as printable lines. Empty means it passes."""
    paths = sorted(os.path.join(folder, f) for f in os.listdir(folder) if f.endswith(".sql"))
    migrations = [Migration(p) for p in paths]
    baseline = next((m for m in migrations if m.name == BASELINE), None)
    problems = []
    if baseline is None:
        problems.append(f"{folder}/{BASELINE}: missing. It holds the explicit grants of every table created before "
                        f"it (Supabase's 2026-10-30 change); restore it.")
    for m in migrations:
        where = os.path.join(folder, m.name)
        before_baseline = baseline is not None and m.name < baseline.name
        for kind, line in m.dynamic:
            problems.append(f"{where}:{line}: a {kind} is created with a name built at run time; the check can't see "
                            f"it. Write CREATE, GRANT and REVOKE as plain SQL.")
        for line, what in m.wide:
            problems.append(f"{where}:{line}: {what} reaches tables nobody listed. Grant each table by name.")
        for line, text in m.bad_markers:
            problems.append(f"{where}:{line}: unreadable marker '{text}'. Write "
                            f"'-- data-api: revoke-only public.<name>: <why no API role may reach it>'.")
        for kind, name, line in m.created:
            key = ("sequence" if kind == "sequence" else "table", name)
            label = f"{kind} {name[0]}.{name[1]}"
            if key in m.granted:
                continue
            if name in m.markers:
                if not {"anon", "authenticated"} <= m.revoked.get(key, set()):
                    problems.append(f"{where}:{line}: {label} is marked revoke-only but the migration has no REVOKE "
                                    f"on it from anon and authenticated.")
                continue
            if before_baseline and key in baseline.granted:
                continue
            problems.append(
                f"{where}:{line}: {label} is created without a Data API GRANT in the same migration. Add "
                f"'grant <privileges> on {'sequence' if kind == 'sequence' else 'table'} {name[0]}.{name[1]} to "
                f"<roles>;' (and REVOKE what a role must not have), or, if no API role may reach it, a REVOKE from "
                f"anon and authenticated plus '-- data-api: revoke-only {name[0]}.{name[1]}: <why>'.")
        for name, (why, line) in m.markers.items():
            if not any(c[1] == name for c in m.created):
                problems.append(f"{where}:{line}: marker for {name[0]}.{name[1]}, which this migration doesn't create.")
    return problems, migrations


def main(argv):
    folder = argv[argv.index("--dir") + 1] if "--dir" in argv else MIGRATIONS
    problems, migrations = check(folder)
    created = sum(len(m.created) for m in migrations)
    print(f"{len(migrations)} migrations, {created} tables, views and sequences created in public, "
          f"{len(problems)} problem{'' if len(problems) == 1 else 's'}")
    for p in problems:
        print("  " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
