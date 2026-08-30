"use client";

import { useEffect, useRef } from "react";

/** Refresh runtime status without holding a database-backed SSE connection. */
export function useGatewayEvents(onEvent: () => void) {
  const onEventRef = useRef(onEvent);

  useEffect(() => {
    onEventRef.current = onEvent;
  }, [onEvent]);

  useEffect(() => {
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") onEventRef.current();
    };
    const interval = setInterval(refreshWhenVisible, 15000);
    document.addEventListener("visibilitychange", refreshWhenVisible);
    window.addEventListener("focus", refreshWhenVisible);

    return () => {
      clearInterval(interval);
      document.removeEventListener("visibilitychange", refreshWhenVisible);
      window.removeEventListener("focus", refreshWhenVisible);
    };
  }, []);
}
