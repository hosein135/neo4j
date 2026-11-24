# Neo4j movie explorer

A local page over the [Neo4j movie graph](https://github.com/neo4j-graph-examples/movies). Type a question as Cypher, run it, and the result is drawn with d3.

The layout follows `../librelane`: Nix flake, Django API, Next.js UI. Graph data lives in **Neo4j Community Edition**. There is no Postgres service.

- **`devops/flake.nix`** — Nixpkgs 25.05, `neo4j`, and `python313Packages.neo4j` (via `python313.withPackages`)
- **`backend/`** — Django JSON API. It only reads from Neo4j.
- **`frontend/`** — Next.js page. The text area starts with “Who acted in The Matrix?”
- **`database/movies.cypher`** — the community movie graph

## Requirements

Linux, macOS, or WSL. `./run.sh` uses Nix **2.28.5** when Nix is missing, and reuses a Nix that is already installed. The first fetch needs a few gigabytes free for the JDK, Neo4j, and Node.js.

## Quick start

```bash
cd /path/to/neo4j
bash run.sh
```

Open **http://127.0.0.1:3000/**. The API listens on **:8000**, or **:8010** when 8000 is already taken. Neo4j Bolt listens on **127.0.0.1:7687**.

On WSL with the repo under `/mnt/c`, Neo4j’s files go to `~/.local/share/neo4j-movies` because the database needs a Linux filesystem. The page still runs from the checkout. WSL1 cannot execute the Nix Node binary; `./run.sh` then downloads the official Linux build of that same Node version and uses it only for the page. Neo4j and Python still come from Nix.

```bash
bash run.sh --prep-only     # Nix env, Neo4j, and the movie load
bash run.sh --force-setup   # refresh the cached Nix env
bash run.sh --build         # production Next.js build
```

The sample question already in the text area is:

```cypher
// Who acted in The Matrix?
MATCH (p:Person)-[r:ACTED_IN]->(m:Movie {title: 'The Matrix'})
RETURN p, r, m
```

Other questions are the chips above the text area. Queries run in a read transaction, so the loaded graph is left as it is.

Default Bolt login, for `cypher-shell` on this machine only: user `neo4j`, password `neo4jadmin`.

## Manual Nix shell

```bash
nix develop devops --accept-flake-config
# then ./run.sh, which also starts Neo4j
```

Do not use the operating system’s `python`. Use `neo4j-movies-manage` and `neo4j-movies-web` from the Nix shell.
