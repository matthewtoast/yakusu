import dedent from "dedent";
import OpenAI from "openai";
import { NonEmpty, TSerial } from "../typings";

export const LLM_SLUGS = [
  "openai/gpt-5",
  "openai/gpt-5-mini",
  "openai/gpt-5-nano",
  "openai/gpt-4.1",
  "openai/gpt-4.1-mini",
  "openai/gpt-4.1-nano",
  "openai/gpt-4o",
  "anthropic/claude-3.5-sonnet",
  "deepseek/deepseek-r1",
  "deepseek/deepseek-v3.1",
  "mistralai/mistral-large",
  "meta-llama/llama-3.1-70b-instruct",
  "cognitivecomputations/dolphin-mistral-24b-venice-edition:free",
  "meta-llama/llama-3.3-70b-instruct:free",
  "meta-llama/llama-3.2-3b-instruct:free",
] as const;

type OpenAIChatModel = (typeof LLM_SLUGS)[number];

export type AIChatMessage = {
  role: "user" | "assistant" | "system" | "developer";
  body: string;
};

export type TokenUsageDetails = {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
};

export type UsageInfo = {
  model: string;
  usage: TokenUsageDetails | null;
};

export type UsageSink = (info: UsageInfo) => void;

const asInput = (p: string | AIChatMessage[]) =>
  typeof p === "string"
    ? [{ role: "user" as const, content: p }]
    : p.map((m) => ({
        role: (m.role === "developer" ? "system" : m.role) as
          | "user"
          | "assistant"
          | "system",
        content: m.body,
      }));

const readText = (r: {
  choices?: Array<{ message?: { content?: string } }>;
}): string => (r.choices ?? []).map((c) => c?.message?.content ?? "").join("");

const readUsage = (
  usage:
    | {
        prompt_tokens?: number;
        completion_tokens?: number;
        total_tokens?: number;
      }
    | null
    | undefined
): TokenUsageDetails | null => {
  if (!usage) {
    return null;
  }
  const prompt = Number(usage.prompt_tokens) || 0;
  const completion = Number(usage.completion_tokens) || 0;
  const total = Number(usage.total_tokens) || prompt + completion;
  return {
    promptTokens: Math.max(prompt, 0),
    completionTokens: Math.max(completion, 0),
    totalTokens: Math.max(total, 0),
  };
};

const emitUsage = (sink: UsageSink | null, info: UsageInfo) => {
  if (!sink) {
    return;
  }
  sink(info);
};

const addOnline = (s: string, on: boolean) =>
  on ? (s.includes(":online") ? s : `${s}:online`) : s;
const prepRoute = (models: NonEmpty<OpenAIChatModel>, online: boolean) => {
  const route = models.map((m) => addOnline(m, online));
  const [model, ...fallbacks] = route;
  return { model, fallbacks };
};

export async function generateText(
  openai: OpenAI,
  prompt: string,
  useWebSearch = false,
  models: NonEmpty<OpenAIChatModel>,
  sink: UsageSink | null
) {
  const { model, fallbacks } = prepRoute(models, useWebSearch);
  const r = await openai.chat.completions.create({
    model,
    messages: asInput(prompt),
    ...(fallbacks.length ? { extra_body: { models: fallbacks } } : {}),
  });
  emitUsage(sink, {
    model,
    usage: readUsage((r as any).usage),
  });
  return readText(r as any);
}

export const generateImage = async (
  openai: OpenAI,
  prompt: string,
  aspectRatio?: string
) => {
  const res = (await openai.chat.completions.create({
    model: "openai/gpt-5-image-mini",
    messages: [{ role: "user", content: prompt }],
    modalities: ["image" as any, "text"],
    ...(aspectRatio ? { image_config: { aspect_ratio: aspectRatio } } : {}),
  })) as any;
  const img = res.choices?.[0]?.message?.images?.[0]?.image_url?.url as
    | string
    | undefined;
  if (!img) throw new Error("No image returned");
  return img; // data URL (e.g., "data:image/png;base64,...")
};

export async function extractJson(
  openai: OpenAI,
  text: string,
  schema: string,
  models: NonEmpty<OpenAIChatModel>,
  sink: UsageSink | null
): Promise<Record<string, TSerial>> {
  return generateJson(
    openai,
    dedent`
      Per the given schema, extract structured data from this input:
      <INPUT>
        ${text}
      </INPUT>
    `.trim(),
    schema,
    models,
    sink
  );
}

