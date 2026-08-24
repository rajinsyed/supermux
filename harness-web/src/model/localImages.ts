import { getBridge } from "../bridge";
import { validateImagePayload } from "./attachments";

export interface ProjectImage {
  mediaType: string;
  dataBase64: string;
}

interface PendingRead {
  path: string;
  resolve(image: ProjectImage | undefined): void;
}

const MAXIMUM_CONCURRENT_READS = 4;
const MAXIMUM_PENDING_READS = 64;
const inFlight = new Map<string, Promise<ProjectImage | undefined>>();
const queue: PendingRead[] = [];
let activeReadCount = 0;

export function projectRelativeImagePath(source: string | undefined): string | undefined {
  const encoded = source?.trim();
  if (!encoded) return undefined;

  let path: string;
  try {
    path = decodeURIComponent(encoded);
  } catch {
    return undefined;
  }
  if (
    !path ||
    path.includes("\0") ||
    path.startsWith("/") ||
    path.startsWith("\\") ||
    path.startsWith("~") ||
    path.startsWith("#") ||
    path.startsWith("?") ||
    /^[a-z][a-z0-9+.-]*:/i.test(path)
  ) {
    return undefined;
  }
  return path;
}

export function loadProjectImage(path: string): Promise<ProjectImage | undefined> {
  const existing = inFlight.get(path);
  if (existing) return existing;
  if (inFlight.size >= MAXIMUM_PENDING_READS) return Promise.resolve(undefined);

  let resolveRead: (image: ProjectImage | undefined) => void = () => undefined;
  const read = new Promise<ProjectImage | undefined>((resolve) => {
    resolveRead = resolve;
  });
  inFlight.set(path, read);
  queue.push({ path, resolve: resolveRead });
  drainQueue();
  void read.then(() => {
    if (inFlight.get(path) === read) inFlight.delete(path);
  });
  return read;
}

function drainQueue(): void {
  while (activeReadCount < MAXIMUM_CONCURRENT_READS) {
    const pending = queue.shift();
    if (!pending) return;
    activeReadCount += 1;
    void readProjectImage(pending.path).then((image) => {
      pending.resolve(image);
      activeReadCount -= 1;
      drainQueue();
    });
  }
}

async function readProjectImage(path: string): Promise<ProjectImage | undefined> {
  try {
    const payload = await getBridge().readImage({ path });
    const validation = validateImagePayload(payload);
    return validation.kind === "valid"
      ? { mediaType: payload.mediaType, dataBase64: payload.dataBase64 }
      : undefined;
  } catch {
    return undefined;
  }
}
