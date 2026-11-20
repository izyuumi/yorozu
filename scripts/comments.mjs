import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, writeFileSync } from 'node:fs';
import { extname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const ignore = [
  { glob: 'apps/web/src/hero/kit/**', reason: 'Vendored Stageshow hero kit with its own license' },
  { glob: '**/pnpm-lock.yaml', reason: 'Generated pnpm dependency lockfile' },
  { glob: 'apps/relay/compat/**', reason: 'Hash-checked copy of an earlier relay release kept for compatibility tests' },
  { glob: 'apps/web/.astro/**', reason: 'Astro-generated type declarations' },
];

const extensions = {
  swift: 'Swift',
  js: 'JavaScript', mjs: 'JavaScript', cjs: 'JavaScript',
  ts: 'TypeScript', tsx: 'TypeScript', mts: 'TypeScript', cts: 'TypeScript',
  rs: 'Rust', jsonc: 'JSONC', css: 'CSS', astro: 'Astro', html: 'HTML',
  sh: 'Shell', bash: 'Shell', py: 'Python', ps1: 'PowerShell',
  yml: 'YAML', yaml: 'YAML', toml: 'TOML',
};

const shebang = /^\uFEFF?#!(?!\[)[^\r\n]*/;
const interpreter = /^\uFEFF?#!\s*(?:[^\s/]+\/|\/)*?(?:env\s+(?:-S\s+)?(?:[^\s/]+\/|\/)*?)?([\w.]+)(?=\s|$)/;
const rustSafetyDoc = 'Rust safety documentation';

export const directives = [
  { reason: 'Executable interpreter', matches: ({ marker }) => marker === '#!' },
  { reason: 'Swift package tools version', matches: /^swift-tools-version\s*:/ },
  { reason: 'Swift lint, formatting, or code generation', matches: /^(?:swiftlint\s*:|swift-format-ignore\b|sourcery\s*:)/ },
  { reason: 'ESLint configuration', matches: /^(?:eslint-(?:disable[\w-]*|enable|env)\b|globals?\s)/ },
  { reason: 'TypeScript compiler configuration', matches: /^@ts-(?:expect-error|ignore|nocheck|check)\b/ },
  { reason: 'TypeScript triple-slash reference', matches: ({ text, body }) =>
    text.startsWith('///') && /^<reference\b/.test(body) },
  { reason: 'JSX compiler configuration', matches: /^@jsx(?:ImportSource)?\b/ },
  { reason: 'Formatter or linter suppression', matches: /^(?:prettier-ignore|biome-ignore)\b/ },
  { reason: 'Coverage exclusion', matches: /^(?:c8|istanbul|v8)\s+ignore\b/ },
  { reason: 'Bundler configuration', matches: /^(?:webpackChunkName\b|@vite-ignore\b)/ },
  { reason: 'Rust unsafe justification', matches: ({ language, marker, body, doc }) =>
    language === 'Rust' && marker === '//' && !doc && /^SAFETY:/.test(body) },
  { reason: rustSafetyDoc, matches: ({ language, doc, body }) =>
    language === 'Rust' && doc && /^#{1,6}[ \t]+Safety(?:[ \t]+#+)?[ \t]*$/.test(body) },
  { reason: 'ShellCheck configuration', matches: /^shellcheck\s/ },
  { reason: 'Dockerfile syntax selection', matches: /^syntax=/ },
  { reason: 'YAML language server configuration', matches: /^yaml-language-server\s*:/ },
  { reason: 'Python tooling or source encoding', matches: /^(?:type\s*:\s*ignore\b|noqa\b|pragma\b|-\*-\s*coding\b)/ },
  { reason: 'License notice', matches: /^(?:SPDX-License-Identifier\b|@license\b)/m },
  { reason: 'Leading copyright header', matches: ({ leading, body }) => leading && /^Copyright\b/i.test(body) },
  { reason: 'Editor folding region', matches: ({ text, body }) =>
    /^#\s*(?:endregion|region)\b/.test(text) || /^#\s*(?:endregion|region)\b/.test(body) },
  { reason: 'Dependabot-managed Actions pin', matches: ({ language, before }) =>
    language === 'YAML' && /^\s*(?:-\s+)?uses\s*:\s*["']?[\w.-]+\/[\w./-]+@[\da-f]{40}(?:["'])?\s+$/i.test(before) },
];

const horizontalSpace = /[^\S\r\n]/;
const whitespace = /\s/;
const identifier = /[$_\p{ID_Start}][$_\u200c\u200d\p{ID_Continue}]*/uy;
const expressionKeyword = /^(?:return|throw|case|delete|void|typeof|new|in|instanceof|of|yield|await|else|do|try)$/;
const controlKeyword = /^(?:if|while|for|with|switch|catch)$/;

class Lexer {
  constructor(source) {
    this.source = source;
    this.comments = [];
    this.lineStarts = [0];
    for (const newline of source.matchAll(/\r\n?|\n/g)) {
      this.lineStarts.push(newline.index + newline[0].length);
    }
  }

  lineAt(offset) {
    let low = 0;
    let high = this.lineStarts.length;
    while (high - low > 1) {
      const middle = (low + high) >>> 1;
      if (this.lineStarts[middle] <= offset) low = middle;
      else high = middle;
    }
    return low;
  }

  lineEnd(offset, end) {
    let next = Math.min(this.lineStarts[this.lineAt(offset) + 1] ?? end, end);
    while (next > offset && /[\r\n]/.test(this.source[next - 1])) next--;
    return next;
  }

  lineComment(start, end, marker) {
    const stop = this.lineEnd(start, end);
    this.comments.push({ start, stop, marker });
    return stop;
  }

  blockComment(start, end, marker, close, nested = false) {
    let stop = start + marker.length;
    let depth = 1;
    while (stop < end) {
      if (this.source.startsWith(close, stop)) {
        stop += close.length;
        if (--depth === 0) break;
      } else if (nested && this.source.startsWith(marker, stop)) {
        depth++;
        stop += marker.length;
      } else {
        stop++;
      }
    }
    this.comments.push({ start, stop: Math.min(stop, end), marker, close });
    return stop;
  }

  quoted(start, end, close, { escape = '\\', doubled = false, interpolate } = {}) {
    const source = this.source;
    for (let position = start; position < end;) {
      if (source.startsWith(close, position)) {
        position += close.length;
        if (!doubled || !source.startsWith(close, position)) return position;
        position += close.length;
      } else {
        const after = interpolate?.(position);
        if (after > position) position = after;
        else if (escape && source.startsWith(escape, position)) position += escape.length + 1;
        else position++;
      }
    }
    return end;
  }

  regex(start, end, hashes = '') {
    const source = this.source;
    let characterClass = false;
    for (let position = start + 1; position < end; position++) {
      const char = source[position];
      if (!hashes && /[\r\n]/.test(char)) break;
      if (char === '\\') position++;
      else if (char === '[') characterClass = true;
      else if (char === ']') characterClass = false;
      else if (!characterClass && source.startsWith('/' + hashes, position)) {
        return position + 1 + hashes.length;
      }
    }
  }

  cLike(start, end, language, { until, jsx = false, fence = false } = {}) {
    const source = this.source;
    const js = language === 'JavaScript' || language === 'TypeScript';
    const swift = language === 'Swift';
    const rust = language === 'Rust';
    const brackets = [];
    let pendingFunction;
    let pendingClass;
    let previous = until ? 'expression' : '';
    let canStartRegex = true;
    let position = start;
    while (position < end) {
      const char = source[position];
      if (fence && this.fenceAt(position, end)) return position;
      if (whitespace.test(char)) {
        position++;
        continue;
      }
      if (char === until && brackets.length === 0) return position + 1;
      if (char === '/' && source[position + 1] === '*') {
        position = this.blockComment(position, end, '/*', '*/', swift || rust);
        continue;
      }
      if (char === '/' && source[position + 1] === '/' && language !== 'CSS') {
        position = this.lineComment(position, end, '//');
        continue;
      }
      if (language === 'CSS' && char === '\\') {
        position += 2;
        continue;
      }
      if (language === 'CSS' && /[uU]/.test(char) && !/[\w#@-]/.test(source[position - 1] ?? '')) {
        const url = this.match(/url\([ \t\r\n\f]*/iy, position);
        const argument = position + (url?.[0].length ?? 0);
        if (url && !/["']/.test(source[argument] ?? '')) {
          position = this.quoted(argument, end, ')');
          continue;
        }
      }

      if (swift && (char === '"' || char === '#')) {
        const raw = this.match(/(#+)(?=["/])/y, position);
        const hashes = raw?.[1] ?? '';
        const delimiter = position + hashes.length;
        if (source[delimiter] === '"') {
          const quote = source.startsWith('"""', delimiter) ? '"""' : '"';
          const escape = '\\' + hashes;
          position = this.quoted(delimiter + quote.length, end, quote + hashes, {
            escape,
            interpolate: (offset) => source.startsWith(escape + '(', offset)
              ? this.cLike(offset + escape.length + 1, end, language, { until: ')' }) : offset,
          });
          canStartRegex = false;
          previous = 'value';
          continue;
        }
        if (hashes && source[delimiter] === '/') {
          const after = this.regex(delimiter, end, hashes);
          if (after !== undefined) {
            position = after;
            canStartRegex = false;
            previous = 'value';
            continue;
          }
        }
      }

      if (rust && (char === 'r' || char === 'b' || char === 'c')) {
        const raw = this.match(/(?:b|c)?r(#*)"/y, position);
        if (raw) {
          position = this.quoted(position + raw[0].length, end, '"' + raw[1], { escape: '' });
          continue;
        }
      }
      if (rust && char === "'") {
        const character = this.match(/'(?:\\(?:u\{[\da-fA-F_]+\}|x[\da-fA-F]{2}|[^\r\n])|[^'\\\r\n])'/uy, position);
        position += character?.[0].length ?? 1;
        continue;
      }

      if (char === '"' || char === "'" || (js && char === '`')) {
        const interpolate = char === '`'
          ? (offset) => source.startsWith('${', offset)
            ? this.cLike(offset + 2, end, language, { until: '}', jsx }) : offset
          : undefined;
        position = this.quoted(position + 1, end, char, { interpolate });
        canStartRegex = false;
        previous = 'value';
        continue;
      }

      if (char === '/' && canStartRegex && (js || (swift && !whitespace.test(source[position + 1] ?? ' ')))) {
        const after = this.regex(position, end);
        if (after !== undefined && (!swift || !whitespace.test(source[after - 2]))) {
          position = after;
          if (js) position += this.match(/[a-z]*/iy, position)[0].length;
          canStartRegex = false;
          previous = 'value';
          continue;
        }
      }

      if (jsx && char === '<' && canStartRegex && this.jsxTagAt(position)) {
        position = this.markup(position, end, 'JSX', true);
        canStartRegex = false;
        previous = 'value';
        continue;
      }

      const word = this.match(identifier, position);
      if (word) {
        const keyword = previous !== '.' && previous !== '?.';
        const [name] = word;
        const declaration = !previous || /^(?:statement|;|export|default|declaration-prefix)$/.test(previous) ||
          (previous === '{' && brackets.at(-1)?.block);
        canStartRegex = keyword && expressionKeyword.test(name);
        previous = keyword ? name : 'value';
        if (js && keyword) {
          if (name === 'function') pendingFunction = { depth: brackets.length, declaration: Boolean(declaration) };
          if (name === 'class') pendingClass = { depth: brackets.length, declaration: Boolean(declaration) };
          if (declaration && /^(?:async|abstract)$/.test(name)) previous = 'declaration-prefix';
        }
        position += name.length;
        continue;
      }

      const pair = source.slice(position, position + 2);
      if (pair === '++' || pair === '--' || pair === '?.' || pair === '=>') {
        if (pair !== '++' && pair !== '--') canStartRegex = pair === '=>';
        previous = pair;
        position += 2;
        continue;
      }

      if (char === '(' || char === '{' || char === '[') {
        let functionDeclaration;
        if (char === '(' && pendingFunction?.depth === brackets.length) {
          functionDeclaration = pendingFunction.declaration;
          pendingFunction = undefined;
        }
        let classDeclaration;
        if (char === '{' && pendingClass?.depth === brackets.length) {
          classDeclaration = pendingClass.declaration;
          pendingClass = undefined;
        }
        const block = char === '{' && (!previous || previous === 'statement' ||
          classDeclaration !== undefined ||
          /^(?:else|try|catch|finally|do|;|\)|\{|\}|=>|function-(?:declaration|expression))$/.test(previous));
        brackets.push({
          close: { '(': ')', '{': '}', '[': ']' }[char],
          block,
          functionDeclaration,
          statement: (char === '(' && controlKeyword.test(previous)) ||
            (block && (classDeclaration ?? !/^(?:=>|function-expression)$/.test(previous))),
        });
        canStartRegex = true;
        previous = char;
      } else if (char === ')' || char === ']' || char === '}') {
        const bracket = brackets.at(-1);
        canStartRegex = bracket?.close === char && bracket.statement;
        previous = canStartRegex ? 'statement' : char;
        if (bracket?.close === char) {
          if (bracket.functionDeclaration !== undefined) {
            previous = bracket.functionDeclaration ? 'function-declaration' : 'function-expression';
          }
          brackets.pop();
        }
      } else if (!(language === 'TypeScript' && char === '!' && !canStartRegex)) {
        canStartRegex = /^[=:;,!?&|%^~*+\-<>/]$/.test(char);
        previous = char;
      }
      position++;
    }
    return end;
  }

  match(pattern, position) {
    pattern.lastIndex = position;
    return pattern.exec(this.source);
  }

  fenceAt(position, end) {
    return this.lineStarts[this.lineAt(position)] === position &&
      /^---[^\S\r\n]*$/.test(this.source.slice(position, this.lineEnd(position, end)));
  }

  jsxTagAt(position) {
    const tag = this.match(/<(?:>|[a-zA-Z_$][\w$.:-]*)/y, position);
    if (!tag) return false;
    const after = position + tag[0].length;
    return !this.match(/(?:,|\s+extends\s+[^>]+>\s*\(|>\s*\([^)]*\)\s*(?:=>|:))/y, after);
  }

  markup(start, end, language, singleTag = false) {
    const source = this.source;
    const expressions = language !== 'HTML';
    const jsx = language === 'JSX';
    const tags = [];
    let position = start;
    while (position < end) {
      if (!jsx && source.startsWith('<!--', position)) {
        position = this.blockComment(position, end, '<!--', '-->');
      } else if (expressions && source[position] === '{') {
        position = this.cLike(position + 1, end, 'TypeScript', { until: '}', jsx: true });
      } else if (source[position] === '<') {
        const tag = this.match(/<(\/?)([\w$.:-]+|(?=>))/y, position);
        if (!tag) {
          position++;
          continue;
        }
        const [, closing, name] = tag;
        position += tag[0].length;
        while (position < end && source[position] !== '>') {
          const char = source[position];
          if (char === '"' || char === "'") {
            position = this.quoted(position + 1, end, char, { escape: '' });
          } else if (expressions && char === '{') {
            position = this.cLike(position + 1, end, 'TypeScript', { until: '}', jsx: true });
          } else {
            position++;
          }
        }
        const selfClosing = source[position - 1] === '/';
        position++;
        if (jsx) {
          if (closing) tags.pop();
          else if (!selfClosing) tags.push(name);
          if (singleTag && tags.length === 0) return position;
        } else if (!closing && !selfClosing && /^(?:script|style|textarea|title|xmp|iframe|noembed|noframes)$/i.test(name)) {
          const tagName = name.toLowerCase();
          const close = new RegExp('</' + tagName + '(?=[\\s/>])', 'ig');
          close.lastIndex = position;
          const stop = Math.min(close.exec(source)?.index ?? end, end);
          if (tagName === 'script' || tagName === 'style') {
            this.cLike(position, stop, tagName === 'script' ? 'JavaScript' : 'CSS');
          }
          position = stop;
        }
      } else {
        position++;
      }
    }
    return end;
  }

  shellSpecial(position, end, indent) {
    const source = this.source;
    if (source.startsWith('$((', position)) {
      return this.shellGroup(position + 3, end, '))', indent);
    }
    if (source.startsWith('$(', position)) {
      return this.shell(position + 2, end, { until: ')', indent });
    }
    if (source.startsWith('${', position)) {
      return this.shellGroup(position + 2, end, '}', indent);
    }
    if (source[position] === '`') {
      return this.shell(position + 1, end, { until: '`', indent });
    }
    return position;
  }

  shellQuote(position, end, indent) {
    const char = this.source[position];
    if (char === "'") return this.quoted(position + 1, end, char, { escape: '' });
    return this.quoted(position + 1, end, char, {
      interpolate: (offset) => this.shellSpecial(offset, end, indent),
    });
  }

  shellGroup(start, end, close, indent) {
    const source = this.source;
    let depth = 0;
    for (let position = start; position < end;) {
      const char = source[position];
      if (depth === 0 && source.startsWith(close, position)) return position + close.length;
      if (char === '\\') position += 2;
      else if (char === '"' || char === "'") position = this.shellQuote(position, end, indent);
      else {
        const special = this.shellSpecial(position, end, indent);
        if (special > position) {
          position = special;
          continue;
        }
        if (close === '))' && char === '(') depth++;
        if (close === '))' && char === ')') depth--;
        position++;
      }
    }
    return end;
  }

  heredoc(start, end) {
    const source = this.source;
    let position = start + 2;
    const stripTabs = source[position] === '-';
    if (stripTabs) position++;
    while (position < end && horizontalSpace.test(source[position])) position++;
    if (position >= end || /[\r\n#;&|()<>]/.test(source[position])) return;

    let delimiter = '';
    while (position < end && !/[\s;&|()<>]/.test(source[position])) {
      const char = source[position++];
      if (char === "'" || char === '"') {
        while (position < end && source[position] !== char) {
          if (char === '"' && source[position] === '\\' && /[$`"\\\r\n]/.test(source[position + 1] ?? '')) position++;
          delimiter += source[position++];
        }
        position++;
      } else if (char === '\\' && position < end) {
        if (source[position] === '\r' && source[position + 1] === '\n') position++;
        if (!/[\r\n]/.test(source[position])) delimiter += source[position];
        position++;
      } else {
        delimiter += char;
      }
    }
    return { position, delimiter, stripTabs };
  }

  shell(start, end, { until, indent = 0 } = {}) {
    const source = this.source;
    const heredocs = [];
    let wordStart = true;
    let parentheses = 0;
    for (let position = start; position < end;) {
      const char = source[position];
      if (char === until && parentheses === 0) return position + 1;
      if (char === '#' && wordStart) {
        position = this.lineComment(position, end, '#');
        continue;
      }
      if (char === '\r' || char === '\n') {
        position = Math.min(this.lineStarts[this.lineAt(position) + 1] ?? end, end);
        for (const { delimiter, stripTabs } of heredocs) {
          while (position < end) {
            const stop = this.lineEnd(position, end);
            let body = source.slice(position + indent, stop);
            if (stripTabs) body = body.replace(/^\t+/, '');
            position = Math.min(this.lineStarts[this.lineAt(position) + 1] ?? end, end);
            if (body === delimiter) break;
          }
        }
        heredocs.length = 0;
        wordStart = true;
        continue;
      }
      if (char === '\\') {
        if (source[position + 1] === '\r' || source[position + 1] === '\n') {
          position = Math.min(this.lineStarts[this.lineAt(position) + 1] ?? end, end);
          position += indent;
        } else {
          position += 2;
          wordStart = false;
        }
        continue;
      }
      if (source.startsWith('<<<', position)) {
        position += 3;
        wordStart = true;
        continue;
      }
      if (source.startsWith('<<', position)) {
        const heredoc = this.heredoc(position, end);
        if (heredoc) {
          heredocs.push(heredoc);
          position = heredoc.position;
          wordStart = false;
          continue;
        }
      }
      if (source.startsWith("$'", position)) {
        position = this.quoted(position + 2, end, "'");
      } else if (char === '"' || char === "'") {
        position = this.shellQuote(position, end, indent);
      } else if (source.startsWith('((', position)) {
        position = this.shellGroup(position + 2, end, '))', indent);
      } else {
        const special = this.shellSpecial(position, end, indent);
        if (special > position) {
          position = special;
        } else {
          if (char === '(') parentheses++;
          if (char === ')' && parentheses > 0) parentheses--;
          wordStart = /[\s;&|()<>]/.test(char);
          position++;
          continue;
        }
      }
      wordStart = false;
    }
    return end;
  }

  pythonFormat(start, end) {
    for (let position = start; position < end; position++) {
      if (this.source[position] === '}') return position + 1;
      if (this.source[position] === '{') {
        position = this.hashCode(position + 1, end, 'Python', '}') - 1;
      }
    }
    return end;
  }

  hashCode(start, end, language, until) {
    const source = this.source;
    const powerShell = language === 'PowerShell';
    const brackets = [];
    const powershellInterpolation = (offset) => source.startsWith('$(', offset)
      ? this.hashCode(offset + 2, end, language, ')') : offset;
    let position = start;
    while (position < end) {
      const char = source[position];
      if (brackets.length === 0 && until) {
        if (char === until) return position + 1;
        if (until === '}' && char === ':') {
          return this.pythonFormat(position + 1, end);
        }
      }
      if (char === '#') {
        position = this.lineComment(position, end, '#');
        continue;
      }
      if (powerShell && source.startsWith('<#', position)) {
        position = this.blockComment(position, end, '<#', '#>');
        continue;
      }
      if (powerShell && char === '@' && /["']/.test(source[position + 1] ?? '') &&
          /^[ \t]*(?:\r\n?|\n)/.test(source.slice(position + 2, this.lineStarts[this.lineAt(position) + 1] ?? end))) {
        const quote = source[position + 1];
        const close = quote === '"' ? /^"@/gm : /^'@/gm;
        close.lastIndex = position + 2;
        const stop = Math.min(close.exec(source)?.index ?? end, end);
        if (quote === '"') {
          for (let offset = position + 2; offset < stop;) {
            if (source[offset] === '`') offset += 2;
            else offset = Math.max(offset + 1, powershellInterpolation(offset));
          }
        }
        position = stop + 2;
        continue;
      }

      let formatted = false;
      if (!powerShell) {
        const word = this.match(identifier, position);
        if (word) {
          formatted = /^(?:f|fr|rf)$/i.test(word[0]);
          position += word[0].length;
          if (source[position] !== '"' && source[position] !== "'") continue;
        }
      }
      const quote = source[position];
      if (quote === '"' || quote === "'") {
        const delimiter = !powerShell && source.startsWith(quote.repeat(3), position) ? quote.repeat(3) : quote;
        let interpolate;
        if (powerShell && quote === '"') interpolate = powershellInterpolation;
        if (formatted) interpolate = (offset) => {
          const char = source[offset];
          const next = source[offset + 1];
          if (char === '\\' && (next === '{' || next === '}')) return offset + 1;
          if ((char === '{' || char === '}') && char === next) return offset + 2;
          return char === '{' ? this.hashCode(offset + 1, end, language, '}') : offset;
        };
        position = this.quoted(position + delimiter.length, end, delimiter, {
          escape: powerShell ? (quote === "'" ? '' : '`') : '\\',
          doubled: powerShell,
          interpolate,
        });
        continue;
      }
      if (powerShell && char === '`') {
        position += 2;
        continue;
      }
      if (char === '(' || char === '[' || char === '{') brackets.push({ '(': ')', '[': ']', '{': '}' }[char]);
      else if (brackets.at(-1) === char) brackets.pop();
      position++;
    }
    return end;
  }

  yamlScalar(position, end) {
    const source = this.source;
    const match = this.match(/[|>](?:[1-9][-+]?|[-+][1-9]?)?(?=[ \t]+#|[ \t]*(?:[\r\n]|$))/y, position);
    if (!match) return position;
    const line = this.lineAt(position);
    const lineStart = this.lineStarts[line];
    const headerEnd = this.lineEnd(position, end);
    const header = source.slice(lineStart, position);
    const parentIndent = header.match(/^(?:[ \t]*-[ \t]+)*[ \t]*/)[0].length;
    const explicit = /[1-9]/.exec(match[0]);
    let indent = explicit ? parentIndent + Number(explicit[0]) : undefined;
    position += match[0].length;
    while (position < headerEnd && horizontalSpace.test(source[position])) position++;
    if (source[position] === '#') this.lineComment(position, end, '#');

    const bodyStart = Math.min(this.lineStarts[line + 1] ?? end, end);
    let stop = bodyStart;
    while (stop < end) {
      const lineEnd = this.lineEnd(stop, end);
      let first = stop;
      while (source[first] === ' ' && first < lineEnd) first++;
      if (first < lineEnd) {
        const spaces = first - stop;
        if (spaces <= parentIndent || (indent !== undefined && spaces < indent)) break;
        indent ??= spaces;
      }
      stop = Math.min(this.lineStarts[this.lineAt(stop) + 1] ?? end, end);
    }
    this.shell(bodyStart, stop, { indent });
    return stop;
  }

  config(start, end, language) {
    const source = this.source;
    const yaml = language === 'YAML';
    let scalarStart = true;
    let flow = 0;
    for (let position = start; position < end;) {
      const char = source[position];
      const next = source[position + 1];
      if (char === '#' && (position === start || whitespace.test(source[position - 1]))) {
        position = this.lineComment(position, end, '#');
        continue;
      }
      if ((char === '"' || char === "'") && (!yaml || scalarStart)) {
        const triple = !yaml && source.startsWith(char.repeat(3), position);
        const delimiter = triple ? char.repeat(3) : char;
        position = this.quoted(position + delimiter.length, end, delimiter, {
          escape: char === "'" ? '' : '\\',
          doubled: yaml && char === "'",
        });
        if (triple) {
          for (let extra = 0; extra < 2 && source[position] === char; extra++) position++;
        }
        scalarStart = false;
        continue;
      }
      if (yaml && scalarStart && (char === '|' || char === '>')) {
        const stop = this.yamlScalar(position, end);
        if (stop > position) {
          position = stop;
          scalarStart = true;
          continue;
        }
      }
      if (yaml && scalarStart && (char === '&' || char === '!')) {
        position += this.match(/[^\s[\]{},]+/y, position)[0].length;
        continue;
      }
      if (yaml && (char === '[' || char === '{') && scalarStart) flow++;
      if (yaml && (char === ']' || char === '}') && flow > 0) flow--;
      if (char === '\r' || char === '\n' ||
          (char === ':' && (whitespace.test(next ?? ' ') || flow > 0)) ||
          (scalarStart && /[-?]/.test(char) && whitespace.test(next ?? ' ')) ||
          (flow > 0 && /[[{,]/.test(char))) {
        scalarStart = true;
      } else if (!whitespace.test(char)) {
        scalarStart = false;
      }
      position++;
    }
  }

  scan(language, file) {
    const end = this.source.length;
    let start = this.source.startsWith('\uFEFF') ? 1 : 0;
    if (shebang.test(this.source)) start = this.lineComment(start, end, '#!');
    switch (language) {
      case 'Shell':
        this.shell(start, end);
        break;
      case 'Python':
      case 'PowerShell':
        this.hashCode(start, end, language);
        break;
      case 'YAML':
      case 'TOML':
        this.config(start, end, language);
        break;
      case 'Astro': {
        const fence = this.match(/[ \t\r\n]*---[ \t]*(?:\r\n?|\n|$)/y, start);
        if (fence) {
          start = this.cLike(start + fence[0].length, end, 'TypeScript', { fence: true });
          start = this.lineEnd(start, end);
        }
        this.markup(start, end, language);
        break;
      }
      case 'HTML':
        this.markup(start, end, language);
        break;
      default:
        this.cLike(start, end, language, { jsx: file.endsWith('.tsx') });
    }
  }
}


function commentBody(text, { marker, close }) {
  let body = text.slice(marker.length);
  if (close && body.endsWith(close)) body = body.slice(0, -close.length);
  if (marker === '//') return body.replace(/^(?:\/+|!)/, '').trimStart();
  if (marker === '/*') {
    body = body.replace(/^[*!]+/, '');
    return body.split(/\r\n?|\n/).map((line, index) =>
      (index === 0 ? line : line.replace(/^\s*\*[ \t]?/, '')).trim()).join('\n');
  }
  return body.trimStart();
}

const heading = /^(#{1,6})[ \t]+(.*)$/;
const normalize = (body) => body.replace(/\s+/g, ' ').trim();
const matchesRustSafetyDoc = directives.find(({ reason }) => reason === rustSafetyDoc).matches;

function groupComments(lexer, file, language) {
  const { source, comments, lineStarts } = lexer;
  const blocks = [];
  let previous;
  let leading = true;
  let safetyDepth = 0;
  for (const token of comments) {
    const { start, stop, marker, close } = token;
    const line = lexer.lineAt(start) + 1;
    const endLine = lexer.lineAt(stop - 1) + 1;
    const before = source.slice(lineStarts[line - 1], start);
    const standalone = before.trim() === '';
    const text = source.slice(start, stop);
    const body = commentBody(text, token);
    const doc = /^(?:\/\/(?:\/(?!\/)|!)|\/\*(?:\*(?![*/])|!))/.test(text);
    const adjacent = previous && !close && !previous.close && standalone && previous.standalone &&
      previous.endLine + 1 === line && previous.marker === marker;
    leading &&= source.slice(previous?.stop ?? 0, start).trim() === '';

    let countedBody = body;
    const exemptLines = new Set();
    const rustDoc = language === 'Rust' && doc;
    if (!rustDoc || !adjacent || !previous.doc || previous.docStyle !== text.slice(0, 3)) safetyDepth = 0;
    if (rustDoc) {
      const lines = body.split('\n');
      for (const [index, content] of lines.entries()) {
        const match = heading.exec(content);
        if (match && match[1].length <= safetyDepth) safetyDepth = 0;
        if (match && matchesRustSafetyDoc({ language, doc, body: content })) safetyDepth = match[1].length;
        if (safetyDepth) exemptLines.add(line + index);
      }
      countedBody = lines.filter((_, index) => !exemptLines.has(line + index)).join('\n');
    }
    const context = {
      language, marker, before, body: countedBody.trimStart(), leading: leading && !adjacent, doc, text,
    };
    let directive = exemptLines.size > 0 && !context.body ? rustSafetyDoc :
      directives.find(({ reason, matches }) => reason !== rustSafetyDoc &&
        (typeof matches === 'function' ? matches(context) : matches.test(context.body)))?.reason;

    if (adjacent && previous.directive === 'Leading copyright header') directive = previous.directive;
    if (adjacent && previous.directive === 'Rust unsafe justification' && !doc && before === previous.before) {
      directive = previous.directive;
    }

    const block = blocks.at(-1);
    if (adjacent && block.directive === directive) {
      block.record.endLine = endLine;
      block.record.lines = endLine - block.record.line + 1;
      block.record.text += source.slice(previous.stop, stop);
      block.normalized = normalize(block.normalized + ' ' + countedBody);
    } else {
      blocks.push({
        record: { file, line, endLine, lines: endLine - line + 1 - exemptLines.size, text },
        normalized: normalize(countedBody),
        directive,
        exemptLines,
      });
    }
    previous = { ...token, standalone, endLine, directive, doc, docStyle: text.slice(0, 3), before };
  }
  return blocks;
}

const baselinePath = 'scripts/comment-baseline.json';

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
}

function trackedSources(root, paths) {
  const pathspecs = paths.map((path) => ':(literal)' + path);
  for (const { glob } of ignore) pathspecs.push(':(exclude,glob)' + glob);
  const files = new Set(git(root, 'ls-files', '-z', '--', ...pathspecs).split('\0').filter(Boolean));
  const sources = [];
  for (const file of files) {
    const extension = extname(file);
    let language = Object.hasOwn(extensions, extension.slice(1)) ? extensions[extension.slice(1)] : undefined;
    if (!language && extension) continue;
    const path = resolve(root, file);
    if (!lstatSync(path, { throwIfNoEntry: false })?.isFile()) continue;
    const source = readFileSync(path, 'utf8');
    if (!language) {
      const name = interpreter.exec(shebang.exec(source)?.[0] ?? '')?.[1] ?? '';
      if (/^(?:sh|bash)$/.test(name)) language = 'Shell';
      else if (/^python(?:\d+(?:\.\d+)*)?$/.test(name)) language = 'Python';
      else continue;
    }
    const lexer = new Lexer(source);
    lexer.scan(language, file);
    sources.push({ language, blocks: groupComments(lexer, file, language) });
  }
  return sources;
}

function commentLines(blocks) {
  const lines = new Set();
  for (const { record, exemptLines } of blocks) {
    for (let line = record.line; line <= record.endLine; line++) {
      if (!exemptLines.has(line)) lines.add(line);
    }
  }
  return lines.size;
}

function list(sources, json) {
  const comments = sources.flatMap(({ blocks }) => blocks.filter(({ directive }) => !directive));
  if (json) {
    console.log(JSON.stringify(comments.map(({ record }) => record), null, 2));
  } else {
    for (const { record: { file, line, text } } of comments) {
      console.log(file + ':' + line + ': ' + text.split(/\r\n?|\n/, 1)[0]);
    }
    const lines = sources.reduce((total, { blocks }) => total + commentLines(blocks.filter(({ directive }) => !directive)), 0);
    console.log(comments.length + ' comments, ' + lines + ' comment lines');
  }
}

function stats(sources) {
  const byLanguage = new Map();
  const total = [0, 0, 0];
  for (const { language, blocks } of sources) {
    const counted = blocks.filter(({ directive }) => !directive);
    const values = [counted.length, commentLines(counted),
      blocks.length - counted.length + counted.filter(({ exemptLines }) => exemptLines.size > 0).length];
    const counts = byLanguage.get(language) ?? [0, 0, 0];
    values.forEach((value, index) => {
      counts[index] += value;
      total[index] += value;
    });
    byLanguage.set(language, counts);
  }
  for (const [language, values] of [...[...byLanguage.keys()].sort().map((key) => [key, byLanguage.get(key)]), ['Total', total]]) {
    console.log(language + ': ' + values[0] + ' comments, ' + values[1] + ' comment lines, ' + values[2] + ' directives');
  }
}

function snapshot(blocks) {
  const files = new Map();
  for (const { record, normalized } of blocks) {
    if (!files.has(record.file)) files.set(record.file, []);
    files.get(record.file).push(normalized);
  }
  return Object.fromEntries([...files.keys()].sort().map((file) => [file, files.get(file).sort()]));
}

function parseBaseline(text, label) {
  const data = JSON.parse(text);
  if (data?.version !== 1 || !data.comments || typeof data.comments !== 'object' ||
      Array.isArray(data.comments) || Object.values(data.comments).some((values) =>
        !Array.isArray(values) || values.some((value) => typeof value !== 'string'))) {
    throw new Error('Invalid comment baseline in ' + label);
  }
  return data.comments;
}

function loadBaseline(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw error;
  }
  return parseBaseline(text, baselinePath);
}

function loadBase(root, ref) {
  const tree = git(root, 'rev-parse', '--verify', '--end-of-options', ref + '^{tree}').trim();
  if (!git(root, 'ls-tree', '-z', tree, '--', baselinePath)) return;
  return parseBaseline(git(root, 'show', tree + ':' + baselinePath), ref + ':' + baselinePath);
}

function allowance(comments) {
  const files = new Map();
  for (const [file, entries] of Object.entries(comments)) {
    const counts = new Map();
    for (const text of entries) counts.set(text, (counts.get(text) ?? 0) + 1);
    files.set(file, counts);
  }
  return (file, text) => {
    const counts = files.get(file);
    const count = counts?.get(text) ?? 0;
    if (count === 0) return false;
    counts.set(text, count - 1);
    return true;
  };
}

function check(root, blocks, ref) {
  const baseline = loadBaseline(resolve(root, baselinePath));
  const base = ref === undefined ? undefined : loadBase(root, ref);
  let failed = false;
  const covered = allowance(baseline);
  for (const { record, normalized } of blocks) {
    if (!covered(record.file, normalized)) {
      console.error(record.file + ':' + record.line + ': ' + record.text.split(/\r\n?|\n/, 1)[0]);
      failed = true;
    }
  }
  const exists = allowance(snapshot(blocks));
  let stale = false;
  for (const [file, entries] of Object.entries(baseline)) {
    for (const text of entries) {
      if (!exists(file, text)) {
        console.error(file + ': stale baseline entry ' + JSON.stringify(text));
        stale = true;
      }
    }
  }
  if (stale) {
    console.error('Run node scripts/comments.mjs baseline to shrink it.');
    failed = true;
  }
  if (base) {
    const allowedAtBase = allowance(base);
    for (const [file, entries] of Object.entries(baseline)) {
      for (const text of entries) {
        if (!allowedAtBase(file, text)) {
          console.error(file + ': baseline entry added since ' + ref + ': ' + JSON.stringify(text));
          failed = true;
        }
      }
    }
  }
  if (failed) return 1;
  console.log('comments: OK (' + blocks.length + ' baselined)');
  return 0;
}

function main([command, ...args]) {
  const json = command === 'list' && args[0] === '--json';
  if (json) args.shift();
  const ref = command === 'check' && args.length === 2 && args[0] === '--base' ? args[1] : undefined;
  if (!['list', 'stats', 'check', 'baseline'].includes(command) ||
      (command !== 'list' && args.length && !ref) || (command === 'list' && args.some((arg) => arg.startsWith('--')))) {
    throw new Error('Usage: node scripts/comments.mjs list [--json] [path ...] | stats | check [--base <git-ref>] | baseline');
  }
  const root = git(process.cwd(), 'rev-parse', '--show-toplevel').replace(/\r?\n$/, '');
  const sources = trackedSources(root, command === 'list' ? args : []);
  if (command === 'list') list(sources, json);
  if (command === 'stats') stats(sources);
  if (command === 'baseline' || command === 'check') {
    const blocks = sources.flatMap(({ blocks }) => blocks.filter(({ directive }) => !directive));
    if (command === 'check') return check(root, blocks, ref);
    writeFileSync(resolve(root, baselinePath), JSON.stringify({ version: 1, comments: snapshot(blocks) }, null, 2) + '\n');
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

