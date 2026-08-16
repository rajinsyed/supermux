export function Spinner({ size = 12, className }: { size?: number; className?: string }) {
  return (
    <span
      className={`spinner${className ? ` ${className}` : ""}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    />
  );
}

export function WorkingDots({ className }: { className?: string }) {
  return (
    <span className={`working-dots${className ? ` ${className}` : ""}`} aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
  );
}
