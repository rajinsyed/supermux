import { createContext, useContext, useMemo, type ReactNode } from "react";
import { copyDefaults, format, resolveCopy, type CopyKey } from "../copyKeys";

export type CopyFn = (key: CopyKey, values?: Record<string, string | number>) => string;

const CopyContext = createContext<Record<CopyKey, string>>(copyDefaults as Record<CopyKey, string>);

export function CopyProvider({
  dict,
  children
}: {
  dict?: Record<string, string>;
  children: ReactNode;
}) {
  const value = useMemo(() => resolveCopy(dict), [dict]);
  return <CopyContext.Provider value={value}>{children}</CopyContext.Provider>;
}

export function useCopy(): CopyFn {
  const dict = useContext(CopyContext);
  return useMemo<CopyFn>(
    () => (key, values) => (values ? format(dict[key], values) : dict[key]),
    [dict]
  );
}

/**
 * English inflects on count and Japanese does not, so a single "{count} earlier
 * tool calls" template cannot serve both — and single-tool turns are the common
 * case, which is exactly when the shared template reads wrong. Each counted
 * string therefore owns a one-form and an other-form key.
 */
export function plural(copy: CopyFn, count: number, one: CopyKey, other: CopyKey): string {
  return copy(count === 1 ? one : other, { count });
}
