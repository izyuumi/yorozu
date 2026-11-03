// Français (vous). Les termes suivent Localizable.xcstrings et le texte App Store de l'app.
export default {
  name: 'Yorozu',
  skip: 'Aller au contenu',
  nav: { primary: 'Principale', footer: 'Pied de page', language: 'Langue', home: 'Accueil', support: 'Assistance', privacy: 'Confidentialité', terms: 'Conditions', getApp: "Obtenir l'app" },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. Yorozu n’est affilié ni à OpenClaw, ni à Nous Research (Hermes Agent), ni à Cua (CuaDriver), ni à Anthropic, ni à OpenAI.',
  },
  governs: 'Cette version française est une traduction fournie à titre indicatif. En cas de divergence avec la <a href="@en">version anglaise</a>, la version anglaise prévaut.',
  home: {
    title: 'Yorozu — Une app de discussion native pour votre agent OpenClaw',
    description: 'Yorozu est une app native pour iPhone, iPad et Mac qui vous permet de discuter avec votre propre agent OpenClaw, avec un chiffrement de bout en bout via un relais incapable de lire vos messages.',
    og: {
      title: 'Yorozu',
      description: 'Une app de discussion native pour votre propre agent OpenClaw, sur iPhone, iPad et Mac. Chiffrée de bout en bout.',
      imageAlt: 'L’icône de l’app Yorozu à côté des mots anglais « Your OpenClaw agent, anywhere. » (Votre agent OpenClaw, partout).',
    },
    hero: 'Votre agent OpenClaw.<br><em>Dans votre poche.</em>',
    appStore: 'Télécharger Yorozu dans l’App Store',
    downloadMac: 'Télécharger pour Mac',
    fine: 'Mac : macOS 15 ou version ultérieure · iPhone et iPad : sur l’App Store, iOS 18 ou version ultérieure · Nécessite votre propre Gateway OpenClaw · <a href="https://github.com/izyuumi/yorozu">Open source, MIT</a>',
    demo: {
      label: 'Une conversation Yorozu sur iPhone. Vous demandez si la sauvegarde de cette nuit est terminée ; l’agent vérifie sur votre ordinateur et répond.',
      title: 'À la maison',
      earlier: [['Qu’est-ce que j’ai demain ?', 'Deux choses : le dentiste à 10 h et un dîner à 19 h.'], ['Rappelle-moi d’arroser les plantes à 18 h', 'D’accord. Je vous le rappellerai à 18 h.'], ['Range mon dossier Téléchargements', 'C’est fait. J’ai classé 38 fichiers dans Documents, Images et Installeurs. Rien n’a été supprimé.']],
      ask: 'La sauvegarde de cette nuit est terminée ?',
      tools: '2 appels d’outils',
      answer: 'Oui. Elle s’est terminée à 3 h 12 et a copié 4 812 fichiers modifiés sur le disque externe. Il reste 212 Go libres.',
      placeholder: 'Message',
    },
    agent: {
      title: 'Configurez-le avec votre agent IA',
      intro: 'Collez ce prompt dans Claude Code, Codex, Cursor ou un autre agent IA. L’agent se connecte au serveur d’aide de Yorozu, vous demande si vous utilisez un Mac, un iPhone ou un iPad, puis vous guide étape par étape.',
      copy: 'Copier',
      copyLabel: 'Copier le prompt',
      copied: 'Copié',
      status: 'Prompt copié.',
      failed: 'Impossible de copier automatiquement. Le prompt est sélectionné ; utilisez la commande Copier de votre appareil.',
      note: 'Le serveur d’aide est en lecture seule et ne demande aucune connexion. Il ne fournit que la documentation de Yorozu et ne peut accéder ni à votre Gateway ni à vos conversations. Le prompt reste en anglais, que les agents suivent le plus fidèlement, et demande à l’agent de vous répondre en français.',
      language: 'French',
    },
    setupTitle: 'Ou configurez-le vous-même',
    stepsIntro: 'Il vous faut <a href="https://docs.openclaw.ai/install">OpenClaw</a> en fonctionnement avec le plug-in Yorozu. Gardez l’ordinateur de la Gateway allumé et en ligne pour joindre votre agent.',
    steps: [
      ['Installez le plug-in', 'Installez le plug-in de canal Yorozu dans votre Gateway OpenClaw (OpenClaw 2026.9.8 ou version ultérieure). Le <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">guide de configuration</a> (en anglais) contient les commandes et les réglages.'],
      ['Créez un code de jumelage', 'Sur l’ordinateur qui fait tourner votre Gateway, exécutez <code>openclaw yorozu pair</code>. La commande affiche un code QR et un lien utilisables une seule fois, qui expirent au bout de 10 minutes.'],
      ['Jumelez votre appareil', 'Scannez le QR avec l’app Appareil photo ou dans Yorozu, ou collez le lien. Vérifiez que l’empreinte correspond à celle affichée par la commande. Aucun compte Yorozu n’est nécessaire. Pour ajouter un Mac plus tard, scannez le code qu’il affiche avec un iPhone ou un iPad jumelé.'],
    ],
    docsTitle: 'Documentation et assistance',
    docs: [
      ['Guide de configuration', 'Commandes, réglages et dépannage du plug-in et des apps (en anglais).'],
      ['Serveur d’aide pour agents IA', 'Connectez n’importe quel client MCP à <code>yorozu.yumi.to/mcp</code> pour obtenir de l’aide sur la configuration et le dépannage (en anglais).'],
      ['Assistance', 'Signalez un problème ou posez une question.'],
      ['Code source', 'Yorozu est open source sous licence MIT, sur GitHub.'],
    ],
    riskTitle: 'Avant d’installer',
    risk: [
      '<strong>Votre agent agit avec les comptes que vous confiez à OpenClaw.</strong> Si OpenClaw pilote Claude Code, Codex ou un modèle via la connexion d’un abonnement, Anthropic et OpenAI décident de l’usage autorisé de cet abonnement, modifient ces règles sans préavis et ont suspendu des comptes utilisés avec des outils d’agents tiers. Pour un risque minimal, utilisez une clé d’API plutôt que la connexion d’un abonnement.',
      'Les agents d’IA agissent pour de vrai : ils exécutent des commandes, modifient et suppriment des fichiers et peuvent envoyer des messages. Vérifiez ce que votre agent est autorisé à faire. Consultez les <a href="@/terms/">Conditions d’utilisation</a>.',
    ],
  },
  pair: {
    title: 'Jumeler avec Yorozu',
    description: 'Ouvrez ce code de jumelage dans Yorozu sur votre iPhone ou iPad.',
    intro: 'Ceci est un code de jumelage Yorozu. Installez Yorozu sur cet iPhone ou iPad, puis scannez à nouveau le code. Une fois Yorozu installé, l’appareil photo l’ouvre dans l’app.',
    open: 'Ouvrir dans Yorozu',
    private: 'Le code reste sur cet appareil : il se trouve dans la partie du lien que votre navigateur ne nous envoie jamais. Gardez-le pour vous ; il ne fonctionne qu’une fois et expire.',
  },
  add: {
    title: 'Ajouter un Mac à Yorozu',
    description: 'Ouvrez ce code dans Yorozu sur un iPhone ou un iPad jumelé.',
    intro: 'Ceci est le code qu’un nouveau Mac affiche pour se jumeler à votre hôte. Scannez-le avec l’app Appareil photo, ou dans Yorozu sous Réglages › Ajouter un appareil › Scanner le code d’un Mac, sur un iPhone ou un iPad qui utilise déjà Yorozu.',
    private: 'Le code reste sur cet appareil : il se trouve dans la partie du lien que votre navigateur ne nous envoie jamais. Il ne fonctionne qu’une fois et expire au bout de 10 minutes.',
  },
  support: {
    title: 'Assistance — Yorozu',
    description: 'De l’aide pour la configuration, le jumelage et les problèmes de l’app Yorozu.',
    heading: 'Assistance Yorozu',
    body: `<p>Pour obtenir de l’aide pour installer, jumeler, connecter ou utiliser Yorozu sur votre Mac, iPhone ou iPad, écrivez à <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>.</p>

  <h2>Ce qu’il faut indiquer</h2>
  <p>Indiquez-nous quelle app Yorozu et quelle version vous utilisez, votre appareil, ce qui s’est passé et les étapes qui ont mené au problème. Joignez tout message d’erreur que vous avez vu. N’envoyez ni mot de passe, ni clé d’API, ni lien de jumelage.</p>

  <h2>Copier les diagnostics</h2>
  <p>Dans Yorozu, ouvrez Réglages › À propos et choisissez Copier les diagnostics, puis collez le résultat dans votre e-mail. Il contient la version de l’app, votre appareil, l’état de la connexion et le journal depuis ce lancement de l’app. Il ne contient aucune clé ni aucun message, et rien n’est envoyé tant que vous ne le collez pas vous-même.</p>`,
  },
  privacy: {
    title: 'Politique de confidentialité — Yorozu',
    description: 'Ce que Yorozu collecte, ce que son relais peut voir et ce qu’il ne peut pas voir.',
    heading: 'Politique de confidentialité',
    effective: 'En vigueur à compter du 2 novembre 2026',
    body: `<p>Yorozu est une app pour iPhone, iPad et Mac et un plug-in pour OpenClaw, créés par Yumi Izumi (« nous »). Le responsable du traitement (exploitant) du relais hébergé et de ce site est Yumi Izumi, une personne physique au Japon, joignable à <a href="mailto:contact@yumi.to">contact@yumi.to</a>. Cette politique explique quelles données Yorozu 0.9 et versions ultérieures traitent. En bref : <strong>nous ne gérons ni comptes, ni statistiques, ni publicité, et nous ne pouvons pas lire vos conversations.</strong></p>

  <h2>Où se trouvent vos données</h2>
  <p>Vos conversations résident dans votre propre Gateway OpenClaw, sur un ordinateur que vous contrôlez. Le plug-in Yorozu s’exécute à l’intérieur. Nous ne recevons jamais vos conversations, vos fichiers, ni vos identifiants Claude, OpenAI ou d’autres fournisseurs ; ils restent dans OpenClaw.</p>
  <ul>
    <li><strong>Dans votre Gateway</strong> : OpenClaw conserve la session et la transcription de chaque conversation, les titres générés et les fichiers que vous envoyez, comme pour tout canal. Le plug-in conserve ses clés privées dans le magasin d’identifiants d’OpenClaw, et sa liste d’appareils jumelés et l’état de lecture dans le magasin d’état d’OpenClaw.</li>
    <li><strong>Sur votre iPhone et votre iPad</strong> : un cache de vos conversations, les messages en attente d’envoi et les fichiers que vous ouvrez, chiffrés au repos par iOS et exclus des sauvegardes. Les clés de jumelage sont dans le trousseau iOS, sur cet appareil uniquement.</li>
    <li><strong>Sur votre Mac</strong> : le même cache dans <code>~/Library/Application Support/to.yumi.yorozu.ios/</code>, et les clés de jumelage dans le trousseau macOS.</li>
  </ul>
  <p>Dissocier un appareil efface son cache et ses clés.</p>

  <h2>Le relais</h2>
  <p>Vos appareils joignent votre Gateway via un relais que nous exploitons sur Cloudflare à l’adresse <code>relay.yumi.to</code>. Vous pouvez aussi exploiter le vôtre. Vos messages, pièces jointes et aperçus de notification sont chiffrés de bout en bout (une négociation Noise IK avec X25519 à chaque connexion, puis ChaCha20-Poly1305) avant d’atteindre le relais, et le relais ne dispose d’aucune clé pour les déchiffrer. Le relais traite :</p>
  <ul>
    <li><strong>Les clés publiques</strong> de votre Gateway et de vos appareils jumelés, et un identifiant de salon tiré de la clé de votre Gateway, pour vérifier qu’un appareil peut rejoindre le salon et que chaque message vient bien de lui.</li>
    <li><strong>La dernière connexion du salon et de chaque appareil</strong>, pour supprimer les salons que personne n’utilise et, une fois 16 appareils jumelés, les données de celui qui ne s’est pas connecté depuis le plus longtemps.</li>
    <li><strong>Les jetons push</strong> : les jetons push Apple de vos appareils, pour les réveiller par des notifications, et le jeton push d’une activité en direct, pour la mettre à jour.</li>
    <li><strong>Les messages chiffrés</strong> de vos appareils, conservés pendant que votre Gateway est hors ligne pour lui parvenir plus tard : jusqu’à 24 heures et 5 Mio au maximum, puis supprimés. Rien de ce qu’envoie votre Gateway n’est conservé.</li>
    <li><strong>Les pièces jointes chiffrées</strong>, transmises en fragments chiffrés de bout en bout. Le relais voit leur taille et leur horodatage.</li>
    <li><strong>Les jetons de jumelage à usage unique</strong>, pour qu’un nouvel appareil puisse rejoindre le salon une fois. Ils expirent au bout de 10 minutes.</li>
    <li><strong>La boîte aux lettres de jumelage du Mac</strong> : quand vous ajoutez un Mac, votre iPhone ou iPad y dépose une lettre chiffrée de 4 Ko au maximum. La boîte est supprimée 10 minutes après son ouverture.</li>
    <li><strong>Des compteurs</strong> : combien de notifications et de mises à jour d’activités en direct sont parties dans la minute en cours, et quand chaque appareil a été réveillé en arrière-plan pour la dernière fois, afin de respecter les limites.</li>
    <li><strong>Les adresses IP</strong>, que Cloudflare traite pour acheminer le trafic, et que le relais utilise comme clé d’une limite de connexions (30 nouvelles connexions par minute et par adresse). Nous ne les enregistrons pas. Voir la <a href="https://www.cloudflare.com/privacypolicy/">politique de confidentialité de Cloudflare</a>.</li>
    <li><strong>Les métadonnées</strong> : quand les appareils se connectent, ainsi que la taille et l’horodatage des messages. Les journaux de connexion ne contiennent que des événements et des nombres, jamais le contenu des messages, de clés ni d’adresses IP.</li>
  </ul>

  <h2>Durée de conservation sur le relais</h2>
  <p>Les données de jumelage sur le relais sont conservées jusqu’à ce que vous dissociiez, ou supprimées après 30 jours sans aucune connexion au salon depuis vos appareils ou votre Gateway. Le jumelage lui-même est enregistré sur vos propres appareils et sur votre Gateway : quand le relais supprime un salon, ils se reconnectent d’eux-mêmes, sans qu’il faille les jumeler à nouveau. Les messages en attente sont conservés 24 heures au maximum, les jetons de jumelage 10 minutes et la boîte aux lettres de jumelage du Mac 10 minutes.</p>

  <h2>Notifications</h2>
  <p>Les notifications push sont distribuées par Apple. Chaque notification de message contient un aperçu de la réponse (le titre de la conversation et sa première ligne, 256 octets au maximum), chiffré pour votre seul appareil ; c’est votre appareil qui l’ouvre. Pour les messages et les aperçus de notification, le relais et Apple ne voient que la boîte chiffrée.</p>
  <p><strong>Mises à jour de l’activité en direct</strong> : si vous utilisez l’activité en direct, ses mises à jour ne peuvent pas être chiffrées de bout en bout, car iOS doit les lire pour afficher l’activité. Elles ne contiennent que des identifiants de tâche aléatoires, le type et l’état de chaque tâche (par exemple « en cours » ou « terminée »), le nombre d’étapes d’outils et des heures. Elles ne contiennent jamais le texte ni le titre des conversations, et le relais ne les enregistre pas. Le relais conserve le jeton push de l’activité en direct pendant qu’elle est en cours, et le supprime quand l’activité se termine, quand Apple signale que le jeton ne fonctionne plus, ou quand vous dissociez l’appareil. Si le relais n’apprend pas la fin, par exemple parce que votre appareil était hors ligne, le jeton reste jusqu’à ce que l’app la signale de nouveau ou que les délais ci-dessus le suppriment.</p>

  <h2>Prestataires</h2>
  <p>Cloudflare héberge le relais et ce site, et Apple distribue les notifications push. Ces prestataires peuvent traiter des données dans d’autres pays que le vôtre, y compris aux États-Unis, selon leurs propres garanties.</p>

  <h2>Serveur d’aide et e-mails d’assistance</h2>
  <p>Le serveur d’aide à l’adresse <code>yorozu.yumi.to/mcp</code> répond à partir de la documentation de Yorozu. Il compte les requêtes par adresse IP en mémoire pour les limiter, et n’enregistre rien. Si vous nous écrivez, nous recevons ce que vous envoyez, comme votre adresse, votre message et les diagnostics que vous collez. Nous le gardons le temps de vous répondre, puis le supprimons.</p>

  <h2>OpenClaw et les fournisseurs de modèles</h2>
  <p>Yorozu transmet vos messages à votre agent OpenClaw. OpenClaw et les outils qu’il exécute envoient des données à leurs fournisseurs de modèles (par exemple Anthropic ou OpenAI) conformément à leurs propres politiques de confidentialité et à vos accords avec ces fournisseurs. Nous n’y sommes pas partie et ne recevons pas ces données.</p>

  <h2>Mises à jour et téléchargements</h2>
  <p>L’app pour iPhone et iPad est installée et mise à jour via l’App Store. L’app pour Mac vérifie les mises à jour sur <code>yorozu.yumi.to</code> et les télécharge depuis GitHub, ce qui révèle votre adresse IP et la version de l’app à Cloudflare et à GitHub, conformément à leurs politiques de confidentialité. Aucun profil système n’est envoyé. Si vous activez la saisie vocale, l’iPhone et l’iPad téléchargent son modèle vocal auprès d’Apple, comme l’app elle-même ; l’app pour Mac le télécharge depuis Hugging Face (<code>huggingface.co</code>), ce qui révèle votre adresse IP à Hugging Face, conformément à sa politique de confidentialité. Ce site n’utilise ni statistiques ni traceurs. Son seul cookie, <code>yorozu_lang</code>, est créé lorsque vous choisissez une langue et ne contient que ce choix, afin que le site s’ouvre dans cette langue la prochaine fois.</p>

  <h2>Autorisations</h2>
  <p>Yorozu ne demande des autorisations que pour la fonctionnalité qui en a besoin : l’appareil photo pour scanner un code de jumelage ou prendre une photo à envoyer, le micro pour la saisie vocale, les photos pour joindre ou enregistrer des images, et les notifications pour les réponses. La saisie vocale est transcrite sur votre appareil ; l’audio n’est jamais envoyé nulle part. Les données auxquelles l’app accède grâce aux autorisations sont utilisées sur vos appareils et ne sont envoyées qu’à votre propre Gateway, chiffrées de bout en bout.</p>

  <h2>Versions antérieures</h2>
  <p>Les versions antérieures de l’app pour Mac exécutaient leur propre assistant. Leurs données restent sur votre Mac, dans <code>~/Yorozu</code> et dans le dossier de Yorozu dans <code>~/Library/Application Support/</code>, jusqu’à ce que vous les supprimiez.</p>

  <h2>Enfants</h2>
  <p>Yorozu n’est pas destiné aux enfants de moins de 17 ans, et nous ne collectons pas sciemment leurs données.</p>

  <h2>Vos choix et vos droits</h2>
  <p>Dissocier un appareil, depuis l’app ou avec <code>openclaw yorozu devices remove</code>, supprime aussitôt ses clés et ses jetons push du relais, ou dès que votre Gateway se reconnecte s’il est hors ligne. Les délais ci-dessus suppriment le reste. Supprimer l’app efface ses données de cet appareil. Vos conversations restent dans OpenClaw jusqu’à ce que vous les y supprimiez ou les supprimiez dans Yorozu.</p>
  <p>Vous pouvez demander l’accès à vos données, leur rectification ou leur suppression, ou vous opposer à leur utilisation, en écrivant à <a href="mailto:contact@yumi.to">contact@yumi.to</a>. Nous ne détenons aucun compte ni contenu lisible, et les données du relais portent des clés d’appareil, pas des noms ; nous pourrons donc avoir besoin d’informations de votre part pour les retrouver, sans garantie d’y parvenir. Vous pouvez aussi adresser une réclamation à l’autorité de protection des données de votre lieu de résidence.</p>

  <h2>Modifications</h2>
  <p>Nous publierons les modifications ici et mettrons à jour la date ci-dessus.</p>`,
  },
  terms: {
    title: 'Conditions d’utilisation — Yorozu',
    description: 'Les conditions d’utilisation de Yorozu, y compris le risque pour les comptes Claude et Codex utilisés par les agents qu’il pilote.',
    heading: 'Conditions d’utilisation',
    effective: 'En vigueur à compter du 2 novembre 2026',
    body: `<p>Les présentes conditions s’appliquent à l’app Yorozu pour iPhone, iPad et Mac, au plug-in Yorozu pour OpenClaw, au relais à l’adresse <code>relay.yumi.to</code> et à ce site (ensemble, « Yorozu »), fournis par Yumi Izumi (« nous »). En installant ou en utilisant Yorozu, vous les acceptez. Si vous ne les acceptez pas, n’utilisez pas Yorozu. Yorozu n’est pas destiné aux enfants de moins de 17 ans. Si vous obtenez l’app pour iPhone sur l’App Store, le <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Contrat de licence utilisateur final standard</a> d’Apple s’applique également. En cas de conflit avec les présentes conditions, il prévaut pour l’app pour iPhone.</p>

  <h2>1. Ce qu’est Yorozu</h2>
  <p>Yorozu est une app de discussion pour votre propre agent OpenClaw : son plug-in fait de Yorozu un canal de votre Gateway OpenClaw, et l’app lui transmet vos messages et vous rapporte ses réponses. L’agent, ainsi que tout outil de programmation qu’il exécute, comme Claude Code ou OpenAI Codex, est un logiciel que vous installez et configurez. Yorozu ne fournit pas de modèles d’IA, ne vend pas d’utilisation d’IA et ne collecte pas vos identifiants. Vous installez ces outils, vous y connectez et les payez vous-même.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Votre compte Claude ou Codex peut être suspendu ou banni</h2>
    <p>Anthropic et OpenAI fixent les règles d’utilisation de leurs abonnements et de leurs comptes, y compris au moyen d’outils automatisés ou tiers. Ces règles ont changé à plusieurs reprises et peuvent changer sans préavis. Anthropic a suspendu des comptes utilisés avec des outils d’agents tiers et déclare pouvoir appliquer ses restrictions sans préavis. Utiliser Yorozu pour piloter Claude Code ou Codex, via OpenClaw ou autrement, avec la connexion d’un abonnement (comme Claude Pro ou Max, ou une formule ChatGPT) <strong>peut enfreindre ces règles et entraîner la limitation, la suspension ou le bannissement définitif de votre compte, sans remboursement.</strong></p>
    <p>Vous êtes seul responsable de la lecture et du respect des conditions de chaque fournisseur que vous utilisez, notamment les <a href="https://www.anthropic.com/legal/consumer-terms">Conditions grand public d’Anthropic</a>, les <a href="https://code.claude.com/docs/en/legal-and-compliance">conditions juridiques et de conformité de Claude Code</a> et les <a href="https://openai.com/policies/terms-of-use/">Conditions d’utilisation d’OpenAI</a>. Une clé d’API facturée à votre nom est généralement l’option la moins risquée. <strong>Nous ne sommes responsables d’aucune mesure prise par un fournisseur contre votre compte, ni d’aucune perte qui en résulte.</strong></p>
  </div>

  <h2>3. Logiciels tiers</h2>
  <p>OpenClaw, Claude Code, Codex et les autres outils utilisés par votre agent sont des logiciels tiers, fournis par leurs propriétaires selon leurs propres licences et conditions. OpenClaw est un logiciel open source de l’OpenClaw Foundation, sous licence MIT, fourni « en l’état », sans garantie. Nous ne développons, ne contrôlons ni ne prenons en charge ces logiciels ou les fournisseurs de modèles qui les sous-tendent, et nous ne sommes pas responsables de leur comportement, de ce qu’ils produisent ni de ce qu’ils font sur votre ordinateur. Cela comprend les commandes qu’ils exécutent, les fichiers qu’ils modifient ou suppriment, les messages qu’ils envoient, les achats qu’ils effectuent et tout ce qui est fait avec les autorisations que vous leur accordez. Yorozu n’est ni affilié à l’OpenClaw Foundation, à Anthropic ou à OpenAI, ni approuvé ou parrainé par eux. Tous les noms de produits appartiennent à leurs propriétaires.</p>

  <h2>4. Vous êtes responsable de vos agents</h2>
  <p>Les agents d’IA peuvent agir sur votre ordinateur et vos comptes en ligne, et ils commettent des erreurs. Vous êtes responsable de leur configuration, des autorisations et approbations que vous accordez (y compris tout mode qui ignore les approbations), de la vérification de leurs résultats et de tout ce qui est fait au moyen de vos appareils. Faites des sauvegardes. N’utilisez pas Yorozu là où une panne ou une action erronée pourrait causer des blessures, une perte financière importante ou un préjudice juridique.</p>

  <h2>5. Utilisation acceptable</h2>
  <p>N’utilisez pas Yorozu pour enfreindre la loi, porter atteinte aux droits de quiconque, enfreindre les conditions d’un fournisseur, attaquer ou surcharger le relais, ou accéder à des appareils ou à des comptes qui ne sont pas les vôtres. Nous pouvons bloquer l’accès au relais hébergé pour le protéger ou protéger ses utilisateurs.</p>

  <h2>6. Le relais</h2>
  <p>Le relais hébergé est fourni gratuitement et dans la mesure du possible. Il peut être lent, indisponible, modifié ou arrêté à tout moment. Vous pouvez exploiter votre propre relais à la place.</p>

  <h2>7. Absence de garantie</h2>
  <p>Dans toute la mesure permise par la loi, Yorozu est fourni « en l’état » et « selon disponibilité », sans garantie d’aucune sorte, expresse ou implicite, y compris de qualité marchande, d’adéquation à un usage particulier, d’absence de contrefaçon, d’exactitude, de sécurité et de fonctionnement ininterrompu ou exempt d’erreurs.</p>

  <h2>8. Limitation de responsabilité</h2>
  <p>Dans toute la mesure permise par la loi, nous ne sommes pas responsables des dommages indirects, accessoires, spéciaux, consécutifs ou punitifs, ni de toute perte de données, de bénéfices, de comptes, d’accès à des services ou abonnements tiers, ou d’activité, découlant de Yorozu, de logiciels ou de fournisseurs tiers, ou d’actions effectuées par des agents d’IA, même si nous avons été informés de la possibilité d’une telle perte. Notre responsabilité totale pour toute réclamation relative à Yorozu est limitée au montant que vous nous avez payé pour Yorozu au cours des 12 mois précédant la réclamation, ou à 10 USD si vous n’avez rien payé. Certaines juridictions n’autorisent pas certaines exclusions ou limitations. Dans ces juridictions, elles ne s’appliquent que dans la mesure permise par la loi. Rien dans les présentes conditions n’exclut ni ne limite notre responsabilité en cas de décès ou de dommage corporel causé par notre négligence, de faute intentionnelle ou de faute lourde, ni toute autre responsabilité que la loi ne permet pas d’exclure ou de limiter.</p>

  <h2>9. Indemnisation</h2>
  <p>Dans la mesure où la loi de votre lieu de résidence le permet, vous acceptez de nous indemniser contre les réclamations causées par votre violation des présentes conditions ou par votre usage abusif de Yorozu.</p>

  <h2>10. Modifications et résiliation</h2>
  <p>Nous pouvons mettre à jour les présentes conditions en publiant une nouvelle version ici. Nous annoncerons toute modification importante sur cette page et dans les notes de version des apps au moins 30 jours avant son entrée en vigueur. Si vous n’êtes pas d’accord, vous pouvez cesser d’utiliser Yorozu à tout moment en supprimant les apps.</p>

  <h2>11. Droit applicable</h2>
  <p>Les présentes conditions sont régies par le droit japonais, et le tribunal de district de Tokyo a compétence exclusive en tant que juridiction de première instance, sans préjudice des protections impératives des consommateurs de votre lieu de résidence.</p>

  <h2>12. Contact</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
