// /llm.txt: the same bytes as public/llms.txt, for agents that ask for the singular name
import text from '../../public/llms.txt?raw';

export const GET = () => new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
