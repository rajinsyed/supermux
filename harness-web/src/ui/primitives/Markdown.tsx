import { memo, useMemo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { CodeBlock } from "./CodeBlock";

interface MarkdownProps {
  text: string;
  streaming?: boolean;
  className?: string;
}

const ALLOWED_PROTOCOL = /^(https?:|mailto:|#|\/)/i;

function safeHref(href: string | undefined): string | undefined {
  if (!href) return undefined;
  return ALLOWED_PROTOCOL.test(href.trim()) ? href : undefined;
}

export const Markdown = memo(function Markdown({ text, streaming, className }: MarkdownProps) {
  const components = useMemo(
    () => ({
      a({ href, children }: { href?: string; children?: React.ReactNode }) {
        const safe = safeHref(href);
        if (!safe) return <span>{children}</span>;
        return (
          <a href={safe} target="_blank" rel="noreferrer noopener">
            {children}
          </a>
        );
      },
      code({
        className: codeClass,
        children
      }: {
        className?: string;
        children?: React.ReactNode;
      }) {
        const raw = String(children ?? "");
        const language = /language-(\w[\w+-]*)/.exec(codeClass ?? "")?.[1];
        if (!language && !raw.includes("\n")) {
          return <code className="inline-code">{raw.replace(/\n$/, "")}</code>;
        }
        return <CodeBlock code={raw} language={language} streaming={streaming} />;
      },
      pre({ children }: { children?: React.ReactNode }) {
        return <>{children}</>;
      },
      table({ children }: { children?: React.ReactNode }) {
        return (
          <div className="md-table-wrap">
            <table>{children}</table>
          </div>
        );
      },
      img({ alt }: { alt?: string }) {
        return <span className="md-image-placeholder">{alt ?? "image"}</span>;
      }
    }),
    [streaming]
  );

  return (
    <div className={`md${className ? ` ${className}` : ""}`}>
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components} skipHtml>
        {text}
      </ReactMarkdown>
    </div>
  );
});
