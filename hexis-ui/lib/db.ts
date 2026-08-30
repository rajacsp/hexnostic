export function normalizeJsonValue(value: unknown) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === "string") {
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  }
  return value;
}

export function toJsonParam(value: unknown) {
  return JSON.stringify(value ?? null);
}
