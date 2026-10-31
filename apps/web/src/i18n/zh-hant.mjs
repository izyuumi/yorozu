// 繁體中文（台灣用語）。用詞與 App 的 Localizable.xcstrings 及 App Store 的 zh-Hant 文字一致。
export default {
  name: 'Yorozu',
  skip: '跳至主要內容',
  nav: { primary: '主要導覽', footer: '頁尾', language: '語言', home: '首頁', support: '支援', privacy: '隱私權', terms: '條款', getApp: '取得 App' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '。Yorozu 與 OpenClaw、Nous Research（Hermes Agent）、Cua（CuaDriver）、Anthropic 或 OpenAI 皆無關聯。',
  },
  governs: '此中文版本為參考譯文。如與英文版本有任何不一致，以<a href="@en">英文版本</a>為準。',
  home: {
    title: 'Yorozu — 為你的 OpenClaw 智慧代理打造的原生聊天 App',
    description: 'Yorozu 是一款適用於 iPhone、iPad 和 Mac 的原生 App，讓你和自己的 OpenClaw 智慧代理聊天。訊息經過端對端加密，透過無法讀取內容的中繼傳送。',
    og: {
      title: 'Yorozu',
      description: '為你自己的 OpenClaw 智慧代理打造的原生聊天 App，支援 iPhone、iPad 和 Mac。端對端加密。',
      imageAlt: 'Yorozu 的 App 圖像，旁邊是英文「Your OpenClaw agent, anywhere.」（隨時隨地使用你的 OpenClaw 智慧代理）。',
    },
    hero: '你的 OpenClaw 智慧代理，<br><em>放進口袋。</em>',
    appStore: '在 App Store 取得 Yorozu',
    downloadMac: '下載 Mac 版',
    fine: 'Mac：macOS 15 或以上版本 · iPhone 和 iPad：已在 App Store 上架，iOS 18 或以上版本 · 需要你自己的 OpenClaw Gateway · <a href="https://github.com/izyuumi/yorozu">開放原始碼，MIT 授權</a>',
    agent: {
      title: '用 AI 智慧代理設定',
      intro: '把這段提示詞貼到 Claude Code、Codex、Cursor 或其他 AI 智慧代理中。智慧代理會連接 Yorozu 的說明伺服器，詢問你用的是 Mac 還是 iPhone、iPad，然後一步步帶你完成設定。',
      copy: '拷貝',
      copyLabel: '拷貝提示詞',
      copied: '已拷貝',
      status: '提示詞已拷貝。',
      failed: '無法自動拷貝。提示詞已選取，請使用裝置的拷貝指令。',
      note: '說明伺服器為唯讀，無需登入。它只提供 Yorozu 的文件，無法存取你的 Gateway 或聊天內容。提示詞保留英文，因為智慧代理對英文的遵循最可靠，並會要求智慧代理以繁體中文回覆。',
      language: 'Traditional Chinese',
    },
    setupTitle: '或者自己動手設定',
    stepsIntro: '你需要執行裝有 Yorozu 外掛的 <a href="https://docs.openclaw.ai/install">OpenClaw</a>。請讓執行 Gateway 的電腦保持喚醒並連上網路，才能聯絡到你的智慧代理。',
    steps: [
      ['安裝外掛', '在你的 OpenClaw Gateway（OpenClaw 2026.9.8 或以上版本）中安裝 Yorozu 頻道外掛。<a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">設定指南</a>（英文）中有所需的指令和設定。'],
      ['產生配對代碼', '在執行 Gateway 的電腦上執行 <code>openclaw yorozu pair</code>。它會顯示一個 QR 碼和一個連結，都只能使用一次，10 分鐘後失效。'],
      ['配對你的裝置', '用「相機」或在 Yorozu 中掃描 QR 碼，或貼上連結。確認指紋與指令顯示的相同。不需 Yorozu 帳號。之後要加入 Mac 時，用已配對的 iPhone 或 iPad 掃描 Mac 上顯示的代碼即可。'],
    ],
    docsTitle: '文件與支援',
    docs: [
      ['設定指南', '外掛和 App 的指令、設定與疑難排解（英文）。'],
      ['給 AI 智慧代理的說明伺服器', '將任何 MCP 用戶端連接到 <code>yorozu.yumi.to/mcp</code>，即可獲得設定與疑難排解方面的協助（英文）。'],
      ['支援', '回報問題或提出疑問。'],
      ['原始碼', 'Yorozu 以 MIT 授權開放原始碼，程式碼放在 GitHub 上。'],
    ],
    riskTitle: '安裝之前',
    risk: [
      '<strong>你的智慧代理會使用你交給 OpenClaw 的帳號行事。</strong>如果 OpenClaw 透過訂閱登入來驅動 Claude Code、Codex 或某個模型，該訂閱允許怎樣使用由 Anthropic 和 OpenAI 決定；它們會不經通知變更這些規則，也曾停用與第三方智慧代理工具一起使用的帳號。為了將風險降到最低，請使用 API 金鑰，而不是訂閱登入。',
      'AI 智慧代理會執行真實的操作：執行指令、編輯和刪除檔案，還可能傳送訊息。請檢查你允許智慧代理做哪些事。詳見<a href="@/terms/">使用條款</a>。',
    ],
  },
  pair: {
    title: '與 Yorozu 配對',
    description: '在 iPhone 或 iPad 上的 Yorozu 中開啟此配對代碼。',
    intro: '這是一個 Yorozu 配對代碼。請先在這部 iPhone 或 iPad 上安裝 Yorozu，然後再掃描一次代碼。安裝 Yorozu 後，「相機」會直接在 App 中開啟它。',
    open: '在 Yorozu 中開啟',
    private: '代碼只會留在這部裝置上：它位於連結中瀏覽器從不傳送給我們的部分。請妥善保密；它只能使用一次，並會失效。',
  },
  add: {
    title: '將 Mac 加入 Yorozu',
    description: '在已配對的 iPhone 或 iPad 上的 Yorozu 中開啟此代碼。',
    intro: '這是新的 Mac 為了與你的主機配對而顯示的代碼。請在已使用 Yorozu 的 iPhone 或 iPad 上，用「相機」掃描它，或在 Yorozu 的「設定」›「加入裝置」›「掃描 Mac 的代碼」中掃描。',
    private: '代碼只會留在這部裝置上：它位於連結中瀏覽器從不傳送給我們的部分。它只能使用一次，10 分鐘後失效。',
  },
  support: {
    title: '支援 — Yorozu',
    description: '取得 Yorozu 設定、配對與 App 問題的協助。',
    heading: 'Yorozu 支援',
    body: `<p>如需在 Mac、iPhone 或 iPad 上安裝、配對、連線或使用 Yorozu 的協助，請寄電子郵件至 <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>。</p>

  <h2>請提供以下資訊</h2>
  <p>請告訴我們你使用的 Yorozu App 及版本、你的裝置、發生了什麼事，以及導致問題的操作步驟。如果看到錯誤訊息，也請一併附上。請不要傳送密碼、API 金鑰或配對連結。</p>

  <h2>拷貝診斷資訊</h2>
  <p>在 Yorozu 中開啟「設定」›「關於」，選擇「拷貝診斷資訊」，然後將結果貼到電子郵件中。其中包含 App 版本、你的裝置、連線狀態，以及這次啟動 App 以來的記錄。它不含任何金鑰或訊息，在你自己貼上之前不會傳送到任何地方。</p>`,
  },
  privacy: {
    title: '隱私權政策 — Yorozu',
    description: 'Yorozu 收集什麼，它的中繼看得到什麼、看不到什麼。',
    heading: '隱私權政策',
    effective: '自 2026 年 10 月 31 日起生效',
    body: `<p>Yorozu 是由 Yumi Izumi（「我們」）製作的一款適用於 iPhone、iPad 和 Mac 的 App，以及一個 OpenClaw 外掛。本政策說明 Yorozu 0.9 及以上版本處理哪些資料。簡單來說：<strong>我們不經營帳號、分析或廣告，也無法讀取你的對話。</strong></p>

  <h2>你的資料存放在哪裡</h2>
  <p>你的對話保存在你自己的 OpenClaw Gateway 中，位於你控制的電腦上。Yorozu 外掛在其中執行。我們從不接收你的對話、檔案，或你的 Claude、OpenAI 及其他供應商的憑證；這些都留在 OpenClaw 中。</p>
  <ul>
    <li><strong>在你的 Gateway 中</strong>：和任何頻道一樣，OpenClaw 會保存每個對話的工作階段和記錄、產生的標題，以及你傳送的檔案。外掛將私密金鑰保存在 OpenClaw 的憑證儲存區中，並將已配對裝置清單和已讀狀態保存在 OpenClaw 的狀態儲存區中。</li>
    <li><strong>在你的 iPhone 和 iPad 上</strong>：對話快取、等待傳送的訊息，以及你開啟的檔案，由 iOS 進行靜態加密，且不包含在備份中。配對金鑰保存在 iOS 鑰匙圈中，僅限此裝置。</li>
    <li><strong>在你的 Mac 上</strong>：同樣的快取保存在 <code>~/Library/Application Support/to.yumi.yorozu.ios/</code> 中，配對金鑰保存在 macOS 鑰匙圈中。</li>
  </ul>
  <p>取消裝置的配對會清除該裝置的快取和金鑰。</p>

  <h2>中繼</h2>
  <p>你的裝置透過我們在 Cloudflare 上營運的中繼 <code>relay.yumi.to</code> 連線到你的 Gateway。你也可以自行執行中繼。所有內容在到達中繼之前都經過端對端加密（每次連線都使用以 X25519 進行的 Noise IK 交握，接著使用 ChaCha20-Poly1305），中繼沒有任何可用來解密的金鑰。中繼確實會處理以下內容：</p>
  <ul>
    <li><strong>加密的訊息</strong>：來自你的裝置，在你的 Gateway 離線期間最多保存 24 小時（最多 5 MiB），之後刪除。你的 Gateway 傳送的內容不會被保存。</li>
    <li><strong>加密的附件</strong>：以端對端加密的區塊傳送。中繼看得到它們的大小和時間。</li>
    <li><strong>公開金鑰</strong>：已配對裝置的公開金鑰和一個房間識別碼，保存到你取消該裝置的配對為止。</li>
    <li><strong>一次性配對權杖</strong>：10 分鐘後失效。</li>
    <li><strong>你的 iPhone 或 iPad 的 Apple 推播權杖</strong>：用來讓中繼傳送通知，保存到你取消該裝置的配對為止。</li>
    <li><strong>中繼資料</strong>：裝置何時連線，以及訊息的大小和時間。連線記錄從不包含訊息內容或金鑰。</li>
    <li><strong>IP 位址</strong>：由 Cloudflare 依據 <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare 的隱私權政策</a>處理，用於傳送流量。</li>
  </ul>

  <h2>通知</h2>
  <p>推播通知由 Apple 傳送。每則通知都帶有回覆的預覽（對話標題及其第一行，最多 256 位元組），並且只為你的裝置加密；由你的裝置開啟。中繼和 Apple 只看得到加密的封包。</p>

  <h2>OpenClaw 與模型供應商</h2>
  <p>Yorozu 會把你的訊息交給你的 OpenClaw 智慧代理。OpenClaw 及其執行的工具會依據各供應商自己的隱私權政策，以及你與這些供應商之間的協議，將資料傳送給它們的模型供應商（例如 Anthropic 或 OpenAI）。我們不是其中的一方，也不會收到這些資料。</p>

  <h2>更新與下載</h2>
  <p>iPhone 和 iPad App 透過 App Store 安裝和更新。Mac App 會在 <code>yorozu.yumi.to</code> 檢查更新，並從 GitHub 下載，這會依據 Cloudflare 和 GitHub 的隱私權政策，向它們透露你的 IP 位址和 App 版本。不會傳送系統描述檔。如果你開啟語音輸入，iPhone 和 iPad 會像下載 App 本身一樣從 Apple 下載語音模型；Mac App 則從 Hugging Face（<code>huggingface.co</code>）下載，這會依據 Hugging Face 的隱私權政策向其透露你的 IP 位址。本網站不使用分析工具或追蹤器。它唯一的 Cookie 是 <code>yorozu_lang</code>，只在你選擇語言時設定，只保存這項選擇，讓網站下次以該語言開啟。</p>

  <h2>權限</h2>
  <p>Yorozu 只為需要權限的功能要求相應權限：使用相機掃描配對代碼或拍攝要傳送的照片，使用麥克風進行語音輸入，存取照片以附加或儲存圖片，以及為回覆傳送通知。語音輸入會在你的裝置上轉寫；音訊絕不會傳送到任何地方。透過權限存取的資料在你的裝置上使用，並且只會經端對端加密傳送到你自己的 Gateway。</p>

  <h2>舊版本</h2>
  <p>Mac App 的舊版本會執行自己的助理。它們的資料會留在你的 Mac 上的 <code>~/Yorozu</code> 以及 <code>~/Library/Application Support/</code> 中 Yorozu 的檔案夾裡，直到你刪除為止。</p>

  <h2>兒童</h2>
  <p>Yorozu 並非以 13 歲以下兒童為對象，我們不會在知情的情況下收集他們的資料。</p>

  <h2>你的選擇</h2>
  <p>透過 App 或使用 <code>openclaw yorozu devices remove</code> 取消裝置的配對，會從中繼刪除該裝置的金鑰和推播權杖。刪除 App 會從該裝置移除其資料。你的對話會保留在 OpenClaw 中，直到你在 OpenClaw 或 Yorozu 中刪除。由於我們不持有任何帳號或可讀取的內容，因此沒有其他可匯出或刪除的內容。如有疑問，請寄電子郵件至 <a href="mailto:contact@yumi.to">contact@yumi.to</a>。</p>

  <h2>變更</h2>
  <p>如有變更，我們會在此公布並更新上方的日期。</p>`,
  },
  terms: {
    title: '使用條款 — Yorozu',
    description: '使用 Yorozu 的條款，包括它所驅動的智慧代理使用的 Claude 和 Codex 帳號所面臨的風險。',
    heading: '使用條款',
    effective: '自 2026 年 10 月 23 日起生效',
    body: `<p>本條款適用於由 Yumi Izumi（「我們」）提供的適用於 iPhone、iPad 和 Mac 的 Yorozu App、OpenClaw 的 Yorozu 外掛、位於 <code>relay.yumi.to</code> 的中繼，以及本網站（合稱「Yorozu」）。安裝或使用 Yorozu，即表示你同意本條款。如果你不同意，請不要使用 Yorozu。如果你從 App Store 取得 iPhone App，Apple 的<a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">標準終端使用者授權合約</a>也同樣適用。若其與本條款衝突，就 iPhone App 而言以其為準。</p>

  <h2>1. Yorozu 是什麼</h2>
  <p>Yorozu 是一款為你自己的 OpenClaw 智慧代理打造的聊天 App：它的外掛讓 Yorozu 成為你的 OpenClaw Gateway 的一個頻道，App 會把你的訊息傳給智慧代理，並帶回它的回覆。智慧代理以及它執行的任何程式設計工具（例如 Claude Code 或 OpenAI Codex），都是由你安裝和設定的軟體。Yorozu 不提供 AI 模型，不販售 AI 使用額度，也不收集你的憑證。這些工具由你自行安裝、登入和付費。</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. 你的 Claude 或 Codex 帳號可能被停用或封鎖</h2>
    <p>Anthropic 和 OpenAI 訂定其訂閱和帳號可如何使用的規則，包括透過自動化工具或第三方工具使用的情形。這些規則已多次變更，並且可能在未經通知的情況下變更。Anthropic 曾停用與第三方智慧代理工具一起使用的帳號，並表示可在未事先通知的情況下執行其限制。使用 Yorozu，透過 OpenClaw 或其他方式，以訂閱登入（例如 Claude Pro 或 Max，或 ChatGPT 方案）驅動 Claude Code 或 Codex，<strong>可能違反這些規則，並可能導致你的帳號被限制速率、停用或永久封鎖，且不予退款。</strong></p>
    <p>你須自行負責閱讀並遵守你所使用的每個供應商的條款，包括 <a href="https://www.anthropic.com/legal/consumer-terms">Anthropic 的消費者條款</a>、<a href="https://code.claude.com/docs/en/legal-and-compliance">Claude Code 法律與法規遵循條款</a>，以及 <a href="https://openai.com/policies/terms-of-use/">OpenAI 的使用條款</a>。由你付費的 API 金鑰通常是風險較低的選擇。<strong>對於供應商對你的帳號採取的任何措施，或由此造成的任何損失，我們概不負責。</strong></p>
  </div>

  <h2>3. 第三方軟體</h2>
  <p>OpenClaw、Claude Code、Codex 以及你的智慧代理使用的其他工具，都是第三方軟體，由其擁有者依據各自的授權和條款提供。OpenClaw 是 OpenClaw Foundation 的開放原始碼軟體，依據 MIT 授權條款「按現狀」提供，不附帶任何保證。我們不開發、控制或支援這些軟體或其背後的模型供應商，也不對它們的行為、輸出，或它們在你的電腦上所做的事負責。這包括它們執行的指令、變更或刪除的檔案、傳送的訊息、進行的購買，以及在你授予的權限下所做的任何事。Yorozu 與 OpenClaw Foundation、Anthropic 或 OpenAI 沒有關聯，也未獲得其認可或贊助。所有產品名稱均屬其擁有者所有。</p>

  <h2>4. 你須對你的智慧代理負責</h2>
  <p>AI 智慧代理可以在你的電腦和線上帳號上執行操作，而且會犯錯。你須負責設定它們、負責你授予的權限和核准（包括任何略過核准的模式）、負責檢查它們的輸出，並對透過你的裝置所做的一切負責。請做好備份。在故障或錯誤操作可能造成人身傷害、重大財務損失或法律損害的情況下，請不要使用 Yorozu。</p>

  <h2>5. 可接受的使用方式</h2>
  <p>不得使用 Yorozu 違反法律、侵害任何人的權利、違反供應商的條款、攻擊中繼或使其超載，或存取不屬於你的裝置或帳號。為了保護託管的中繼或其使用者，我們可能封鎖對託管中繼的存取。</p>

  <h2>6. 中繼</h2>
  <p>託管的中繼免費提供，並盡力而為。它可能隨時變慢、無法使用、被變更或停止。你也可以改為執行自己的中繼。</p>

  <h2>7. 不提供保證</h2>
  <p>在法律允許的最大範圍內，Yorozu 依「現狀」及「現有」狀態提供，不附帶任何形式的明示或默示保證，包括適售性、特定用途適用性、不侵權、正確性、安全性，以及不中斷或無錯誤運作。</p>

  <h2>8. 責任限制</h2>
  <p>在法律允許的最大範圍內，對於因 Yorozu、第三方軟體或供應商，或 AI 智慧代理所採取的操作而產生的任何間接、附帶、特殊、衍生性或懲罰性損害，或任何資料、利潤、帳號、對第三方服務或訂閱的存取權或業務的損失，即使我們已被告知可能發生此類損失，我們也不承擔責任。對於與 Yorozu 相關的任何求償，我們的總責任以你在求償前 12 個月內為 Yorozu 支付給我們的金額為限；如果你未支付任何費用，則以 10 美元為限。某些司法管轄區不允許某些排除或限制。在這些司法管轄區，它們僅在法律允許的範圍內適用。本條款中的任何內容均不限制法律上無法限制的責任，例如因故意不當行為或重大過失而產生的責任。</p>

  <h2>9. 賠償</h2>
  <p>在法律允許的範圍內，你同意就因你使用 Yorozu、你的智慧代理的行為，或你違反本條款或第三方條款而引起的求償，向我們提供賠償。</p>

  <h2>10. 變更與終止</h2>
  <p>我們可能透過在此公布新版本來更新本條款。更新後繼續使用 Yorozu，即表示你接受更新。你可以隨時刪除 App 來停止使用 Yorozu。</p>

  <h2>11. 準據法</h2>
  <p>本條款受日本法律管轄，並以東京地方法院為第一審專屬管轄法院，但你居住國家的消費者保護法律另有要求者除外。</p>

  <h2>12. 聯絡方式</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
