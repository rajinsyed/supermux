import { useState } from "react";
import type { SessionMeta, UsageTotals } from "../../model/types";
import type {
  ContextUsage,
  EffortLevel,
  ModelDescriptor,
  PermissionMode,
  SessionSummary
} from "../../protocol/types";
import { useCopy } from "../CopyContext";
import {
  Bolt,
  ChevronDown,
  Download,
  ExternalLink,
  Folder,
  Fork,
  History,
  More,
  Plus,
  Scissors,
  Terminal,
  Trash
} from "../Icons";
import { displayDirectory, formatCost, formatRelativeTime } from "../format";
import { MenuEmpty, MenuItem, MenuSection } from "../primitives/MenuList";
import { Popover } from "../primitives/Popover";
import { ContextRing } from "./ContextRing";

const MODES: PermissionMode[] = ["default", "acceptEdits", "plan", "bypassPermissions"];

/**
 * The model picker lives IN the composer pill (the model is a property of the
 * message you are about to send, not of the session chrome), and its data
 * plumbing moved with it. These three are still re-exported here because they
 * are the header's own vocabulary as much as the picker's — the effort a turn
 * ran at is printed in turn footers, and the menu source is the pane's answer to
 * "what models does this binary have".
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

/** One line per mode saying what it changes — the reason to pick one over another. */
function modeDetail(mode: PermissionMode, copy: ReturnType<typeof useCopy>): string {
  switch (mode) {
    case "acceptEdits":
      return copy("supermux.harness.mode.acceptEditsDetail");
    case "plan":
      return copy("supermux.harness.mode.planDetail");
    case "bypassPermissions":
      return copy("supermux.harness.mode.bypassPermissionsDetail");
    default:
      return copy("supermux.harness.mode.defaultDetail");
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
  /**
   * Still accepted, deliberately unused: the bottom bar no longer carries the
   * session title, so it has no rename affordance to wire. The prop stays on the
   * contract so a rename can come back on a surface that suits it (the sessions
   * panel, a context menu) without another round through App.tsx.
   */
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

  return (
    <header className="header">
      {/* The left is the pane's ADDRESS and nothing else. The session title
          used to sit here as an editable button; it was the widest thing on the
          strip, it named something the user had not chosen (the CLI's own
          auto-title), and clicking it opened a rename field in a bar whose every
          other control opens a menu. The folder is the one identity that
          answers a real question: which checkout is this. */}
      <div className="header-left">
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

            <ModeMenu mode={session.permissionMode} onPick={props.onSetPermissionMode} />
          </>
        )}

        <SessionsMenu
          sessions={props.sessions}
          onLoad={props.onLoadSessions}
          onResume={props.onResumeSession}
          onOpenInNewPane={props.onOpenSessionInNewPane}
          onNewSession={props.onNewSession}
        />

        <Popover
          label={copy("supermux.harness.header.more")}
          className="menu-more"
          popClassName="pop-more"
          trigger={() => (
            <span className="icon-pill">
              <More size={12} />
            </span>
          )}
        >
          {(close) => (
            <>
              <MenuSection>
                <MenuItem
                  selectable={false}
                  icon={<Plus size={12} />}
                  onClick={() => {
                    props.onNewSession();
                    close();
                  }}
                >
                  {copy("supermux.harness.header.newSession")}
                </MenuItem>
                <MenuItem
                  selectable={false}
                  icon={<Scissors size={12} />}
                  onClick={() => {
                    props.onCompact();
                    close();
                  }}
                >
                  {copy("supermux.harness.header.compact")}
                </MenuItem>
              </MenuSection>
              <MenuSection>
                <MenuItem
                  selectable={false}
                  icon={<Download size={12} />}
                  onClick={() => {
                    props.onExport();
                    close();
                  }}
                >
                  {copy("supermux.harness.header.export")}
                </MenuItem>
                <MenuItem
                  selectable={false}
                  icon={<Terminal size={12} />}
                  onClick={() => {
                    props.onOpenTerminal();
                    close();
                  }}
                >
                  {copy("supermux.harness.header.openTerminal")}
                </MenuItem>
                <MenuItem
                  selectable={false}
                  icon={<Bolt size={12} />}
                  onClick={() => {
                    // Focus back to the More trigger BEFORE the dialog mounts:
                    // the dialog captures whatever holds focus so it can return
                    // it on close, and this row is about to unmount with the
                    // popover. Without the handover the dialog captures a
                    // detached node and closing it drops focus onto <body>.
                    close(true);
                    props.onOpenBinarySettings();
                  }}
                >
                  {copy("supermux.harness.header.binary")}
                </MenuItem>
              </MenuSection>
              <MenuSection>
                <MenuItem
                  danger
                  selectable={false}
                  icon={<Trash size={12} />}
                  onClick={() => {
                    props.onClear();
                    close();
                  }}
                >
                  {copy("supermux.harness.header.clear")}
                </MenuItem>
              </MenuSection>
            </>
          )}
        </Popover>
      </div>
    </header>
  );
}

/**
 * The permission mode.
 *
 * Four rows, each a name over one line of consequence, with the mode's own hue
 * carried by a leading bar rather than a dot: the modes differ in how much they
 * let through, and a graded left edge says that at a glance where four identical
 * grey dots said nothing. The trigger stays text-only — the mode's colour names
 * it, and a shield glyph beside a folder glyph beside a ring was four icon
 * weights on one 28px line.
 */
