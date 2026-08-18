import { useEffect, useRef, useState } from "react";
import type { SessionMeta, UsageTotals } from "../../model/types";
import type {
  ContextUsage,
  EffortLevel,
  ModelDescriptor,
  PermissionMode,
  SessionSummary
} from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { Bolt, ChevronDown, Folder, History, More, Plus, Scissors, Terminal, Trash } from "../Icons";
import { displayDirectory, formatCost, formatRelativeTime } from "../format";
import { ContextRing } from "./ContextRing";
import { Menu, MenuItem, MenuSection } from "./Menu";

const MODES: PermissionMode[] = ["default", "acceptEdits", "plan", "bypassPermissions"];

/**
 * The model picker moved INTO the composer pill (Cursor's grammar: the model is
 * a property of the message you are about to send, not of the session chrome),
 * and its data plumbing moved with it. These two are still re-exported here
 * because they are the header's own vocabulary as much as the picker's — the
 * effort a turn ran at is printed in turn footers, and the menu source is the
 * pane's answer to "what models does this binary have".
 */
export { clampEffort, effortLabel, modelMenuSource } from "../composer/ModelMenu";

export function modeLabel(mode: PermissionMode, copy: ReturnType<typeof useCopy>, short = false): string {
  switch (mode) {
    case "acceptEdits":
      return copy(short ? "supermux.harness.mode.acceptEditsShort" : "supermux.harness.mode.acceptEdits");
    case "plan":
      return copy(short ? "supermux.harness.mode.planShort" : "supermux.harness.mode.plan");
    case "bypassPermissions":
      return copy(
        short ? "supermux.harness.mode.bypassPermissionsShort" : "supermux.harness.mode.bypassPermissions"
      );
    default:
      return copy(short ? "supermux.harness.mode.defaultShort" : "supermux.harness.mode.default");
  }
}

export interface HeaderProps {
  degraded?: boolean;
  session: SessionMeta;
  usage: UsageTotals;
  contextUsage?: ContextUsage;
  workingDirectory?: string;
  sessions: SessionSummary[];
  /** Catalog persisted from an earlier run of this binary; see modelMenuSource. */
  cachedModels?: ModelDescriptor[];
  onRename(title: string): void;
  onSetModel(model: string, effort?: EffortLevel): void;
  onSetPermissionMode(mode: PermissionMode): void;
  onResumeSession(sessionId: string, fork: boolean): void;
  onOpenSessionInNewPane(sessionId: string): void;
  onLoadSessions(): void;
  onCompact(): void;
  onClear(): void;
  onExport(): void;
  onOpenTerminal(): void;
  onNewSession(): void;
  onOpenBinarySettings(): void;
}

