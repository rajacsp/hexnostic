"use client";

import { Maximize2, MousePointer2, Network, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { Badge } from "../components/ui/badge";
import { Spinner } from "../components/ui/spinner";

export type MemoryGraphNode = {
  id: string;
  type: string;
  content: string;
  importance: number | null;
  trust_level: number | null;
  strength: number | null;
  emotional_valence: number | null;
  score: number | null;
  access_count: number | null;
  created_at: string | null;
  last_accessed: string | null;
  status?: string | null;
  source?: string | null;
  metadata: unknown;
  x: number;
  y: number;
  z: number;
  semantic_neighbors: string[];
};

export type MemoryGraphEdge = {
  id: string;
  source: string;
  target: string;
  rel_type: string;
  weight: number;
  kind: string | null;
  source_label: string | null;
  properties: unknown;
  created_at: string | null;
  updated_at: string | null;
};

export type MemoryGraphData = {
  nodes: MemoryGraphNode[];
  edges: MemoryGraphEdge[];
  projection: {
    method: string;
    source: string;
    dimensions: number;
    limit: number;
    neighbor_count: number;
  };
};

type MemoryGraphProps = {
  data: MemoryGraphData | null;
  loading: boolean;
  error: string | null;
  selectedId: string | null;
  focusId: string | null;
  onSelect: (node: MemoryGraphNode) => void;
  onFocus: (id: string) => void;
  onResetFocus: () => void;
  onRefresh: () => void;
};

type DisposableObject = THREE.Object3D & {
  geometry?: THREE.BufferGeometry;
  material?: THREE.Material | THREE.Material[];
};

const TYPE_COLORS: Record<string, number> = {
  episodic: 0xd65d3b,
  semantic: 0x176c63,
  procedural: 0x6b7280,
  strategic: 0x2563eb,
  worldview: 0xa84026,
  goal: 0x7c3aed,
};

const CANVAS_HEIGHT = 560;

export function MemoryGraph({
  data,
  loading,
  error,
  selectedId,
  focusId,
  onSelect,
  onFocus,
  onResetFocus,
  onRefresh,
}: MemoryGraphProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const sceneRef = useRef<THREE.Scene | null>(null);
  const cameraRef = useRef<THREE.PerspectiveCamera | null>(null);
  const rendererRef = useRef<THREE.WebGLRenderer | null>(null);
  const controlsRef = useRef<OrbitControls | null>(null);
  const graphGroupRef = useRef<THREE.Group | null>(null);
  const nodeGroupRef = useRef<THREE.Group | null>(null);
  const raycasterRef = useRef<THREE.Raycaster | null>(null);
  const pointerRef = useRef(new THREE.Vector2());
  const pointerDownRef = useRef<{ x: number; y: number } | null>(null);
  const frameKeyRef = useRef<string>("");
  const latestNodesRef = useRef<Map<string, MemoryGraphNode>>(new Map());
  const latestOnSelectRef = useRef(onSelect);
  const latestOnFocusRef = useRef(onFocus);
  const [renderError, setRenderError] = useState<string | null>(null);

  const nodes = useMemo(() => data?.nodes ?? [], [data]);
  const edges = useMemo(() => data?.edges ?? [], [data]);
  const nodeById = useMemo(() => new Map(nodes.map((node) => [node.id, node])), [nodes]);
  const edgeDegree = useMemo(() => {
    const counts = new Map<string, number>();
    for (const edge of edges) {
      counts.set(edge.source, (counts.get(edge.source) || 0) + 1);
      counts.set(edge.target, (counts.get(edge.target) || 0) + 1);
    }
    return counts;
  }, [edges]);

  const focusSet = useMemo(() => {
    if (!focusId) return null;
    const node = nodeById.get(focusId);
    if (!node) return null;
    return new Set([node.id, ...node.semantic_neighbors]);
  }, [focusId, nodeById]);

  const visibleNodes = useMemo(
    () => focusSet ? nodes.filter((node) => focusSet.has(node.id)) : nodes,
    [focusSet, nodes]
  );
  const visibleNodeIds = useMemo(
    () => new Set(visibleNodes.map((node) => node.id)),
    [visibleNodes]
  );
  const visibleEdges = useMemo(
    () => edges.filter((edge) => visibleNodeIds.has(edge.source) && visibleNodeIds.has(edge.target)),
    [edges, visibleNodeIds]
  );
  const frameKey = useMemo(
    () => `${focusId || "all"}:${visibleNodes.map((node) => node.id).join("|")}`,
    [focusId, visibleNodes]
  );
  const typeCounts = useMemo(() => groupByType(nodes), [nodes]);

  useEffect(() => {
    latestOnSelectRef.current = onSelect;
  }, [onSelect]);

  useEffect(() => {
    latestOnFocusRef.current = onFocus;
  }, [onFocus]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    } catch {
      queueMicrotask(() => {
        setRenderError("3D memory map is unavailable because WebGL could not start.");
      });
      return;
    }

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0xfbfcfb);
    scene.fog = new THREE.Fog(0xfbfcfb, 900, 2200);

    const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 5000);
    camera.position.set(620, 420, 740);

    renderer.setClearColor(0xfbfcfb, 1);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.domElement.setAttribute("aria-label", "Projected memory graph");
    renderer.domElement.setAttribute("role", "img");
    renderer.domElement.style.display = "block";
    renderer.domElement.style.height = "100%";
    renderer.domElement.style.width = "100%";
    renderer.domElement.style.cursor = "grab";
    container.appendChild(renderer.domElement);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.rotateSpeed = 0.65;
    controls.zoomSpeed = 0.85;
    controls.panSpeed = 0.55;
    controls.minDistance = 80;
    controls.maxDistance = 2600;
    controls.mouseButtons = {
      LEFT: THREE.MOUSE.ROTATE,
      MIDDLE: THREE.MOUSE.DOLLY,
      RIGHT: THREE.MOUSE.PAN,
    };
    controls.touches = {
      ONE: THREE.TOUCH.ROTATE,
      TWO: THREE.TOUCH.DOLLY_PAN,
    };

    scene.add(new THREE.AmbientLight(0xffffff, 1.6));
    const keyLight = new THREE.DirectionalLight(0xffffff, 1.8);
    keyLight.position.set(320, 520, 420);
    scene.add(keyLight);
    const grid = new THREE.GridHelper(1100, 11, 0xd8ded9, 0xe9eeea);
    grid.position.y = -300;
    scene.add(grid);

    const raycaster = new THREE.Raycaster();
    raycaster.params.Line.threshold = 6;

    const resize = () => {
      const width = Math.max(container.clientWidth, 320);
      const height = Math.max(container.clientHeight, CANVAS_HEIGHT);
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
    };

    const selectFromPointer = (event: MouseEvent, mode: "select" | "focus") => {
      const id = intersectNode(event, renderer, camera, raycaster, pointerRef.current, nodeGroupRef.current);
      if (!id) return;
      const node = latestNodesRef.current.get(id);
      if (!node) return;
      latestOnSelectRef.current(node);
      if (mode === "focus") latestOnFocusRef.current(id);
    };

    const onPointerDown = (event: PointerEvent) => {
      pointerDownRef.current = { x: event.clientX, y: event.clientY };
      renderer.domElement.style.cursor = "grabbing";
    };
    const onPointerUp = () => {
      renderer.domElement.style.cursor = "grab";
    };
    const onClick = (event: MouseEvent) => {
      const down = pointerDownRef.current;
      pointerDownRef.current = null;
      if (down && Math.hypot(event.clientX - down.x, event.clientY - down.y) > 4) return;
      selectFromPointer(event, "select");
    };
    const onDoubleClick = (event: MouseEvent) => {
      event.preventDefault();
      selectFromPointer(event, "focus");
    };
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
    };

    const observer = new ResizeObserver(resize);
    observer.observe(container);
    resize();

    renderer.domElement.addEventListener("pointerdown", onPointerDown);
    renderer.domElement.addEventListener("pointerup", onPointerUp);
    renderer.domElement.addEventListener("pointercancel", onPointerUp);
    renderer.domElement.addEventListener("click", onClick);
    renderer.domElement.addEventListener("dblclick", onDoubleClick);
    renderer.domElement.addEventListener("wheel", onWheel, { passive: false });

    renderer.setAnimationLoop(() => {
      controls.update();
      renderer.render(scene, camera);
    });

    sceneRef.current = scene;
    cameraRef.current = camera;
    rendererRef.current = renderer;
    controlsRef.current = controls;
    raycasterRef.current = raycaster;

    return () => {
      observer.disconnect();
      renderer.setAnimationLoop(null);
      renderer.domElement.removeEventListener("pointerdown", onPointerDown);
      renderer.domElement.removeEventListener("pointerup", onPointerUp);
      renderer.domElement.removeEventListener("pointercancel", onPointerUp);
      renderer.domElement.removeEventListener("click", onClick);
      renderer.domElement.removeEventListener("dblclick", onDoubleClick);
      renderer.domElement.removeEventListener("wheel", onWheel);
      controls.dispose();
      if (graphGroupRef.current) disposeObject(graphGroupRef.current);
      graphGroupRef.current = null;
      nodeGroupRef.current = null;
      sceneRef.current = null;
      cameraRef.current = null;
      rendererRef.current = null;
      controlsRef.current = null;
      raycasterRef.current = null;
      renderer.dispose();
      renderer.domElement.remove();
    };
  }, []);

  useEffect(() => {
    latestNodesRef.current = new Map(visibleNodes.map((node) => [node.id, node]));

    const scene = sceneRef.current;
    const camera = cameraRef.current;
    const controls = controlsRef.current;
    if (!scene || !camera || !controls) return;

    if (graphGroupRef.current) {
      scene.remove(graphGroupRef.current);
      disposeObject(graphGroupRef.current);
      graphGroupRef.current = null;
      nodeGroupRef.current = null;
    }

    if (visibleNodes.length === 0) return;

    const graphGroup = new THREE.Group();
    const nodeGroup = new THREE.Group();
    const nodeLookup = new Map(visibleNodes.map((node) => [node.id, node]));

    const edgePositions: number[] = [];
    for (const edge of visibleEdges) {
      const source = nodeLookup.get(edge.source);
      const target = nodeLookup.get(edge.target);
      if (!source || !target) continue;
      edgePositions.push(source.x, source.y, source.z, target.x, target.y, target.z);
    }
    if (edgePositions.length > 0) {
      const edgeGeometry = new THREE.BufferGeometry();
      edgeGeometry.setAttribute("position", new THREE.Float32BufferAttribute(edgePositions, 3));
      const edgeMaterial = new THREE.LineBasicMaterial({
        color: 0x9aa6a0,
        transparent: true,
        opacity: focusSet ? 0.62 : 0.34,
        depthWrite: false,
      });
      graphGroup.add(new THREE.LineSegments(edgeGeometry, edgeMaterial));
    }

    for (const node of visibleNodes) {
      const selected = selectedId === node.id;
      const degree = edgeDegree.get(node.id) || 0;
      const radius = nodeRadius(node, degree);

      if (selected) {
        const halo = new THREE.Mesh(
          new THREE.SphereGeometry(radius + 5, 24, 16),
          new THREE.MeshBasicMaterial({
            color: 0x18211e,
            transparent: true,
            opacity: 0.16,
            depthWrite: false,
          })
        );
        halo.position.set(node.x, node.y, node.z);
        graphGroup.add(halo);
      }

      const mesh = new THREE.Mesh(
        new THREE.SphereGeometry(radius, 24, 16),
        new THREE.MeshStandardMaterial({
          color: TYPE_COLORS[node.type] || 0x5d6863,
          emissive: selected ? 0x18211e : 0x000000,
          emissiveIntensity: selected ? 0.18 : 0,
          roughness: 0.58,
          metalness: 0.04,
        })
      );
      mesh.position.set(node.x, node.y, node.z);
      mesh.userData.memoryId = node.id;
      nodeGroup.add(mesh);
    }

    graphGroup.add(nodeGroup);
    scene.add(graphGroup);
    graphGroupRef.current = graphGroup;
    nodeGroupRef.current = nodeGroup;

    if (frameKeyRef.current !== frameKey) {
      frameKeyRef.current = frameKey;
      frameCamera(visibleNodes, camera, controls);
    }
  }, [edgeDegree, focusSet, frameKey, selectedId, visibleEdges, visibleNodes]);

  return (
    <section className="min-w-0">
      <div className="flex flex-col gap-3 border-b border-[var(--outline)] px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Network size={17} className="text-[var(--teal)]" />
            <h2 className="text-sm font-semibold">Memory Map</h2>
            {data ? <Badge variant="muted">{data.projection.method.toUpperCase()} 3D</Badge> : null}
          </div>
          <p className="mt-1 text-xs text-[var(--ink-soft)]">
            {nodes.length.toLocaleString()} embedded memories · {edges.length.toLocaleString()} edges
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            title="Reset focus"
            aria-label="Reset focus"
            onClick={onResetFocus}
            disabled={!focusId}
            className="flex h-9 w-9 items-center justify-center rounded-md border border-[var(--outline)] disabled:opacity-30"
          >
            <Maximize2 size={16} />
          </button>
          <button
            type="button"
            title="Refresh map"
            aria-label="Refresh map"
            onClick={onRefresh}
            className="flex h-9 w-9 items-center justify-center rounded-md border border-[var(--outline)] hover:bg-[var(--surface-strong)]"
          >
            <RefreshCw size={16} />
          </button>
        </div>
      </div>

      <div className="border-b border-[var(--outline)] px-4 py-2">
        <div className="flex flex-wrap gap-2">
          {typeCounts.map(([type, count]) => (
            <Badge key={type} variant="muted" className="capitalize">
              {type} {count}
            </Badge>
          ))}
        </div>
      </div>

      <div className="relative h-[560px] min-h-[560px] overflow-hidden bg-[#fbfcfb]">
        <div ref={containerRef} className="h-full w-full" />
        {loading ? (
          <div className="absolute inset-0 flex items-center justify-center bg-[#fbfcfb]/80">
            <Spinner label="Loading memory map..." />
          </div>
        ) : error || renderError ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center px-6 text-center">
            <p className="text-sm text-red-700">{error || renderError}</p>
            <button
              type="button"
              onClick={onRefresh}
              className="mt-3 rounded-md border border-red-200 px-3 py-2 text-sm text-red-700"
            >
              Retry
            </button>
          </div>
        ) : visibleNodes.length === 0 ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center px-6 text-center">
            <MousePointer2 size={24} className="text-[var(--ink-soft)]" />
            <p className="mt-3 text-sm text-[var(--ink-soft)]">No embedded memories to map.</p>
          </div>
        ) : null}
      </div>
    </section>
  );
}

