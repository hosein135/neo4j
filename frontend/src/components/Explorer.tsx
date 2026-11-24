"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { GraphLink, GraphNode, GraphView } from "@/components/GraphView";

type Example = {
  question: string;
  cypher: string;
};

const EXAMPLES: Example[] = [
  {
    question: "Who acted in The Matrix?",
    cypher: `MATCH (p:Person)-[r:ACTED_IN]->(m:Movie {title: 'The Matrix'})
RETURN p, r, m`,
  },
  {
    question: "Who worked on The Matrix?",
    cypher: `MATCH (p:Person)-[r]->(m:Movie {title: 'The Matrix'})
RETURN p, r, m`,
  },
  {
    question: "Which movies did Tom Hanks act in, and who acted with him?",
    cypher: `MATCH (tom:Person {name: 'Tom Hanks'})-[acted:ACTED_IN]->(movie:Movie)<-[coacted:ACTED_IN]-(coactor:Person)
RETURN tom, acted, movie, coacted, coactor`,
  },
  {
    question: "Who directed a movie released after 2000?",
    cypher: `MATCH (person:Person)-[directed:DIRECTED]->(movie:Movie)
WHERE movie.released > 2000
RETURN person, directed, movie`,
  },
];

type QueryResult = {
  columns: string[];
  rows: Record<string, unknown>[];
  nodes: GraphNode[];
  links: GraphLink[];
  summary: string;
  truncated: boolean;
};

type Health = {
  ok: boolean;
  movies?: number;
  people?: number;
  error?: string;
};

function withQuestion(example: Example): string {
  return `// ${example.question}\n${example.cypher}`;
}

function questionFromCypher(text: string): string {
  const line = text.split("\n").find((item) => item.trim().startsWith("//"));
  if (!line) return "Custom Cypher question";
  return line.replace(/^\s*\/\/\s?/, "").trim() || "Custom Cypher question";
}

function formatCell(value: unknown): string {
  if (Array.isArray(value)) return value.map((item) => formatCell(item)).join(", ");
  if (value && typeof value === "object") return JSON.stringify(value);
  if (value === null || value === undefined) return "";
  return String(value);
}

export function Explorer() {
  const [cypher, setCypher] = useState(withQuestion(EXAMPLES[0]));
  const [health, setHealth] = useState<Health | null>(null);
  const [result, setResult] = useState<QueryResult | null>(null);
  const [error, setError] = useState("");
  const [running, setRunning] = useState(false);
  const question = useMemo(() => questionFromCypher(cypher), [cypher]);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/health")
      .then(async (response) => {
        const body = (await response.json()) as Health;
        if (!cancelled) setHealth(body);
      })
      .catch(() => {
        if (!cancelled) setHealth({ ok: false, error: "The API is not reachable." });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function run(event?: FormEvent) {
    event?.preventDefault();
    setRunning(true);
    setError("");
    try {
      const response = await fetch("/api/query", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cypher }),
      });
      const body = (await response.json()) as QueryResult & { error?: string };
      if (!response.ok) {
        setResult(null);
        setError(body.error || "The query failed.");
        return;
      }
      setResult(body);
    } catch {
      setResult(null);
      setError("The API is not reachable.");
    } finally {
      setRunning(false);
    }
  }

  const status = health?.ok
    ? `${health.movies ?? 0} movies · ${health.people ?? 0} people`
    : health?.error || "Checking Neo4j…";

  return (
    <div className="page">
      <header className="topbar">
        <div>
          <p className="eyebrow">Neo4j Community</p>
          <h1>Movie graph</h1>
        </div>
        <p className={health?.ok ? "status ok" : "status"}>{status}</p>
      </header>

      <main className="layout">
        <section className="ask">
          <form onSubmit={(event) => void run(event)}>
            <div className="ask-head">
              <h2>{question}</h2>
              <p>
                The first line is the question. The lines under it are the Cypher sent to the movie
                database. Edit either one, or pick another question.
              </p>
            </div>
            <div className="chips">
              {EXAMPLES.map((example) => (
                <button
                  key={example.question}
                  type="button"
                  className={example.question === question ? "chip active" : "chip"}
                  onClick={() => setCypher(withQuestion(example))}
                >
                  {example.question}
                </button>
              ))}
            </div>
            <label className="sr-only" htmlFor="question">
              Question and Cypher
            </label>
            <textarea
              id="question"
              value={cypher}
              spellCheck={false}
              onChange={(event) => setCypher(event.target.value)}
              onKeyDown={(event) => {
                if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
                  event.preventDefault();
                  void run();
                }
              }}
            />
            <div className="actions">
              <button className="run" type="submit" disabled={running}>
                {running ? "Running…" : "Run question"}
              </button>
              <span className="hint">Ctrl+Enter</span>
            </div>
          </form>

          {error ? <p className="error">{error}</p> : null}
          {result ? <p className="summary">{result.summary}</p> : null}

          {result && result.rows.length > 0 ? (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    {result.columns.map((column) => (
                      <th key={column}>{column}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {result.rows.map((row, index) => (
                    <tr key={index}>
                      {result.columns.map((column) => (
                        <td key={column}>{formatCell(row[column])}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : null}
        </section>

        <section className="stage">
          {result ? (
            <GraphView nodes={result.nodes} links={result.links} />
          ) : (
            <div className="graph-frame empty">
              <p>Run the sample question to draw the cast of The Matrix.</p>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}
