import { ButtonHTMLAttributes, forwardRef } from "react";

type ButtonVariant = "primary" | "secondary" | "ghost";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
}

const variantClasses: Record<ButtonVariant, string> = {
  primary:
    "rounded-lg bg-[var(--foreground)] px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-[var(--teal)] disabled:cursor-not-allowed disabled:opacity-50",
  secondary:
    "rounded-lg border border-[var(--outline)] bg-white px-4 py-2.5 text-sm font-semibold text-[var(--foreground)] transition hover:bg-[var(--surface-strong)] disabled:cursor-not-allowed disabled:opacity-50",
  ghost:
    "rounded-lg px-3 py-2 text-sm text-[var(--ink-soft)] transition hover:bg-[var(--surface-strong)] hover:text-[var(--foreground)]",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ variant = "primary", className = "", ...props }, ref) => (
    <button
      ref={ref}
      className={`${variantClasses[variant]} ${className}`}
      {...props}
    />
  )
);
Button.displayName = "Button";
