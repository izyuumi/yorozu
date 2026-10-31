// Português do Brasil (você). Os termos seguem Localizable.xcstrings e o texto da App Store do app.
export default {
  name: 'Yorozu',
  skip: 'Pular para o conteúdo',
  nav: { primary: 'Principal', footer: 'Rodapé', language: 'Idioma', home: 'Início', support: 'Suporte', privacy: 'Privacidade', terms: 'Termos', getApp: 'Baixar o app' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. O Yorozu não é afiliado a OpenClaw, Nous Research (Hermes Agent), Cua (CuaDriver), Anthropic nem OpenAI.',
  },
  governs: 'Esta versão em português é uma tradução de referência. Em caso de divergência com a <a href="@en">versão em inglês</a>, prevalece a versão em inglês.',
  home: {
    title: 'Yorozu — Um app de conversa nativo para o seu agente OpenClaw',
    description: 'O Yorozu é um app nativo para iPhone, iPad e Mac para conversar com o seu próprio agente OpenClaw, com criptografia de ponta a ponta por um relay que não consegue ler suas mensagens.',
    og: {
      title: 'Yorozu',
      description: 'Um app de conversa nativo para o seu próprio agente OpenClaw, no iPhone, iPad e Mac. Com criptografia de ponta a ponta.',
      imageAlt: 'O ícone do app Yorozu ao lado das palavras em inglês “Your OpenClaw agent, anywhere.” (Seu agente OpenClaw, em qualquer lugar).',
    },
    hero: 'Seu agente OpenClaw.<br><em>No seu bolso.</em>',
    appStore: 'Baixe o Yorozu na App Store',
    downloadMac: 'Baixar para Mac',
    fine: 'Mac: macOS 15 ou posterior · iPhone e iPad: na App Store, iOS 18 ou posterior · Requer o seu próprio Gateway do OpenClaw · <a href="https://github.com/izyuumi/yorozu">Código aberto, MIT</a>',
    agent: {
      title: 'Configure com seu agente de IA',
      intro: 'Cole este prompt no Claude Code, no Codex, no Cursor ou em outro agente de IA. O agente se conecta ao servidor de ajuda do Yorozu, pergunta se você usa um Mac, um iPhone ou um iPad e guia você passo a passo.',
      copy: 'Copiar',
      copyLabel: 'Copiar prompt',
      copied: 'Copiado',
      status: 'Prompt copiado.',
      failed: 'Não foi possível copiar automaticamente. O prompt está selecionado; use o comando Copiar do seu dispositivo.',
      note: 'O servidor de ajuda é somente leitura e não exige login. Ele só fornece a documentação do Yorozu e não tem acesso ao seu Gateway nem às suas conversas. O prompt fica em inglês, que os agentes seguem com mais confiabilidade, e pede ao agente que responda em português.',
      language: 'Brazilian Portuguese',
    },
    setupTitle: 'Ou configure você mesmo',
    stepsIntro: 'Você precisa do <a href="https://docs.openclaw.ai/install">OpenClaw</a> em execução com o plugin do Yorozu. Mantenha o computador do Gateway ligado e on-line para falar com o seu agente.',
    steps: [
      ['Instale o plugin', 'Instale o plugin de canal do Yorozu no seu Gateway do OpenClaw (OpenClaw 2026.9.8 ou posterior). O <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">guia de configuração</a> (em inglês) tem os comandos e as configurações.'],
      ['Gere um código de emparelhamento', 'No computador que executa o seu Gateway, rode <code>openclaw yorozu pair</code>. Ele mostra um QR code e um link que funcionam uma única vez e expiram em 10 minutos.'],
      ['Emparelhe seu dispositivo', 'Escaneie o QR com a Câmera ou no Yorozu, ou cole o link. Confira se a impressão digital é igual à que o comando mostrou. Não é preciso ter uma conta Yorozu. Para adicionar um Mac depois, escaneie o código que ele mostra com um iPhone ou iPad emparelhado.'],
    ],
    docsTitle: 'Documentação e suporte',
    docs: [
      ['Guia de configuração', 'Comandos, configurações e solução de problemas do plugin e dos apps (em inglês).'],
      ['Servidor de ajuda para agentes de IA', 'Conecte qualquer cliente MCP a <code>yorozu.yumi.to/mcp</code> para receber ajuda com a configuração e a solução de problemas (em inglês).'],
      ['Suporte', 'Relate um problema ou tire uma dúvida.'],
      ['Código-fonte', 'O Yorozu é de código aberto sob a licença MIT e está no GitHub.'],
    ],
    riskTitle: 'Antes de instalar',
    risk: [
      '<strong>Seu agente age com as contas que você dá ao OpenClaw.</strong> Se o OpenClaw controla o Claude Code, o Codex ou um modelo pelo login de uma assinatura, a Anthropic e a OpenAI decidem que uso dessa assinatura é permitido, mudam essas regras sem aviso e já suspenderam contas usadas com ferramentas de agentes de terceiros. Para o menor risco, use uma chave de API em vez do login de uma assinatura.',
      'Agentes de IA realizam ações reais: executam comandos, editam e apagam arquivos e podem enviar mensagens. Revise o que o seu agente tem permissão para fazer. Consulte os <a href="@/terms/">Termos de Uso</a>.',
    ],
  },
  pair: {
    title: 'Emparelhar com o Yorozu',
    description: 'Abra este código de emparelhamento no Yorozu no seu iPhone ou iPad.',
    intro: 'Este é um código de emparelhamento do Yorozu. Instale o Yorozu neste iPhone ou iPad e escaneie o código de novo. Com o Yorozu instalado, a câmera o abre no app.',
    open: 'Abrir no Yorozu',
    private: 'O código fica neste dispositivo: ele está na parte do link que o seu navegador nunca nos envia. Mantenha-o em sigilo; ele funciona uma única vez e expira.',
  },
  add: {
    title: 'Adicionar um Mac ao Yorozu',
    description: 'Abra este código no Yorozu em um iPhone ou iPad emparelhado.',
    intro: 'Este é o código que um Mac novo mostra para se emparelhar com o seu host. Escaneie-o com a Câmera, ou no Yorozu em Ajustes › Adicionar um dispositivo › Escanear o código de um Mac, em um iPhone ou iPad que já usa o Yorozu.',
    private: 'O código fica neste dispositivo: ele está na parte do link que o seu navegador nunca nos envia. Ele funciona uma única vez e expira em 10 minutos.',
  },
  support: {
    title: 'Suporte — Yorozu',
    description: 'Ajuda com a configuração, o emparelhamento e problemas do app Yorozu.',
    heading: 'Suporte do Yorozu',
    body: `<p>Para ajuda com a instalação, o emparelhamento, a conexão ou o uso do Yorozu no seu Mac, iPhone ou iPad, envie um e-mail para <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>.</p>

  <h2>O que incluir</h2>
  <p>Conte qual app do Yorozu e qual versão você usa, o seu dispositivo, o que aconteceu e os passos que levaram ao problema. Inclua qualquer mensagem de erro que você tenha visto. Não envie senhas, chaves de API nem links de emparelhamento.</p>

  <h2>Copiar Diagnóstico</h2>
  <p>No Yorozu, abra Ajustes › Sobre e escolha Copiar Diagnóstico; depois cole o resultado no seu e-mail. Ele inclui a versão do app, o seu dispositivo, o estado da conexão e o registro desde que o app foi aberto desta vez. Ele não contém chaves nem mensagens, e nada é enviado até que você mesmo cole.</p>`,
  },
  privacy: {
    title: 'Política de Privacidade — Yorozu',
    description: 'O que o Yorozu coleta, o que o relay dele pode ver e o que não pode.',
    heading: 'Política de Privacidade',
    effective: 'Em vigor a partir de 31 de outubro de 2026',
    body: `<p>O Yorozu é um app para iPhone, iPad e Mac e um plugin para o OpenClaw, criados por Yumi Izumi (“nós”). Esta política explica quais dados o Yorozu 0.9 e posteriores tratam. Em resumo: <strong>não mantemos contas, análises nem publicidade, e não conseguimos ler suas conversas.</strong></p>

  <h2>Onde seus dados ficam</h2>
  <p>Suas conversas ficam no seu próprio Gateway do OpenClaw, em um computador que você controla. O plugin do Yorozu roda dentro dele. Nunca recebemos suas conversas, seus arquivos nem suas credenciais do Claude, da OpenAI ou de outros provedores; elas ficam no OpenClaw.</p>
  <ul>
    <li><strong>No seu Gateway</strong>: o OpenClaw guarda a sessão e a transcrição de cada conversa, os títulos gerados e os arquivos que você envia, como faz com qualquer canal. O plugin guarda as chaves privadas no armazenamento de credenciais do OpenClaw, e a lista de dispositivos emparelhados e o estado de leitura no armazenamento de estado do OpenClaw.</li>
    <li><strong>No seu iPhone e iPad</strong>: um cache das suas conversas, as mensagens aguardando envio e os arquivos que você abre, criptografados em repouso pelo iOS e excluídos dos backups. As chaves de emparelhamento ficam nas Chaves do iOS, somente neste dispositivo.</li>
    <li><strong>No seu Mac</strong>: o mesmo cache em <code>~/Library/Application Support/to.yumi.yorozu.ios/</code>, e as chaves de emparelhamento nas Chaves do macOS.</li>
  </ul>
  <p>Desemparelhar um dispositivo apaga o cache e as chaves dele.</p>

  <h2>O relay</h2>
  <p>Seus dispositivos chegam ao seu Gateway por um relay que operamos na Cloudflare, em <code>relay.yumi.to</code>. Você também pode rodar o seu. Tudo é criptografado de ponta a ponta (um handshake Noise IK com X25519 a cada conexão e, depois, ChaCha20-Poly1305) antes de chegar ao relay, e o relay não tem nenhuma chave para descriptografar. O relay lida com:</p>
  <ul>
    <li><strong>Mensagens criptografadas</strong> dos seus dispositivos, guardadas por até 24 horas (no máximo 5 MiB) enquanto o seu Gateway está offline e depois apagadas. Nada do que o seu Gateway envia é guardado.</li>
    <li><strong>Anexos criptografados</strong>, em partes criptografadas de ponta a ponta. O relay vê o tamanho e o horário deles.</li>
    <li><strong>Chaves públicas</strong> dos dispositivos emparelhados e um identificador de sala, mantidos até você desemparelhar o dispositivo.</li>
    <li><strong>Tokens de emparelhamento de uso único</strong>, que expiram em 10 minutos.</li>
    <li><strong>O token de notificações push da Apple do seu iPhone ou iPad</strong>, para que o relay possa enviar notificações, mantido até você desemparelhar o dispositivo.</li>
    <li><strong>Metadados</strong>: quando os dispositivos se conectam, e o tamanho e o horário das mensagens. Os registros de conexão nunca contêm o conteúdo das mensagens nem chaves.</li>
    <li><strong>Endereços IP</strong>, que a Cloudflare processa para entregar o tráfego, conforme a <a href="https://www.cloudflare.com/privacypolicy/">política de privacidade da Cloudflare</a>.</li>
  </ul>

  <h2>Notificações</h2>
  <p>As notificações push são entregues pela Apple. Cada uma traz uma prévia da resposta (o título da conversa e a primeira linha, no máximo 256 bytes), criptografada só para o seu dispositivo; o seu dispositivo a abre. O relay e a Apple veem apenas a caixa criptografada.</p>

  <h2>OpenClaw e provedores de modelos</h2>
  <p>O Yorozu entrega suas mensagens ao seu agente OpenClaw. O OpenClaw e as ferramentas que ele executa enviam dados aos respectivos provedores de modelos (por exemplo, Anthropic ou OpenAI) conforme as políticas de privacidade deles e os seus acordos com esses provedores. Não somos parte disso e não recebemos esses dados.</p>

  <h2>Atualizações e downloads</h2>
  <p>O app para iPhone e iPad é instalado e atualizado pela App Store. O app para Mac procura atualizações em <code>yorozu.yumi.to</code> e as baixa do GitHub, o que revela o seu endereço IP e a versão do app à Cloudflare e ao GitHub, conforme as políticas de privacidade deles. Nenhum perfil do sistema é enviado. Se você ativar a entrada de voz, o iPhone e o iPad baixam o modelo de fala da Apple, como o próprio app; o app para Mac o baixa do Hugging Face (<code>huggingface.co</code>), o que revela o seu endereço IP ao Hugging Face, conforme a política de privacidade dele. Este site não usa análises nem rastreadores. O único cookie dele, <code>yorozu_lang</code>, é criado quando você escolhe um idioma e guarda apenas essa escolha, para que o site abra nesse idioma da próxima vez.</p>

  <h2>Permissões</h2>
  <p>O Yorozu pede permissões só para o recurso que precisa delas: a câmera para escanear um código de emparelhamento ou tirar uma foto para enviar, o microfone para a entrada de voz, as fotos para anexar ou salvar imagens e as notificações para as respostas. A entrada de voz é transcrita no seu dispositivo; o áudio nunca é enviado a lugar nenhum. Os dados acessados por meio de permissões são usados nos seus dispositivos e enviados somente ao seu próprio Gateway, com criptografia de ponta a ponta.</p>

  <h2>Versões anteriores</h2>
  <p>As versões anteriores do app para Mac executavam um assistente próprio. Os dados delas ficam no seu Mac, em <code>~/Yorozu</code> e na pasta do Yorozu em <code>~/Library/Application Support/</code>, até você apagá-los.</p>

  <h2>Crianças</h2>
  <p>O Yorozu não se destina a crianças menores de 13 anos, e não coletamos os dados delas intencionalmente.</p>

  <h2>Suas escolhas</h2>
  <p>Desemparelhar um dispositivo, pelo app ou com <code>openclaw yorozu devices remove</code>, apaga as chaves e o token push dele do relay. Apagar o app remove os dados dele desse dispositivo. Suas conversas ficam no OpenClaw até você apagá-las lá ou no Yorozu. Como não temos nenhuma conta nem conteúdo legível, não há mais nada para exportar ou apagar. Em caso de dúvidas, envie um e-mail para <a href="mailto:contact@yumi.to">contact@yumi.to</a>.</p>

  <h2>Alterações</h2>
  <p>Publicaremos as alterações aqui e atualizaremos a data acima.</p>`,
  },
  terms: {
    title: 'Termos de Uso — Yorozu',
    description: 'Os termos de uso do Yorozu, incluindo o risco para as contas do Claude e do Codex usadas pelos agentes que ele controla.',
    heading: 'Termos de Uso',
    effective: 'Em vigor a partir de 23 de outubro de 2026',
    body: `<p>Estes termos se aplicam ao app Yorozu para iPhone, iPad e Mac, ao plugin do Yorozu para o OpenClaw, ao relay em <code>relay.yumi.to</code> e a este site (em conjunto, “Yorozu”), fornecidos por Yumi Izumi (“nós”). Ao instalar ou usar o Yorozu, você concorda com eles. Se não concordar, não use o Yorozu. Se você obtiver o app para iPhone na App Store, o <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Contrato de Licença de Usuário Final Padrão</a> da Apple também se aplica. Quando houver conflito com estes termos, ele prevalece em relação ao app para iPhone.</p>

  <h2>1. O que é o Yorozu</h2>
  <p>O Yorozu é um app de conversa para o seu próprio agente OpenClaw: o plugin transforma o Yorozu em um canal do seu Gateway do OpenClaw, e o app leva suas mensagens até ele e traz as respostas de volta. O agente, e qualquer ferramenta de programação que ele execute, como o Claude Code ou o OpenAI Codex, é um software que você instala e configura. O Yorozu não fornece modelos de IA, não vende uso de IA nem coleta suas credenciais. Você mesmo instala essas ferramentas, faz login nelas e paga por elas.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Sua conta do Claude ou do Codex pode ser suspensa ou banida</h2>
    <p>A Anthropic e a OpenAI definem as regras de como suas assinaturas e contas podem ser usadas, inclusive por meio de ferramentas automatizadas ou de terceiros. Essas regras já mudaram várias vezes e podem mudar sem aviso. A Anthropic já suspendeu contas usadas com ferramentas de agentes de terceiros e declara que pode aplicar suas restrições sem aviso prévio. Usar o Yorozu para controlar o Claude Code ou o Codex, pelo OpenClaw ou de outra forma, com o login de uma assinatura (como Claude Pro ou Max, ou um plano do ChatGPT) <strong>pode violar essas regras e levar a sua conta a ser limitada, suspensa ou banida permanentemente, sem reembolso.</strong></p>
    <p>Você é o único responsável por ler e cumprir os termos de cada provedor que usa, incluindo os <a href="https://www.anthropic.com/legal/consumer-terms">Termos para Consumidores da Anthropic</a>, os <a href="https://code.claude.com/docs/en/legal-and-compliance">termos jurídicos e de conformidade do Claude Code</a> e os <a href="https://openai.com/policies/terms-of-use/">Termos de Uso da OpenAI</a>. Uma chave de API cobrada de você costuma ser a opção de menor risco. <strong>Não somos responsáveis por nenhuma medida que um provedor tome contra a sua conta nem por nenhuma perda resultante.</strong></p>
  </div>

  <h2>3. Software de terceiros</h2>
  <p>O OpenClaw, o Claude Code, o Codex e as outras ferramentas que o seu agente usa são softwares de terceiros, fornecidos pelos respectivos proprietários sob as próprias licenças e termos. O OpenClaw é um software de código aberto da OpenClaw Foundation, licenciado sob a Licença MIT “no estado em que se encontra”, sem garantia. Não desenvolvemos, controlamos nem damos suporte a esse software ou aos provedores de modelos por trás dele, e não somos responsáveis pelo comportamento dele, pelo que ele produz ou pelo que ele faz no seu computador. Isso inclui os comandos que ele executa, os arquivos que altera ou apaga, as mensagens que envia, as compras que faz e tudo o que for feito com as permissões que você conceder a ele. O Yorozu não é afiliado à OpenClaw Foundation, à Anthropic nem à OpenAI, nem endossado ou patrocinado por elas. Todos os nomes de produtos pertencem aos respectivos proprietários.</p>

  <h2>4. Você é responsável pelos seus agentes</h2>
  <p>Agentes de IA podem agir no seu computador e nas suas contas on-line, e eles cometem erros. Você é responsável por configurá-los, pelas permissões e aprovações que concede (incluindo qualquer modo que pule aprovações), por revisar os resultados deles e por tudo o que for feito por meio dos seus dispositivos. Faça backups. Não use o Yorozu onde uma falha ou uma ação equivocada possa causar lesões, perdas financeiras significativas ou danos jurídicos.</p>

  <h2>5. Uso aceitável</h2>
  <p>Não use o Yorozu para infringir a lei, violar os direitos de qualquer pessoa, violar os termos de um provedor, atacar ou sobrecarregar o relay, nem acessar dispositivos ou contas que não sejam seus. Podemos bloquear o acesso ao relay hospedado para protegê-lo ou proteger os usuários dele.</p>

  <h2>6. O relay</h2>
  <p>O relay hospedado é oferecido gratuitamente e na base do melhor esforço. Ele pode ficar lento, indisponível, ser alterado ou descontinuado a qualquer momento. Em vez disso, você pode rodar o seu próprio relay.</p>

  <h2>7. Ausência de garantia</h2>
  <p>Na máxima extensão permitida por lei, o Yorozu é fornecido “no estado em que se encontra” e “conforme disponível”, sem garantias de qualquer tipo, expressas ou implícitas, incluindo comerciabilidade, adequação a uma finalidade específica, não violação, exatidão, segurança e funcionamento ininterrupto ou livre de erros.</p>

  <h2>8. Limitação de responsabilidade</h2>
  <p>Na máxima extensão permitida por lei, não somos responsáveis por quaisquer danos indiretos, incidentais, especiais, consequenciais ou punitivos, nem por qualquer perda de dados, lucros, contas, acesso a serviços ou assinaturas de terceiros, ou negócios, decorrentes do Yorozu, de softwares ou provedores de terceiros, ou de ações realizadas por agentes de IA, mesmo que tenhamos sido avisados de que tal perda era possível. Nossa responsabilidade total por qualquer reclamação relacionada ao Yorozu se limita ao valor que você nos pagou pelo Yorozu nos 12 meses anteriores à reclamação, ou a USD 10 se você não pagou nada. Algumas jurisdições não permitem certas exclusões ou limitações. Nessas jurisdições, elas se aplicam apenas na medida em que a lei permitir. Nada nestes termos limita uma responsabilidade que não possa ser limitada por lei, como a responsabilidade por dolo ou culpa grave.</p>

  <h2>9. Indenização</h2>
  <p>Na medida permitida por lei, você concorda em nos indenizar contra reclamações decorrentes do seu uso do Yorozu, das ações dos seus agentes ou da sua violação destes termos ou dos termos de terceiros.</p>

  <h2>10. Alterações e encerramento</h2>
  <p>Podemos atualizar estes termos publicando uma nova versão aqui. Continuar usando o Yorozu depois de uma atualização significa que você a aceita. Você pode parar de usar o Yorozu a qualquer momento apagando os apps.</p>

  <h2>11. Lei aplicável</h2>
  <p>Estes termos são regidos pelas leis do Japão, e o Tribunal Distrital de Tóquio tem jurisdição exclusiva como tribunal de primeira instância, exceto quando as leis de proteção ao consumidor do seu país de residência exigirem o contrário.</p>

  <h2>12. Contato</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
