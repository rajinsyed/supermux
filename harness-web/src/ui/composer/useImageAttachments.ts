import { useCallback, useEffect, useRef, useState } from "react";
import {
  attachmentFromFile,
  attachmentFromPayload,
  MAXIMUM_IMAGE_COUNT,
  MAXIMUM_TOTAL_IMAGE_BYTES,
  payloadFromAttachment,
  type AttachmentErrorCode,
  type PendingImageAttachment,
  type PickedImageAttachments
} from "../../model/attachments";
import type { ImageAttachment } from "../../model/types";

type AttachmentCandidate =
  | ReturnType<typeof attachmentFromFile>
  | ReturnType<typeof attachmentFromPayload>;

export function useImageAttachments(identity: string | undefined) {
  const [images, setImages] = useState<PendingImageAttachment[]>([]);
  const [error, setError] = useState<AttachmentErrorCode>();
  const imagesRef = useRef<PendingImageAttachment[]>([]);
  const previousIdentity = useRef(identity);
  const generation = useRef(0);
  const nextID = useRef(1);
  const sending = useRef(false);

  const commit = useCallback((next: PendingImageAttachment[]) => {
    imagesRef.current = next;
    setImages(next);
  }, []);

  const releaseAll = useCallback(() => {
    const owned = imagesRef.current;
    commit([]);
    for (const image of owned) URL.revokeObjectURL(image.previewURL);
    setError(undefined);
  }, [commit]);

  const remove = useCallback(
    (id: string) => {
      const owned = imagesRef.current;
      const removed = owned.find((image) => image.id === id);
      if (!removed) return;
      URL.revokeObjectURL(removed.previewURL);
      commit(owned.filter((image) => image.id !== id));
    },
    [commit]
  );

  const add = useCallback(
    (candidates: AttachmentCandidate[]) => {
      const next = imagesRef.current.slice();
      let totalBytes = next.reduce((sum, image) => sum + image.blob.size, 0);
      let nextError: AttachmentErrorCode | undefined;

      for (const candidate of candidates) {
        if (candidate.kind === "error") {
          nextError = candidate.code;
          continue;
        }
        if (next.length >= MAXIMUM_IMAGE_COUNT) {
          nextError = "tooManyImages";
          continue;
        }
        if (totalBytes + candidate.attachment.blob.size > MAXIMUM_TOTAL_IMAGE_BYTES) {
          nextError = "totalTooLarge";
          continue;
        }
        totalBytes += candidate.attachment.blob.size;
        next.push({
          ...candidate.attachment,
          id: `attachment-${nextID.current}`,
          previewURL: URL.createObjectURL(candidate.attachment.blob)
        });
        nextID.current += 1;
      }

      if (next.length !== imagesRef.current.length) commit(next);
      setError(nextError);
    },
    [commit]
  );

  const addFiles = useCallback(
    (files: File[]) => add(files.map(attachmentFromFile)),
    [add]
  );

  const pickFiles = useCallback(
    (picker: () => Promise<PickedImageAttachments>) => {
      const ownedGeneration = generation.current;
      void picker()
        .then((result) => {
          if (generation.current !== ownedGeneration) return;
          add(result.images.map(attachmentFromPayload));
          if (result.error) setError(result.error);
        })
        .catch(() => {
          if (generation.current === ownedGeneration) setError("invalidImage");
        });
    },
    [add]
  );

  const consumeForSend = useCallback(async (): Promise<ImageAttachment[] | undefined> => {
    if (sending.current) return undefined;
    const owned = imagesRef.current;
    if (owned.length === 0) return [];

    sending.current = true;
    commit([]);
    for (const image of owned) URL.revokeObjectURL(image.previewURL);
    setError(undefined);
    try {
      return await Promise.all(owned.map(payloadFromAttachment));
    } catch {
      setError("invalidImage");
      return undefined;
    } finally {
      sending.current = false;
    }
  }, [commit]);

  useEffect(() => {
    if (previousIdentity.current === identity) return;
    previousIdentity.current = identity;
    generation.current += 1;
    releaseAll();
  }, [identity, releaseAll]);

  useEffect(
    () => () => {
      generation.current += 1;
      for (const image of imagesRef.current) URL.revokeObjectURL(image.previewURL);
      imagesRef.current = [];
    },
    []
  );

  return { images, error, addFiles, pickFiles, remove, releaseAll, consumeForSend };
}
