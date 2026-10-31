// 简体中文。术语与 App 的 Localizable.xcstrings 和 App Store 的 zh-Hans 文本一致。
export default {
  name: 'Yorozu',
  skip: '跳到正文',
  nav: { primary: '主导航', footer: '页脚', language: '语言', home: '首页', support: '支持', privacy: '隐私', terms: '条款', getApp: '获取 App' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '。Yorozu 与 OpenClaw、Nous Research（Hermes Agent）、Cua（CuaDriver）、Anthropic 或 OpenAI 均无关联。',
  },
  governs: '本中文版本为参考译文。如与英文版本有任何不一致，以<a href="@en">英文版本</a>为准。',
  home: {
    title: 'Yorozu — 为你的 OpenClaw 智能体打造的原生聊天应用',
    description: 'Yorozu 是一款适用于 iPhone、iPad 和 Mac 的原生应用，让你与自己的 OpenClaw 智能体聊天。消息端到端加密，经由无法读取内容的中继传输。',
    og: {
      title: 'Yorozu',
      description: '为你自己的 OpenClaw 智能体打造的原生聊天应用，支持 iPhone、iPad 和 Mac。端到端加密。',
      imageAlt: 'Yorozu 的应用图标，旁边是英文“Your OpenClaw agent, anywhere.”（随时随地使用你的 OpenClaw 智能体）。',
    },
    hero: '你的 OpenClaw 智能体，<br><em>装进口袋。</em>',
    appStore: '在 App Store 获取 Yorozu',
    downloadMac: '下载 Mac 版',
    fine: 'Mac：macOS 15 或更高版本 · iPhone 和 iPad：已在 App Store 上架，iOS 18 或更高版本 · 需要你自己的 OpenClaw Gateway · <a href="https://github.com/izyuumi/yorozu">开源，MIT 许可</a>',
    agent: {
      title: '用 AI 智能体设置',
      intro: '把这段提示词粘贴到 Claude Code、Codex、Cursor 或其他 AI 智能体中。智能体会连接 Yorozu 的帮助服务器，询问你用的是 Mac 还是 iPhone、iPad，然后一步步带你完成设置。',
      copy: '复制',
      copyLabel: '复制提示词',
      copied: '已复制',
      status: '提示词已复制。',
      failed: '无法自动复制。提示词已选中，请使用设备的复制命令。',
      note: '帮助服务器为只读，无需登录。它只提供 Yorozu 的文档，无法访问你的 Gateway 或聊天内容。提示词保留英文，因为智能体对英文的遵循最可靠，并会要求智能体用简体中文回复。',
      language: 'Simplified Chinese',
    },
    setupTitle: '或者自己动手设置',
    stepsIntro: '你需要运行装有 Yorozu 插件的 <a href="https://docs.openclaw.ai/install">OpenClaw</a>。请让运行 Gateway 的电脑保持唤醒并联网，才能联系到你的智能体。',
    steps: [
      ['安装插件', '在你的 OpenClaw Gateway（OpenClaw 2026.9.8 或更高版本）中安装 Yorozu 频道插件。<a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">设置指南</a>（英文）中有所需的命令和设置。'],
      ['生成配对代码', '在运行 Gateway 的电脑上执行 <code>openclaw yorozu pair</code>。它会显示一个二维码和一个链接，均只能使用一次，10 分钟后过期。'],
      ['配对你的设备', '用相机或在 Yorozu 中扫描二维码，或粘贴链接。确认指纹与命令显示的一致。无需 Yorozu 账户。以后要添加 Mac 时，用已配对的 iPhone 或 iPad 扫描 Mac 上显示的代码即可。'],
    ],
    docsTitle: '文档与支持',
    docs: [
      ['设置指南', '插件和应用的命令、设置与故障排除（英文）。'],
      ['面向 AI 智能体的帮助服务器', '将任意 MCP 客户端连接到 <code>yorozu.yumi.to/mcp</code>，即可获得设置和故障排除方面的帮助（英文）。'],
      ['支持', '报告问题或提出疑问。'],
      ['源代码', 'Yorozu 以 MIT 许可开源，代码托管在 GitHub 上。'],
    ],
    riskTitle: '安装之前',
    risk: [
      '<strong>你的智能体使用你交给 OpenClaw 的账户行事。</strong>如果 OpenClaw 通过订阅登录来驱动 Claude Code、Codex 或某个模型，该订阅允许怎样使用由 Anthropic 和 OpenAI 决定；它们会不经通知更改这些规则，并曾停用与第三方智能体工具一起使用的账户。为将风险降到最低，请使用 API 密钥，而不是订阅登录。',
      'AI 智能体会执行真实的操作：运行命令、编辑和删除文件，还可能发送消息。请检查你允许智能体做哪些事。详见<a href="@/terms/">使用条款</a>。',
    ],
  },
  pair: {
    title: '与 Yorozu 配对',
    description: '在 iPhone 或 iPad 上的 Yorozu 中打开此配对代码。',
    intro: '这是一个 Yorozu 配对代码。请先在这台 iPhone 或 iPad 上安装 Yorozu，然后再次扫描代码。安装 Yorozu 后，相机会直接在应用中打开它。',
    open: '在 Yorozu 中打开',
    private: '代码只留在这台设备上：它位于链接中浏览器从不发送给我们的部分。请妥善保密；它只能使用一次，并会过期。',
  },
  add: {
    title: '将 Mac 添加到 Yorozu',
    description: '在已配对的 iPhone 或 iPad 上的 Yorozu 中打开此代码。',
    intro: '这是新 Mac 为与你的主机配对而显示的代码。请在已使用 Yorozu 的 iPhone 或 iPad 上，用相机扫描它，或在 Yorozu 的“设置”›“添加设备”›“扫描 Mac 的代码”中扫描。',
    private: '代码只留在这台设备上：它位于链接中浏览器从不发送给我们的部分。它只能使用一次，10 分钟后过期。',
  },
  support: {
    title: '支持 — Yorozu',
    description: '获取有关 Yorozu 设置、配对和应用问题的帮助。',
    heading: 'Yorozu 支持',
    body: `<p>如需有关在 Mac、iPhone 或 iPad 上安装、配对、连接或使用 Yorozu 的帮助，请发送邮件至 <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>。</p>

  <h2>请提供以下信息</h2>
  <p>请告诉我们你使用的 Yorozu 应用及版本、你的设备、发生了什么，以及导致问题的操作步骤。如果看到错误信息，也请一并附上。请不要发送密码、API 密钥或配对链接。</p>

  <h2>拷贝诊断信息</h2>
  <p>在 Yorozu 中打开“设置”›“关于”，选择“拷贝诊断信息”，然后将结果粘贴到邮件中。其中包含应用版本、你的设备、连接状态以及本次启动应用以来的日志。它不包含任何密钥或消息，在你自己粘贴之前不会发送到任何地方。</p>`,
  },
  privacy: {
    title: '隐私政策 — Yorozu',
    description: 'Yorozu 收集什么，它的中继能看到什么、看不到什么。',
    heading: '隐私政策',
    effective: '2026 年 10 月 31 日起生效',
    body: `<p>Yorozu 是由 Yumi Izumi（“我们”）制作的一款适用于 iPhone、iPad 和 Mac 的应用，以及一个 OpenClaw 插件。本政策说明 Yorozu 0.9 及更高版本处理哪些数据。简而言之：<strong>我们不运营账户、分析或广告，也无法读取你的对话。</strong></p>

  <h2>你的数据存放在哪里</h2>
  <p>你的对话保存在你自己的 OpenClaw Gateway 中，位于你控制的电脑上。Yorozu 插件在其中运行。我们从不接收你的对话、文件，或你的 Claude、OpenAI 及其他提供商的凭据；这些都留在 OpenClaw 中。</p>
  <ul>
    <li><strong>在你的 Gateway 中</strong>：与任何频道一样，OpenClaw 会保存每个对话的会话和记录、生成的标题以及你发送的文件。插件将私钥保存在 OpenClaw 的凭据存储中，将已配对设备列表和已读状态保存在 OpenClaw 的状态存储中。</li>
    <li><strong>在你的 iPhone 和 iPad 上</strong>：对话缓存、等待发送的消息以及你打开的文件，由 iOS 进行静态加密，并且不包含在备份中。配对密钥保存在 iOS 钥匙串中，仅限此设备。</li>
    <li><strong>在你的 Mac 上</strong>：同样的缓存保存在 <code>~/Library/Application Support/to.yumi.yorozu.ios/</code> 中，配对密钥保存在 macOS 钥匙串中。</li>
  </ul>
  <p>取消设备的配对会清除该设备的缓存和密钥。</p>

  <h2>中继</h2>
  <p>你的设备通过我们在 Cloudflare 上运营的中继 <code>relay.yumi.to</code> 连接到你的 Gateway。你也可以自行运行中继。所有内容在到达中继之前都经过端到端加密（每次连接都使用基于 X25519 的 Noise IK 握手，然后使用 ChaCha20-Poly1305），中继没有任何可用于解密的密钥。中继确实会处理以下内容：</p>
  <ul>
    <li><strong>加密消息</strong>：来自你的设备，在你的 Gateway 离线期间最多保存 24 小时（最多 5 MiB），之后删除。你的 Gateway 发送的内容不会被保存。</li>
    <li><strong>加密附件</strong>：以端到端加密的分块形式传输。中继能看到它们的大小和时间。</li>
    <li><strong>公钥</strong>：已配对设备的公钥和一个房间标识符，保存到你取消该设备的配对为止。</li>
    <li><strong>一次性配对令牌</strong>：10 分钟后过期。</li>
    <li><strong>你的 iPhone 或 iPad 的 Apple 推送令牌</strong>：用于让中继发送通知，保存到你取消该设备的配对为止。</li>
    <li><strong>元数据</strong>：设备何时连接，以及消息的大小和时间。连接日志从不包含消息内容或密钥。</li>
    <li><strong>IP 地址</strong>：由 Cloudflare 根据 <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare 的隐私政策</a>处理，用于传送流量。</li>
  </ul>

  <h2>通知</h2>
  <p>推送通知由 Apple 传送。每条通知都带有回复的预览（对话标题及其第一行，最多 256 字节），并且仅为你的设备加密；由你的设备打开。中继和 Apple 只能看到加密的封包。</p>

  <h2>OpenClaw 与模型提供商</h2>
  <p>Yorozu 将你的消息交给你的 OpenClaw 智能体。OpenClaw 及其运行的工具会根据各提供商自己的隐私政策以及你与这些提供商之间的协议，将数据发送给它们的模型提供商（例如 Anthropic 或 OpenAI）。我们不是其中的一方，也不会收到这些数据。</p>

  <h2>更新与下载</h2>
  <p>iPhone 和 iPad 应用通过 App Store 安装和更新。Mac 应用会在 <code>yorozu.yumi.to</code> 检查更新并从 GitHub 下载，这会根据 Cloudflare 和 GitHub 的隐私政策向它们透露你的 IP 地址和应用版本。不会发送系统概况。如果你打开语音输入，iPhone 和 iPad 会像下载应用本身一样从 Apple 下载语音模型；Mac 应用则从 Hugging Face（<code>huggingface.co</code>）下载，这会根据 Hugging Face 的隐私政策向其透露你的 IP 地址。本网站不使用分析工具或跟踪器。它唯一的 Cookie 是 <code>yorozu_lang</code>，仅在你选择语言时设置，只保存这一选择，以便下次以该语言打开网站。</p>

  <h2>权限</h2>
  <p>Yorozu 只为需要权限的功能请求相应权限：使用相机扫描配对代码或拍摄要发送的照片，使用麦克风进行语音输入，访问照片以添加或保存图片，以及为回复发送通知。语音输入在你的设备上转写；音频绝不会发送到任何地方。通过权限访问的数据在你的设备上使用，并且只会经端到端加密发送到你自己的 Gateway。</p>

  <h2>早期版本</h2>
  <p>Mac 应用的早期版本运行自己的助手。它们的数据会留在你的 Mac 上的 <code>~/Yorozu</code> 和 <code>~/Library/Application Support/</code> 中 Yorozu 的文件夹里，直到你删除为止。</p>

  <h2>儿童</h2>
  <p>Yorozu 不面向 13 岁以下的儿童，我们不会故意收集他们的数据。</p>

  <h2>你的选择</h2>
  <p>通过应用或使用 <code>openclaw yorozu devices remove</code> 取消设备的配对，会从中继删除该设备的密钥和推送令牌。删除应用会从该设备上移除其数据。你的对话会保留在 OpenClaw 中，直到你在 OpenClaw 或 Yorozu 中删除它们。由于我们不持有任何账户或可读内容，因此没有其他可导出或删除的内容。如有疑问，请发送邮件至 <a href="mailto:contact@yumi.to">contact@yumi.to</a>。</p>

  <h2>变更</h2>
  <p>如有变更，我们会在此发布并更新上方的日期。</p>`,
  },
  terms: {
    title: '使用条款 — Yorozu',
    description: '使用 Yorozu 的条款，包括它所驱动的智能体使用的 Claude 和 Codex 账户面临的风险。',
    heading: '使用条款',
    effective: '2026 年 10 月 23 日起生效',
    body: `<p>本条款适用于由 Yumi Izumi（“我们”）提供的适用于 iPhone、iPad 和 Mac 的 Yorozu 应用、OpenClaw 的 Yorozu 插件、位于 <code>relay.yumi.to</code> 的中继以及本网站（统称“Yorozu”）。安装或使用 Yorozu 即表示你同意本条款。如果你不同意，请不要使用 Yorozu。如果你从 App Store 获取 iPhone 应用，Apple 的<a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">标准最终用户许可协议</a>同样适用。若其与本条款冲突，就 iPhone 应用而言以其为准。</p>

  <h2>1. Yorozu 是什么</h2>
  <p>Yorozu 是一款面向你自己的 OpenClaw 智能体的聊天应用：它的插件让 Yorozu 成为你的 OpenClaw Gateway 的一个频道，应用将你的消息传给智能体并带回它的回复。智能体以及它运行的任何编程工具（例如 Claude Code 或 OpenAI Codex）都是由你安装和配置的软件。Yorozu 不提供 AI 模型，不出售 AI 使用额度，也不收集你的凭据。这些工具由你自行安装、登录和付费。</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. 你的 Claude 或 Codex 账户可能被停用或封禁</h2>
    <p>Anthropic 和 OpenAI 制定其订阅和账户可如何使用的规则，包括通过自动化工具或第三方工具使用的情形。这些规则已多次变更，并且可能在不通知的情况下变更。Anthropic 曾停用与第三方智能体工具一起使用的账户，并声明可在不事先通知的情况下执行其限制。使用 Yorozu，通过 OpenClaw 或其他方式，以订阅登录（例如 Claude Pro 或 Max，或 ChatGPT 套餐）驱动 Claude Code 或 Codex，<strong>可能违反这些规则，并可能导致你的账户被限速、停用或永久封禁，且不予退款。</strong></p>
    <p>你须自行负责阅读并遵守你所使用的每个提供商的条款，包括 <a href="https://www.anthropic.com/legal/consumer-terms">Anthropic 的消费者条款</a>、<a href="https://code.claude.com/docs/en/legal-and-compliance">Claude Code 法律与合规条款</a>以及 <a href="https://openai.com/policies/terms-of-use/">OpenAI 的使用条款</a>。由你付费的 API 密钥通常是风险较低的选择。<strong>对于提供商对你的账户采取的任何措施，或由此造成的任何损失，我们概不负责。</strong></p>
  </div>

  <h2>3. 第三方软件</h2>
  <p>OpenClaw、Claude Code、Codex 以及你的智能体使用的其他工具都是第三方软件，由其所有者依据各自的许可和条款提供。OpenClaw 是 OpenClaw Foundation 的开源软件，依据 MIT 许可证“按原样”提供，不附带任何保证。我们不开发、控制或支持这些软件或其背后的模型提供商，也不对它们的行为、输出或它们在你的电脑上所做的事情负责。这包括它们运行的命令、更改或删除的文件、发送的消息、进行的购买，以及在你授予的权限下所做的任何事情。Yorozu 与 OpenClaw Foundation、Anthropic 或 OpenAI 没有关联，也未获得其认可或赞助。所有产品名称均归其所有者所有。</p>

  <h2>4. 你对你的智能体负责</h2>
  <p>AI 智能体可以在你的电脑和在线账户上执行操作，并且会犯错。你须负责配置它们、负责你授予的权限和批准（包括任何跳过批准的模式）、负责审查它们的输出，并对通过你的设备所做的一切负责。请做好备份。在故障或错误操作可能导致人身伤害、重大经济损失或法律损害的场合，请不要使用 Yorozu。</p>

  <h2>5. 可接受的使用</h2>
  <p>不得使用 Yorozu 违反法律、侵犯任何人的权利、违反提供商的条款、攻击中继或使其过载，或访问不属于你的设备或账户。为保护托管中继或其用户，我们可能阻止对托管中继的访问。</p>

  <h2>6. 中继</h2>
  <p>托管中继免费提供，并尽力而为。它可能随时变慢、不可用、被更改或停止。你也可以改为运行自己的中继。</p>

  <h2>7. 无保证</h2>
  <p>在法律允许的最大范围内，Yorozu 按“原样”和“现有”状态提供，不附带任何形式的明示或默示保证，包括适销性、特定用途适用性、不侵权、准确性、安全性以及不间断或无错误运行。</p>

  <h2>8. 责任限制</h2>
  <p>在法律允许的最大范围内，对于因 Yorozu、第三方软件或提供商，或 AI 智能体所采取的操作而产生的任何间接、附带、特殊、后果性或惩罚性损害，或任何数据、利润、账户、对第三方服务或订阅的访问权或业务的损失，即使我们已被告知可能发生此类损失，我们也不承担责任。对于与 Yorozu 相关的任何索赔，我们的总责任以你在索赔前 12 个月内为 Yorozu 向我们支付的金额为限；如果你未支付任何费用，则以 10 美元为限。某些司法管辖区不允许某些排除或限制。在这些司法管辖区，它们仅在法律允许的范围内适用。本条款中的任何内容均不限制法律上不能限制的责任，例如因故意不当行为或重大过失而产生的责任。</p>

  <h2>9. 赔偿</h2>
  <p>在法律允许的范围内，你同意就因你使用 Yorozu、你的智能体的行为，或你违反本条款或第三方条款而引起的索赔向我们作出赔偿。</p>

  <h2>10. 变更与终止</h2>
  <p>我们可能通过在此发布新版本来更新本条款。更新后继续使用 Yorozu 即表示你接受更新。你可以随时通过删除应用停止使用 Yorozu。</p>

  <h2>11. 适用法律</h2>
  <p>本条款受日本法律管辖，东京地方法院为第一审专属管辖法院，但你的居住国的消费者保护法律另有要求的除外。</p>

  <h2>12. 联系方式</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
