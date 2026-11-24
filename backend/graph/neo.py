"""Read-only Cypher against the local movie graph, shaped for the page."""

from __future__ import annotations

import os
from typing import Any

from neo4j import GraphDatabase
from neo4j.exceptions import AuthError, Neo4jError, ServiceUnavailable
from neo4j.graph import Node, Path, Relationship

MAX_CYPHER_CHARS = 20_000
MAX_RECORDS = 400

_driver = None


class QueryError(Exception):
    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.status = status


def _auth() -> tuple[str, str]:
    return (
        os.environ.get("NEO4J_USER", "neo4j"),
        os.environ.get("NEO4J_PASSWORD", "neo4jadmin"),
    )


def get_driver():
    global _driver
    if _driver is None:
        uri = os.environ.get("NEO4J_URI", "bolt://127.0.0.1:7687")
        _driver = GraphDatabase.driver(uri, auth=_auth())
    return _driver


def close_driver() -> None:
    global _driver
    if _driver is not None:
        _driver.close()
        _driver = None


def jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, Node):
        return {
            "element_id": value.element_id,
            "labels": sorted(value.labels),
            "properties": jsonable(dict(value)),
        }
    if isinstance(value, Relationship):
        return {"element_id": value.element_id, "type": value.type}
    if isinstance(value, Path):
        return [jsonable(item) for item in value]
    return str(value)


def caption(node: Node) -> str:
    props = dict(node)
    for key in ("title", "name"):
        if props.get(key):
            return str(props[key])
    labels = sorted(node.labels)
    return labels[0] if labels else node.element_id


def preview(value: Any) -> Any:
    if isinstance(value, Node):
        return caption(value)
    if isinstance(value, Relationship):
        return value.type
    if isinstance(value, Path):
        return " → ".join(caption(node) for node in value.nodes)
    if isinstance(value, list):
        return [preview(item) for item in value]
    return jsonable(value)


class GraphBuilder:
    def __init__(self) -> None:
        self.nodes: dict[str, dict[str, Any]] = {}
        self.links: dict[str, dict[str, Any]] = {}

    def add_node(self, node: Node) -> None:
        props = jsonable(dict(node))
        labels = sorted(node.labels)
        current = self.nodes.get(node.element_id)
        if current is None:
            self.nodes[node.element_id] = {
                "id": node.element_id,
                "labels": labels,
                "caption": caption(node),
                "properties": props,
            }
            return
        if labels:
            current["labels"] = sorted(set(current["labels"]) | set(labels))
        if props:
            current["properties"].update(props)
            current["caption"] = caption(node)

    def add_relationship(self, rel: Relationship) -> None:
        if rel.start_node is not None:
            self.add_node(rel.start_node)
        if rel.end_node is not None:
            self.add_node(rel.end_node)
        start = getattr(rel.start_node, "element_id", None)
        end = getattr(rel.end_node, "element_id", None)
        if not start or not end:
            return
        self.links[rel.element_id] = {
            "id": rel.element_id,
            "source": start,
            "target": end,
            "type": rel.type,
            "properties": jsonable(dict(rel)),
        }

    def absorb(self, value: Any) -> None:
        if isinstance(value, Node):
            self.add_node(value)
        elif isinstance(value, Relationship):
            self.add_relationship(value)
        elif isinstance(value, Path):
            for node in value.nodes:
                self.add_node(node)
            for rel in value.relationships:
                self.add_relationship(rel)
        elif isinstance(value, list):
            for item in value:
                self.absorb(item)
        elif isinstance(value, dict):
            for item in value.values():
                self.absorb(item)


def run_query(cypher: str) -> dict[str, Any]:
    text = (cypher or "").lstrip("\ufeff").strip()
    if not text:
        raise QueryError("Write a question first. The sample asks who acted in The Matrix.")
    if len(text) > MAX_CYPHER_CHARS:
        raise QueryError(f"Query is longer than {MAX_CYPHER_CHARS} characters.")

    def work(tx):
        result = tx.run(text, timeout=30)
        columns = list(result.keys())
        rows = []
        graph = GraphBuilder()
        truncated = False
        for index, record in enumerate(result):
            if index >= MAX_RECORDS:
                truncated = True
                break
            rows.append({key: preview(record[key]) for key in columns})
            for key in columns:
                graph.absorb(record[key])
        result.consume()
        return {
            "columns": columns,
            "rows": rows,
            "nodes": list(graph.nodes.values()),
            "links": list(graph.links.values()),
            "truncated": truncated,
        }

    try:
        with get_driver().session() as session:
            payload = session.execute_read(work)
    except ServiceUnavailable as exc:
        close_driver()
        raise QueryError(f"Neo4j is not reachable: {exc}", status=503) from exc
    except AuthError as exc:
        close_driver()
        raise QueryError(f"Neo4j rejected the login: {exc}", status=503) from exc
    except Neo4jError as exc:
        message = getattr(exc, "message", None) or str(exc)
        if "read access mode" in message.lower() or "writing" in message.lower():
            message = "This page only runs read-only questions. The movie graph stays unchanged."
        raise QueryError(message) from exc
    except Exception as exc:
        close_driver()
        raise QueryError(f"Could not run the query: {exc}", status=500) from exc

    payload["summary"] = _summary(payload)
    return payload


def _summary(payload: dict[str, Any]) -> str:
    parts = [
        f"{len(payload['nodes'])} nodes",
        f"{len(payload['links'])} relationships",
        f"{len(payload['rows'])} rows",
    ]
    if payload["truncated"]:
        parts.append(f"stopped after {MAX_RECORDS} rows")
    return ", ".join(parts)


def counts() -> dict[str, int]:
    def work(tx):
        record = tx.run(
            "RETURN count { (:Movie) } AS movies, count { (:Person) } AS people"
        ).single()
        if record is None:
            return {"movies": 0, "people": 0}
        return {"movies": record["movies"], "people": record["people"]}

    with get_driver().session() as session:
        return session.execute_read(work)