export async function generateJsonWithWeb(
  openai: OpenAI,
  prompt: string,
  schema: string,
  models: NonEmpty<OpenAIChatModel>,
  sink: UsageSink | null
) {
  return extractJson(
    openai,
    await generateText(openai, prompt, true, models, sink),
    schema,
    models,
    sink
  );
}

export async function generateJson(
  openai: OpenAI,
  prompt: string,
  schema: string,
  models: NonEmpty<OpenAIChatModel>,
  sink: UsageSink | null
): Promise<Record<string, TSerial>> {
  const { model, fallbacks } = prepRoute(models, false);
  const preface = "Return only a JSON object. Follow this schema:\n" + schema;
  const r = await openai.chat.completions.create({
    model,
    messages: [
      { role: "system", content: preface },
      { role: "user", content: prompt },
    ],
    response_format: { type: "json_object" as const },
    ...(fallbacks.length ? { extra_body: { models: fallbacks } } : {}),
  });
  emitUsage(sink, {
    model,
    usage: readUsage((r as any).usage),
  });
  const txt = readText(r as any) || "{}";
  return JSON.parse(txt);
}

export async function generateChatResponse(
  openai: OpenAI,
  messages: AIChatMessage[],
  models: NonEmpty<OpenAIChatModel>,
  sink: UsageSink | null
) {
  const { model, fallbacks } = prepRoute(models, true);
  const r = await openai.chat.completions.create({
    model,
    messages: asInput(messages),
    ...(fallbacks.length ? { extra_body: { models: fallbacks } } : {}),
  });
  emitUsage(sink, {
    model,
    usage: readUsage((r as any).usage),
  });
  return readText(r as any);
}

export const OpenRouterModerationCategories = {
  spam: "Unsolicited, repetitive, or irrelevant content.",
  hate: "Content expressing or promoting hate or discrimination against a group or individual.",
  harassment: "Targeted insults, bullying, or intimidation.",
  self_harm:
    "Expressions, encouragement, or instructions of self-injury or suicide.",
  sexual: "Sexual or pornographic content, including explicit roleplay.",
  sexual_minors: "Any sexual content involving minors.",
  violence: "Threats or depictions of physical harm or aggression.",
  graphic_content:
    "Highly explicit descriptions of violence, gore, or sexual acts.",
  criminal_activity: "Promotion or instruction of illegal activities.",
  extremism: "Advocacy or recruitment for extremist or terrorist causes.",
  drugs: "Discussion or promotion of illegal or controlled substances.",
  impersonation: "Pretending to be another person, entity, or the system.",
  malicious_input:
    "Attempts to exploit or manipulate system behavior via crafted input (e.g., prompt injection, code injection).",
  system_abuse:
    "Actions aimed at disrupting, crashing, or exploiting the system.",
  evasion: "Attempts to bypass safety filters or moderation controls.",
} as const;

export type TOpenRouterModerationCategory =
  keyof typeof OpenRouterModerationCategories;

export type TOpenRouterModerationScores = Record<
  TOpenRouterModerationCategory,
  number
>;

export type TOpenRouterModerationResult = {
  flagged: boolean;
  scores: TOpenRouterModerationScores;
};

export async function moderateInput(
  openai: OpenAI,
  input: string,
  models: NonEmpty<OpenAIChatModel>,
  threshold: number,
  sink: UsageSink | null
): Promise<TOpenRouterModerationResult | null> {
  const schema: Record<string, TSerial> = {};
  (
    Object.keys(
      OpenRouterModerationCategories
    ) as TOpenRouterModerationCategory[]
  ).forEach((k) => {
    schema[k] = "number";
  });
  const prompt = dedent`
    Score the input between 0 and 1 for each moderation category.
    Only return numeric values for every category.
    <input>${input}</input>
  `;
  const data = await generateJson(
    openai,
    prompt.trim(),
    JSON.stringify(schema),
    models,
    sink
  ).catch((err) => {
    console.warn("Failed to score moderation", err);
    return null;
  });
  if (!data) {
    return null;
  }
  const scores = {} as TOpenRouterModerationScores;
  const keys = Object.keys(
    OpenRouterModerationCategories
  ) as TOpenRouterModerationCategory[];
  keys.forEach((k) => {
    const raw = data[k];
    const num = typeof raw === "number" ? raw : Number(raw);
    const val = Number.isFinite(num) ? num : 0;
    const clamped = Math.min(Math.max(val, 0), 1);
    scores[k] = clamped;
  });
  const t = Math.min(Math.max(threshold, 0), 1);
  const flagged = keys.some((k) => scores[k] > t);
  return { flagged, scores };
}
