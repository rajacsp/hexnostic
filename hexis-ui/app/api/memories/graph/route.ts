import { NextRequest, NextResponse } from "next/server";
import { normalizeJsonValue } from "@/lib/db";
import { prisma } from "@/lib/prisma";

type MemoryRow = Record<string, unknown>;
type EdgeRow = Record<string, unknown>;

type ProjectedMemory = {
  id: string;
  type: string;
  content: string;
  importance: number | null;
  trust_level: number | null;
  strength: number | null;
  emotional_valence: number | null;
  score: number | null;
  access_count: number | null;
  created_at: unknown;
  last_accessed: unknown;
  status: string | null;
  source: string | null;
  metadata: unknown;
  x: number;
  y: number;
  z: number;
  semantic_neighbors: string[];
  vector: number[];
};

const DEFAULT_LIMIT = 260;
const MAX_LIMIT = 500;
const MAX_EDGES = 1200;
const PCA_ITERATIONS = 28;
const NEIGHBOR_COUNT = 10;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Failed to fetch memory graph";
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function parseLimit(value: string | null): number {
  const parsed = Number.parseInt(value || `${DEFAULT_LIMIT}`, 10);
  if (!Number.isFinite(parsed)) return DEFAULT_LIMIT;
  return Math.max(25, Math.min(parsed, MAX_LIMIT));
}

function parseVector(value: unknown): number[] | null {
  if (typeof value !== "string" || value.length < 3) return null;
  const body = value.startsWith("[") && value.endsWith("]")
    ? value.slice(1, -1)
    : value;
  const vector = body.split(",").map((part) => Number(part.trim()));
  return vector.length > 0 && vector.every(Number.isFinite) ? vector : null;
}

function normalize(vector: number[]): number[] {
  let norm = 0;
  for (const value of vector) norm += value * value;
  norm = Math.sqrt(norm);
  if (!Number.isFinite(norm) || norm <= 1e-12) return vector.map(() => 0);
  return vector.map((value) => value / norm);
}

function seededVector(dimensions: number, axis: 1 | 2 | 3): number[] {
  const frequency = axis === 1 ? 12.9898 : axis === 2 ? 78.233 : 39.425;
  const offset = axis === 1 ? 43758.5453 : axis === 2 ? 24634.6345 : 98123.5711;
  return normalize(Array.from({ length: dimensions }, (_, index) => {
    const raw = Math.sin((index + 1) * frequency) * offset;
    return (raw - Math.floor(raw)) * 2 - 1;
  }));
}

function dot(left: number[], right: number[]): number {
  let total = 0;
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) total += left[index] * right[index];
  return total;
}

function covarianceMultiply(centered: number[][], vector: number[]): number[] {
  const dimensions = vector.length;
  const result = Array.from({ length: dimensions }, () => 0);

  for (const row of centered) {
    const score = dot(row, vector);
    for (let index = 0; index < dimensions; index += 1) {
      result[index] += score * row[index];
    }
  }

  return result;
}

function principalComponent(
  centered: number[][],
  dimensions: number,
  axis: 1 | 2 | 3,
  orthogonalTo: number[][] = []
): number[] {
  let vector = seededVector(dimensions, axis);

  for (let iteration = 0; iteration < PCA_ITERATIONS; iteration += 1) {
    let next = covarianceMultiply(centered, vector);
    for (const component of orthogonalTo) {
      const overlap = dot(next, component);
      next = next.map((value, index) => value - overlap * component[index]);
    }
    const normalized = normalize(next);
    if (normalized.every((value) => value === 0)) break;
    vector = normalized;
  }

  return vector;
}

function centeredVectors(vectors: number[][]): number[][] {
  const dimensions = vectors[0]?.length || 0;
  const means = Array.from({ length: dimensions }, () => 0);

  for (const vector of vectors) {
    for (let index = 0; index < dimensions; index += 1) {
      means[index] += vector[index];
    }
  }
  for (let index = 0; index < dimensions; index += 1) {
    means[index] /= vectors.length;
  }

  return vectors.map((vector) => vector.map((value, index) => value - means[index]));
}

