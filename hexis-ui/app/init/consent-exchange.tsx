export type ConsentExchange = {
  request_messages: Array<{ role?: string; content?: unknown }>;
  raw_content: string;
  raw_tool_calls: Array<{ name?: string; arguments?: unknown }>;
};

function formattedArguments(value: unknown): string {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value ?? {}, null, 2);
  } catch {
    return String(value);
  }
}

export function ConsentExchangeView({ exchange }: { exchange: ConsentExchange }) {
  const hasResponse = Boolean(exchange.raw_content.trim()) || exchange.raw_tool_calls.length > 0;

  return (
    <section
      aria-label="Consent request and response"
      className="mt-4 border-t border-[var(--outline)] pt-4"
    >
      <h4 className="text-sm font-semibold text-[var(--foreground)]">Request</h4>
      <div className="mt-2 space-y-3">
        {exchange.request_messages.map((message, index) => (
          <div key={`${message.role || "message"}-${index}`}>
            <p className="text-xs font-semibold uppercase text-[var(--ink-soft)]">
              {message.role || "message"}
            </p>
            <pre className="mt-1 max-h-72 overflow-auto whitespace-pre-wrap break-words bg-[var(--surface)] p-3 text-xs leading-5 text-[var(--foreground)]">
              {typeof message.content === "string"
                ? message.content
                : formattedArguments(message.content)}
            </pre>
          </div>
        ))}
      </div>

      <h4 className="mt-5 text-sm font-semibold text-[var(--foreground)]">Response</h4>
      <div className="mt-2 space-y-3">
        {exchange.raw_content.trim() ? (
          <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words bg-[var(--surface)] p-3 text-xs leading-5 text-[var(--foreground)]">
            {exchange.raw_content}
          </pre>
        ) : null}
        {exchange.raw_tool_calls.map((toolCall, index) => (
          <div key={`${toolCall.name || "tool"}-${index}`}>
            <p className="text-xs font-semibold text-[var(--ink-soft)]">
              Tool call: {toolCall.name || "unknown"}
            </p>
            <pre className="mt-1 max-h-72 overflow-auto whitespace-pre-wrap break-words bg-[var(--surface)] p-3 text-xs leading-5 text-[var(--foreground)]">
              {formattedArguments(toolCall.arguments)}
            </pre>
          </div>
        ))}
        {!hasResponse ? (
          <p className="text-xs text-[var(--ink-soft)]">
            The model returned no content and no tool call.
          </p>
        ) : null}
      </div>
    </section>
  );
}
