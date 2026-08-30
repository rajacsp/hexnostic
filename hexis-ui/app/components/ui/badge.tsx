interface BadgeProps {
  children: React.ReactNode;
  variant?: "default" | "accent" | "teal" | "success" | "warning" | "error" | "muted";
  className?: string;
}

const variantClasses: Record<string, string> = {
  default: "bg-[var(--surface-strong)] text-[var(--foreground)]",
  accent: "bg-[var(--accent)]/15 text-[var(--accent-strong)]",
  teal: "bg-[var(--teal)]/15 text-[var(--teal)]",
  success: "bg-green-100 text-green-700",
  warning: "bg-amber-100 text-amber-700",
  error: "bg-red-100 text-red-700",
  muted: "bg-[var(--surface-strong)] text-[var(--ink-soft)]",
};

export function Badge({ children, variant = "default", className = "" }: BadgeProps) {
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${variantClasses[variant]} ${className}`}
    >
      {children}
    </span>
  );
}

const memoryTypeVariants: Record<string, BadgeProps["variant"]> = {
  episodic: "accent",
  semantic: "teal",
  procedural: "default",
  strategic: "success",
  worldview: "warning",
  goal: "muted",
};

export function MemoryTypeBadge({ type }: { type: string }) {
  return <Badge variant={memoryTypeVariants[type] || "default"}>{type}</Badge>;
}

const goalPriorityVariants: Record<string, BadgeProps["variant"]> = {
  active: "accent",
  queued: "teal",
  backburner: "muted",
  completed: "success",
  abandoned: "error",
};

export function GoalPriorityBadge({ priority }: { priority: string }) {
  return <Badge variant={goalPriorityVariants[priority] || "default"}>{priority}</Badge>;
}