export function Header(props: HeaderProps) {
  const copy = useCopy();
  const { session } = props;
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [sessionQuery, setSessionQuery] = useState("");
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing) input.current?.select();
  }, [editing]);

  const title = session.title ?? copy("supermux.harness.app.untitledSession");

  const filtered = props.sessions.filter((item) =>
    sessionQuery.trim().length === 0
      ? true
      : `${item.title} ${item.firstPrompt ?? ""}`.toLowerCase().includes(sessionQuery.toLowerCase())
  );

  return (
    <header className="header">
      <div className="header-left">
        {editing ? (
          <input
            ref={input}
            className="title-input"
            value={draft}
            aria-label={copy("supermux.harness.header.rename")}
            title={`${copy("supermux.harness.header.renameSave")} ⏎ · ${copy(
              "supermux.harness.header.renameCancel"
            )} Esc`}
            onChange={(event) => setDraft(event.target.value)}
            onBlur={() => setEditing(false)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                const next = draft.trim();
                if (next) props.onRename(next);
                setEditing(false);
              } else if (event.key === "Escape") {
                event.preventDefault();
                setEditing(false);
              }
            }}
          />
        ) : (
          <button
            type="button"
            className="title-btn"
            onClick={() => {
              setDraft(title);
              setEditing(true);
            }}
            title={copy("supermux.harness.header.rename")}
          >
            <span className="title-text">{title}</span>
          </button>
        )}
        {props.workingDirectory ? (
          <span className="dir-chip mono" title={props.workingDirectory}>
            <Folder size={12} />
            <span className="dir-chip-text">{displayDirectory(props.workingDirectory)}</span>
          </span>
        ) : null}
      </div>

      <div className="header-right">
        {props.degraded ? null : (
          <>
        {props.usage.costUsd > 0 ? (
          <span className="cost-badge tnum" title={copy("supermux.harness.header.cost")}>
            {formatCost(props.usage.costUsd)}
          </span>
        ) : null}

        <ContextRing usage={props.contextUsage} />

        <Menu
          label={copy("supermux.harness.header.permissionMode")}
          trigger={() => (
            /* Text-only, like Cursor's "Auto-edit ⌄": the mode's own hue names
               it, and a shield glyph beside a folder glyph beside a ring beside
               a history glyph was four different icon weights on one 30px line. */
            <span className={`mode-pill is-${session.permissionMode}`}>
              <span className="pill-label">{modeLabel(session.permissionMode, copy, true)}</span>
              <ChevronDown size={9} />
            </span>
          )}
        >
          {(close) => (
            <MenuSection title={copy("supermux.harness.header.permissionMode")}>
              {MODES.map((mode) => (
                <MenuItem
                  key={mode}
                  role="menuitemradio"
                  active={mode === session.permissionMode}
                  icon={<span className={`mode-dot is-${mode}`} />}
                  onClick={() => {
                    props.onSetPermissionMode(mode);
                    close();
                  }}
                >
                  {modeLabel(mode, copy)}
                </MenuItem>
              ))}
            </MenuSection>
          )}
        </Menu>

          </>
        )}

        <Menu
          label={copy("supermux.harness.header.sessions")}
          className="menu-sessions"
          trigger={() => (
            <span className="icon-pill">
              <History size={12} />
            </span>
          )}
        >
          {(close) => (
            <div className="sessions-pop" onFocus={props.onLoadSessions}>
              <input
                className="sessions-search"
                placeholder={copy("supermux.harness.header.sessionsSearch")}
                value={sessionQuery}
                onChange={(event) => setSessionQuery(event.target.value)}
              />
              {filtered.length === 0 ? (
                <div className="menu-empty">{copy("supermux.harness.header.sessionsEmpty")}</div>
              ) : (
                <ul className="sessions-list">
                  {filtered.slice(0, 24).map((item) => (
                    <li key={item.sessionId} className="session-row">
                      <div className="session-info">
                        <span className="session-title">{item.title}</span>
                        <span className="session-meta tnum">
                          {formatRelativeTime(item.updatedAtMs, copy)}
                          {item.gitBranch ? ` · ${item.gitBranch}` : ""}
                          {item.messageCount ? ` · ${item.messageCount} msgs` : ""}
                        </span>
                      </div>
                      <div className="session-actions">
                        <button
                          type="button"
                          className="btn btn-tiny"
                          title={copy("supermux.harness.header.resumeHint")}
                          onClick={() => {
                            props.onResumeSession(item.sessionId, false);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.resume")}
                        </button>
                        <button
                          type="button"
                          className="btn btn-tiny btn-ghost"
                          title={copy("supermux.harness.header.forkHint")}
                          onClick={() => {
                            props.onResumeSession(item.sessionId, true);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.fork")}
                        </button>
                        {/* One live process per pane is by design, so "run two
                            sessions at once" has to be a visible affordance
                            rather than something a user has to infer. */}
                        <button
                          type="button"
                          className="btn btn-tiny btn-ghost"
                          title={copy("supermux.harness.header.openInNewPaneHint")}
                          onClick={() => {
                            props.onOpenSessionInNewPane(item.sessionId);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.openInNewPane")}
                        </button>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </Menu>

        <Menu
          label={copy("supermux.harness.header.more")}
          trigger={() => (
            <span className="icon-pill">
              <More size={12} />
            </span>
          )}
        >
          {(close) => (
            <MenuSection>
              <MenuItem
                icon={<Plus size={12} />}
                onClick={() => {
                  props.onNewSession();
                  close();
                }}
              >
                {copy("supermux.harness.header.newSession")}
              </MenuItem>
              <MenuItem
                icon={<Scissors size={12} />}
                onClick={() => {
                  props.onCompact();
                  close();
                }}
              >
                {copy("supermux.harness.header.compact")}
              </MenuItem>
              <MenuItem
                icon={<History size={12} />}
                onClick={() => {
                  props.onExport();
                  close();
                }}
              >
                {copy("supermux.harness.header.export")}
              </MenuItem>
              <MenuItem
                icon={<Terminal size={12} />}
                onClick={() => {
                  props.onOpenTerminal();
                  close();
                }}
              >
                {copy("supermux.harness.header.openTerminal")}
              </MenuItem>
              <MenuItem
                icon={<Bolt size={12} />}
                onClick={() => {
                  // Focus back to the More trigger BEFORE the dialog mounts: the
                  // dialog captures whatever holds focus so it can return it on
                  // close, and this row is about to unmount with the popover.
                  // Without the handover the dialog captures a detached node and
                  // closing it drops focus onto <body>.
                  close(true);
                  props.onOpenBinarySettings();
                }}
              >
                {copy("supermux.harness.header.binary")}
              </MenuItem>
              <MenuItem
                danger
                icon={<Trash size={12} />}
                onClick={() => {
                  props.onClear();
                  close();
                }}
              >
                {copy("supermux.harness.header.clear")}
              </MenuItem>
            </MenuSection>
          )}
        </Menu>
      </div>
    </header>
  );
}