function frameCamera(
  nodes: MemoryGraphNode[],
  camera: THREE.PerspectiveCamera,
  controls: OrbitControls
): void {
  const box = new THREE.Box3();
  for (const node of nodes) {
    box.expandByPoint(new THREE.Vector3(node.x, node.y, node.z));
  }

  const sphere = new THREE.Sphere();
  box.getBoundingSphere(sphere);
  const radius = Math.max(sphere.radius, 90);
  const distance = radius / Math.sin(THREE.MathUtils.degToRad(camera.fov * 0.5)) * 1.15;
  const direction = new THREE.Vector3(0.9, 0.58, 1).normalize();

  camera.position.copy(sphere.center).add(direction.multiplyScalar(distance));
  camera.near = Math.max(distance / 800, 0.1);
  camera.far = distance + radius * 8 + 1000;
  camera.updateProjectionMatrix();
  controls.target.copy(sphere.center);
  controls.minDistance = Math.max(radius * 0.18, 45);
  controls.maxDistance = Math.max(radius * 7, 1200);
  controls.update();
}

function intersectNode(
  event: MouseEvent,
  renderer: THREE.WebGLRenderer,
  camera: THREE.PerspectiveCamera,
  raycaster: THREE.Raycaster,
  pointer: THREE.Vector2,
  nodeGroup: THREE.Group | null
): string | null {
  if (!nodeGroup) return null;
  const rect = renderer.domElement.getBoundingClientRect();
  pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
  pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointer, camera);
  const intersections = raycaster.intersectObjects(nodeGroup.children, false);
  const id = intersections[0]?.object.userData.memoryId;
  return typeof id === "string" ? id : null;
}

function disposeObject(object: THREE.Object3D): void {
  object.traverse((child) => {
    const disposable = child as DisposableObject;
    disposable.geometry?.dispose();
    if (Array.isArray(disposable.material)) {
      for (const material of disposable.material) material.dispose();
    } else {
      disposable.material?.dispose();
    }
  });
}

function groupByType(nodes: MemoryGraphNode[]): Array<[string, number]> {
  const counts = new Map<string, number>();
  for (const node of nodes) counts.set(node.type, (counts.get(node.type) || 0) + 1);
  return Array.from(counts.entries()).sort((left, right) => right[1] - left[1]);
}

function nodeRadius(node: MemoryGraphNode, degree: number): number {
  const importance = node.importance ?? 0.5;
  return 5 + importance * 6 + Math.min(degree, 12) * 0.35;
}
