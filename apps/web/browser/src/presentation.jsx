import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { PairingMethods } from '../../../windows/app/src/components/shared/PairingQr';
import { ChatHeader, ClientIcon, ComposerFields, FingerprintConfirmation, ForgetAction, PairLinkForm, TextMessage, fitComposer }
  from '../../../windows/app/src/components/shared/ClientUI';

export function mountUI() {
  const node = (id) => document.getElementById(id);
  const mount = (id, child) => createRoot(node(id)).render(child);
  flushSync(() => {
    mount('pair-fields', <PairLinkForm webTouch formId="pair-form" inputId="pair-link"
      continuationId="continue" errorId="pair-error" label="Pairing link" rows={1} continueLabel="Continue"
      heading="Connect to your Mac" description="Open your invitation link in this browser, or paste it below."
      placeholder="Paste an invitation link"
      hint={<p id="pair-hint" role="status" />}
      extras={<label className="remember-choice"><input id="remember" type="checkbox" defaultChecked /> Remember this browser</label>}
      help={<details className="pair-help"><summary>Need a pairing link?</summary><p>On your Mac, run:</p><code>openclaw yorozu pair-browser</code></details>}
      error={<p id="pair-error" role="alert" hidden />} />);
    mount('pair-confirmation', <FingerprintConfirmation hidden id="confirm" headingId="confirm-heading"
      fingerprintId="fingerprint" pairId="pair-now" cancelId="cancel" confirmLabel="Pair"
      details={<p>Compare this code with the fingerprint shown on your Mac. Only pair if they match.</p>}
      footer={<><p className="help">If your Mac already has 16 paired devices, this replaces the oldest pairing.</p><p id="pair-progress" role="status" hidden /></>} />);
    mount('chat-header', <ChatHeader title="New chat" titleId="chat-title"
      navigation={<button id="chats-button" className="icon-button" type="button" aria-controls="mobile-chats" aria-haspopup="dialog" aria-label="Show chats">
        <ClientIcon name="chats" />
      </button>}
      status={<p id="connection" role="status" />}
      actions={<button id="settings-button" className="icon-button" aria-haspopup="dialog" type="button" aria-label="Settings" title="Settings">
        <ClientIcon name="settings" />
      </button>} />);
    mount('chat-composer', <ComposerFields wide disabled rows={1} formId="composer" buttonId="send"
      label="Message" sendLabel="Send" />);
    mount('forget-action', <ForgetAction id="forget" label="Forget this browser" />);
  });
  const methods = createRoot(node('pair-methods'));
  const transcript = node('timeline');
  const messages = node('messages');
  const root = createRoot(messages);
  let shown, thread;
  return { renderPairMethods(props) { methods.render(<PairingMethods {...props} />); }, captureScroll() {
    const position = transcript.scrollTop;
    const top = transcript.getBoundingClientRect().top;
    const anchor = Array.from(messages.children).find(el => el.getBoundingClientRect().bottom > top);
    return { position, follows: transcript.scrollHeight - transcript.clientHeight - position < 40,
      id: anchor?.dataset.messageAnchor, offset: anchor && anchor.getBoundingClientRect().top - top };
  }, renderMessages(items, activeThread, updateControls = () => {}, previousScroll) {
    const changingThread = activeThread !== thread;
    const sameThread = !changingThread && shown?.length;
    const previousFirst = shown?.[0]?.id;
    const position = transcript.scrollTop;
    const height = transcript.scrollHeight;
    const following = height - transcript.clientHeight - position < 40;
    const prepended = sameThread && items[0]?.id !== previousFirst && items.some(item => item.id === previousFirst);
    const top = transcript.getBoundingClientRect().top;
    const anchor = prepended && Array.from(messages.children).find(el => el.getBoundingClientRect().bottom > top);
    const anchorTop = anchor && anchor.getBoundingClientRect().top;
    flushSync(() => root.render(items.map((item) => <TextMessage key={item.id} itemId={item.id} kind={item.kind} text={item.text} />)));
    updateControls();
    if (prepended) transcript.scrollTop = position + (anchor ? anchor.getBoundingClientRect().top - anchorTop : transcript.scrollHeight - height);
    else if (changingThread && previousScroll && !previousScroll.follows) {
      const restored = Array.from(messages.children).find(el => el.dataset.messageAnchor === previousScroll.id);
      transcript.scrollTop = restored
        ? transcript.scrollTop + restored.getBoundingClientRect().top - top - previousScroll.offset
        : previousScroll.position;
    } else if (!sameThread || following) transcript.scrollTop = transcript.scrollHeight;
    shown = items;
    thread = activeThread;
  }, fitMessage() { fitComposer(node('message')); } };
}
