// English, the source text. "@/page/" links point at that page in the reader's language.
export default {
  name: 'Yorozu',
  skip: 'Skip to content',
  nav: { primary: 'Primary', footer: 'Footer', language: 'Language', home: 'Home', support: 'Support', privacy: 'Privacy', terms: 'Terms', getApp: 'Get the app' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. Yorozu is not affiliated with OpenClaw, Nous Research (Hermes Agent), Cua (CuaDriver), Anthropic or OpenAI.',
  },
  governs: null,
  home: {
    title: 'Yorozu — A native chat app for your OpenClaw agent',
    description: 'Yorozu is a native iPhone, iPad and Mac app for chatting with your own OpenClaw agent, end-to-end encrypted through a relay that cannot read your messages.',
    og: {
      title: 'Yorozu',
      description: 'A native chat app for your own OpenClaw agent, on iPhone, iPad and Mac. End-to-end encrypted.',
      imageAlt: 'The Yorozu app icon beside the words: Your OpenClaw agent, anywhere.',
    },
    hero: 'Your OpenClaw agent.<br><em>In your pocket.</em>',
    lede: 'Yorozu <span class="kana" lang="ja">(よろず)</span> is a native chat app for the <a href="https://docs.openclaw.ai/install">OpenClaw</a> agent you already run. Its plugin makes Yorozu a channel of your Gateway, like Signal or Telegram, and the app on your iPhone, iPad or Mac talks to it end-to-end encrypted. OpenClaw runs the agent, its memory and its schedules; Yorozu carries the conversation.',
    appStore: 'Get Yorozu on the App Store',
    downloadMac: 'Download for Mac',
    setUpPlugin: 'Set up the plugin',
    fine: 'Mac: Yorozu 0.10, macOS 15 or later · iPhone and iPad: on the App Store, iOS 18 or later · Needs your own OpenClaw Gateway · <a href="https://github.com/izyuumi/yorozu">Open source, MIT</a>',
    chatTitle: 'Every conversation, on every device.',
    chatFacts: [
      ['Many conversations', 'Start a new conversation with +. Each one is its own OpenClaw session, listed on every paired device, with full history loaded from your Gateway.'],
      ['Side by side', 'Open two conversations side by side on iPad and iPhone Duo, or drag a conversation onto the screen to open it beside the one you are in.'],
      ['See the work', 'Replies arrive whole, with a typing indicator while the agent runs and each tool call shown as a collapsed row.'],
      ['Delivery and read marks', 'Every message goes from Sent to Delivered to Read. Read state and unread badges stay in step across your devices.'],
      ['Replies and reactions', 'Reply to a particular message or react to it with an emoji. Your agent sees which message you mean, and can react too.'],
      ['Pin, search, rename', 'Pin the conversations you use most to the top of the list, and search them; Siri and Spotlight can find them too. Titles are made for you after the first turn. Rename, archive or delete from any device and the others follow.'],
    ],
    moreTitle: 'Built for the agent you already run.',
    moreFacts: [
      ['Automations', "See your agent's scheduled jobs with their next run, and change one with Edit in Chat: the agent edits it with its own tools. A job can deliver its result into a conversation."],
      ['Files, both ways', 'Send photos and files, paste them into the composer or take a photo from it, or share them from other apps. Files the agent returns open in the conversation.'],
      ['Notifications', 'One push per finished reply, with a preview only your device can open. Nothing is pushed for the conversation you are looking at.'],
      ['Voice input', 'Turn it on in Settings and speak instead of typing. Speech is transcribed on your device and the audio is never sent anywhere. On iPhone and iPad it needs iOS 26 or later.'],
      ['A native app', 'SwiftUI on iPhone, iPad and Mac, with light, dark or system appearance and eight accent colors. On the Mac and iPad, zoom the text from 75% to 200%.'],
      ['In your language', 'The app and this website speak English, Japanese, Simplified and Traditional Chinese, Korean, Spanish, French, German and Brazilian Portuguese.'],
    ],
    relayTitle: "The relay can't read a word of it.",
    diagram: {
      label: 'Your devices and your OpenClaw Gateway exchange messages encrypted with ChaCha20-Poly1305 through a relay that sees only size and timing.',
      encryption: 'ChaCha20-Poly1305 · End-to-end encrypted',
      relay: 'sees size and timing',
    },
    relayFacts: [
      ['Fresh keys for every connection', "Each connection runs a Noise IK handshake. Private keys stay in the device Keychain and in your Gateway's credentials store."],
      ['No open port', 'The plugin connects out to the relay, so the computer running your Gateway needs no port forwarding.'],
      ['Send while it sleeps', 'While your Gateway is offline, the relay holds what your devices send for up to 24 hours, sealed, and hands it over when the Gateway is back.'],
      ['No Yorozu account', 'No email, no password, no analytics. Your model providers and their logins stay in OpenClaw.'],
    ],
    getTitle: 'Get Yorozu.',
    getIntro: 'Yorozu has two parts: the plugin in your OpenClaw Gateway, and the app on each device.',
    plugin: {
      title: 'The plugin',
      text: 'Install the Yorozu channel plugin in your OpenClaw Gateway (OpenClaw 2026.9.8 or later). The <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">setup guide</a> has the commands and settings.',
      link: 'Open the setup guide',
    },
    ios: {
      title: 'iPhone and iPad',
      text: 'Yorozu is on the App Store for iPhone and iPad with iOS 18 or later. No Gateway yet? Enter <code>YOROZU-DEMO</code> on the pairing screen to look around with sample conversations.',
    },
    mac: {
      title: 'Mac',
      text: 'The same app runs natively on Macs with macOS 15 or later; Yorozu 0.10 is the current release. Move it to Applications and open it; it updates itself.',
    },
    stepsTitle: 'Then pair once.',
    stepsIntro: "You'll need <a href=\"https://docs.openclaw.ai/install\">OpenClaw</a> running with the Yorozu plugin. Keep the Gateway's computer awake and online to reach your agent.",
    steps: [
      ['Make a pairing code', 'On the computer that runs your Gateway, run <code>openclaw yorozu pair</code>. It prints a QR code and a link that work once and expire after 10 minutes.'],
      ['Pair your device', 'Scan the QR with the Camera or in Yorozu, or paste the link. Check that the fingerprint matches the one the command printed. No Yorozu account needed. To add a Mac later, scan the code it shows with a paired iPhone or iPad.'],
      ['Talk from anywhere', 'Your conversations live in OpenClaw. Every paired device sees them all, through the relay.'],
    ],
    riskTitle: 'Before you install',
    risk: [
      '<strong>Your agent acts with the accounts you give OpenClaw.</strong> If OpenClaw drives Claude Code, Codex or a model through a subscription login, Anthropic and OpenAI decide what use of that subscription is allowed, change those rules without notice, and have suspended accounts used with third-party agent tools. For the lowest risk, use an API key rather than a subscription login.',
      'AI agents take real actions: they run commands, edit and delete files and can send messages. Review what your agent is allowed to do. See the <a href="@/terms/">Terms of Use</a>.',
    ],
  },
  pair: {
    title: 'Pair with Yorozu',
    description: 'Open this pairing code in Yorozu on your iPhone or iPad.',
    intro: 'This is a Yorozu pairing code. Get Yorozu on this iPhone or iPad, then scan the code again. With Yorozu installed, the camera opens it in the app.',
    open: 'Open in Yorozu',
    private: 'The code stays on this device: it is in the part of the link your browser never sends to us. Keep it private; it works once and expires.',
  },
  add: {
    title: 'Add a Mac to Yorozu',
    description: 'Open this code in Yorozu on a paired iPhone or iPad.',
    intro: 'This is the code a new Mac shows to pair with your host. Scan it with the Camera, or in Yorozu under Settings › Add a Device › Scan a Mac’s Code, on an iPhone or iPad that already uses Yorozu.',
    private: 'The code stays on this device: it is in the part of the link your browser never sends to us. It works once and expires after 10 minutes.',
  },
  support: {
    title: 'Support — Yorozu',
    description: 'Get help with Yorozu setup, pairing, and app issues.',
    heading: 'Yorozu Support',
    body: `<p>For help with installing, pairing, connecting, or using Yorozu on your Mac, iPhone, or iPad, email <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>.</p>

  <h2>What to include</h2>
  <p>Tell us which Yorozu app and version you use, your device, what happened, and the steps that led to the problem. Include any error message you saw. Do not send passwords, API keys, or pairing links.</p>

  <h2>Copy Diagnostics</h2>
  <p>In Yorozu, open Settings › About and choose Copy Diagnostics, then paste the result into your email. It holds the app version, your device, the connection state and the log from this launch of the app. It contains no keys and no messages, and nothing is sent until you paste it yourself.</p>`,
  },
  privacy: {
    title: 'Privacy Policy — Yorozu',
    description: 'What Yorozu collects, what its relay can see, and what it cannot.',
    heading: 'Privacy Policy',
    effective: 'Effective October 31, 2026',
    body: `<p>Yorozu is an app for iPhone, iPad and Mac and a plugin for OpenClaw, made by Yumi Izumi ("we"). This policy explains what data Yorozu 0.9 and later handles. In short: <strong>we don't run accounts, analytics or advertising, and we can't read your conversations.</strong></p>

  <h2>Where your data lives</h2>
  <p>Your conversations live in your own OpenClaw Gateway, on a computer you control. The Yorozu plugin runs inside it. We never receive your conversations, files, or your Claude, OpenAI or other provider credentials; those stay with OpenClaw.</p>
  <ul>
    <li><strong>In your Gateway</strong>: OpenClaw keeps each conversation's session and transcript, generated titles and the files you send, as it does for any channel. The plugin keeps its private keys in OpenClaw's credentials store, and its list of paired devices and read state in OpenClaw's state store.</li>
    <li><strong>On your iPhone and iPad</strong>: a cache of your conversations, messages waiting to send and the files you open, encrypted at rest by iOS and excluded from backups. Pairing keys are in the iOS Keychain, on this device only.</li>
    <li><strong>On your Mac</strong>: the same cache in <code>~/Library/Application Support/to.yumi.yorozu.ios/</code>, and pairing keys in the macOS Keychain.</li>
  </ul>
  <p>Unpairing a device wipes its cache and keys.</p>

  <h2>The relay</h2>
  <p>Your devices reach your Gateway through a relay we operate on Cloudflare at <code>relay.yumi.to</code>. You can also run your own. Everything is end-to-end encrypted (a Noise IK handshake with X25519 for every connection, then ChaCha20-Poly1305) before it reaches the relay, and the relay has no key to decrypt it. The relay does handle:</p>
  <ul>
    <li><strong>Encrypted messages</strong> from your devices, held for up to 24 hours (at most 5 MiB) while your Gateway is offline, then deleted. Nothing your Gateway sends is held.</li>
    <li><strong>Encrypted attachments</strong>, in end-to-end encrypted chunks. The relay sees their size and timing.</li>
    <li><strong>Public keys</strong> of paired devices and a room identifier, kept until you unpair the device.</li>
    <li><strong>One-time pairing tokens</strong>, which expire after 10 minutes.</li>
    <li><strong>Your iPhone or iPad's Apple push token</strong>, so the relay can send notifications, kept until you unpair the device.</li>
    <li><strong>Metadata</strong>: when devices connect, and message sizes and timing. Connection logs never contain message content or keys.</li>
    <li><strong>IP addresses</strong>, which Cloudflare processes to deliver traffic, under <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare's privacy policy</a>.</li>
  </ul>

  <h2>Notifications</h2>
  <p>Push notifications are delivered by Apple. Each one carries a preview of the reply (the conversation title and its first line, at most 256 bytes), encrypted for your device alone; your device opens it. The relay and Apple see only the encrypted box.</p>

  <h2>OpenClaw and model providers</h2>
  <p>Yorozu hands your messages to your OpenClaw agent. OpenClaw and the tools it runs send data to their model providers (for example Anthropic or OpenAI) under their own privacy policies and your agreements with those providers. We are not a party to that and don't receive that data.</p>

  <h2>Updates and downloads</h2>
  <p>The iPhone and iPad app is installed and updated through the App Store. The Mac app checks <code>yorozu.yumi.to</code> for updates and downloads them from GitHub, which reveals your IP address and app version to Cloudflare and GitHub under their privacy policies. No system profile is sent. If you turn on voice input, iPhone and iPad download its speech model from Apple, like the app itself; the Mac app downloads it from Hugging Face (<code>huggingface.co</code>), which reveals your IP address to Hugging Face under its privacy policy. This website uses no analytics or trackers. Its only cookie, <code>yorozu_lang</code>, is set when you choose a language and holds just that choice, so the site opens in it next time.</p>

  <h2>Permissions</h2>
  <p>Yorozu asks for permissions only for the feature that needs them: the camera to scan a pairing code or take a photo to send, the microphone for voice input, photos to attach or save pictures, and notifications for replies. Voice input is transcribed on your device; the audio is never sent anywhere. Data accessed through permissions is used on your devices and is sent only to your own Gateway, end-to-end encrypted.</p>

  <h2>Earlier versions</h2>
  <p>Earlier versions of the Mac app ran their own assistant. Their data stays on your Mac, in <code>~/Yorozu</code> and Yorozu's folder in <code>~/Library/Application Support/</code>, until you delete it.</p>

  <h2>Children</h2>
  <p>Yorozu is not directed to children under 13, and we do not knowingly collect their data.</p>

  <h2>Your choices</h2>
  <p>Unpairing a device, from the app or with <code>openclaw yorozu devices remove</code>, deletes its keys and push token from the relay. Deleting the app removes its data from that device. Your conversations stay in OpenClaw until you delete them there or in Yorozu. Because we hold no account or readable content, there is nothing else to export or delete. For questions, email <a href="mailto:contact@yumi.to">contact@yumi.to</a>.</p>

  <h2>Changes</h2>
  <p>We will post changes here and update the date above.</p>`,
  },
  terms: {
    title: 'Terms of Use — Yorozu',
    description: 'The terms for using Yorozu, including the risk to Claude and Codex accounts used by the agents it drives.',
    heading: 'Terms of Use',
    effective: 'Effective October 23, 2026',
    body: `<p>These terms apply to the Yorozu app for iPhone, iPad and Mac, the Yorozu plugin for OpenClaw, the relay at <code>relay.yumi.to</code> and this website (together, "Yorozu"), provided by Yumi Izumi ("we", "us"). By installing or using Yorozu you agree to them. If you don't agree, don't use Yorozu. If you get the iPhone app from the App Store, Apple's <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Standard End User License Agreement</a> also applies. Where it conflicts with these terms, it controls for the iPhone app.</p>

  <h2>1. What Yorozu is</h2>
  <p>Yorozu is a chat app for your own OpenClaw agent: its plugin makes Yorozu a channel of your OpenClaw Gateway, and the app carries your messages to it and its replies back. The agent, and any coding tools it runs such as Claude Code or OpenAI Codex, is software you install and configure. Yorozu does not provide AI models, sell AI usage, or collect your credentials. You install, sign in to and pay for those tools yourself.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Your Claude or Codex account may be suspended or banned</h2>
    <p>Anthropic and OpenAI set the rules for how their subscriptions and accounts may be used, including through automated or third-party tools. Those rules have changed repeatedly and can change without notice. Anthropic has suspended accounts used with third-party agent tools, and states it may enforce its restrictions without prior notice. Using Yorozu to drive Claude Code or Codex, through OpenClaw or otherwise, with a subscription login (such as Claude Pro or Max, or a ChatGPT plan) <strong>may violate those rules and may lead to your account being rate-limited, suspended or permanently banned, with no refund.</strong></p>
    <p>You are solely responsible for reading and complying with the terms of every provider you use, including <a href="https://www.anthropic.com/legal/consumer-terms">Anthropic's Consumer Terms</a>, the <a href="https://code.claude.com/docs/en/legal-and-compliance">Claude Code legal and compliance terms</a>, and <a href="https://openai.com/policies/terms-of-use/">OpenAI's Terms of Use</a>. An API key billed to you is generally the lower-risk option. <strong>We are not responsible for any action a provider takes against your account, or for any loss that results.</strong></p>
  </div>

  <h2>3. Third-party software</h2>
  <p>OpenClaw, Claude Code, Codex and the other tools your agent uses are third-party software, provided by their owners under their own licenses and terms. OpenClaw is open-source software from the OpenClaw Foundation, licensed under the MIT License "as is", without warranty. We do not develop, control or support that software or the model providers behind it, and we are not responsible for how it behaves, what it outputs, or what it does on your computer. That includes commands it runs, files it changes or deletes, messages it sends, purchases it makes, and anything done under permissions you grant it. Yorozu is not affiliated with, endorsed by or sponsored by the OpenClaw Foundation, Anthropic or OpenAI. All product names belong to their owners.</p>

  <h2>4. You are responsible for your agents</h2>
  <p>AI agents can act on your computer and online accounts, and they make mistakes. You are responsible for configuring them, for the permissions and approvals you grant (including any mode that skips approvals), for reviewing their output, and for everything done through your devices. Keep backups. Do not use Yorozu where a failure or mistaken action could cause injury, significant financial loss or legal harm.</p>

  <h2>5. Acceptable use</h2>
  <p>Don't use Yorozu to break the law, violate anyone's rights, violate a provider's terms, attack or overload the relay, or access devices or accounts that aren't yours. We may block access to the hosted relay to protect it or its users.</p>

  <h2>6. The relay</h2>
  <p>The hosted relay is provided free of charge and on a best-effort basis. It may be slow, unavailable, changed or discontinued at any time. You can run your own relay instead.</p>

  <h2>7. No warranty</h2>
  <p>To the fullest extent permitted by law, Yorozu is provided "as is" and "as available", without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose, non-infringement, accuracy, security, and uninterrupted or error-free operation.</p>

  <h2>8. Limitation of liability</h2>
  <p>To the fullest extent permitted by law, we are not liable for any indirect, incidental, special, consequential or punitive damages, or for any loss of data, profits, accounts, access to third-party services or subscriptions, or business, arising from Yorozu, from third-party software or providers, or from actions taken by AI agents, even if we were told such loss was possible. Our total liability for any claim relating to Yorozu is limited to the amount you paid us for Yorozu in the 12 months before the claim, or USD 10 if you paid nothing. Some jurisdictions do not allow certain exclusions or limits. In those jurisdictions, they apply only as far as the law allows. Nothing in these terms limits liability that cannot be limited by law, such as liability for intentional misconduct or gross negligence.</p>

  <h2>9. Indemnity</h2>
  <p>To the extent permitted by law, you agree to indemnify us against claims arising from your use of Yorozu, your agents' actions, or your violation of these terms or a third party's terms.</p>

  <h2>10. Changes and termination</h2>
  <p>We may update these terms by posting a new version here. Continuing to use Yorozu after an update means you accept it. You can stop using Yorozu at any time by deleting the apps.</p>

  <h2>11. Governing law</h2>
  <p>These terms are governed by the laws of Japan, and the Tokyo District Court has exclusive jurisdiction as the court of first instance, except where the consumer-protection laws of your country of residence require otherwise.</p>

  <h2>12. Contact</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