function scaleProjection(points: Array<{ x: number; y: number; z: number }>): void {
  if (points.length === 0) return;

  const xs = points.map((point) => point.x);
  const ys = points.map((point) => point.y);
  const zs = points.map((point) => point.z);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const minZ = Math.min(...zs);
  const maxZ = Math.max(...zs);
  const centerX = (minX + maxX) / 2;
  const centerY = (minY + maxY) / 2;
  const centerZ = (minZ + maxZ) / 2;
  const spanX = Math.max(maxX - minX, 1e-9);
  const spanY = Math.max(maxY - minY, 1e-9);
  const spanZ = Math.max(maxZ - minZ, 1e-9);
  const scale = Math.min(760 / spanX, 520 / spanY, 520 / spanZ);

  for (const point of points) {
    point.x = (point.x - centerX) * scale;
    point.y = (point.y - centerY) * scale;
    point.z = (point.z - centerZ) * scale;
  }
}

function cosineNeighbors(nodes: ProjectedMemory[]): Map<string, string[]> {
  const norms = new Map<string, number>();
  for (const node of nodes) {
    norms.set(node.id, Math.sqrt(dot(node.vector, node.vector)));
  }

  const neighbors = new Map<string, string[]>();
  for (const node of nodes) {
    const nodeNorm = norms.get(node.id) || 0;
    const scored: Array<{ id: string; score: number }> = [];
    if (nodeNorm > 1e-12) {
      for (const candidate of nodes) {
        if (candidate.id === node.id) continue;
        const candidateNorm = norms.get(candidate.id) || 0;
        if (candidateNorm <= 1e-12) continue;
        scored.push({
          id: candidate.id,
          score: dot(node.vector, candidate.vector) / (nodeNorm * candidateNorm),
        });
      }
    }
    scored.sort((left, right) => right.score - left.score);
    neighbors.set(node.id, scored.slice(0, NEIGHBOR_COUNT).map((item) => item.id));
  }
  return neighbors;
}

function projectRows(rows: MemoryRow[]): ProjectedMemory[] {
  const withVectors = rows
    .map((row) => ({ row, vector: parseVector(row.embedding_text) }))
    .filter((item): item is { row: MemoryRow; vector: number[] } => item.vector !== null);

  if (withVectors.length === 0) return [];

  const dimensions = Math.min(...withVectors.map((item) => item.vector.length));
  const trimmedVectors = withVectors.map((item) => item.vector.slice(0, dimensions));
  const centered = centeredVectors(trimmedVectors);
  const component1 = dimensions > 0 ? principalComponent(centered, dimensions, 1) : [];
  const component2 = dimensions > 1 ? principalComponent(centered, dimensions, 2, [component1]) : [];
  const component3 = dimensions > 2 ? principalComponent(centered, dimensions, 3, [component1, component2]) : [];

  const projected: ProjectedMemory[] = withVectors.map(({ row }, index) => {
    const centeredVector = centered[index];
    return {
      id: String(row.id),
      type: String(row.type ?? row.memory_type ?? "unknown"),
      content: String(row.content ?? ""),
      importance: numberOrNull(row.importance),
      trust_level: numberOrNull(row.trust_level),
      strength: numberOrNull(row.strength),
      emotional_valence: numberOrNull(row.emotional_valence),
      score: numberOrNull(row.score),
      access_count: numberOrNull(row.access_count),
      created_at: row.created_at ?? null,
      last_accessed: row.last_accessed ?? null,
      status: stringOrNull(row.status),
      source: stringOrNull(row.source),
      metadata: null,
      x: dimensions > 0 ? dot(centeredVector, component1) : 0,
      y: dimensions > 1 ? dot(centeredVector, component2) : 0,
      z: dimensions > 2 ? dot(centeredVector, component3) : 0,
      semantic_neighbors: [],
      vector: trimmedVectors[index],
    };
  });

  scaleProjection(projected);

  const neighbors = cosineNeighbors(projected);
  for (const node of projected) {
    node.semantic_neighbors = neighbors.get(node.id) || [];
  }

  return projected;
}

function orderClause(sort: string): string {
  if (sort === "importance") return "ORDER BY m.importance DESC NULLS LAST, m.created_at DESC";
  if (sort === "oldest") return "ORDER BY m.created_at ASC";
  return "ORDER BY m.created_at DESC";
}

