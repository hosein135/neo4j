"use client";

import * as d3 from "d3";
import { useEffect, useRef, useState } from "react";

export type GraphNode = {
  id: string;
  labels: string[];
  caption: string;
  properties: Record<string, unknown>;
};

export type GraphLink = {
  id: string;
  source: string;
  target: string;
  type: string;
  properties: Record<string, unknown>;
};

type SimNode = GraphNode & d3.SimulationNodeDatum;
type SimLink = d3.SimulationLinkDatum<SimNode> & {
  id: string;
  type: string;
  properties: Record<string, unknown>;
};

function nodeFill(labels: string[]): string {
  if (labels.includes("Movie")) return "#1d4e89";
  if (labels.includes("Person")) return "#b8432f";
  return "#5c6b73";
}

function trimCaption(value: string): string {
  return value.length > 28 ? `${value.slice(0, 26)}…` : value;
}

function formatValue(value: unknown): string {
  if (Array.isArray(value)) return value.map((item) => String(item)).join(", ");
  if (value && typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function asNode(value: SimLink["source"]): SimNode {
  return value as SimNode;
}

export function GraphView({ nodes, links }: { nodes: GraphNode[]; links: GraphLink[] }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [selected, setSelected] = useState<GraphNode | null>(null);

  useEffect(() => {
    const host = hostRef.current;
    const svgElement = svgRef.current;
    if (!host || !svgElement || nodes.length === 0) {
      setSelected(null);
      return;
    }

    setSelected(null);
    const width = Math.max(320, host.clientWidth);
    const height = Math.max(420, host.clientHeight);
    const svg = d3.select(svgElement);
    svg.selectAll("*").remove();
    svg.attr("viewBox", `0 0 ${width} ${height}`);

    const simNodes: SimNode[] = nodes.map((node) => ({ ...node }));
    const ids = new Set(simNodes.map((node) => node.id));
    const simLinks: SimLink[] = links
      .filter((link) => ids.has(link.source) && ids.has(link.target))
      .map((link) => ({ ...link }));

    const root = svg.append("g");
    svg.call(
      d3
        .zoom<SVGSVGElement, unknown>()
        .scaleExtent([0.25, 3])
        .filter((event) => {
          const target = event.target as Element | null;
          return !target?.closest?.(".node");
        })
        .on("zoom", (event) => {
          root.attr("transform", event.transform);
        }),
    );

    svg
      .append("defs")
      .append("marker")
      .attr("id", "arrow")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 28)
      .attr("refY", 0)
      .attr("markerWidth", 7)
      .attr("markerHeight", 7)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#a8a29e");

    const link = root
      .append("g")
      .selectAll("line")
      .data(simLinks)
      .join("line")
      .attr("stroke", "#a8a29e")
      .attr("stroke-width", 1.4)
      .attr("marker-end", "url(#arrow)");

    const linkLabel = root
      .append("g")
      .selectAll("text")
      .data(simLinks)
      .join("text")
      .text((item) => item.type.replaceAll("_", " "))
      .attr("fill", "#78716c")
      .attr("font-size", 10)
      .attr("text-anchor", "middle")
      .attr("stroke", "#fffdf8")
      .attr("stroke-width", 3)
      .attr("paint-order", "stroke");

    const simulation = d3
      .forceSimulation(simNodes)
      .force(
        "link",
        d3
          .forceLink<SimNode, SimLink>(simLinks)
          .id((node) => node.id)
          .distance(118),
      )
      .force("charge", d3.forceManyBody().strength(-280))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collide", d3.forceCollide(36));

    const node = root
      .append("g")
      .selectAll("g")
      .data(simNodes)
      .join("g")
      .attr("class", "node")
      .style("cursor", "grab")
      .on("click", (event, datum) => {
        event.stopPropagation();
        setSelected(datum);
      })
      .call(
        d3
          .drag<SVGGElement, SimNode>()
          .on("start", (event, datum) => {
            if (!event.active) simulation.alphaTarget(0.25).restart();
            datum.fx = datum.x;
            datum.fy = datum.y;
          })
          .on("drag", (event, datum) => {
            datum.fx = event.x;
            datum.fy = event.y;
          })
          .on("end", (event, datum) => {
            if (!event.active) simulation.alphaTarget(0);
            datum.fx = null;
            datum.fy = null;
          }),
      );

    node
      .append("circle")
      .attr("r", 18)
      .attr("fill", (datum) => nodeFill(datum.labels))
      .attr("stroke", "#fffdf8")
      .attr("stroke-width", 2);

    node
      .append("text")
      .text((datum) => trimCaption(datum.caption))
      .attr("dy", 34)
      .attr("text-anchor", "middle")
      .attr("fill", "#292524")
      .attr("font-size", 12);

    simulation.on("tick", () => {
      link
        .attr("x1", (datum) => asNode(datum.source).x ?? 0)
        .attr("y1", (datum) => asNode(datum.source).y ?? 0)
        .attr("x2", (datum) => asNode(datum.target).x ?? 0)
        .attr("y2", (datum) => asNode(datum.target).y ?? 0);
      linkLabel
        .attr("x", (datum) => ((asNode(datum.source).x ?? 0) + (asNode(datum.target).x ?? 0)) / 2)
        .attr("y", (datum) => ((asNode(datum.source).y ?? 0) + (asNode(datum.target).y ?? 0)) / 2);
      node.attr("transform", (datum) => `translate(${datum.x ?? 0},${datum.y ?? 0})`);
    });

    svg.on("click", () => setSelected(null));

    return () => {
      simulation.stop();
    };
  }, [nodes, links]);

  if (nodes.length === 0) {
    return (
      <div className="graph-frame empty">
        <p>This answer has no nodes or relationships to draw.</p>
        <p>Return a node, relationship, or path to see the graph.</p>
      </div>
    );
  }

  return (
    <div className="graph-frame" ref={hostRef}>
      <svg ref={svgRef} role="img" aria-label="Query result graph" />
      <div className="legend">
        <span>
          <i className="swatch person" /> Person
        </span>
        <span>
          <i className="swatch movie" /> Movie
        </span>
      </div>
      {selected ? (
        <aside className="inspector">
          <p className="inspector-kicker">{selected.labels.join(" · ") || "Node"}</p>
          <h2>{selected.caption}</h2>
          <dl>
            {Object.entries(selected.properties).map(([key, value]) => (
              <div key={key}>
                <dt>{key}</dt>
                <dd>{formatValue(value)}</dd>
              </div>
            ))}
          </dl>
        </aside>
      ) : (
        <p className="graph-hint">Drag a node. Scroll to zoom. Click a node for its properties.</p>
      )}
    </div>
  );
}
