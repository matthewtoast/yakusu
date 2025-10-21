import { NextResponse } from "next/server";
import { safeJsonParseTyped } from "../../../../lib/JSONHelpers";
import { getOpenAI, translateText } from "../../../../lib/OpenAIUtils";

export const runtime = "nodejs";

type Body = {
  lines: string[];
  sl: string;
  tl: string;
  instruction: string;
};

type ResBody = {
  ok: boolean;
  lines: string[];
};

export async function POST(req: Request) {
  const payload = await req.text();
  const body = safeJsonParseTyped<Body>(
    payload,
    (v) =>
      Array.isArray(v?.lines) &&
      v.lines.every((line: unknown) => typeof line === "string") &&
      typeof v?.sl === "string" &&
      typeof v?.tl === "string" &&
      typeof v?.instruction === "string"
  );
  if (!body) {
    console.warn("invalid translate payload");
    return NextResponse.json<ResBody>(
      { ok: false, lines: [] },
      { status: 400 }
    );
  }
  const src = body.lines
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  if (src.length === 0) {
    console.warn("empty translate text");
    return NextResponse.json<ResBody>(
      { ok: false, lines: [] },
      { status: 400 }
    );
  }
  const hint = body.instruction.trim();
  if (hint.length > 100) {
    return NextResponse.json<ResBody>(
      { ok: false, lines: [] },
      { status: 400 }
    );
  }
  const ai = getOpenAI();
  if (!ai) {
    return NextResponse.json<ResBody>(
      { ok: false, lines: [] },
      { status: 500 }
    );
  }
  console.info("request ::", body.sl, body.tl, src);
  const res = await translateText(ai, {
    lines: src,
    sl: body.sl,
    tl: body.tl,
    instruction: hint,
  });
  console.info("response ::", res);
  if (!res) {
    return NextResponse.json<ResBody>(
      { ok: false, lines: [] },
      { status: 502 }
    );
  }
  return NextResponse.json<ResBody>({ ok: true, lines: res }, { status: 200 });
}
