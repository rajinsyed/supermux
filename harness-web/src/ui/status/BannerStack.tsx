import { useState } from "react";
import type { CopyKey } from "../../copyKeys";
import type { Banner } from "../../model/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, Close, Info, XCircle } from "../Icons";

export function BannerStack({
  banners,
  onDismiss
}: {
  banners: Banner[];
  onDismiss: (id: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const copy = useCopy();
  if (banners.length === 0) return null;

  const ordered = banners.slice().reverse();
  const shown = expanded ? ordered : ordered.slice(0, 1);
  const hidden = ordered.length - shown.length;

  return (
    <div
      className={`banner-stack${expanded ? " is-expanded" : ""}`}
      onMouseEnter={() => setExpanded(true)}
      onMouseLeave={() => setExpanded(false)}
    >
      {shown.map((banner) => {
        const Icon = banner.severity === "error" ? XCircle : banner.severity === "warning" ? AlertTriangle : Info;
        return (
          <div key={banner.id} className={`banner is-${banner.severity}`} role="alert">
            <Icon size={13} className="banner-icon" />
            <div className="banner-body">
              <span className="banner-title">
                {banner.titleKey
                  ? copy(banner.titleKey as CopyKey, { subject: banner.title })
                  : banner.title}
              </span>
              {banner.retry ? (
                <span className="banner-detail tnum">
                  {banner.retry.retryDelayMs
                    ? copy("supermux.harness.status.retrying", {
                        seconds: Math.max(1, Math.round(banner.retry.retryDelayMs / 1000)),
                        attempt: banner.retry.attempt,
                        max: banner.retry.maxRetries ?? "?"
                      })
                    : copy("supermux.harness.banner.retryAttempt", {
                        attempt: banner.retry.attempt,
                        max: banner.retry.maxRetries ?? "?"
                      })}
                </span>
              ) : banner.detail ? (
                <span className="banner-detail">{banner.detail}</span>
              ) : null}
            </div>
            <button
              type="button"
              className="icon-btn"
              onClick={() => onDismiss(banner.id)}
              aria-label={copy("supermux.harness.banner.dismiss")}
            >
              <Close size={11} />
            </button>
          </div>
        );
      })}
      {hidden > 0 ? <div className="banner-peek" aria-hidden="true" /> : null}
    </div>
  );
}
