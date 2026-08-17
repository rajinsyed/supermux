import type { CliStatus, SessionSummary } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, ArrowUp, Folder, History, Refresh } from "../Icons";
import { displayDirectory, formatRelativeTime } from "../format";

function ClaudeMark() {
  return (
    <span className="claude-mark" aria-hidden="true">
      <svg viewBox="0 0 32 32" width="30" height="30">
        <path
          d="M16 3.2 27.4 9.6v12.8L16 28.8 4.6 22.4V9.6Z"
          fill="none"
          stroke="var(--claude-strong)"
          strokeWidth="1.4"
          strokeLinejoin="round"
        />
        <path
          d="M16 10.4 21.6 13.6v6.4L16 23.2l-5.6-3.2v-6.4Z"
          fill="var(--claude-soft)"
          stroke="var(--claude-strong)"
          strokeWidth="1.2"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  );
}

export function EmptyState({
  workingDirectory,
  modelName,
  sessions,
  onSuggestion,
  onResume
}: {
  workingDirectory?: string;
  modelName?: string;
  sessions: SessionSummary[];
  onSuggestion: (text: string) => void;
  onResume: (sessionId: string) => void;
}) {
  const copy = useCopy();
  const suggestions = [
    copy("supermux.harness.empty.suggestion1"),
    copy("supermux.harness.empty.suggestion2"),
    copy("supermux.harness.empty.suggestion3")
  ];

  return (
    <div className="empty">
      <ClaudeMark />
      <h2 className="empty-headline">{copy("supermux.harness.empty.headline")}</h2>
      <p className="empty-sub">{copy("supermux.harness.empty.subhead")}</p>

      <div className="empty-meta">
        {workingDirectory ? (
          <span className="dir-chip mono" title={workingDirectory}>
            <Folder size={11} />
            <span className="dir-chip-text">{displayDirectory(workingDirectory)}</span>
          </span>
        ) : null}
        <span className={`empty-model${modelName ? "" : " is-pending"}`}>
          {modelName ?? copy("supermux.harness.empty.detectingModel")}
        </span>
      </div>

      <div className="empty-suggestions">
        <div className="empty-label">{copy("supermux.harness.empty.suggestionsTitle")}</div>
        {suggestions.map((suggestion) => (
          <button
            key={suggestion}
            type="button"
            className="suggestion"
            onClick={() => onSuggestion(suggestion)}
          >
            <span>{suggestion}</span>
            <ArrowUp size={12} className="suggestion-arrow" />
          </button>
        ))}
      </div>

      {sessions.length > 0 ? (
        <div className="empty-sessions">
          <div className="empty-label">
            <History size={11} />
            {copy("supermux.harness.empty.recentSessions")}
          </div>
          {sessions.slice(0, 4).map((session) => (
            <button
              key={session.sessionId}
              type="button"
              className="recent-session"
              onClick={() => onResume(session.sessionId)}
            >
              <span className="recent-title">{session.title}</span>
              <span className="recent-meta tnum">
                {formatRelativeTime(session.updatedAtMs)}
                {session.gitBranch ? ` · ${session.gitBranch}` : ""}
              </span>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function NoCliState({ status, onRetry }: { status: CliStatus; onRetry: () => void }) {
  const copy = useCopy();
  return (
    <div className="empty is-error">
      <span className="empty-icon-warn">
        <AlertTriangle size={22} />
      </span>
      <h2 className="empty-headline">{copy("supermux.harness.nocli.headline")}</h2>
      <p className="empty-sub">{copy("supermux.harness.nocli.body")}</p>
      <pre className="install-cmd mono">{copy("supermux.harness.nocli.install")}</pre>
      {status.error ? <p className="empty-error mono">{status.error}</p> : null}
      <p className="empty-note">{copy("supermux.harness.nocli.searchedPath")}</p>
      <div className="empty-actions">
        <button type="button" className="btn btn-primary" onClick={onRetry}>
          <Refresh size={12} />
          {copy("supermux.harness.nocli.retry")}
        </button>
        <a
          className="btn btn-ghost"
          href="https://docs.claude.com/en/docs/claude-code/setup"
          target="_blank"
          rel="noreferrer noopener"
        >
          {copy("supermux.harness.nocli.docs")}
        </a>
      </div>
    </div>
  );
}

export function ExitedState({ error, onRestart }: { error?: string; onRestart: () => void }) {
  const copy = useCopy();
  return (
    <div className="exited-state">
      <span className="exited-icon">
        <AlertTriangle size={14} />
      </span>
      <div>
        <div className="exited-title">{copy("supermux.harness.exited.headline")}</div>
        <div className="exited-body">{error ?? copy("supermux.harness.exited.body")}</div>
      </div>
      <button type="button" className="btn btn-tiny" onClick={onRestart}>
        <Refresh size={11} />
        {copy("supermux.harness.exited.restart")}
      </button>
    </div>
  );
}
