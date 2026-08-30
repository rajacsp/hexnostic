"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

export type OAuthCredentialStatus = {
  provider: string;
  configured: boolean;
  expires_at?: string;
  expires_in_seconds?: number;
  email?: string;
  account_id?: string;
  base_url?: string;
  project_id?: string;
  resource_url?: string;
  region?: string;
};

type OAuthSession = {
  session_id: string;
  provider: string;
  flow: "authorization_code" | "device_code";
  status:
    | "awaiting_code"
    | "waiting_for_user"
    | "exchanging"
    | "complete"
    | "error"
    | "expired";
  expires_in_seconds: number;
  callback_active?: boolean;
  authorization_url?: string;
  verification_uri?: string;
  user_code?: string;
  error?: string;
  credential?: OAuthCredentialStatus;
};

type OAuthOptions = {
  client_id: string;
  client_secret: string;
  redirect_uri: string;
  enterprise_domain: string;
  region: "global" | "cn";
};

type Props = {
  provider: string;
  label: string;
  refreshKey: number;
  onAuthenticated: (provider: string) => void;
};

const initialOptions: OAuthOptions = {
  client_id: "",
  client_secret: "",
  redirect_uri: "",
  enterprise_domain: "",
  region: "global",
};

async function authRequest<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, { cache: "no-store", ...init });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = payload?.detail || payload?.error || payload?.message;
    throw new Error(typeof message === "string" ? message : `Authorization request failed (${response.status}).`);
  }
  return payload as T;
}

export async function getOAuthStatus(
  provider: string,
  validate = false
): Promise<OAuthCredentialStatus> {
  const params = new URLSearchParams({ provider });
  if (validate) params.set("validate", "true");
  return authRequest<OAuthCredentialStatus>(
    `/api/init/auth/status?${params.toString()}`
  );
}

function credentialIdentity(status: OAuthCredentialStatus): string | null {
  return (
    status.email ||
    status.account_id ||
    status.project_id ||
    status.base_url ||
    status.resource_url ||
    null
  );
}

