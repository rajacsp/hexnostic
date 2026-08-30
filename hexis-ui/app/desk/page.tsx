"use client";

import { useCallback, useEffect, useState } from "react";
import { Pin, PinOff, Trash2, X } from "lucide-react";
import Link from "next/link";
import { Card } from "../components/ui/card";
import { PageHeader } from "../components/ui/page-header";
import { Spinner } from "../components/ui/spinner";

type DeskItem = {
  desk_unit_id: string;
  document_id: string | null;
  chunk_id: string | null;
  chunk_index: number | null;
  title: string | null;
  path: string | null;
  locator: Record<string, unknown> | null;
  reason: string | null;
  pinned: boolean;
  loaded_at: string | null;
  last_accessed: string | null;
  char_count: number | null;
  snippet: string | null;
};

type OpenItem = {
  desk_unit_id: string;
  title?: string;
  content?: string;
  truncated?: boolean;
  next_offset?: number | null;
  total_chars?: number;
  error?: string;
  hint?: string;
};

export default function DeskPage() {
  const [items, setItems] = useState<DeskItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [openItem, setOpenItem] = useState<OpenItem | null>(null);

  const fetchItems = useCallback(async () => {
    try {
      const res = await fetch("/api/desk?limit=100", { cache: "no-store" });
      if (!res.ok) throw new Error(`Failed to load the desk (${res.status})`);
      const data = await res.json();
      setItems(data.items || []);
      setTotal(data.total || 0);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load the desk.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchItems();
  }, [fetchItems]);

  const openOne = useCallback(async (unitId: string, offset = 0) => {
    const res = await fetch(`/api/desk?open=${unitId}&open_offset=${offset}`, { cache: "no-store" });
    const data = await res.json();
    if (data.error) {
      setNotice(data.hint || "Desk item not found.");
      return;
    }
    setOpenItem((prev) =>
      offset > 0 && prev && prev.desk_unit_id === data.desk_unit_id
        ? { ...data, content: `${prev.content || ""}${data.content || ""}` }
        : data
    );
  }, []);

  const act = useCallback(
    async (body: Record<string, unknown>, message: string) => {
      setNotice(null);
      const res = await fetch("/api/desk", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok || data.error) {
        setNotice(`Action failed: ${data.error || res.status}`);
      } else {
        setNotice(message);
      }
      fetchItems();
    },
    [fetchItems]
  );

  const pinnedCount = items.filter((i) => i.pinned).length;

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Desk"
        subtitle="Mid-term working material: passages deliberately loaded from the filing cabinet. Cleared items are archived — sources always stay in the cabinet."
      />

      {notice ? (
        <div className="rounded-md border border-[var(--teal)]/40 bg-[var(--teal)]/5 px-3 py-2 text-sm">{notice}</div>
      ) : null}
      {error ? (
        <div className="rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700">{error}</div>
      ) : null}

      <div className="flex items-center gap-3 text-sm text-[var(--ink-soft)]">
        <span>
          {total} item(s) · {pinnedCount} pinned
        </span>
        <button
          type="button"
          onClick={() =>
            act({ action: "clear", all: true }, "Cleared the unpinned desk. Sources remain in the cabinet.")
          }
          disabled={items.length === 0}
          className="flex items-center gap-1.5 rounded-md border border-[var(--outline)] px-2.5 py-1 text-xs font-medium hover:border-[var(--teal)] disabled:opacity-40"
        >
          <Trash2 size={13} /> Clear unpinned
        </button>
      </div>

      <div className="grid gap-6 lg:grid-cols-[1fr,1.2fr]">
        <Card className="max-h-[70vh] overflow-y-auto p-2">
          {loading ? (
            <div className="flex items-center gap-2 p-4 text-sm text-[var(--ink-soft)]">
              <Spinner /> Loading…
            </div>
          ) : items.length === 0 ? (
            <p className="p-4 text-sm text-[var(--ink-soft)]">
              The desk is clear. Load a source from the{" "}
              <Link href="/documents" className="font-semibold text-[var(--teal)] underline">
                Documents page
              </Link>
              .
            </p>
          ) : (
            items.map((item) => (
              <div
                key={item.desk_unit_id}
                className={`mb-1 rounded-md border px-3 py-2 ${
                  openItem?.desk_unit_id === item.desk_unit_id
                    ? "border-[var(--teal)]"
                    : "border-[var(--outline)]"
                }`}
              >
                <button
                  type="button"
                  onClick={() => openOne(item.desk_unit_id)}
                  className="block w-full text-left"
                >
                  <div className="flex items-center gap-2 text-sm font-medium">
                    {item.pinned ? <Pin size={13} className="flex-none text-[var(--teal)]" /> : null}
                    <span className="truncate">{item.title || item.path || "Untitled"}</span>
                    {item.chunk_index != null ? (
                      <span className="flex-none text-xs text-[var(--ink-soft)]">chunk {item.chunk_index}</span>
                    ) : null}
                  </div>
                  {item.reason ? (
                    <p className="mt-0.5 truncate text-xs italic text-[var(--ink-soft)]">“{item.reason}”</p>
                  ) : null}
                  <p className="mt-1 line-clamp-2 text-xs text-[var(--ink-soft)]">{item.snippet}</p>
                </button>
                <div className="mt-1.5 flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() =>
                      act(
                        { action: item.pinned ? "unpin" : "pin", desk_unit_id: item.desk_unit_id },
                        item.pinned ? "Unpinned — normal cleanup applies again." : "Pinned — cleanup will keep it."
                      )
                    }
                    className="flex items-center gap-1 rounded border border-[var(--outline)] px-2 py-0.5 text-xs hover:border-[var(--teal)]"
                  >
                    {item.pinned ? <PinOff size={12} /> : <Pin size={12} />}
                    {item.pinned ? "Unpin" : "Pin"}
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      act(
                        { action: "clear", desk_unit_ids: [item.desk_unit_id], include_pinned: true },
                        "Archived the desk item. The source remains in the cabinet."
                      )
                    }
                    className="flex items-center gap-1 rounded border border-[var(--outline)] px-2 py-0.5 text-xs hover:border-[var(--teal)]"
                  >
                    <Trash2 size={12} /> Remove
                  </button>
                </div>
              </div>
            ))
          )}
        </Card>

        <Card className="max-h-[70vh] overflow-y-auto p-4">
          {!openItem ? (
            <p className="text-sm text-[var(--ink-soft)]">Select a desk item to read it.</p>
          ) : (
            <div className="space-y-3">
              <div className="flex items-start justify-between gap-3">
                <h2 className="min-w-0 truncate text-base font-semibold">{openItem.title || "Desk item"}</h2>
                <button
                  type="button"
                  aria-label="Close reader"
                  onClick={() => setOpenItem(null)}
                  className="rounded p-1 text-[var(--ink-soft)] hover:bg-[var(--surface-strong)]"
                >
                  <X size={15} />
                </button>
              </div>
              <pre className="whitespace-pre-wrap break-words rounded-md bg-[var(--surface-strong)] p-3 text-xs leading-relaxed">
                {openItem.content}
              </pre>
              {openItem.truncated && openItem.next_offset != null ? (
                <button
                  type="button"
                  onClick={() => openOne(openItem.desk_unit_id, openItem.next_offset as number)}
                  className="rounded-md border border-[var(--outline)] px-3 py-1.5 text-xs font-medium hover:border-[var(--teal)]"
                >
                  Load more ({openItem.total_chars?.toLocaleString()} chars total)
                </button>
              ) : null}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
