import { createServer, type Server } from "node:http";
import { afterAll, beforeAll, expect, test } from "vitest";
import { decodeEntities, fetchReadable, fetchTool } from "./fetch.js";

/** Everything a real page puts between the model and the article. */
const PAGE = `<!DOCTYPE html>
<html>
<head>
  <title>Yorozu &amp; the Art of Fetching</title>
  <style>body { color: hotpink }</style>
  <script>window.tracker = "do not read me";</script>
</head>
<body>
  <nav><a href="/">Home</a><a href="/about">About the navigation</a></nav>
  <header>Site wide header junk</header>
  <main>
    <article>
      <h1>The heading</h1>
      <p>First paragraph with an &amp; and a &#8212; dash.</p>
      <p>Second paragraph.</p>
    </article>
  </main>
  <footer>Copyright nobody</footer>
  <noscript>Enable JavaScript</noscript>
</body>
</html>`;

const LONG = `<html><head><title>Long</title></head><body><p>${"x".repeat(5_000)}</p></body></html>`;

let server: Server;
let base: string;

beforeAll(async () => {
  server = createServer((req, res) => {
    switch (req.url) {
      case "/page":
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        return res.end(PAGE);
      case "/moved":
        res.writeHead(302, { location: "/page" });
        return res.end();
      case "/plain":
        res.writeHead(200, { "content-type": "text/plain" });
        return res.end("  just text, no markup  ");
      case "/long":
        res.writeHead(200, { "content-type": "text/html" });
        return res.end(LONG);
      default:
        res.writeHead(404, { "content-type": "text/html" });
        return res.end("<html><body>nope</body></html>");
    }
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});

afterAll(() => new Promise<void>((done) => void server.close(() => done())));

test("reads a page as its title and main text", async () => {
  const page = await fetchReadable(`${base}/page`);

  expect(page.title).toBe("Yorozu & the Art of Fetching");
  expect(page.text).toContain("The heading");
  expect(page.text).toContain("First paragraph with an & and a — dash.");
  // Paragraphs stay apart rather than running into one line.
  expect(page.text).toContain("Second paragraph.");
  expect(page.text.split("\n").length).toBeGreaterThan(2);
});

test("scripts, styles and page furniture never reach the model", async () => {
  const { text } = await fetchReadable(`${base}/page`);

  for (const junk of [
    "do not read me",
    "hotpink",
    "About the navigation",
    "Site wide header junk",
    "Copyright nobody",
    "Enable JavaScript",
  ]) {
    expect(text, junk).not.toContain(junk);
  }
  expect(text).not.toContain("<");
});

test("redirects are followed and the landing URL is what comes back", async () => {
  const page = await fetchReadable(`${base}/moved`);

  expect(page.url).toBe(`${base}/page`);
  expect(page.title).toBe("Yorozu & the Art of Fetching");
});

test("an HTTP error is an error, not a page of error markup", async () => {
  await expect(fetchReadable(`${base}/missing`)).rejects.toThrow("404");
});

test("a non-HTML body comes back as it arrived", async () => {
  const page = await fetchReadable(`${base}/plain`);

  expect(page.title).toBe("");
  expect(page.text).toBe("just text, no markup");
});

test("a long page is truncated to the cap the model can afford", async () => {
  const page = await fetchReadable(`${base}/long`, 200);

  expect(page.text).toContain("truncated");
  expect(page.text.length).toBeLessThan(300);
});

test("the tool reports the title, the URL and then the text", async () => {
  const out = await fetchTool.run({ url: `${base}/page` });

  expect(out.split("\n").slice(0, 2)).toEqual([
    "# Yorozu & the Art of Fetching",
    `${base}/page`,
  ]);
  expect(out).toContain("Second paragraph.");
});

test("the tool refuses anything that is not http", async () => {
  await expect(Promise.resolve(fetchTool.run({ url: "file:///etc/passwd" }))).rejects.toThrow(
    "http or https",
  );
});

test("entities decode by name and by code point", () => {
  expect(decodeEntities("a &amp; b &#8212; c &#x2014; d &nbsp;e &bogus;")).toBe(
    "a & b — c — d  e &bogus;",
  );
});
