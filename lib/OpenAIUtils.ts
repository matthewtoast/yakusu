import OpenAI from "openai";
import { NonEmpty } from "../typings";
import { generateText, LLM_SLUGS } from "./OpenRouterUtils";

type TranslateArgs = {
  text: string;
  sl: string;
  tl: string;
};

let cli: OpenAI | null = null;

const MODELS: NonEmpty<(typeof LLM_SLUGS)[number]> = ["openai/gpt-4.1-mini"];

export function getOpenAI(): OpenAI | null {
  if (cli) return cli;
  const key = process.env.OPENROUTER_API_KEY;
  const url = process.env.OPENROUTER_BASE_URL;
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
): Promise<string | null> {
  const src = args.text.trim();
  if (!src) return null;
  const from = cleanLang(args.sl);
  const to = cleanLang(args.tl);
  const prompt = `Translate this text from ${from} to ${to}. Return only the translation.\n\n${src}`;
  const res = await generateText(ai, prompt, false, MODELS, null).catch(
    (err) => {
      console.warn("translate failed", err);
      return null;
    }
  );
  if (!res) return null;
  const out = res.trim();
  if (!out) return null;
  return out;
}
