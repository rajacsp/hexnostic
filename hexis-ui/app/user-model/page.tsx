"use client";

import { Check, RefreshCw, Search, ShieldAlert, UserRound, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { PageHeader } from "../components/ui/page-header";
import { Spinner } from "../components/ui/spinner";

type UserClaim = {
  id: string;
  claim_key: string;
  category: string;
  claim: string;
  confidence: number;
  importance: number;
  evidence_count: number;
  status: string;
  review_status: string;
  metadata: Record<string, unknown>;
  first_seen_at: string | null;
  last_evidence_at: string | null;
};

type ClaimsPayload = {
  claims: UserClaim[];
  total: number;
  limit: number;
  offset: number;
};

type ImportanceItem = {
  source_item_id: string;
  connector_id: string;
  account_key: string;
  score: number;
  label: string;
  reasons: string[];
  recommended_actions: Record<string, unknown>[];
  title: string | null;
  preview: string | null;
  updated_at: string | null;
};

type ImportancePayload = {
  items: ImportanceItem[];
  total: number;
};

const REVIEW_FILTERS = [
  { value: "pending_review", label: "Pending" },
  { value: "approved", label: "Approved" },
  { value: "rejected", label: "Rejected" },
  { value: "superseded", label: "Superseded" },
];

export default function UserModelPage() {
  const [claims, setClaims] = useState<ClaimsPayload>({ claims: [], total: 0, limit: 50, offset: 0 });
  const [importance, setImportance] = useState<ImportancePayload>({ items: [], total: 0 });
  const [reviewStatus, setReviewStatus] = useState("pending_review");
  const [category, setCategory] = useState("");
  const [loading, setLoading] = useState(true);
  const [busyClaim, setBusyClaim] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const claimParams = new URLSearchParams({ limit: "50", offset: "0" });
      if (reviewStatus) claimParams.set("review_status", reviewStatus);
      if (category) claimParams.set("category", category);
      const [claimResponse, importanceResponse] = await Promise.all([
        fetch(`/api/user-model/claims?${claimParams}`, { cache: "no-store" }),
        fetch("/api/connector-importance?limit=8&status=completed", { cache: "no-store" }),
      ]);
      if (!claimResponse.ok) throw new Error(`Failed to load claims (${claimResponse.status})`);
      if (!importanceResponse.ok) throw new Error(`Failed to load importance (${importanceResponse.status})`);
      setClaims((await claimResponse.json()) as ClaimsPayload);
      setImportance((await importanceResponse.json()) as ImportancePayload);
      setError(null);
    } catch (requestError: unknown) {
      setError(requestError instanceof Error ? requestError.message : "Failed to load user model.");
    } finally {
      setLoading(false);
    }
  }, [category, reviewStatus]);

  useEffect(() => {
    void load();
  }, [load]);

  const review = async (claimId: string, decision: "approve" | "reject" | "restore") => {
    setBusyClaim(claimId);
    setError(null);
    try {
      const response = await fetch(`/api/user-model/claims/${claimId}/review`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ decision, actor: "web-user-model" }),
      });
      if (!response.ok) {
        const body = await response.text();
        throw new Error(body.slice(0, 180) || `Review failed (${response.status})`);
      }
      await load();
    } catch (requestError: unknown) {
      setError(requestError instanceof Error ? requestError.message : "Review failed.");
    } finally {
      setBusyClaim(null);
    }
  };

  return (
    <div className="space-y-6 p-6">
      <div className="border-b border-[var(--outline)] pb-5">
        <PageHeader title="User Model" subtitle="Evidence-backed beliefs derived from connected history" />
      </div>

      {error ? (
        <div className="rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-2">
        {REVIEW_FILTERS.map((filter) => (
          <button
            key={filter.value}
            type="button"
            onClick={() => setReviewStatus(filter.value)}
            className={`rounded-md px-3 py-2 text-xs font-semibold ${
              reviewStatus === filter.value
                ? "bg-[var(--foreground)] text-white"
                : "border border-[var(--outline)] text-[var(--ink-soft)] hover:bg-[var(--surface-strong)]"
            }`}
          >
            {filter.label}
          </button>
        ))}
        <div className="flex items-center rounded-md border border-[var(--outline)] px-2">
          <Search size={15} className="text-[var(--ink-soft)]" />
          <select
            value={category}
            onChange={(event) => setCategory(event.target.value)}
            className="bg-transparent px-2 py-2 text-xs outline-none"
          >
            <option value="">All categories</option>
            <option value="preference">Preference</option>
            <option value="relationship">Relationship</option>
            <option value="commitment">Commitment</option>
            <option value="routine">Routine</option>
            <option value="judgment_pattern">Judgment pattern</option>
            <option value="identity">Identity</option>
          </select>
        </div>
        <Button type="button" variant="ghost" onClick={load} className="gap-2 px-3 py-2 text-xs">
          <RefreshCw size={14} /> Refresh
        </Button>
      </div>

      {loading ? (
        <div className="flex justify-center py-16">
          <Spinner label="Loading user model..." />
        </div>
      ) : (
        <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
          <section className="rounded-lg border border-[var(--outline)] bg-white">
            <div className="flex items-center justify-between border-b border-[var(--outline)] px-4 py-3">
              <h2 className="text-sm font-semibold">Derived beliefs</h2>
              <Badge variant="muted">{claims.total}</Badge>
            </div>
            {claims.claims.length === 0 ? (
              <div className="flex flex-col items-center py-16 text-center text-sm text-[var(--ink-soft)]">
                <UserRound size={26} />
                <p className="mt-3">No claims in this review state.</p>
              </div>
            ) : (
              <div className="divide-y divide-[var(--outline)]">
                {claims.claims.map((claim) => (
                  <article key={claim.id} className="space-y-3 px-4 py-4">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge variant="teal">{claim.category}</Badge>
                      <Badge variant={claim.review_status === "pending_review" ? "warning" : statusVariant(claim.review_status)}>
                        {humanize(claim.review_status)}
                      </Badge>
                      <span className="text-xs text-[var(--ink-soft)]">
                        evidence {claim.evidence_count} · confidence {percent(claim.confidence)}
                      </span>
                    </div>
                    <p className="text-sm leading-6">{claim.claim}</p>
                    <p className="break-all text-xs text-[var(--ink-soft)]">{claim.claim_key}</p>
                    <div className="flex flex-wrap gap-2">
                      {claim.review_status !== "approved" ? (
                        <Button
                          type="button"
                          variant="secondary"
                          disabled={busyClaim === claim.id}
                          onClick={() => void review(claim.id, "approve")}
                          className="gap-1.5 px-3 py-1.5 text-xs"
                        >
                          <Check size={14} /> Approve
                        </Button>
                      ) : null}
                      {claim.status !== "rejected" ? (
                        <Button
                          type="button"
                          variant="ghost"
                          disabled={busyClaim === claim.id}
                          onClick={() => void review(claim.id, "reject")}
                          className="gap-1.5 px-3 py-1.5 text-xs"
                        >
                          <X size={14} /> Reject
                        </Button>
                      ) : (
                        <Button
                          type="button"
                          variant="ghost"
                          disabled={busyClaim === claim.id}
                          onClick={() => void review(claim.id, "restore")}
                          className="gap-1.5 px-3 py-1.5 text-xs"
                        >
                          <RefreshCw size={14} /> Restore
                        </Button>
                      )}
                    </div>
                  </article>
                ))}
              </div>
            )}
          </section>

          <aside className="rounded-lg border border-[var(--outline)] bg-white">
            <div className="flex items-center justify-between border-b border-[var(--outline)] px-4 py-3">
              <h2 className="text-sm font-semibold">Important connector items</h2>
              <Badge variant="muted">{importance.total}</Badge>
            </div>
            <div className="divide-y divide-[var(--outline)]">
              {importance.items.length === 0 ? (
                <div className="flex flex-col items-center py-12 text-center text-sm text-[var(--ink-soft)]">
                  <ShieldAlert size={24} />
                  <p className="mt-3">No scored items yet.</p>
                </div>
              ) : importance.items.map((item) => (
                <article key={item.source_item_id} className="space-y-2 px-4 py-4">
                  <div className="flex items-center justify-between gap-3">
                    <p className="truncate text-sm font-semibold">{item.title || item.connector_id}</p>
                    <Badge variant={item.label === "urgent" ? "error" : item.label === "important" ? "warning" : "muted"}>
                      {item.label} {percent(item.score)}
                    </Badge>
                  </div>
                  <p className="line-clamp-4 text-xs leading-5 text-[var(--ink-soft)]">{item.preview}</p>
                  {item.reasons.length ? (
                    <p className="text-xs text-[var(--ink-soft)]">{item.reasons.slice(0, 3).join(" · ")}</p>
                  ) : null}
                </article>
              ))}
            </div>
          </aside>
        </div>
      )}
    </div>
  );
}

function percent(value: number): string {
  return `${Math.round(Math.max(0, Math.min(1, value || 0)) * 100)}%`;
}

function humanize(value: string): string {
  return value.split("_").join(" ");
}

function statusVariant(value: string): "success" | "error" | "muted" | "warning" {
  if (value === "approved") return "success";
  if (value === "rejected") return "error";
  if (value === "pending_review") return "warning";
  return "muted";
}
