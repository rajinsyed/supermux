import type { AttachmentErrorCode } from "../bridge";
import type { ImageAttachment } from "./types";

export type { AttachmentErrorCode } from "../bridge";

// Match Claude's direct-API image ceiling; the aggregate stays below the
// standard 32 MiB request envelope after base64 expansion and JSON overhead.
export const MAXIMUM_IMAGE_BYTES = 10 * 1024 * 1024;
export const MAXIMUM_TOTAL_IMAGE_BYTES = 20 * 1024 * 1024;
export const MAXIMUM_IMAGE_COUNT = 8;

const SUPPORTED_MEDIA_TYPES = new Set(["image/gif", "image/jpeg", "image/png", "image/webp"]);
const BASE64_CHUNK_BYTES = 32 * 1024;

export interface PickedImageAttachments {
  images: ImageAttachment[];
  error?: AttachmentErrorCode;
}

export interface PendingImageAttachment {
  id: string;
  mediaType: string;
  blob: Blob;
  name?: string;
  previewURL: string;
  /** Reuse native-picker bytes instead of decoding and encoding the same payload twice. */
  dataBase64?: string;
}

type AttachmentResult =
  | { kind: "attachment"; attachment: Omit<PendingImageAttachment, "id" | "previewURL"> }
  | { kind: "error"; code: AttachmentErrorCode };

export type ImagePayloadValidation =
  | { kind: "valid"; decoded: string }
  | { kind: "error"; code: AttachmentErrorCode };

export function attachmentFromFile(file: File): AttachmentResult {
  if (!SUPPORTED_MEDIA_TYPES.has(file.type)) {
    return { kind: "error", code: "unsupportedMediaType" };
  }
  if (file.size === 0) return { kind: "error", code: "invalidImage" };
  if (file.size > MAXIMUM_IMAGE_BYTES) {
    return { kind: "error", code: "imageTooLarge" };
  }
  return {
    kind: "attachment",
    attachment: { mediaType: file.type, blob: file, name: file.name }
  };
}

export function validateImagePayload(payload: ImageAttachment): ImagePayloadValidation {
  if (!SUPPORTED_MEDIA_TYPES.has(payload.mediaType)) {
    return { kind: "error", code: "unsupportedMediaType" };
  }
  const maximumEncodedBytes = Math.ceil(MAXIMUM_IMAGE_BYTES / 3) * 4;
  if (payload.dataBase64.length > maximumEncodedBytes) {
    return { kind: "error", code: "imageTooLarge" };
  }
  if (!isStrictBase64(payload.dataBase64)) {
    return { kind: "error", code: "invalidImage" };
  }

  try {
    const decoded = atob(payload.dataBase64);
    if (decoded.length === 0) return { kind: "error", code: "invalidImage" };
    if (decoded.length > MAXIMUM_IMAGE_BYTES) {
      return { kind: "error", code: "imageTooLarge" };
    }
    return { kind: "valid", decoded };
  } catch {
    return { kind: "error", code: "invalidImage" };
  }
}

export function attachmentFromPayload(payload: ImageAttachment): AttachmentResult {
  const validation = validateImagePayload(payload);
  if (validation.kind === "error") return validation;

  const bytes = new Uint8Array(validation.decoded.length);
  for (let index = 0; index < validation.decoded.length; index += 1) {
    bytes[index] = validation.decoded.charCodeAt(index);
  }
  return {
    kind: "attachment",
    attachment: {
      mediaType: payload.mediaType,
      blob: new Blob([bytes], { type: payload.mediaType }),
      name: payload.name,
      dataBase64: payload.dataBase64
    }
  };
}

export async function payloadFromAttachment(
  attachment: PendingImageAttachment
): Promise<ImageAttachment> {
  const dataBase64 =
    attachment.dataBase64 ?? encodeBase64(new Uint8Array(await attachment.blob.arrayBuffer()));
  return {
    mediaType: attachment.mediaType,
    dataBase64,
    ...(attachment.name ? { name: attachment.name } : {})
  };
}

function isStrictBase64(value: string): boolean {
  if (value.length === 0 || value.length % 4 !== 0) return false;
  return /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

function encodeBase64(bytes: Uint8Array): string {
  const chunks: string[] = [];
  for (let offset = 0; offset < bytes.length; offset += BASE64_CHUNK_BYTES) {
    chunks.push(String.fromCharCode(...bytes.subarray(offset, offset + BASE64_CHUNK_BYTES)));
  }
  return btoa(chunks.join(""));
}