async function fetchMemoryRows(q: string, type: string, sort: string, limit: number): Promise<MemoryRow[]> {
  const selectClause = `m.id::text, m.type::text AS type, left(m.content, 1600) AS content,
                       m.importance, m.trust_level, m.access_count,
                       m.created_at, m.last_accessed, m.metadata, m.status::text,
                       COALESCE(m.source_attribution->>'source', m.metadata->>'source') AS source,
                       calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
                       CASE WHEN m.metadata->>'emotional_valence' ~ '^-?[0-9]+(\\.[0-9]+)?$'
                            THEN (m.metadata->>'emotional_valence')::float END AS emotional_valence,
                       m.embedding::text AS embedding_text`;

  if (q.trim()) {
    if (type) {
      return prisma.$queryRawUnsafe<MemoryRow[]>(
        `WITH hits AS (
           SELECT memory_id, score
           FROM fast_recall($1, $2::integer)
         )
         SELECT ${selectClause}, h.score
         FROM hits h
         JOIN memories m ON m.id = h.memory_id
         WHERE m.status = 'active'
           AND m.embedding IS NOT NULL
           AND m.type = $3::memory_type
         ORDER BY h.score DESC NULLS LAST
         LIMIT $2`,
        q,
        limit,
        type
      );
    }

    return prisma.$queryRawUnsafe<MemoryRow[]>(
      `WITH hits AS (
         SELECT memory_id, score
         FROM fast_recall($1, $2::integer)
       )
       SELECT ${selectClause}, h.score
       FROM hits h
       JOIN memories m ON m.id = h.memory_id
       WHERE m.status = 'active'
         AND m.embedding IS NOT NULL
       ORDER BY h.score DESC NULLS LAST
       LIMIT $2`,
      q,
      limit
    );
  }

  if (type) {
    return prisma.$queryRawUnsafe<MemoryRow[]>(
      `SELECT ${selectClause}, NULL::float AS score
       FROM memories m
       WHERE m.status = 'active'
         AND m.embedding IS NOT NULL
         AND m.type = $1::memory_type
       ${orderClause(sort)}
       LIMIT $2`,
      type,
      limit
    );
  }

  return prisma.$queryRawUnsafe<MemoryRow[]>(
    `SELECT ${selectClause}, NULL::float AS score
     FROM memories m
     WHERE m.status = 'active'
       AND m.embedding IS NOT NULL
     ${orderClause(sort)}
     LIMIT $1`,
    limit
  );
}

async function fetchEdges(ids: string[]): Promise<EdgeRow[]> {
  if (ids.length === 0) return [];
  return prisma.$queryRawUnsafe<EdgeRow[]>(
    `WITH selected AS (
       SELECT value::text AS id
       FROM jsonb_array_elements_text($1::jsonb)
     )
     SELECT e.id::text, e.src_id, e.dst_id, e.rel_type, e.weight,
            e.kind, e.source, e.properties, e.created_at, e.updated_at
     FROM memory_edges e
     JOIN selected src ON src.id = e.src_id
     JOIN selected dst ON dst.id = e.dst_id
     WHERE lower(e.src_type) = 'memory'
       AND lower(e.dst_type) = 'memory'
     ORDER BY e.weight DESC NULLS LAST, e.updated_at DESC
     LIMIT $2`,
    JSON.stringify(ids),
    MAX_EDGES
  );
}

export async function GET(req: NextRequest) {
  try {
    const url = new URL(req.url);
    const q = url.searchParams.get("q") || "";
    const type = url.searchParams.get("type") || "";
    const sort = url.searchParams.get("sort") || "recent";
    const limit = parseLimit(url.searchParams.get("limit"));

    const rows = await fetchMemoryRows(q, type, sort, limit);
    const nodes = projectRows(rows);
    const ids = nodes.map((node) => node.id);
    const edges = await fetchEdges(ids);

    return NextResponse.json({
      nodes: nodes.map((node) => ({
        id: node.id,
        type: node.type,
        content: node.content,
        importance: node.importance,
        trust_level: node.trust_level,
        strength: node.strength,
        emotional_valence: node.emotional_valence,
        score: node.score,
        access_count: node.access_count,
        created_at: node.created_at,
        last_accessed: node.last_accessed,
        status: node.status,
        source: node.source,
        metadata: node.metadata,
        x: node.x,
        y: node.y,
        z: node.z,
        semantic_neighbors: node.semantic_neighbors,
      })),
      edges: edges.map((edge) => ({
        id: edge.id,
        source: edge.src_id,
        target: edge.dst_id,
        rel_type: edge.rel_type,
        weight: numberOrNull(edge.weight) ?? 1,
        kind: edge.kind ?? null,
        source_label: edge.source ?? null,
        properties: normalizeJsonValue(edge.properties),
        created_at: edge.created_at ?? null,
        updated_at: edge.updated_at ?? null,
      })),
      projection: {
        method: "pca",
        source: "memories.embedding",
        dimensions: 3,
        limit,
        neighbor_count: NEIGHBOR_COUNT,
      },
    });
  } catch (error: unknown) {
    console.error("Memory graph API error:", error);
    return NextResponse.json(
      { error: errorMessage(error) },
      { status: 500 }
    );
  }
}
