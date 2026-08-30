interface PageHeaderProps {
  title: string;
  subtitle?: string;
  breadcrumb?: string;
}

export function PageHeader({ title, subtitle, breadcrumb = "Hexis" }: PageHeaderProps) {
  return (
    <header className="flex flex-col gap-1">
      <p className="text-xs font-semibold uppercase text-[var(--teal)]">
        {breadcrumb}
      </p>
      <h1 className="font-display text-2xl leading-tight text-[var(--foreground)] md:text-3xl">
        {title}
      </h1>
      {subtitle && (
        <p className="max-w-2xl text-sm text-[var(--ink-soft)]">{subtitle}</p>
      )}
    </header>
  );
}
