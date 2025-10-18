import { NextResponse } from "next/server";
import { getOpenAI, translateText } from "../../../../lib/OpenAIUtils";
import { safeJsonParseTyped } from "../../../../lib/JSONHelpers";

export const runtime = "nodejs";

type Body = {
  text: string;
  sl: string;
  tl: string;
  instruction: string;
};

type ResBody = {
  ok: boolean;
  text: string | null;
};

export async function POST(req: Request) {
  const payload = await req.text();
  const body = safeJsonParseTyped<Body>(
    payload,
    (v) =>
      typeof v?.text === "string" &&
      typeof v?.sl === "string" &&
      typeof v?.tl === "string" &&
      typeof v?.instruction === "string"
  );
  if (!body) {
    console.warn("invalid translate payload");
    return NextResponse.json<ResBody>({ ok: false, text: null }, { status: 400 });
  }
  const txt = body.text.trim();
  if (!txt) {
    console.warn("empty translate text");
    return NextResponse.json<ResBody>({ ok: false, text: null }, { status: 400 });
  }
  const hint = body.instruction.trim();
  if (hint.length > 100) {
    return NextResponse.json<ResBody>({ ok: false, text: null }, { status: 400 });
  }
  const ai = getOpenAI();
  if (!ai) {
    return NextResponse.json<ResBody>({ ok: false, text: null }, { status: 500 });
  }
  const res = await translateText(ai, {
    text: txt,
    sl: body.sl,
    tl: body.tl,
    instruction: hint,
  });
  if (!res) {
    return NextResponse.json<ResBody>({ ok: false, text: null }, { status: 502 });
  }
  return NextResponse.json<ResBody>({ ok: true, text: res }, { status: 200 });
}
