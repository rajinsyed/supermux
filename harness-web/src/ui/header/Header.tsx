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
import {
  Bolt,
  ChevronDown,
  Folder,
  History,
  More,
  Plus,
  Scissors,
  Shield,
  Terminal,
  Trash
} from "../Icons";
import { displayDirectory, formatCost, formatRelativeTime } from "../format";
import { ContextRing } from "./ContextRing";
import { Menu, MenuItem, MenuSection } from "./Menu";

const MODES: PermissionMode[] = ["default", "acceptEdits", "plan", "bypassPermissions"];

/**
 * Effort is a per-model capability, so it cannot travel across a model switch
 * unchanged: sending `max` to a model that tops out at `high` makes the CLI
 * reject it while the pill keeps advertising a setting that does not exist.
 */
export function clampEffort(
  model: ModelDescriptor | undefined,
  effort: EffortLevel | undefined
): EffortLevel | undefined {
  if (!effort || !model?.supportsEffort) return undefined;
  const levels = model.supportedEffortLevels;
  if (!levels || levels.length === 0) return undefined;
  return levels.includes(effort) ? effort : undefined;
}

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
  onRename(title: string): void;
  onSetModel(model: string, effort?: EffortLevel): void;
  onSetPermissionMode(mode: PermissionMode): void;
  onResumeSession(sessionId: string, fork: boolean): void;
  onLoadSessions(): void;
  onCompact(): void;
  onClear(): void;
  onExport(): void;
  onOpenTerminal(): void;
  onNewSession(): void;
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
  const activeModel = session.models.find((m) => m.value === session.model);
  const modelName = activeModel?.displayName ?? session.model ?? copy("supermux.harness.header.model");
  // The chip must never outlive the capability it describes: a model that has no
  // effort levels shows no effort tag, whatever the session last carried.
  const effort = clampEffort(activeModel, session.effort);

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
            <Folder size={11} />
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
            <span className={`mode-pill is-${session.permissionMode}`}>
              <Shield size={11} />
              <span className="pill-label">{modeLabel(session.permissionMode, copy, true)}</span>
              <ChevronDown size={10} />
            </span>
          )}
        >
          {(close) => (
            <MenuSection title={copy("supermux.harness.header.permissionMode")}>
              {MODES.map((mode) => (
                <MenuItem
                  key={mode}
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

        <Menu
          label={copy("supermux.harness.header.model")}
          trigger={() => (
            <span className="model-pill">
              <Bolt size={11} />
              <span className="pill-label">{modelName}</span>
              {effort ? <span className="effort-tag">{effort}</span> : null}
              <ChevronDown size={10} />
            </span>
          )}
        >
          {(close) => (
            <>
              <MenuSection title={copy("supermux.harness.header.model")}>
                {session.models.length === 0 ? (
                  <div className="menu-empty">{session.model ?? "—"}</div>
                ) : (
                  session.models.map((model) => (
                    <MenuItem
                      key={model.value}
                      active={model.value === session.model}
                      detail={model.description}
                      onClick={() => {
                        props.onSetModel(model.value, clampEffort(model, session.effort));
                        close();
                      }}
                    >
                      {model.displayName}
                    </MenuItem>
                  ))
                )}
              </MenuSection>
              {activeModel?.supportsEffort && activeModel.supportedEffortLevels?.length ? (
                <MenuSection title={copy("supermux.harness.header.effort")}>
                  {activeModel.supportedEffortLevels.map((level) => (
                    <MenuItem
                      key={level}
                      active={level === effort}
                      badge={
                        level === activeModel.defaultEffortLevel
                          ? copy("supermux.harness.header.effortDefault")
                          : undefined
                      }
                      onClick={() => {
                        props.onSetModel(session.model ?? activeModel.value, level);
                        close();
                      }}
                    >
                      {level}
                    </MenuItem>
                  ))}
                </MenuSection>
              ) : null}
            </>
          )}
        </Menu>

          </>
        )}

        <Menu
          label={copy("supermux.harness.header.sessions")}
          className="menu-sessions"
          trigger={() => (
            <span className="icon-pill">
              <History size={13} />
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
                          onClick={() => {
                            props.onResumeSession(item.sessionId, true);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.fork")}
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
              <More size={13} />
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
