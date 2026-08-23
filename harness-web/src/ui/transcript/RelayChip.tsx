import { useContext } from "react";
import type { RelayRecord } from "../../model/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, ArrowUp, Check, Layers } from "../Icons";
import { Spinner } from "../primitives/Spinner";
import { OpenViewContext } from "../views/OpenViewContext";

/**
 * A relayed message, in the MAIN transcript, as one line.
 *
 * The user did not write "Relay this message verbatim to the running 'X'
 * subagent…" — the pane did, on their behalf, because that is the only way to
 * reach a running agent over this wire. Rendering that instruction as the
 * user's own bubble puts words in their mouth and buries what they actually
 * said inside protocol scaffolding. So the main chat shows the fact ("→ sent to
 * X") with their real text, and the message itself lives in the agent's view
 * where it was addressed.
 */
export function RelayChip({ relay }: { relay: RelayRecord }) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const label = relay.description
    ? copy(
        relay.state === "failed"
          ? "supermux.harness.relay.chipFailed"
          : "supermux.harness.relay.chip",
        { agent: relay.description }
      )
    : copy(
        relay.state === "failed"
          ? "supermux.harness.relay.chipFailedUnknown"
          : "supermux.harness.relay.chipUnknown"
      );

  return (
    <div className={`relay-chip is-${relay.state}`}>
      <ArrowUp size={10} className="relay-chip-arrow" />
      <button
        type="button"
        className="relay-chip-target"
        onClick={() => openView({ kind: "agent", toolUseId: relay.toolUseId })}
      >
        <Layers size={10} />
        {label}
      </button>
      <span className="relay-chip-text" title={relay.text}>
        {relay.text}
      </span>
      <span className="relay-chip-state">
        {relay.state === "sending" ? (
          <Spinner size={9} />
        ) : relay.state === "delivered" ? (
          <Check size={10} className="mark-ok" />
        ) : relay.state === "failed" ? (
          <AlertTriangle size={10} className="mark-error" />
        ) : null}
      </span>
    </div>
  );
}
