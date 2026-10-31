// Español (tú). Los términos siguen Localizable.xcstrings y el texto de la app en el App Store.
export default {
  name: 'Yorozu',
  skip: 'Saltar al contenido',
  nav: { primary: 'Principal', footer: 'Pie de página', language: 'Idioma', home: 'Inicio', support: 'Soporte', privacy: 'Privacidad', terms: 'Términos', getApp: 'Obtener la app' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. Yorozu no está afiliado a OpenClaw, Nous Research (Hermes Agent), Cua (CuaDriver), Anthropic ni OpenAI.',
  },
  governs: 'Esta versión en español es una traducción de referencia. Si difiere de la <a href="@en">versión en inglés</a>, prevalece la versión en inglés.',
  home: {
    title: 'Yorozu — Una app de chat nativa para tu agente de OpenClaw',
    description: 'Yorozu es una app nativa para iPhone, iPad y Mac con la que chateas con tu propio agente de OpenClaw, con cifrado de extremo a extremo a través de un relé que no puede leer tus mensajes.',
    og: {
      title: 'Yorozu',
      description: 'Una app de chat nativa para tu propio agente de OpenClaw, en iPhone, iPad y Mac. Con cifrado de extremo a extremo.',
      imageAlt: 'El icono de la app Yorozu junto al texto en inglés «Your OpenClaw agent, anywhere.» (Tu agente de OpenClaw, en cualquier lugar).',
    },
    hero: 'Tu agente de OpenClaw.<br><em>En tu bolsillo.</em>',
    lede: 'Yorozu <span class="kana" lang="ja">(よろず)</span> es una app de chat nativa para el agente de <a href="https://docs.openclaw.ai/install">OpenClaw</a> que ya tienes en marcha. Su plugin convierte Yorozu en un canal de tu Gateway, como Signal o Telegram, y la app de tu iPhone, iPad o Mac se comunica con él con cifrado de extremo a extremo. OpenClaw ejecuta el agente, su memoria y sus tareas programadas; Yorozu lleva la conversación.',
    appStore: 'Obtén Yorozu en el App Store',
    downloadMac: 'Descargar para Mac',
    setUpPlugin: 'Configurar el plugin',
    fine: 'Mac: Yorozu 0.10, macOS 15 o posterior · iPhone y iPad: en el App Store, iOS 18 o posterior · Necesitas tu propio Gateway de OpenClaw · <a href="https://github.com/izyuumi/yorozu">Código abierto, MIT</a>',
    chatTitle: 'Todas tus conversaciones, en todos tus dispositivos.',
    chatFacts: [
      ['Muchas conversaciones', 'Empieza una conversación nueva con +. Cada una es su propia sesión de OpenClaw, aparece en todos los dispositivos emparejados y carga el historial completo desde tu Gateway.'],
      ['Una al lado de otra', 'Abre dos conversaciones una al lado de otra en el iPad y el iPhone Duo, o arrastra una conversación a la pantalla para abrirla junto a la que tienes abierta.'],
      ['Ve el trabajo', 'Las respuestas llegan completas, con un indicador de escritura mientras el agente trabaja y cada llamada a una herramienta en una fila contraída.'],
      ['Marcas de entrega y lectura', 'Cada mensaje pasa de Enviado a Entregado y a Leído. El estado de lectura y las insignias de no leídos se mantienen sincronizados en todos tus dispositivos.'],
      ['Respuestas y reacciones', 'Responde a un mensaje concreto o reacciona con un emoji. Tu agente sabe a qué mensaje te refieres y también puede reaccionar.'],
      ['Fijar, buscar, renombrar', 'Fija arriba de la lista las conversaciones que más usas y búscalas; Siri y Spotlight también las encuentran. Los títulos se crean solos tras el primer turno. Renombra, archiva o elimina desde cualquier dispositivo y los demás se actualizan.'],
    ],
    moreTitle: 'Hecha para el agente que ya tienes en marcha.',
    moreFacts: [
      ['Automatizaciones', 'Consulta las tareas programadas de tu agente con su próxima ejecución y cambia una con Editar en el chat: el agente la modifica con sus propias herramientas. Una tarea puede entregar su resultado en una conversación.'],
      ['Archivos en ambos sentidos', 'Envía fotos y archivos, pégalos en el campo de texto o toma una foto desde él, o compártelos desde otras apps. Los archivos que devuelve el agente se abren en la conversación.'],
      ['Notificaciones', 'Una notificación por cada respuesta terminada, con una vista previa que solo tu dispositivo puede abrir. No se envía nada de la conversación que estás viendo.'],
      ['Entrada de voz', 'Actívala en Ajustes y habla en lugar de escribir. La voz se transcribe en tu dispositivo y el audio nunca se envía a ninguna parte. En iPhone y iPad requiere iOS 26 o posterior.'],
      ['Una app nativa', 'SwiftUI en iPhone, iPad y Mac, con apariencia clara, oscura o del sistema y ocho colores de acento. En el Mac y el iPad, amplía el texto del 75 % al 200 %.'],
      ['En tu idioma', 'La app y este sitio web están en inglés, japonés, chino simplificado y tradicional, coreano, español, francés, alemán y portugués de Brasil.'],
    ],
    relayTitle: 'El relé no puede leer ni una palabra.',
    diagram: {
      label: 'Tus dispositivos y tu Gateway de OpenClaw intercambian mensajes cifrados con ChaCha20-Poly1305 a través de un relé que solo ve el tamaño y el momento.',
      encryption: 'ChaCha20-Poly1305 · Cifrado de extremo a extremo',
      relay: 've tamaño y momento',
    },
    relayFacts: [
      ['Claves nuevas en cada conexión', 'Cada conexión realiza un handshake Noise IK. Las claves privadas se quedan en el llavero del dispositivo y en el almacén de credenciales de tu Gateway.'],
      ['Sin puertos abiertos', 'El plugin se conecta hacia fuera al relé, así que el ordenador donde corre tu Gateway no necesita redirección de puertos.'],
      ['Envía mientras duerme', 'Mientras tu Gateway está desconectado, el relé guarda lo que envían tus dispositivos hasta 24 horas, sellado, y lo entrega cuando el Gateway vuelve.'],
      ['Sin cuenta de Yorozu', 'Sin correo, sin contraseña, sin analíticas. Tus proveedores de modelos y sus inicios de sesión se quedan en OpenClaw.'],
    ],
    getTitle: 'Obtén Yorozu.',
    getIntro: 'Yorozu tiene dos partes: el plugin en tu Gateway de OpenClaw y la app en cada dispositivo.',
    plugin: {
      title: 'El plugin',
      text: 'Instala el plugin de canal de Yorozu en tu Gateway de OpenClaw (OpenClaw 2026.9.8 o posterior). La <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">guía de configuración</a> (en inglés) tiene los comandos y ajustes.',
      link: 'Abrir la guía de configuración',
    },
    ios: {
      title: 'iPhone y iPad',
      text: 'Yorozu está en el App Store para iPhone y iPad con iOS 18 o posterior. ¿Aún no tienes un Gateway? Introduce <code>YOROZU-DEMO</code> en la pantalla de emparejamiento para explorar con conversaciones de ejemplo.',
    },
    mac: {
      title: 'Mac',
      text: 'La misma app funciona de forma nativa en Mac con macOS 15 o posterior; Yorozu 0.10 es la versión actual. Muévela a Aplicaciones y ábrela; se actualiza sola.',
    },
    stepsTitle: 'Después, empareja una sola vez.',
    stepsIntro: 'Necesitas <a href="https://docs.openclaw.ai/install">OpenClaw</a> en marcha con el plugin de Yorozu. Mantén el ordenador del Gateway encendido y conectado para llegar a tu agente.',
    steps: [
      ['Crea un código de enlace', 'En el ordenador donde corre tu Gateway, ejecuta <code>openclaw yorozu pair</code>. Muestra un código QR y un enlace que funcionan una sola vez y caducan a los 10 minutos.'],
      ['Empareja tu dispositivo', 'Escanea el QR con la Cámara o en Yorozu, o pega el enlace. Comprueba que la huella coincide con la que mostró el comando. No necesitas una cuenta de Yorozu. Para añadir un Mac más adelante, escanea el código que muestra con un iPhone o iPad emparejado.'],
      ['Habla desde cualquier lugar', 'Tus conversaciones viven en OpenClaw. Todos los dispositivos emparejados las ven todas, a través del relé.'],
    ],
    riskTitle: 'Antes de instalar',
    risk: [
      '<strong>Tu agente actúa con las cuentas que le das a OpenClaw.</strong> Si OpenClaw maneja Claude Code, Codex o un modelo mediante el inicio de sesión de una suscripción, Anthropic y OpenAI deciden qué uso de esa suscripción está permitido, cambian esas reglas sin aviso y han suspendido cuentas usadas con herramientas de agentes de terceros. Para el menor riesgo, usa una clave de API en lugar del inicio de sesión de una suscripción.',
      'Los agentes de IA realizan acciones reales: ejecutan comandos, editan y eliminan archivos y pueden enviar mensajes. Revisa lo que tu agente tiene permitido hacer. Consulta los <a href="@/terms/">Términos de uso</a>.',
    ],
  },
  pair: {
    title: 'Emparejar con Yorozu',
    description: 'Abre este código de enlace en Yorozu en tu iPhone o iPad.',
    intro: 'Este es un código de enlace de Yorozu. Instala Yorozu en este iPhone o iPad y vuelve a escanear el código. Con Yorozu instalado, la cámara lo abre en la app.',
    open: 'Abrir en Yorozu',
    private: 'El código se queda en este dispositivo: está en la parte del enlace que tu navegador nunca nos envía. No lo compartas; funciona una sola vez y caduca.',
  },
  add: {
    title: 'Añadir un Mac a Yorozu',
    description: 'Abre este código en Yorozu en un iPhone o iPad emparejado.',
    intro: 'Este es el código que muestra un Mac nuevo para emparejarse con tu host. Escanéalo con la Cámara, o en Yorozu en Ajustes › Añadir un dispositivo › Escanear el código de un Mac, en un iPhone o iPad que ya use Yorozu.',
    private: 'El código se queda en este dispositivo: está en la parte del enlace que tu navegador nunca nos envía. Funciona una sola vez y caduca a los 10 minutos.',
  },
  support: {
    title: 'Soporte — Yorozu',
    description: 'Ayuda con la configuración, el emparejamiento y los problemas de la app Yorozu.',
    heading: 'Soporte de Yorozu',
    body: `<p>Si necesitas ayuda para instalar, emparejar, conectar o usar Yorozu en tu Mac, iPhone o iPad, escribe a <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>.</p>

  <h2>Qué incluir</h2>
  <p>Dinos qué app de Yorozu y qué versión usas, tu dispositivo, qué ocurrió y los pasos que llevaron al problema. Incluye cualquier mensaje de error que hayas visto. No envíes contraseñas, claves de API ni enlaces de emparejamiento.</p>

  <h2>Copiar diagnóstico</h2>
  <p>En Yorozu, abre Ajustes › Acerca de y elige Copiar diagnóstico; después pega el resultado en tu correo. Incluye la versión de la app, tu dispositivo, el estado de la conexión y el registro desde que se abrió la app esta vez. No contiene claves ni mensajes, y no se envía nada hasta que lo pegues tú.</p>`,
  },
  privacy: {
    title: 'Política de privacidad — Yorozu',
    description: 'Qué recopila Yorozu, qué puede ver su relé y qué no.',
    heading: 'Política de privacidad',
    effective: 'Vigente desde el 31 de octubre de 2026',
    body: `<p>Yorozu es una app para iPhone, iPad y Mac y un plugin para OpenClaw, creados por Yumi Izumi («nosotros»). Esta política explica qué datos maneja Yorozu 0.9 y versiones posteriores. En resumen: <strong>no gestionamos cuentas, analíticas ni publicidad, y no podemos leer tus conversaciones.</strong></p>

  <h2>Dónde están tus datos</h2>
  <p>Tus conversaciones están en tu propio Gateway de OpenClaw, en un ordenador que tú controlas. El plugin de Yorozu se ejecuta dentro de él. Nunca recibimos tus conversaciones, tus archivos ni tus credenciales de Claude, OpenAI u otros proveedores; todo eso se queda en OpenClaw.</p>
  <ul>
    <li><strong>En tu Gateway</strong>: OpenClaw guarda la sesión y la transcripción de cada conversación, los títulos generados y los archivos que envías, como hace con cualquier canal. El plugin guarda sus claves privadas en el almacén de credenciales de OpenClaw, y su lista de dispositivos emparejados y el estado de lectura en el almacén de estado de OpenClaw.</li>
    <li><strong>En tu iPhone y iPad</strong>: una caché de tus conversaciones, los mensajes pendientes de envío y los archivos que abres, cifrados en reposo por iOS y excluidos de las copias de seguridad. Las claves de emparejamiento están en el llavero de iOS, solo en este dispositivo.</li>
    <li><strong>En tu Mac</strong>: la misma caché en <code>~/Library/Application Support/to.yumi.yorozu.ios/</code>, y las claves de emparejamiento en el llavero de macOS.</li>
  </ul>
  <p>Desemparejar un dispositivo borra su caché y sus claves.</p>

  <h2>El relé</h2>
  <p>Tus dispositivos llegan a tu Gateway a través de un relé que operamos en Cloudflare, en <code>relay.yumi.to</code>. También puedes ejecutar el tuyo. Todo se cifra de extremo a extremo (un handshake Noise IK con X25519 en cada conexión y, después, ChaCha20-Poly1305) antes de llegar al relé, y el relé no tiene ninguna clave para descifrarlo. El relé sí maneja:</p>
  <ul>
    <li><strong>Mensajes cifrados</strong> de tus dispositivos, guardados hasta 24 horas (5 MiB como máximo) mientras tu Gateway está desconectado y luego eliminados. No se guarda nada de lo que envía tu Gateway.</li>
    <li><strong>Archivos adjuntos cifrados</strong>, en fragmentos cifrados de extremo a extremo. El relé ve su tamaño y su momento.</li>
    <li><strong>Claves públicas</strong> de los dispositivos emparejados y un identificador de sala, conservados hasta que desemparejes el dispositivo.</li>
    <li><strong>Tokens de emparejamiento de un solo uso</strong>, que caducan a los 10 minutos.</li>
    <li><strong>El token de notificaciones push de Apple de tu iPhone o iPad</strong>, para que el relé pueda enviar notificaciones, conservado hasta que desemparejes el dispositivo.</li>
    <li><strong>Metadatos</strong>: cuándo se conectan los dispositivos, y el tamaño y el momento de los mensajes. Los registros de conexión nunca contienen el contenido de los mensajes ni claves.</li>
    <li><strong>Direcciones IP</strong>, que Cloudflare procesa para entregar el tráfico, según la <a href="https://www.cloudflare.com/privacypolicy/">política de privacidad de Cloudflare</a>.</li>
  </ul>

  <h2>Notificaciones</h2>
  <p>Apple entrega las notificaciones push. Cada una lleva una vista previa de la respuesta (el título de la conversación y su primera línea, 256 bytes como máximo), cifrada solo para tu dispositivo; tu dispositivo la abre. El relé y Apple solo ven la caja cifrada.</p>

  <h2>OpenClaw y los proveedores de modelos</h2>
  <p>Yorozu entrega tus mensajes a tu agente de OpenClaw. OpenClaw y las herramientas que ejecuta envían datos a sus proveedores de modelos (por ejemplo, Anthropic u OpenAI) según sus propias políticas de privacidad y tus acuerdos con esos proveedores. No somos parte de ello y no recibimos esos datos.</p>

  <h2>Actualizaciones y descargas</h2>
  <p>La app para iPhone y iPad se instala y se actualiza a través del App Store. La app para Mac busca actualizaciones en <code>yorozu.yumi.to</code> y las descarga de GitHub, lo que revela tu dirección IP y la versión de la app a Cloudflare y GitHub según sus políticas de privacidad. No se envía ningún perfil del sistema. Si activas la entrada de voz, el iPhone y el iPad descargan su modelo de voz de Apple, como la propia app; la app para Mac lo descarga de Hugging Face (<code>huggingface.co</code>), lo que revela tu dirección IP a Hugging Face según su política de privacidad. Este sitio web no usa analíticas ni rastreadores. Su única cookie, <code>yorozu_lang</code>, se crea cuando eliges un idioma y solo guarda esa elección, para que el sitio se abra en ese idioma la próxima vez.</p>

  <h2>Permisos</h2>
  <p>Yorozu pide permisos solo para la función que los necesita: la cámara para escanear un código de enlace o tomar una foto para enviar, el micrófono para la entrada de voz, las fotos para adjuntar o guardar imágenes, y las notificaciones para las respuestas. La entrada de voz se transcribe en tu dispositivo; el audio nunca se envía a ninguna parte. Los datos a los que se accede mediante permisos se usan en tus dispositivos y solo se envían a tu propio Gateway, con cifrado de extremo a extremo.</p>

  <h2>Versiones anteriores</h2>
  <p>Las versiones anteriores de la app para Mac ejecutaban su propio asistente. Sus datos se quedan en tu Mac, en <code>~/Yorozu</code> y en la carpeta de Yorozu dentro de <code>~/Library/Application Support/</code>, hasta que los elimines.</p>

  <h2>Menores</h2>
  <p>Yorozu no está dirigido a menores de 13 años, y no recopilamos sus datos a sabiendas.</p>

  <h2>Tus opciones</h2>
  <p>Desemparejar un dispositivo, desde la app o con <code>openclaw yorozu devices remove</code>, elimina sus claves y su token push del relé. Eliminar la app borra sus datos de ese dispositivo. Tus conversaciones permanecen en OpenClaw hasta que las elimines allí o en Yorozu. Como no tenemos ninguna cuenta ni contenido legible, no hay nada más que exportar o eliminar. Si tienes preguntas, escribe a <a href="mailto:contact@yumi.to">contact@yumi.to</a>.</p>

  <h2>Cambios</h2>
  <p>Publicaremos los cambios aquí y actualizaremos la fecha de arriba.</p>`,
  },
  terms: {
    title: 'Términos de uso — Yorozu',
    description: 'Los términos para usar Yorozu, incluido el riesgo para las cuentas de Claude y Codex que usan los agentes que maneja.',
    heading: 'Términos de uso',
    effective: 'Vigentes desde el 23 de octubre de 2026',
    body: `<p>Estos términos se aplican a la app Yorozu para iPhone, iPad y Mac, al plugin de Yorozu para OpenClaw, al relé en <code>relay.yumi.to</code> y a este sitio web (en conjunto, «Yorozu»), proporcionados por Yumi Izumi («nosotros»). Al instalar o usar Yorozu, aceptas estos términos. Si no los aceptas, no uses Yorozu. Si obtienes la app para iPhone en el App Store, también se aplica el <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Contrato de licencia de usuario final estándar</a> de Apple. Cuando entre en conflicto con estos términos, prevalecerá en lo que respecta a la app para iPhone.</p>

  <h2>1. Qué es Yorozu</h2>
  <p>Yorozu es una app de chat para tu propio agente de OpenClaw: su plugin convierte Yorozu en un canal de tu Gateway de OpenClaw, y la app le lleva tus mensajes y te trae sus respuestas. El agente, y cualquier herramienta de programación que ejecute, como Claude Code u OpenAI Codex, es software que tú instalas y configuras. Yorozu no proporciona modelos de IA, no vende uso de IA ni recopila tus credenciales. Tú mismo instalas esas herramientas, inicias sesión en ellas y las pagas.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Tu cuenta de Claude o Codex puede ser suspendida o bloqueada</h2>
    <p>Anthropic y OpenAI establecen las reglas sobre cómo pueden usarse sus suscripciones y cuentas, incluso mediante herramientas automatizadas o de terceros. Esas reglas han cambiado repetidamente y pueden cambiar sin aviso. Anthropic ha suspendido cuentas usadas con herramientas de agentes de terceros y afirma que puede aplicar sus restricciones sin aviso previo. Usar Yorozu para manejar Claude Code o Codex, mediante OpenClaw o de otro modo, con el inicio de sesión de una suscripción (como Claude Pro o Max, o un plan de ChatGPT) <strong>puede infringir esas reglas y hacer que tu cuenta sea limitada, suspendida o bloqueada de forma permanente, sin reembolso.</strong></p>
    <p>Eres el único responsable de leer y cumplir los términos de cada proveedor que uses, incluidos los <a href="https://www.anthropic.com/legal/consumer-terms">Términos para consumidores de Anthropic</a>, los <a href="https://code.claude.com/docs/en/legal-and-compliance">términos legales y de cumplimiento de Claude Code</a> y los <a href="https://openai.com/policies/terms-of-use/">Términos de uso de OpenAI</a>. Una clave de API facturada a tu nombre suele ser la opción de menor riesgo. <strong>No somos responsables de ninguna medida que un proveedor tome contra tu cuenta ni de ninguna pérdida que se derive de ella.</strong></p>
  </div>

  <h2>3. Software de terceros</h2>
  <p>OpenClaw, Claude Code, Codex y las demás herramientas que usa tu agente son software de terceros, proporcionado por sus propietarios bajo sus propias licencias y términos. OpenClaw es software de código abierto de la OpenClaw Foundation, con licencia MIT, «tal cual» y sin garantía. No desarrollamos, controlamos ni damos soporte a ese software ni a los proveedores de modelos que hay detrás, y no somos responsables de cómo se comporta, de lo que produce ni de lo que hace en tu ordenador. Eso incluye los comandos que ejecuta, los archivos que cambia o elimina, los mensajes que envía, las compras que realiza y todo lo que se haga con los permisos que le concedas. Yorozu no está afiliado a la OpenClaw Foundation, Anthropic ni OpenAI, ni cuenta con su respaldo o patrocinio. Todos los nombres de productos pertenecen a sus propietarios.</p>

  <h2>4. Eres responsable de tus agentes</h2>
  <p>Los agentes de IA pueden actuar en tu ordenador y en tus cuentas en línea, y cometen errores. Eres responsable de configurarlos, de los permisos y aprobaciones que concedas (incluido cualquier modo que omita las aprobaciones), de revisar sus resultados y de todo lo que se haga a través de tus dispositivos. Haz copias de seguridad. No uses Yorozu donde un fallo o una acción errónea pueda causar lesiones, pérdidas económicas importantes o daños legales.</p>

  <h2>5. Uso aceptable</h2>
  <p>No uses Yorozu para infringir la ley, vulnerar los derechos de nadie, incumplir los términos de un proveedor, atacar o sobrecargar el relé, ni acceder a dispositivos o cuentas que no sean tuyos. Podemos bloquear el acceso al relé alojado para protegerlo a él o a sus usuarios.</p>

  <h2>6. El relé</h2>
  <p>El relé alojado se ofrece de forma gratuita y en la medida de lo posible. Puede ser lento, no estar disponible, cambiar o dejar de ofrecerse en cualquier momento. En su lugar, puedes ejecutar tu propio relé.</p>

  <h2>7. Sin garantía</h2>
  <p>En la máxima medida permitida por la ley, Yorozu se proporciona «tal cual» y «según disponibilidad», sin garantías de ningún tipo, expresas o implícitas, incluidas las de comerciabilidad, idoneidad para un fin concreto, no infracción, exactitud, seguridad y funcionamiento ininterrumpido o libre de errores.</p>

  <h2>8. Limitación de responsabilidad</h2>
  <p>En la máxima medida permitida por la ley, no somos responsables de ningún daño indirecto, incidental, especial, consecuente o punitivo, ni de ninguna pérdida de datos, beneficios, cuentas, acceso a servicios o suscripciones de terceros, o negocio, derivados de Yorozu, de software o proveedores de terceros, o de acciones realizadas por agentes de IA, aunque se nos haya advertido de que tal pérdida era posible. Nuestra responsabilidad total por cualquier reclamación relacionada con Yorozu se limita al importe que nos pagaste por Yorozu en los 12 meses anteriores a la reclamación, o a 10 USD si no pagaste nada. Algunas jurisdicciones no permiten ciertas exclusiones o límites. En esas jurisdicciones, se aplican solo en la medida en que la ley lo permita. Nada en estos términos limita la responsabilidad que la ley no permite limitar, como la responsabilidad por dolo o negligencia grave.</p>

  <h2>9. Indemnización</h2>
  <p>En la medida permitida por la ley, aceptas indemnizarnos frente a las reclamaciones derivadas de tu uso de Yorozu, de las acciones de tus agentes o de tu incumplimiento de estos términos o de los términos de un tercero.</p>

  <h2>10. Cambios y terminación</h2>
  <p>Podemos actualizar estos términos publicando una nueva versión aquí. Seguir usando Yorozu después de una actualización significa que la aceptas. Puedes dejar de usar Yorozu en cualquier momento eliminando las apps.</p>

  <h2>11. Ley aplicable</h2>
  <p>Estos términos se rigen por las leyes de Japón, y el Tribunal de Distrito de Tokio tiene jurisdicción exclusiva como tribunal de primera instancia, salvo cuando las leyes de protección del consumidor de tu país de residencia exijan otra cosa.</p>

  <h2>12. Contacto</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};
