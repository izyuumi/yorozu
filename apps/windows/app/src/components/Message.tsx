import { command, type Item } from "../api";
import { strings } from "../strings";
import { TextMessage } from "./shared/ClientUI";
export function Message({ item, convId, act }: { item: Item; convId: string; act: (task: Promise<void>) => void }) {
  if (item.kind === "reset") return <li className="session-divider">{strings.newSession}</li>;
  if (item.kind === "tools") return <li className="tools"><ul>{item.tools.map(tool => <li key={tool.callId}>{tool.name}: {tool.status}</li>)}</ul></li>;
  const mark = item.mark;
  return <TextMessage kind={item.kind} text={item.text}>
    {mark && <div className="mark">{mark.state === "failed" ? <>
      <span>Not delivered: {mark.reason}</span>{" "}<button onClick={() => act(command("retry_message", { convId, messageId: item.id }))}>{strings.retry}</button>
    </> : <span aria-label={mark.state}>{mark.state === "sent" ? "✓" : mark.state === "delivered" ? "✓✓" : mark.state === "read" ? strings.read : ""}</span>}</div>}
    {item.runFailed && <p role="status">{strings.runFailed}</p>}
  </TextMessage>;
}
