import dedent from "dedent";
import OpenAI from "openai";
import { loadSstEnv } from "../env/env-sst";
import { NonEmpty } from "../typings";
import { safeJsonParseTyped } from "./JSONHelpers";
import { generateText, LLM_SLUGS } from "./OpenRouterUtils";

type TranslateArgs = {
  lines: string[];
  sl: string;
  tl: string;
  instruction: string;
};

let cli: OpenAI | null = null;

const MODELS: NonEmpty<(typeof LLM_SLUGS)[number]> = [
  "openai/gpt-5-mini",
  "openai/gpt-5-nano",
  "openai/gpt-4.1-mini",
  "openai/gpt-4.1-nano",
];

const env = loadSstEnv();

export function getOpenAI(): OpenAI | null {
  if (cli) return cli;
  const key = env.OPENROUTER_API_KEY;
  const url = env.OPENROUTER_BASE_URL;
  if (!key || !url) {
    console.warn("missing openrouter config");
    return null;
  }
  cli = new OpenAI({ apiKey: key, baseURL: url });
  return cli;
}

const cleanLang = (code: string) => {
  const raw = code.trim();
  if (!raw) return raw;
  const parts = raw.split(/[-_]/g).filter((part) => part.length > 0);
  if (parts.length === 0) return raw;
  const lang = parts[0].toLowerCase();
  if (parts.length === 1) return lang;
  const tail = parts
    .slice(1)
    .map((part) => part.toUpperCase())
    .join("-");
  return `${lang}-${tail}`;
};

export async function translateText(
  ai: OpenAI,
  args: TranslateArgs
): Promise<string[] | null> {
  const src = args.lines
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  if (src.length === 0) return null;
  const from = cleanLang(args.sl);
  const to = cleanLang(args.tl);
  const extra = args.instruction.trim().slice(0, 100);
  const guidance = extra ? `. Follow this guidance: ${extra}` : "";
  const header = `Translate the content of the given JSON input from ${from} to ${to}${guidance}.`;
  const format = dedent`
    Return a valid JSON array of ${src.length} translated strings, in corresponding order.
    Add no additional text, no formatting, no Markdown, no comments.
    Return only JSON:
  `.trim();
  const prompt = `${header}\n${format}\n<input>${JSON.stringify(src)}</input>`;
  const res = await generateText(ai, prompt, false, MODELS, null).catch(
    (err) => {
      console.error("translate failed", err);
      return null;
    }
  );
  if (!res) {
    console.error("empty response");
    return null;
  }
  const out = res.trim();
  if (!out) {
    console.error("blank response");
    return null;
  }
  const parsed = safeJsonParseTyped<string[]>(
    out,
    (value) =>
      Array.isArray(value) &&
      value.length === src.length &&
      value.every((v) => typeof v === "string")
  );
  if (!parsed) {
    console.error("invalid payload", out);
    return null;
  }
  return parsed.map((line) => line.trim());
}
