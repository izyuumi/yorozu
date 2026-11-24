import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { ComposerFields, FingerprintConfirmation, ForgetAction, PairLinkForm, TextMessage }
  from '../../../windows/app/src/components/shared/ClientUI';

export function mountUI() {
  const node = (id) => document.getElementById(id);
  const mount = (id, child) => createRoot(node(id)).render(child);
  flushSync(() => {
    mount('pair-fields', <PairLinkForm webTouch formId="pair-form" inputId="pair-link"
      continuationId="continue" errorId="pair-error" label="Pairing link" rows={1} continueLabel="Continue"
      hint={<p id="pair-hint" />}
      extras={<label><input id="remember" type="checkbox" defaultChecked /> Remember this browser</label>}
      error={<p id="pair-error" role="alert" hidden />} />);
    mount('pair-confirmation', <FingerprintConfirmation hidden id="confirm" headingId="confirm-heading"
      fingerprintId="fingerprint" pairId="pair-now" cancelId="cancel" confirmLabel="Pair"
      details={<p>Check that this key matches the fingerprint shown with the pairing link.</p>}
      footer={<p>Yorozu can keep up to 16 paired devices. If it is full, pairing removes the oldest device.</p>} />);
    mount('chat-composer', <ComposerFields wide disabled rows={2} formId="composer" buttonId="send"
      label="Message" sendLabel="Send" />);
    mount('forget-action', <ForgetAction id="forget" label="Forget this browser" />);
  });
  const transcript = node('messages');
  const root = createRoot(transcript);
  let shown, thread;
  return { renderMessages(items, activeThread) {
    const sameThread = activeThread === thread && shown?.length;
    const previousFirst = shown?.[0]?.id;
    const position = transcript.scrollTop;
    const height = transcript.scrollHeight;
    const following = transcript.scrollHeight - transcript.clientHeight - position < 40;
    const prepended = sameThread && items[0]?.id !== previousFirst && items.some(item => item.id === previousFirst);
    flushSync(() => root.render(items.map((item) => <TextMessage key={item.id} kind={item.kind} text={item.text} />)));
    if (prepended) transcript.scrollTop = position + transcript.scrollHeight - height;
    else if (!sameThread || following) transcript.scrollTop = transcript.scrollHeight;
    shown = items;
    thread = activeThread;
  } };
}