export function OAuthControl({ provider, label, refreshKey, onAuthenticated }: Props) {
  const [credential, setCredential] = useState<OAuthCredentialStatus | null>(null);
  const [session, setSession] = useState<OAuthSession | null>(null);
  const [authorizationInput, setAuthorizationInput] = useState("");
  const [options, setOptions] = useState<OAuthOptions>(initialOptions);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadStatus = useCallback(async () => {
    setLoading(true);
    try {
      const next = await getOAuthStatus(provider);
      setCredential(next);
      setError(null);
    } catch (reason: unknown) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setLoading(false);
    }
  }, [provider]);

  useEffect(() => {
    setSession(null);
    setAuthorizationInput("");
    loadStatus();
  }, [loadStatus, refreshKey]);

  useEffect(() => {
    if (!session || session.status === "complete" || session.status === "error" || session.status === "expired") {
      return;
    }
    if (session.flow === "authorization_code" && !session.callback_active && session.status === "awaiting_code") {
      return;
    }

    const timer = window.setInterval(async () => {
      try {
        const next = await authRequest<OAuthSession>(
          `/api/init/auth/session/${encodeURIComponent(session.session_id)}`
        );
        setSession(next);
        if (next.status === "complete") {
          if (next.credential) setCredential(next.credential);
          setError(null);
          onAuthenticated(provider);
        } else if (next.status === "error" || next.status === "expired") {
          setError(next.error || "This authorization attempt expired. Start a new one.");
        }
      } catch (reason: unknown) {
        setError(reason instanceof Error ? reason.message : String(reason));
      }
    }, 1500);
    return () => window.clearInterval(timer);
  }, [onAuthenticated, provider, session]);

  const publicOptions = useMemo(() => {
    const entries = Object.entries(options).filter(([, value]) => value.trim());
    return Object.fromEntries(entries);
  }, [options]);

  const start = async () => {
    setBusy(true);
    setError(null);
    setAuthorizationInput("");
    try {
      const next = await authRequest<OAuthSession>("/api/init/auth/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ provider, options: publicOptions }),
      });
      setSession(next);
    } catch (reason: unknown) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  };

  const complete = async () => {
    if (!session) return;
    setBusy(true);
    setError(null);
    try {
      const next = await authRequest<OAuthSession>("/api/init/auth/complete", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          session_id: session.session_id,
          authorization_input: authorizationInput,
        }),
      });
      setSession(next);
      if (next.credential) setCredential(next.credential);
      onAuthenticated(provider);
    } catch (reason: unknown) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  };

  const identity = credential ? credentialIdentity(credential) : null;
  const needsClientCredentials =
    provider === "google-gemini-cli" || provider === "google-antigravity";

  return (
    <div className="rounded-xl border border-[var(--outline)] bg-[var(--surface)] px-4 py-4 text-sm text-[var(--ink)]">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="font-semibold">
            {loading ? "Checking login..." : credential?.configured ? "Login stored" : "Authentication required"}
          </p>
          {credential?.configured ? (
            <p className="mt-1 break-words text-[var(--ink-soft)]">
              {identity ? `${label}: ${identity}` : `${label} is authorized for Hexis.`}
            </p>
          ) : (
            <p className="mt-1 text-[var(--ink-soft)]">
              Authorize {label} here before continuing. No API key is needed.
            </p>
          )}
        </div>
        {!session || session.status === "complete" || session.status === "error" || session.status === "expired" ? (
          <button
            type="button"
            className="rounded-full border border-[var(--foreground)] px-4 py-2 font-semibold transition hover:bg-[var(--foreground)] hover:text-white disabled:opacity-50"
            onClick={start}
            disabled={busy || loading}
          >
            {credential?.configured ? "Authenticate again" : "Start authorization"}
          </button>
        ) : null}
      </div>

      {provider === "chutes" && (!session || session.status === "error" || session.status === "expired") ? (
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <OptionInput
            label="Chutes client ID"
            value={options.client_id}
            onChange={(value) => setOptions((current) => ({ ...current, client_id: value }))}
            placeholder="Required unless configured on the server"
          />
          <OptionInput
            label="Redirect URI"
            value={options.redirect_uri}
            onChange={(value) => setOptions((current) => ({ ...current, redirect_uri: value }))}
            placeholder="http://localhost:11435/auth/callback"
          />
        </div>
      ) : null}

      {provider === "github-copilot" && (!session || session.status === "error" || session.status === "expired") ? (
        <div className="mt-4">
          <OptionInput
            label="GitHub enterprise hostname"
            value={options.enterprise_domain}
            onChange={(value) => setOptions((current) => ({ ...current, enterprise_domain: value }))}
            placeholder="Optional, for example github.example.com"
          />
        </div>
      ) : null}

      {provider === "minimax-portal" && (!session || session.status === "error" || session.status === "expired") ? (
        <label className="mt-4 block text-xs uppercase tracking-[0.2em] text-[var(--ink-soft)]">
          Region
          <select
            className="mt-2 w-full rounded-xl border border-[var(--outline)] bg-white px-3 py-2 text-sm normal-case tracking-normal text-[var(--foreground)]"
            value={options.region}
            onChange={(event) =>
              setOptions((current) => ({ ...current, region: event.target.value as "global" | "cn" }))
            }
          >
            <option value="global">Global</option>
            <option value="cn">China</option>
          </select>
        </label>
      ) : null}

      {needsClientCredentials && (!session || session.status === "error" || session.status === "expired") ? (
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <OptionInput
            label="OAuth client ID"
            value={options.client_id}
            onChange={(value) => setOptions((current) => ({ ...current, client_id: value }))}
            placeholder="Uses server configuration when blank"
          />
          <OptionInput
            label="OAuth client secret"
            value={options.client_secret}
            onChange={(value) => setOptions((current) => ({ ...current, client_secret: value }))}
            placeholder="Uses server configuration when blank"
            secret
          />
        </div>
      ) : null}

      {session?.verification_uri ? (
        <div className="mt-4 border-t border-[var(--outline)] pt-4">
          <p className="font-semibold">Approve this device</p>
          <div className="mt-3 flex flex-wrap items-center gap-3">
            {session.user_code ? (
              <code className="rounded-lg bg-white px-3 py-2 text-base font-semibold tracking-[0.12em]">
                {session.user_code}
              </code>
            ) : null}
            <a
              className="rounded-full bg-[var(--foreground)] px-4 py-2 font-semibold text-white transition hover:bg-[var(--accent-strong)]"
              href={session.verification_uri}
              target="_blank"
              rel="noreferrer"
            >
              Open authorization page
            </a>
            {session.user_code && typeof navigator !== "undefined" && navigator.clipboard ? (
              <button
                type="button"
                className="underline decoration-[var(--outline)] underline-offset-4"
                onClick={() => navigator.clipboard.writeText(session.user_code || "")}
              >
                Copy code
              </button>
            ) : null}
          </div>
          <p className="mt-3 text-[var(--ink-soft)]">Waiting for approval in the other tab...</p>
        </div>
      ) : null}

      {session?.authorization_url && session.status !== "complete" ? (
        <div className="mt-4 border-t border-[var(--outline)] pt-4">
          <a
            className="inline-flex rounded-full bg-[var(--foreground)] px-4 py-2 font-semibold text-white transition hover:bg-[var(--accent-strong)]"
            href={session.authorization_url}
            target="_blank"
            rel="noreferrer"
          >
            Open authorization page
          </a>
          <p className="mt-3 text-[var(--ink-soft)]">
            {session.callback_active
              ? "After approval, this page updates automatically. If it does not, paste the redirect URL below."
              : "After approval, paste the displayed code or full redirect URL below."}
          </p>
          <label className="mt-3 block text-xs uppercase tracking-[0.2em] text-[var(--ink-soft)]">
            Authorization code or redirect URL
            <input
              className="mt-2 w-full rounded-xl border border-[var(--outline)] bg-white px-3 py-2 text-sm normal-case tracking-normal text-[var(--foreground)]"
              value={authorizationInput}
              onChange={(event) => setAuthorizationInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && authorizationInput.trim() && !busy) complete();
              }}
              autoComplete="off"
            />
          </label>
          <button
            type="button"
            className="mt-3 rounded-full border border-[var(--foreground)] px-4 py-2 font-semibold transition hover:bg-[var(--foreground)] hover:text-white disabled:opacity-50"
            onClick={complete}
            disabled={busy || !authorizationInput.trim()}
          >
            Complete authorization
          </button>
        </div>
      ) : null}

      {session?.status === "exchanging" ? (
        <p className="mt-4 text-[var(--ink-soft)]">Completing authorization...</p>
      ) : null}
      {session?.status === "complete" ? (
        <p className="mt-4 font-semibold text-[var(--teal)]">Authorization complete.</p>
      ) : null}
      {error ? (
        <p className="mt-4 rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-red-700" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  );
}

function OptionInput({
  label,
  value,
  onChange,
  placeholder,
  secret = false,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  secret?: boolean;
}) {
  return (
    <label className="block text-xs uppercase tracking-[0.2em] text-[var(--ink-soft)]">
      {label}
      <input
        className="mt-2 w-full rounded-xl border border-[var(--outline)] bg-white px-3 py-2 text-sm normal-case tracking-normal text-[var(--foreground)]"
        type={secret ? "password" : "text"}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        autoComplete="off"
      />
    </label>
  );
}