function ModeMenu({
  mode,
  onPick
}: {
  mode: PermissionMode;
  onPick(mode: PermissionMode): void;
}) {
  const copy = useCopy();
  return (
    <Popover
      label={copy("supermux.harness.header.permissionMode")}
      className="menu-modes"
      popClassName="pop-modes"
      autoFocus="checked"
      trigger={() => (
        <span className={`mode-pill is-${mode}`}>
          <span className="pill-label">{modeLabel(mode, copy, true)}</span>
          <ChevronDown size={9} />
        </span>
      )}
    >
      {(close) => (
        <MenuSection title={copy("supermux.harness.header.permissionMode")}>
          {MODES.map((option) => (
            <MenuItem
              key={option}
              role="menuitemradio"
              active={option === mode}
              className={`mode-item is-${option}`}
              detail={modeDetail(option, copy)}
              onClick={() => {
                onPick(option);
                close();
              }}
            >
              {modeLabel(option, copy)}
            </MenuItem>
          ))}
        </MenuSection>
      )}
    </Popover>
  );
}

/**
 * The session browser.
 *
 * One row per session, and the row itself is Resume — the primary action on a
 * list of sessions is "open this one", so it is the row's own click rather than
 * the first of three identical 11px buttons crowding every line. Fork and New
 * pane are secondary and appear on hover/focus as icon buttons at the trailing
 * edge, which is what makes the list read as a list. New session is pinned to
 * the foot, where it does not scroll away behind twenty-four rows.
 *
 * Rebuilt on the kit: the rows are `.ui-menu-item`s in all but name (same 28px
 * line, same 7px radius, same hover bed), the search field is the kit's input,
 * and the foot is the kit's `.ui-menu-foot` — so this panel and the ••• menu
 * beside it are visibly the same object at two widths.
 */
function SessionsMenu({
  sessions,
  onLoad,
  onResume,
  onOpenInNewPane,
  onNewSession
}: {
  sessions: SessionSummary[];
  onLoad(): void;
  onResume(sessionId: string, fork: boolean): void;
  onOpenInNewPane(sessionId: string): void;
  onNewSession(): void;
}) {
  const copy = useCopy();
  const [query, setQuery] = useState("");

  const needle = query.trim().toLowerCase();
  const filtered = sessions.filter((item) =>
    needle.length === 0
      ? true
      : `${item.title} ${item.firstPrompt ?? ""}`.toLowerCase().includes(needle)
  );

  return (
    <Popover
      label={copy("supermux.harness.header.sessions")}
      className="menu-sessions"
      popClassName="pop-sessions"
      onOpen={onLoad}
      trigger={() => (
        <span className="icon-pill">
          <History size={12} />
        </span>
      )}
    >
      {(close) => (
        <>
          {/* The search earns its row here in a way the model menu's did not:
              a folder accumulates hundreds of sessions and the list is capped
              at 24, so without it the older ones are simply unreachable. */}
          <div className="sessions-head">
            <input
              className="ui-menu-input"
              placeholder={copy("supermux.harness.header.sessionsSearch")}
              aria-label={copy("supermux.harness.header.sessionsSearch")}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>

          {filtered.length === 0 ? (
            <MenuEmpty>{copy("supermux.harness.header.sessionsEmpty")}</MenuEmpty>
          ) : (
            <ul className="sessions-list">
              {filtered.slice(0, 24).map((item) => (
                <li key={item.sessionId} className="session-row">
                  <button
                    type="button"
                    className="session-open"
                    role="menuitem"
                    title={copy("supermux.harness.header.resumeHint")}
                    onClick={() => {
                      onResume(item.sessionId, false);
                      close();
                    }}
                  >
                    <span className="session-title">
                      {item.title || copy("supermux.harness.app.untitledSession")}
                    </span>
                    <span className="session-meta tnum">
                      {formatRelativeTime(item.updatedAtMs, copy)}
                      {item.gitBranch ? ` · ${item.gitBranch}` : ""}
                      {item.messageCount
                        ? ` · ${copy("supermux.harness.header.sessionMessages", {
                            count: item.messageCount
                          })}`
                        : ""}
                    </span>
                  </button>
                  {/* Hover/focus-revealed, so twenty rows are twenty titles
                      rather than sixty buttons. They stay in the tab order —
                      :focus-within on the row is what brings them back. */}
                  <div className="session-actions">
                    <button
                      type="button"
                      className="session-action"
                      title={copy("supermux.harness.header.forkHint")}
                      aria-label={copy("supermux.harness.header.fork")}
                      onClick={() => {
                        onResume(item.sessionId, true);
                        close();
                      }}
                    >
                      <Fork size={12} />
                    </button>
                    {/* One live process per pane is by design, so "run two
                        sessions at once" has to be a visible affordance rather
                        than something a user has to infer. */}
                    <button
                      type="button"
                      className="session-action"
                      title={copy("supermux.harness.header.openInNewPaneHint")}
                      aria-label={copy("supermux.harness.header.openInNewPane")}
                      onClick={() => {
                        onOpenInNewPane(item.sessionId);
                        close();
                      }}
                    >
                      <ExternalLink size={12} />
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}

          {/* The kit's footer, carrying the one action that must not scroll
              away. The old build printed a "Resume" legend beside it explaining
              that the row's own click resumes; the row now carries that as its
              title, and the foot is one action rather than an action plus a
              caption about a different one. */}
          <div className="ui-menu-foot">
            <button
              type="button"
              className="sessions-new"
              role="menuitem"
              onClick={() => {
                onNewSession();
                close();
              }}
            >
              <Plus size={12} />
              {copy("supermux.harness.header.newSession")}
            </button>
          </div>
        </>
      )}
    </Popover>
  );
}
