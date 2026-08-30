import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { ConsentExchangeView } from "./consent-exchange";

describe("ConsentExchangeView", () => {
  it("shows the complete request and tool-call response", () => {
    render(
      <ConsentExchangeView
        exchange={{
          request_messages: [
            { role: "user", content: "Consent prompt text and response contract" },
          ],
          raw_content: "",
          raw_tool_calls: [
            {
              name: "sign_consent",
              arguments: { decision: "decline", reason: "I need more context." },
            },
          ],
        }}
      />
    );

    expect(screen.getByRole("region", { name: "Consent request and response" })).toBeVisible();
    expect(screen.getByText("Consent prompt text and response contract")).toBeVisible();
    expect(screen.getByText("Tool call: sign_consent")).toBeVisible();
    expect(screen.getByText(/I need more context/)).toBeVisible();
  });

  it("shows an explicit empty response", () => {
    render(
      <ConsentExchangeView
        exchange={{
          request_messages: [{ role: "user", content: "Consent prompt text" }],
          raw_content: "",
          raw_tool_calls: [],
        }}
      />
    );

    expect(screen.getByText("The model returned no content and no tool call.")).toBeVisible();
  });
});
