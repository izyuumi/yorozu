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
    lede: 'Yorozu<span class="kana" lang="ja">(よろず)</span>는 이미 실행 중인 <a href="https://docs.openclaw.ai/install">OpenClaw</a> 에이전트를 위한 네이티브 채팅 앱입니다. 플러그인이 Yorozu를 Signal이나 Telegram처럼 Gateway의 채널로 만들고, iPhone, iPad 또는 Mac의 앱이 종단 간 암호화로 그 채널과 통신합니다. 에이전트와 그 기억, 일정은 OpenClaw가 실행하고, Yorozu는 대화를 전달합니다.',
    appStore: 'App Store에서 Yorozu 받기',
    downloadMac: 'Mac용 다운로드',
    setUpPlugin: '플러그인 설정하기',
    fine: 'Mac: Yorozu 0.10, macOS 15 이상 · iPhone 및 iPad: App Store에서 제공, iOS 18 이상 · 직접 운영하는 OpenClaw Gateway 필요 · <a href="https://github.com/izyuumi/yorozu">오픈 소스, MIT</a>',
    chatTitle: '모든 대화를, 모든 기기에서.',
    chatFacts: [
      ['여러 개의 대화', '+로 새 대화를 시작하세요. 각 대화는 별도의 OpenClaw 세션이며, 페어링된 모든 기기에 표시되고 전체 기록을 Gateway에서 불러옵니다.'],
      ['나란히 보기', 'iPad와 iPhone Duo에서 두 대화를 나란히 열거나, 대화를 화면으로 끌어 와 지금 보고 있는 대화 옆에 열 수 있습니다.'],
      ['작업 과정 보기', '답장은 완성된 형태로 도착합니다. 에이전트가 작업하는 동안 입력 중 표시가 나타나고, 각 도구 호출은 접힌 한 줄로 표시됩니다.'],
      ['전달 및 읽음 표시', '모든 메시지는 보냄에서 전달됨, 읽음으로 바뀝니다. 읽음 상태와 읽지 않음 배지는 모든 기기에서 동기화됩니다.'],
      ['답장과 반응', '특정 메시지에 답장하거나 이모지로 반응할 수 있습니다. 에이전트는 어떤 메시지를 말하는지 알고, 반응할 수도 있습니다.'],
      ['고정, 검색, 이름 변경', '자주 쓰는 대화를 목록 맨 위에 고정하고 검색할 수 있으며, Siri와 Spotlight에서도 찾을 수 있습니다. 제목은 첫 대화 후 자동으로 만들어집니다. 어느 기기에서든 이름 변경, 보관, 삭제를 하면 다른 기기에도 반영됩니다.'],
    ],
    moreTitle: '이미 실행 중인 에이전트를 위해 만들었습니다.',
    moreFacts: [
      ['자동화', '에이전트의 예약된 작업과 다음 실행 시각을 확인하고, 채팅에서 편집으로 작업을 바꿀 수 있습니다. 에이전트가 자신의 도구로 직접 수정합니다. 작업 결과를 대화로 보낼 수도 있습니다.'],
      ['파일 주고받기', '사진과 파일을 보내고, 입력창에 붙여 넣거나 입력창에서 바로 사진을 찍고, 다른 앱에서 공유할 수도 있습니다. 에이전트가 돌려준 파일은 대화 안에서 열립니다.'],
      ['알림', '답장이 끝날 때마다 푸시는 한 번만 오며, 미리보기는 내 기기만 열 수 있습니다. 지금 보고 있는 대화는 푸시를 보내지 않습니다.'],
      ['음성 입력', '설정에서 켜면 타이핑 대신 말로 입력할 수 있습니다. 음성은 기기에서 텍스트로 변환되며, 오디오는 어디에도 전송되지 않습니다. iPhone과 iPad에서는 iOS 26 이상이 필요합니다.'],
      ['네이티브 앱', 'iPhone, iPad, Mac에서 동작하는 SwiftUI 앱으로, 라이트, 다크 또는 시스템 화면 모드와 여덟 가지 강조 색상을 고를 수 있습니다. Mac과 iPad에서는 텍스트를 75%에서 200%까지 확대할 수 있습니다.'],
      ['사용자의 언어로', '앱과 이 웹사이트는 영어, 일본어, 중국어 간체, 중국어 번체, 한국어, 스페인어, 프랑스어, 독일어, 브라질 포르투갈어를 지원합니다.'],
    ],
    relayTitle: '릴레이는 한 글자도 읽을 수 없습니다.',
    diagram: {
      label: '내 기기와 OpenClaw Gateway는 크기와 시간만 볼 수 있는 릴레이를 거쳐 ChaCha20-Poly1305로 암호화된 메시지를 주고받습니다.',
      encryption: 'ChaCha20-Poly1305 · 종단 간 암호화',
      relay: '크기와 시간만 봄',
    },
    relayFacts: [
      ['연결마다 새 키', '연결할 때마다 Noise IK 핸드셰이크를 수행합니다. 개인 키는 기기의 키체인과 Gateway의 자격 증명 저장소에만 있습니다.'],
      ['포트 개방 불필요', '플러그인이 릴레이로 직접 연결하므로, Gateway를 실행하는 컴퓨터에 포트 포워딩이 필요 없습니다.'],
      ['잠자는 동안에도 전송', 'Gateway가 오프라인인 동안 릴레이는 기기가 보낸 내용을 봉인된 상태로 최대 24시간 보관하고, Gateway가 돌아오면 전달합니다.'],
      ['Yorozu 계정 없음', '이메일도, 비밀번호도, 분석 도구도 없습니다. 모델 제공업체와 로그인 정보는 OpenClaw에 남아 있습니다.'],
    ],
    getTitle: 'Yorozu 받기.',
    getIntro: 'Yorozu는 OpenClaw Gateway의 플러그인과 각 기기의 앱, 두 부분으로 이루어집니다.',
    plugin: {
      title: '플러그인',
      text: 'OpenClaw Gateway(OpenClaw 2026.9.8 이상)에 Yorozu 채널 플러그인을 설치하세요. 필요한 명령과 설정은 <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">설정 가이드</a>(영어)에 있습니다.',
      link: '설정 가이드 열기',
    },
    ios: {
      title: 'iPhone 및 iPad',
      text: 'Yorozu는 iOS 18 이상의 iPhone과 iPad용으로 App Store에 있습니다. 아직 Gateway가 없나요? 페어링 화면에 <code>YOROZU-DEMO</code>를 입력하면 예시 대화로 둘러볼 수 있습니다.',
    },
    mac: {
      title: 'Mac',
      text: '같은 앱이 macOS 15 이상의 Mac에서 네이티브로 실행되며, 현재 버전은 Yorozu 0.10입니다. 응용 프로그램 폴더로 옮겨 열면 이후에는 스스로 업데이트됩니다.',
    },
    stepsTitle: '그다음 한 번만 페어링하세요.',
    stepsIntro: 'Yorozu 플러그인이 설치된 <a href="https://docs.openclaw.ai/install">OpenClaw</a>가 실행 중이어야 합니다. 에이전트에 연결하려면 Gateway 컴퓨터를 깨어 있고 온라인 상태로 유지하세요.',
    steps: [
      ['페어링 코드 만들기', 'Gateway를 실행하는 컴퓨터에서 <code>openclaw yorozu pair</code>를 실행하세요. 한 번만 사용할 수 있고 10분 후 만료되는 QR 코드와 링크가 표시됩니다.'],
      ['기기 페어링하기', '카메라 또는 Yorozu에서 QR 코드를 스캔하거나 링크를 붙여 넣으세요. 지문이 명령이 표시한 것과 같은지 확인하세요. Yorozu 계정은 필요 없습니다. 나중에 Mac을 추가하려면 Mac에 표시된 코드를 페어링된 iPhone 또는 iPad로 스캔하세요.'],
      ['어디서나 대화하기', '대화는 OpenClaw에 저장됩니다. 페어링된 모든 기기가 릴레이를 통해 모든 대화를 볼 수 있습니다.'],
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
