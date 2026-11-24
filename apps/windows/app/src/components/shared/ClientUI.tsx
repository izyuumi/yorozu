import type { ChangeEvent, ClipboardEvent, FormEvent, ReactNode } from "react";

type PairBoxProps = {
  formId?: string; inputId: string; continuationId?: string; errorId?: string;
  label: ReactNode; hint?: ReactNode; extras?: ReactNode; error?: ReactNode;
  value?: string; onChange?: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onPaste?: (event: ClipboardEvent<HTMLTextAreaElement>) => void;
  onContinue?: (event: FormEvent<HTMLFormElement>) => void; continueLabel: string;
  disabled?: boolean; webTouch?: boolean; rows: number;
};

export function PairLinkForm(props: PairBoxProps) {
  return <form id={props.formId} noValidate onSubmit={props.onContinue}>
    <label htmlFor={props.inputId}>{props.label}</label>
    {props.hint}
    <textarea id={props.inputId} rows={props.rows} spellCheck={false} autoComplete="off" autoCapitalize="none"
      inputMode={props.webTouch ? "url" : undefined} maxLength={props.webTouch ? 8192 : undefined}
      aria-describedby={props.errorId} value={props.value} onChange={props.onChange} onPaste={props.onPaste} />
    {props.extras}
    {props.error}
    <button id={props.continuationId} type={props.webTouch ? "button" : "submit"} disabled={props.disabled}>{props.continueLabel}</button>
  </form>;
}

type FingerprintProps = {
  id?: string; headingId?: string; fingerprintId?: string; pairId?: string; cancelId?: string;
  heading?: string; details?: ReactNode; fingerprint?: string; footer?: ReactNode; hidden?: boolean;
  confirmLabel: string; onPair?: () => void; onCancel?: () => void; disabled?: boolean;
};

export function FingerprintConfirmation(props: FingerprintProps) {
  return <div id={props.id} hidden={props.hidden}>
    <h2 id={props.headingId} tabIndex={-1}>{props.heading ?? "Confirm host fingerprint"}</h2>
    {props.details}
    <code id={props.fingerprintId}>{props.fingerprint}</code>
    {props.footer}
    <button id={props.pairId} type="button" disabled={props.disabled} onClick={props.onPair}>{props.confirmLabel}</button>
    <button id={props.cancelId} type="button" onClick={props.onCancel}>Cancel</button>
  </div>;
}

type ComposerProps = {
  formId?: string; buttonId?: string; label: string; sendLabel: string; wide?: boolean;
  value?: string; onChange?: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onSubmit?: (event: FormEvent<HTMLFormElement>) => void; disabled: boolean; rows: number; limit?: string;
};

export function ComposerFields(props: ComposerProps) {
  return <form id={props.formId} className="composer" onSubmit={props.onSubmit}>
    <label htmlFor="message">{props.label}</label>
    <textarea id="message" rows={props.rows} value={props.value} aria-invalid={!!props.limit}
      aria-describedby={props.limit ? "message-limit" : undefined} onChange={props.onChange}
      maxLength={props.wide ? 60_000 : undefined} required={props.wide}
      onKeyDown={e => {
        if (e.key === "Enter" && e.ctrlKey && !e.nativeEvent.isComposing) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); }
      }} />
    {props.limit && <p id="message-limit" role="alert">{props.limit}</p>}
    <button id={props.buttonId} disabled={props.disabled} type="submit" aria-label={props.sendLabel}>
      {props.wide ? "↑" : props.sendLabel}
    </button>
  </form>;
}

export function TextMessage({ kind, text, children }: { kind: "user" | "agent"; text: string; children?: ReactNode }) {
  return <li className={`message ${kind}`}>
    <span className="speaker">{kind === "user" ? "You" : "Yorozu"}</span>
    <p>{text}</p>
    {children}
  </li>;
}

export function ForgetAction({ id, label, onForget }: { id?: string; label: string; onForget?: () => void }) {
  return <button id={id} type="button" onClick={onForget}>{label}</button>;
}
