import type { ChangeEvent, ClipboardEvent, FormEvent, ReactNode } from "react";

type PairBoxProps = {
  formId?: string; inputId: string; continuationId?: string; errorId?: string;
  label: ReactNode; heading?: string; description?: string; hint?: ReactNode; extras?: ReactNode;
  help?: ReactNode; error?: ReactNode; value?: string; placeholder?: string;
  onChange?: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onPaste?: (event: ClipboardEvent<HTMLTextAreaElement>) => void;
  onContinue?: (event: FormEvent<HTMLFormElement>) => void; continueLabel: string;
  disabled?: boolean; webTouch?: boolean; rows: number;
};

export function PairLinkForm(props: PairBoxProps) {
  return <form className="pair-fields" id={props.formId} noValidate onSubmit={props.onContinue}>
    {props.heading && <><div className="step-label">Step 1 of 2</div><h1>{props.heading}</h1><p className="pair-description">{props.description}</p></>}
    {props.hint}
    <label className="field-label" htmlFor={props.inputId}>{props.label}</label>
    <textarea id={props.inputId} rows={props.rows} spellCheck={false} autoComplete="off" autoCapitalize="none"
      inputMode={props.webTouch ? "url" : undefined} maxLength={props.webTouch ? 8192 : undefined}
      aria-describedby={props.errorId} placeholder={props.placeholder} value={props.value} onChange={props.onChange} onPaste={props.onPaste} />
    {props.error}
    {props.extras}
    <button className="primary-button pair-primary" id={props.continuationId} type={props.webTouch ? "button" : "submit"} disabled={props.disabled}>{props.continueLabel}</button>
    {props.help}
  </form>;
}

type FingerprintProps = {
  id?: string; headingId?: string; fingerprintId?: string; pairId?: string; cancelId?: string;
  heading?: string; details?: ReactNode; fingerprint?: string; footer?: ReactNode; hidden?: boolean;
  confirmLabel: string; onPair?: () => void; onCancel?: () => void; disabled?: boolean;
};

export function FingerprintConfirmation(props: FingerprintProps) {
  return <div className="fingerprint-step" id={props.id} hidden={props.hidden}>
    <div className="step-label">Step 2 of 2</div>
    <h1 id={props.headingId} tabIndex={-1}>{props.heading ?? "Confirm host fingerprint"}</h1>
    {props.details}
    <code className="fingerprint" id={props.fingerprintId}>{props.fingerprint}</code>
    {props.footer}
    <div className="pair-actions">
      <button id={props.cancelId} type="button" onClick={props.onCancel}>Cancel</button>
      <button className="primary-button" id={props.pairId} type="button" disabled={props.disabled} onClick={props.onPair}>{props.confirmLabel}</button>
    </div>
  </div>;
}

export function ClientIcon({ name }: { name: "chats" | "settings" }) {
  return <svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
    strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
    {name === "chats" ? <path d="M4 6h16M4 12h16M4 18h16" /> : <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 2v3m0 14v3M2 12h3m14 0h3M5 5l2.1 2.1m9.8 9.8L19 19m0-14-2.1 2.1m-9.8 9.8L5 19" /><circle cx="12" cy="12" r="7" />
    </>}
  </svg>;
}

export function ChatHeader({ title, titleId, navigation, status, actions }: {
  title: string; titleId?: string; navigation?: ReactNode; status?: ReactNode; actions?: ReactNode;
}) {
  return <header className="chat-heading">
    {navigation}
    <div className="chat-heading-copy"><h1 id={titleId}>{title}</h1>{status}</div>
    {actions}
  </header>;
}

type ComposerProps = {
  formId?: string; buttonId?: string; label: string; sendLabel: string; wide?: boolean;
  value?: string; onChange?: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onSubmit?: (event: FormEvent<HTMLFormElement>) => void; disabled: boolean; rows: number; limit?: string;
};

export function fitComposer(field: HTMLTextAreaElement | null) {
  if (!field) return;
  field.style.height = "auto";
  field.style.height = `${field.scrollHeight}px`;
}

export function ComposerFields(props: ComposerProps) {
  return <form id={props.formId} className="composer" onSubmit={props.onSubmit}>
    <label className="visually-hidden" htmlFor="message">{props.label}</label>
    <textarea id="message" placeholder="Write a message…" rows={props.rows} ref={fitComposer}
      value={props.value} aria-invalid={!!props.limit}
      aria-describedby={props.limit ? "message-limit" : undefined}
      onChange={event => { fitComposer(event.currentTarget); props.onChange?.(event); }}
      maxLength={props.wide ? 60_000 : undefined} required={props.wide}
      onKeyDown={e => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && !e.nativeEvent.isComposing) {
          e.preventDefault();
          e.currentTarget.form?.requestSubmit();
        }
      }} />
    <button className="primary-button send-button" id={props.buttonId} disabled={props.disabled} type="submit" aria-label={props.sendLabel} title={props.sendLabel}>
      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 19V5m-6 6 6-6 6 6" /></svg>
    </button>
    {props.limit && <p id="message-limit" className="composer-limit" role="alert">{props.limit}</p>}
  </form>;
}

export function TextMessage({ kind, text, itemId, children }: { kind: "user" | "agent"; text: string; itemId?: string; children?: ReactNode }) {
  return <li className={`message ${kind}`} data-message-anchor={itemId}>
    <span className="speaker">{kind === "user" ? "You" : "Yorozu"}</span>
    <p>{text}</p>
    {children}
  </li>;
}

export function ForgetAction({ id, label, onForget }: { id?: string; label: string; onForget?: () => void }) {
  return <button className="danger-button" id={id} type="button" onClick={onForget}>{label}</button>;
}
