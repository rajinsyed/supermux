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

/**
 * Cursor's working glyph: a 2×2 constellation of dots drifting through a
 * staggered pulse. Pure CSS — thirty on screen cost nothing. It is the ONLY
 * state mark a running row wears, in the panel and the transcript alike.
 */
export function WorkingGlyph({ className }: { className?: string }) {
  return (
    <span className={`dock-glyph${className ? ` ${className}` : ""}`} aria-hidden="true">
      <i />
      <i />
      <i />
      <i />
    </span>
  );
}
