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
