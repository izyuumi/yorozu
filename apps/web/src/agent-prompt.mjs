// The prompt the home page's "Set up with your AI agent" block shows and copies.
// It stays in English, which agents follow most reliably and which the help server answers in;
// a translated page adds one line asking the agent to reply in the page's language.
export const helpMcpUrl = 'https://yorozu.yumi.to/mcp';
export const setupGuideUrl = 'https://github.com/izyuumi/yorozu/blob/main/docs/setup.md';

export function agentPrompt(language = 'English') {
  const lines = [
    'Help me set up Yorozu, the end-to-end encrypted chat app for my OpenClaw agent on iPhone, iPad and Mac (https://yorozu.yumi.to).',
    '',
    `1. Connect the Yorozu help MCP server at ${helpMcpUrl}. It is read-only and needs no sign-in.`,
    `   - Claude Code: claude mcp add --transport http yorozu-help ${helpMcpUrl}`,
    `   - Other MCP clients: add {"mcpServers": {"yorozu-help": {"url": "${helpMcpUrl}"}}} to the MCP config.`,
    `   If you can't connect an MCP server, read ${setupGuideUrl} instead.`,
    "2. Ask me whether I'm setting up Yorozu on a Mac or on an iPhone or iPad.",
    "3. Walk me through installing and configuring it one step at a time, using the server's get_setup_guide, get_permissions_needed, explain_setting and troubleshoot tools. OpenClaw commands run on the computer that runs my OpenClaw Gateway. Wait for me to confirm each step before the next.",
  ];
  if (language !== 'English') lines.push('', `Reply to me in ${language}.`);
  return lines.join('\n');
}
