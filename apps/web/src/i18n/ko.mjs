// 한국어. 용어는 앱의 Localizable.xcstrings 및 App Store ko 텍스트와 맞춥니다.
export default {
  name: 'Yorozu',
  skip: '본문으로 건너뛰기',
  nav: { primary: '주 메뉴', footer: '바닥글', language: '언어', home: '홈', support: '지원', privacy: '개인정보', terms: '약관', getApp: '앱 받기' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. Yorozu는 OpenClaw, Nous Research(Hermes Agent), Cua(CuaDriver), Anthropic, OpenAI와 제휴 관계가 없습니다.',
  },
  governs: '이 한국어판은 참고용 번역입니다. 영어판과 내용이 다를 경우 <a href="@en">영어판</a>이 우선합니다.',
  home: {
    title: 'Yorozu — OpenClaw 에이전트를 위한 네이티브 채팅 앱',
    description: 'Yorozu는 내 OpenClaw 에이전트와 대화하는 iPhone, iPad, Mac용 네이티브 앱입니다. 메시지는 종단 간 암호화되어, 내용을 읽을 수 없는 릴레이를 거쳐 전달됩니다.',
    og: {
      title: 'Yorozu',
      description: '내 OpenClaw 에이전트를 위한 iPhone, iPad, Mac용 네이티브 채팅 앱. 종단 간 암호화.',
      imageAlt: 'Yorozu 앱 아이콘과 영어 문구 “Your OpenClaw agent, anywhere.”(어디서나 내 OpenClaw 에이전트와).',
    },
    hero: '나의 OpenClaw 에이전트,<br><em>내 손안에.</em>',
    appStore: 'App Store에서 Yorozu 받기',
    downloadMac: 'Mac용 다운로드',
    fine: 'Mac: macOS 15 이상 · iPhone 및 iPad: App Store에서 제공, iOS 18 이상 · 직접 운영하는 OpenClaw Gateway 필요 · <a href="https://github.com/izyuumi/yorozu">오픈 소스, MIT</a>',
    agent: {
      title: 'AI 에이전트로 설정하기',
      intro: '이 프롬프트를 Claude Code, Codex, Cursor 등 AI 에이전트에 붙여 넣으세요. 에이전트가 Yorozu 도움말 서버에 연결하고, Mac인지 iPhone·iPad인지 물은 뒤 한 단계씩 안내합니다.',
      copy: '복사',
      copyLabel: '프롬프트 복사',
      copied: '복사됨',
      status: '프롬프트를 복사했습니다.',
      failed: '자동으로 복사하지 못했습니다. 프롬프트를 선택해 두었으니 기기의 복사 기능을 사용하세요.',
      note: '도움말 서버는 읽기 전용이며 로그인이 필요 없습니다. Yorozu 문서만 제공하며 Gateway나 대화에는 접근할 수 없습니다. 프롬프트는 에이전트가 가장 안정적으로 따르는 영어로 두었고, 한국어로 답하도록 요청합니다.',
      language: 'Korean',
    },
    setupTitle: '직접 설정하기',
    stepsIntro: 'Yorozu 플러그인이 설치된 <a href="https://docs.openclaw.ai/install">OpenClaw</a>가 실행 중이어야 합니다. 에이전트에 연결하려면 Gateway 컴퓨터를 깨어 있고 온라인 상태로 유지하세요.',
    steps: [
      ['플러그인 설치하기', 'OpenClaw Gateway(OpenClaw 2026.9.8 이상)에 Yorozu 채널 플러그인을 설치하세요. 필요한 명령과 설정은 <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">설정 가이드</a>(영어)에 있습니다.'],
      ['페어링 코드 만들기', 'Gateway를 실행하는 컴퓨터에서 <code>openclaw yorozu pair</code>를 실행하세요. 한 번만 사용할 수 있고 10분 후 만료되는 QR 코드와 링크가 표시됩니다.'],
      ['기기 페어링하기', '카메라 또는 Yorozu에서 QR 코드를 스캔하거나 링크를 붙여 넣으세요. 지문이 명령이 표시한 것과 같은지 확인하세요. Yorozu 계정은 필요 없습니다. 나중에 Mac을 추가하려면 Mac에 표시된 코드를 페어링된 iPhone 또는 iPad로 스캔하세요.'],
    ],
    docsTitle: '문서 및 지원',
    docs: [
      ['설정 가이드', '플러그인과 앱의 명령, 설정, 문제 해결(영어).'],
      ['AI 에이전트용 도움말 서버', 'MCP 클라이언트를 <code>yorozu.yumi.to/mcp</code>에 연결하면 설정과 문제 해결에 도움을 받을 수 있습니다(영어).'],
      ['지원', '문제를 신고하거나 질문하세요.'],
      ['소스 코드', 'Yorozu는 MIT 라이선스의 오픈 소스이며 GitHub에 공개되어 있습니다.'],
    ],
    riskTitle: '설치하기 전에',
    risk: [
      '<strong>에이전트는 OpenClaw에 맡긴 계정으로 행동합니다.</strong> OpenClaw가 구독 로그인으로 Claude Code, Codex 또는 모델을 구동하는 경우, 그 구독을 어떻게 사용할 수 있는지는 Anthropic과 OpenAI가 정하며, 이들은 예고 없이 규칙을 바꾸고 서드파티 에이전트 도구와 함께 사용된 계정을 정지한 적이 있습니다. 위험을 최소화하려면 구독 로그인 대신 API 키를 사용하세요.',
      'AI 에이전트는 실제로 행동합니다. 명령을 실행하고, 파일을 편집하고 삭제하며, 메시지를 보낼 수도 있습니다. 에이전트에 무엇을 허용했는지 확인하세요. <a href="@/terms/">이용 약관</a>을 참고하세요.',
    ],
  },
  pair: {
    title: 'Yorozu와 페어링',
    description: '이 페어링 코드를 iPhone 또는 iPad의 Yorozu에서 여세요.',
    intro: 'Yorozu 페어링 코드입니다. 이 iPhone 또는 iPad에 Yorozu를 설치한 다음 코드를 다시 스캔하세요. Yorozu가 설치되어 있으면 카메라가 앱에서 바로 엽니다.',
    open: 'Yorozu에서 열기',
    private: '코드는 이 기기에만 남습니다. 링크 중 브라우저가 저희에게 절대 보내지 않는 부분에 들어 있습니다. 다른 사람에게 알리지 마세요. 한 번만 사용할 수 있으며 만료됩니다.',
  },
  add: {
    title: 'Yorozu에 Mac 추가하기',
    description: '이 코드를 페어링된 iPhone 또는 iPad의 Yorozu에서 여세요.',
    intro: '새 Mac이 호스트와 페어링하기 위해 표시하는 코드입니다. 이미 Yorozu를 사용하는 iPhone 또는 iPad에서 카메라로 스캔하거나, Yorozu의 설정 › 기기 추가 › Mac의 코드 스캔에서 스캔하세요.',
    private: '코드는 이 기기에만 남습니다. 링크 중 브라우저가 저희에게 절대 보내지 않는 부분에 들어 있습니다. 한 번만 사용할 수 있으며 10분 후 만료됩니다.',
  },
  support: {
    title: '지원 — Yorozu',
    description: 'Yorozu 설정, 페어링, 앱 문제에 대한 도움말.',
    heading: 'Yorozu 지원',
    body: `<p>Mac, iPhone 또는 iPad에서 Yorozu를 설치하거나 페어링, 연결, 사용하는 데 도움이 필요하면 <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>로 이메일을 보내 주세요.</p>

  <h2>함께 알려 주실 내용</h2>
  <p>사용 중인 Yorozu 앱과 버전, 기기, 무슨 일이 있었는지, 그리고 문제가 생기기까지의 단계를 알려 주세요. 오류 메시지를 보셨다면 함께 보내 주세요. 비밀번호, API 키, 페어링 링크는 보내지 마세요.</p>

  <h2>진단 정보 복사</h2>
  <p>Yorozu에서 설정 › 정보를 열고 진단 정보 복사를 선택한 다음, 그 결과를 이메일에 붙여 넣으세요. 앱 버전, 기기, 연결 상태, 그리고 이번에 앱을 실행한 이후의 로그가 담겨 있습니다. 키나 메시지는 포함되지 않으며, 직접 붙여 넣기 전까지는 아무것도 전송되지 않습니다.</p>`,
  },
  privacy: {
    title: '개인정보 처리방침 — Yorozu',
    description: 'Yorozu가 수집하는 정보, 그리고 릴레이가 볼 수 있는 것과 볼 수 없는 것.',
    heading: '개인정보 처리방침',
    effective: '2026년 10월 31일부터 시행',
    body: `<p>Yorozu는 Yumi Izumi(“저희”)가 만든 iPhone, iPad, Mac용 앱이자 OpenClaw용 플러그인입니다. 이 방침은 Yorozu 0.9 이상이 처리하는 데이터를 설명합니다. 요약하면, <strong>저희는 계정, 분석, 광고를 운영하지 않으며, 사용자의 대화를 읽을 수 없습니다.</strong></p>

  <h2>데이터가 있는 곳</h2>
  <p>대화는 사용자가 관리하는 컴퓨터에 있는 사용자 자신의 OpenClaw Gateway에 저장됩니다. Yorozu 플러그인은 그 안에서 실행됩니다. 저희는 사용자의 대화, 파일, 또는 Claude, OpenAI 및 기타 제공업체의 자격 증명을 받지 않으며, 이는 모두 OpenClaw에 남습니다.</p>
  <ul>
    <li><strong>Gateway 안</strong>: OpenClaw는 다른 채널과 마찬가지로 각 대화의 세션과 기록, 생성된 제목, 사용자가 보낸 파일을 보관합니다. 플러그인은 개인 키를 OpenClaw의 자격 증명 저장소에, 페어링된 기기 목록과 읽음 상태를 OpenClaw의 상태 저장소에 보관합니다.</li>
    <li><strong>iPhone 및 iPad</strong>: 대화 캐시, 전송 대기 중인 메시지, 사용자가 연 파일이 iOS에 의해 저장 시 암호화되며 백업에서 제외됩니다. 페어링 키는 이 기기에서만 iOS 키체인에 보관됩니다.</li>
    <li><strong>Mac</strong>: 같은 캐시가 <code>~/Library/Application Support/to.yumi.yorozu.ios/</code>에, 페어링 키가 macOS 키체인에 보관됩니다.</li>
  </ul>
  <p>기기의 페어링을 해제하면 해당 기기의 캐시와 키가 삭제됩니다.</p>

  <h2>릴레이</h2>
  <p>사용자의 기기는 저희가 Cloudflare에서 운영하는 릴레이 <code>relay.yumi.to</code>를 거쳐 Gateway에 연결됩니다. 직접 릴레이를 운영할 수도 있습니다. 모든 내용은 릴레이에 도달하기 전에 종단 간 암호화되며(연결마다 X25519를 사용하는 Noise IK 핸드셰이크 후 ChaCha20-Poly1305), 릴레이에는 이를 복호화할 키가 없습니다. 릴레이가 처리하는 것은 다음과 같습니다.</p>
  <ul>
    <li><strong>암호화된 메시지</strong>: 기기에서 보낸 것으로, Gateway가 오프라인인 동안 최대 24시간(최대 5MiB) 보관된 후 삭제됩니다. Gateway가 보내는 내용은 보관되지 않습니다.</li>
    <li><strong>암호화된 첨부 파일</strong>: 종단 간 암호화된 조각으로 전달됩니다. 릴레이는 그 크기와 시간을 볼 수 있습니다.</li>
    <li><strong>공개 키</strong>: 페어링된 기기의 공개 키와 방 식별자로, 해당 기기의 페어링을 해제할 때까지 보관됩니다.</li>
    <li><strong>일회용 페어링 토큰</strong>: 10분 후 만료됩니다.</li>
    <li><strong>iPhone 또는 iPad의 Apple 푸시 토큰</strong>: 릴레이가 알림을 보낼 수 있도록 하며, 해당 기기의 페어링을 해제할 때까지 보관됩니다.</li>
    <li><strong>메타데이터</strong>: 기기가 연결된 시각, 메시지의 크기와 시간. 연결 로그에는 메시지 내용이나 키가 절대 포함되지 않습니다.</li>
    <li><strong>IP 주소</strong>: 트래픽 전달을 위해 <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare의 개인정보 처리방침</a>에 따라 Cloudflare가 처리합니다.</li>
  </ul>

  <h2>알림</h2>
  <p>푸시 알림은 Apple이 전달합니다. 각 알림에는 답장의 미리보기(대화 제목과 첫 줄, 최대 256바이트)가 사용자의 기기만을 위해 암호화되어 담기며, 기기가 이를 엽니다. 릴레이와 Apple은 암호화된 상자만 볼 수 있습니다.</p>

  <h2>OpenClaw와 모델 제공업체</h2>
  <p>Yorozu는 사용자의 메시지를 OpenClaw 에이전트에 전달합니다. OpenClaw와 그것이 실행하는 도구는 각 제공업체의 개인정보 처리방침과 사용자와 해당 제공업체 간의 계약에 따라 모델 제공업체(예: Anthropic 또는 OpenAI)에 데이터를 보냅니다. 저희는 그 당사자가 아니며 그 데이터를 받지 않습니다.</p>

  <h2>업데이트와 다운로드</h2>
  <p>iPhone 및 iPad 앱은 App Store를 통해 설치되고 업데이트됩니다. Mac 앱은 <code>yorozu.yumi.to</code>에서 업데이트를 확인하고 GitHub에서 다운로드하며, 이 과정에서 Cloudflare와 GitHub의 개인정보 처리방침에 따라 사용자의 IP 주소와 앱 버전이 이들에게 공개됩니다. 시스템 프로필은 전송되지 않습니다. 음성 입력을 켜면 iPhone과 iPad는 앱과 마찬가지로 음성 모델을 Apple에서 다운로드하고, Mac 앱은 Hugging Face(<code>huggingface.co</code>)에서 다운로드하며, 이때 Hugging Face의 개인정보 처리방침에 따라 사용자의 IP 주소가 Hugging Face에 공개됩니다. 이 웹사이트는 분석 도구나 추적기를 사용하지 않습니다. 유일한 쿠키인 <code>yorozu_lang</code>은 언어를 선택할 때 설정되며, 다음에 그 언어로 사이트가 열리도록 그 선택만 담고 있습니다.</p>

  <h2>권한</h2>
  <p>Yorozu는 권한이 필요한 기능에 대해서만 권한을 요청합니다. 페어링 코드를 스캔하거나 보낼 사진을 찍기 위한 카메라, 음성 입력을 위한 마이크, 사진을 첨부하거나 저장하기 위한 사진, 답장을 위한 알림입니다. 음성 입력은 기기에서 텍스트로 변환되며, 오디오는 어디에도 전송되지 않습니다. 권한을 통해 접근한 데이터는 사용자의 기기에서 사용되며, 종단 간 암호화되어 사용자 자신의 Gateway로만 전송됩니다.</p>

  <h2>이전 버전</h2>
  <p>Mac 앱의 이전 버전은 자체 어시스턴트를 실행했습니다. 그 데이터는 삭제할 때까지 Mac의 <code>~/Yorozu</code>와 <code>~/Library/Application Support/</code> 안의 Yorozu 폴더에 남아 있습니다.</p>

  <h2>아동</h2>
  <p>Yorozu는 13세 미만 아동을 대상으로 하지 않으며, 저희는 아동의 데이터를 고의로 수집하지 않습니다.</p>

  <h2>사용자의 선택</h2>
  <p>앱에서 또는 <code>openclaw yorozu devices remove</code>로 기기의 페어링을 해제하면 릴레이에서 해당 기기의 키와 푸시 토큰이 삭제됩니다. 앱을 삭제하면 해당 기기에서 앱 데이터가 제거됩니다. 대화는 OpenClaw 또는 Yorozu에서 삭제할 때까지 OpenClaw에 남아 있습니다. 저희는 계정이나 읽을 수 있는 콘텐츠를 보유하지 않으므로, 그 밖에 내보내거나 삭제할 것은 없습니다. 문의 사항은 <a href="mailto:contact@yumi.to">contact@yumi.to</a>로 이메일을 보내 주세요.</p>

  <h2>변경</h2>
  <p>변경 사항은 이곳에 게시하고 위의 날짜를 업데이트합니다.</p>`,
  },
  terms: {
    title: '이용 약관 — Yorozu',
    description: 'Yorozu 이용 약관. Yorozu가 구동하는 에이전트가 사용하는 Claude 및 Codex 계정의 위험을 포함합니다.',
    heading: '이용 약관',
    effective: '2026년 10월 23일부터 시행',
    body: `<p>이 약관은 Yumi Izumi(“저희”)가 제공하는 iPhone, iPad, Mac용 Yorozu 앱, OpenClaw용 Yorozu 플러그인, <code>relay.yumi.to</code>의 릴레이 및 이 웹사이트(통칭 “Yorozu”)에 적용됩니다. Yorozu를 설치하거나 사용하면 이 약관에 동의하는 것입니다. 동의하지 않으면 Yorozu를 사용하지 마십시오. App Store에서 iPhone 앱을 받은 경우 Apple의 <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">표준 최종 사용자 사용권 계약</a>도 적용됩니다. 그것이 이 약관과 충돌하는 경우, iPhone 앱에 대해서는 그것이 우선합니다.</p>

  <h2>1. Yorozu란</h2>
  <p>Yorozu는 사용자 자신의 OpenClaw 에이전트를 위한 채팅 앱입니다. 플러그인이 Yorozu를 OpenClaw Gateway의 채널로 만들고, 앱이 사용자의 메시지를 에이전트에 전달하고 그 답장을 가져옵니다. 에이전트와 에이전트가 실행하는 Claude Code나 OpenAI Codex 같은 코딩 도구는 사용자가 설치하고 구성하는 소프트웨어입니다. Yorozu는 AI 모델을 제공하지 않고, AI 사용량을 판매하지 않으며, 사용자의 자격 증명을 수집하지 않습니다. 이러한 도구의 설치, 로그인, 결제는 사용자가 직접 합니다.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Claude 또는 Codex 계정이 정지되거나 영구 차단될 수 있습니다</h2>
    <p>Anthropic과 OpenAI는 자동화 도구나 서드파티 도구를 통한 사용을 포함하여, 자사 구독과 계정을 어떻게 사용할 수 있는지에 대한 규칙을 정합니다. 이 규칙은 여러 차례 변경되었으며 예고 없이 변경될 수 있습니다. Anthropic은 서드파티 에이전트 도구와 함께 사용된 계정을 정지한 적이 있으며, 사전 통지 없이 제한을 시행할 수 있다고 밝히고 있습니다. OpenClaw를 통하든 다른 방법을 통하든, 구독 로그인(Claude Pro 또는 Max, ChatGPT 요금제 등)으로 Claude Code나 Codex를 구동하는 데 Yorozu를 사용하는 것은 <strong>이 규칙을 위반할 수 있으며, 그 결과 계정이 속도 제한, 정지 또는 영구 차단될 수 있고 환불도 되지 않을 수 있습니다.</strong></p>
    <p><a href="https://www.anthropic.com/legal/consumer-terms">Anthropic의 소비자 약관</a>, <a href="https://code.claude.com/docs/en/legal-and-compliance">Claude Code 법률 및 규정 준수 약관</a>, <a href="https://openai.com/policies/terms-of-use/">OpenAI의 이용 약관</a>을 포함하여, 사용하는 모든 제공업체의 약관을 읽고 준수할 책임은 전적으로 사용자에게 있습니다. 일반적으로 사용자에게 청구되는 API 키가 위험이 더 낮은 선택입니다. <strong>저희는 제공업체가 사용자의 계정에 대해 취하는 어떠한 조치나 그로 인한 어떠한 손실에 대해서도 책임지지 않습니다.</strong></p>
  </div>

  <h2>3. 서드파티 소프트웨어</h2>
  <p>OpenClaw, Claude Code, Codex 및 에이전트가 사용하는 기타 도구는 각 소유자가 자체 라이선스와 약관에 따라 제공하는 서드파티 소프트웨어입니다. OpenClaw는 OpenClaw Foundation의 오픈 소스 소프트웨어로, MIT 라이선스에 따라 보증 없이 “있는 그대로” 제공됩니다. 저희는 그 소프트웨어나 그 배후의 모델 제공업체를 개발, 관리 또는 지원하지 않으며, 그것이 어떻게 동작하는지, 무엇을 출력하는지, 사용자의 컴퓨터에서 무엇을 하는지에 대해 책임지지 않습니다. 여기에는 그것이 실행하는 명령, 변경하거나 삭제하는 파일, 보내는 메시지, 하는 구매, 사용자가 부여한 권한으로 수행되는 모든 일이 포함됩니다. Yorozu는 OpenClaw Foundation, Anthropic, OpenAI와 제휴하거나 이들의 보증 또는 후원을 받지 않습니다. 모든 제품명은 각 소유자에게 귀속됩니다.</p>

  <h2>4. 에이전트에 대한 사용자의 책임</h2>
  <p>AI 에이전트는 사용자의 컴퓨터와 온라인 계정에서 행동할 수 있으며, 실수를 합니다. 에이전트의 구성, 사용자가 부여하는 권한과 승인(승인을 건너뛰는 모드 포함), 에이전트 출력의 검토, 그리고 사용자의 기기를 통해 이루어지는 모든 일에 대한 책임은 사용자에게 있습니다. 백업을 해 두십시오. 장애나 잘못된 조치가 부상, 상당한 금전적 손실 또는 법적 피해를 일으킬 수 있는 곳에서는 Yorozu를 사용하지 마십시오.</p>

  <h2>5. 허용되는 사용</h2>
  <p>법을 어기거나, 타인의 권리를 침해하거나, 제공업체의 약관을 위반하거나, 릴레이를 공격하거나 과부하를 일으키거나, 본인의 것이 아닌 기기나 계정에 접근하는 데 Yorozu를 사용하지 마십시오. 저희는 호스팅 릴레이나 그 사용자를 보호하기 위해 호스팅 릴레이에 대한 접근을 차단할 수 있습니다.</p>

  <h2>6. 릴레이</h2>
  <p>호스팅 릴레이는 무료로, 최선의 노력을 기준으로 제공됩니다. 언제든지 느려지거나, 사용할 수 없거나, 변경되거나, 중단될 수 있습니다. 대신 직접 릴레이를 운영할 수도 있습니다.</p>

  <h2>7. 보증의 부인</h2>
  <p>법이 허용하는 최대한의 범위에서, Yorozu는 상품성, 특정 목적에의 적합성, 비침해, 정확성, 보안, 중단이나 오류 없는 동작을 포함하여 명시적이든 묵시적이든 어떠한 종류의 보증도 없이 “있는 그대로” 및 “제공 가능한 상태로” 제공됩니다.</p>

  <h2>8. 책임의 제한</h2>
  <p>법이 허용하는 최대한의 범위에서, 저희는 Yorozu, 서드파티 소프트웨어 또는 제공업체, 또는 AI 에이전트가 취한 조치로 인해 발생하는 간접적, 부수적, 특별, 결과적 또는 징벌적 손해, 또는 데이터, 수익, 계정, 서드파티 서비스나 구독에 대한 접근, 또는 사업의 손실에 대해, 그러한 손실의 가능성을 알았더라도 책임지지 않습니다. Yorozu와 관련된 모든 청구에 대한 저희의 총 책임은 청구 전 12개월 동안 사용자가 Yorozu에 대해 저희에게 지불한 금액으로 제한되며, 지불한 금액이 없는 경우 10미국 달러로 제한됩니다. 일부 관할권에서는 특정 배제나 제한을 허용하지 않습니다. 그러한 관할권에서는 법이 허용하는 범위에서만 적용됩니다. 이 약관의 어떠한 내용도 고의적 위법 행위나 중과실에 대한 책임 등 법으로 제한할 수 없는 책임을 제한하지 않습니다.</p>

  <h2>9. 면책</h2>
  <p>법이 허용하는 범위에서, 사용자는 사용자의 Yorozu 사용, 에이전트의 행위, 또는 이 약관이나 제3자 약관의 위반으로 인해 발생하는 청구에 대해 저희를 면책하는 데 동의합니다.</p>

  <h2>10. 변경 및 종료</h2>
  <p>저희는 새 버전을 이곳에 게시하여 이 약관을 업데이트할 수 있습니다. 업데이트 후에도 Yorozu를 계속 사용하면 업데이트에 동의하는 것입니다. 사용자는 언제든지 앱을 삭제하여 Yorozu 사용을 중단할 수 있습니다.</p>

  <h2>11. 준거법</h2>
  <p>이 약관은 일본법에 따르며, 도쿄 지방법원을 제1심 전속 관할 법원으로 합니다. 다만 사용자가 거주하는 국가의 소비자 보호법이 달리 요구하는 경우에는 그러하지 않습니다.</p>

  <h2>12. 연락처</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
