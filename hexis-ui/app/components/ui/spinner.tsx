interface SpinnerProps {
  label?: string;
  className?: string;
}

export function Spinner({ label, className = "" }: SpinnerProps) {
  return (
    <div className={`flex items-center gap-3 ${className}`}>
      <div className="h-4 w-4 animate-spin rounded-full border-2 border-[var(--accent)] border-t-transparent" />
      {label && <span className="text-sm text-[var(--ink-soft)]">{label}</span>}
    </div>
  );
}
