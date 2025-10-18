import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import { ulid } from "ulid";
import { loadAppEnv } from "../env/env-app";
import { cleanSplit } from "./TextHelpers";
import { createUserRepo, UserRecord } from "./UserRepo";

const env = loadAppEnv();
const userRepo = createUserRepo({
  ddb: new DynamoDBClient({}),
  tableName: env.USERS_TABLE,
});

type SessionClaims = {
  uid: string;
  ver: number;
  roles: string[];
};

export type ProviderAccount = {
  provider: "apple" | "dev";
  providerUserId: string;
  email: string | null;
};

const appleIssuer = "https://appleid.apple.com";
const appleKeys = createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys")
);

export async function verifyAppleIdentityToken(
  token: string
): Promise<ProviderAccount | null> {
  const aud = cleanSplit(env.APPLE_AUDIENCE, ",");
  return jwtVerify(token, appleKeys, {
    issuer: appleIssuer,
    audience: aud,
  }).then((res) => {
    const payload = res.payload as Record<string, unknown>;
    const sub = payload.sub;
    if (typeof sub !== "string") return null;
    const email = typeof payload.email === "string" ? payload.email : null;
    return {
      provider: "apple",
      providerUserId: sub,
      email,
    } as ProviderAccount;
  });
}

export function verifyDevToken(token: string): ProviderAccount | null {
  const keys = cleanSplit(env.DEV_API_KEYS, ",");
  if (keys.length === 0) return null;
  const match = keys.find((k) => k === token);
  if (!match) return null;
  return {
    provider: "dev",
    providerUserId: match,
    email: null,
  } as ProviderAccount;
}

let cachedKey: Uint8Array | null = null;

function key(): Uint8Array | null {
  if (cachedKey) return cachedKey;
  const secret = env.AUTH_SECRET;
  if (!secret) return null;
  cachedKey = new TextEncoder().encode(secret);
  return cachedKey;
}

export async function issueSessionToken(
  claims: SessionClaims,
  expirationTimeExpr: string
): Promise<string | null> {
  const k = key();
  if (!k) return null;
  const token = await new SignJWT({
    uid: claims.uid,
    ver: claims.ver,
    roles: claims.roles,
  })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(expirationTimeExpr)
    .sign(k)
    .catch((err) => {
      console.warn("failed to sign session", err);
      return null as string | null;
    });
  if (!token) return null;
  return token;
}

export async function verifySessionToken(
  token: string
): Promise<SessionClaims | null> {
  const k = key();
  if (!k) return null;
  return jwtVerify(token, k)
    .then((res) => {
      const payload = res.payload as Record<string, unknown>;
      const uid = payload.uid;
      const ver = payload.ver;
      const roles = payload.roles;
      if (typeof uid !== "string") return null;
      if (typeof ver !== "number") return null;
      if (!Array.isArray(roles)) return null;
      if (roles.some((r) => typeof r !== "string")) return null;
      return { uid, ver, roles: roles as string[] };
    })
    .catch((err) => {
      console.warn("invalid session token", err);
      return null;
    });
}

type ProviderId = ProviderAccount["provider"];

function ensureRoles(roles: string[] | null | undefined): string[] {
  if (!roles) return [];
  return roles;
}

async function upsertUser(
  account: ProviderAccount
): Promise<UserRecord | null> {
  const existing = await userRepo.findUserByProvider(
    account.provider,
    account.providerUserId
  );
  const now = Date.now();
  if (!existing) {
    const record: UserRecord = {
      id: ulid(),
      provider: account.provider,
      providerUserId: account.providerUserId,
      email: account.email,
      roles: [],
      sessionVersion: 1,
      createdAt: now,
      updatedAt: now,
    };
    await userRepo.saveUser(record);
    return record;
  }
  const next: UserRecord = {
    ...existing,
    email: account.email,
    roles: ensureRoles(existing.roles),
    updatedAt: now,
  };
  await userRepo.saveUser(next);
  return next;
}

async function issue(
  account: ProviderAccount,
  expirationTimeExpr: string
): Promise<{
  token: string;
  user: UserRecord;
} | null> {
  const user = await upsertUser(account);
  if (!user) return null;
  const token = await issueSessionToken(
    {
      uid: user.id,
      ver: user.sessionVersion,
      roles: ensureRoles(user.roles),
    },
    expirationTimeExpr
  );
  if (!token) return null;
  return { token, user };
}

function mapProvider(
  provider: ProviderId,
  proof: string
): Promise<ProviderAccount | null> {
  if (provider === "apple") return verifyAppleIdentityToken(proof);
  if (provider === "dev") return Promise.resolve(verifyDevToken(proof));
  return Promise.resolve(null);
}

export async function exchangeSession(
  provider: ProviderId,
  proof: string,
  expirationTimeExpr: string
): Promise<{ token: string; user: UserRecord } | null> {
  const account = await mapProvider(provider, proof);
  if (!account) return null;
  return issue(account, expirationTimeExpr);
}

export async function authenticateSession(
  token: string
): Promise<UserRecord | null> {
  const claims = await verifySessionToken(token);
  if (!claims) return null;
  const user = await userRepo.getUser(claims.uid);
  if (!user) return null;
  if (user.sessionVersion !== claims.ver) return null;
  const roles = ensureRoles(user.roles);
  return { ...user, roles };
}

export function fromAuthorization(req: Request): string | null {
  const header = req.headers.get("authorization");
  if (!header) return null;
  if (!header.toLowerCase().startsWith("bearer ")) return null;
  return header.slice(7).trim();
}

export function parseCookies(raw: string): Record<string, string> {
  const pairs = raw.split(";");
  const out: Record<string, string> = {};
  for (const pair of pairs) {
    const index = pair.indexOf("=");
    if (index === -1) continue;
    const name = pair.slice(0, index).trim();
    if (!name) continue;
    const value = pair.slice(index + 1).trim();
    out[name] = value;
  }
  return out;
}

export function fromCookie(req: Request): string | null {
  const header = req.headers.get("cookie");
  if (!header) return null;
  const cookies = parseCookies(header);
  if (!cookies.session) return null;
  return cookies.session;
}
