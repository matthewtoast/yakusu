import { ChildProcess, spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { loadDevEnv } from "../env/env-dev";
import { loadSstEnv } from "../env/env-sst";
import { safeConfigValue } from "../lib/DevTools";
import {
  cleanSplit,
  extractNetworkDomainFromSSTString,
} from "../lib/TextHelpers";
import { apiFetchDevSessions } from "../lib/WebAPI";

const API_BASE_VAR = "YAKUSU_API_BASE";
const API_PROTO_VAR = "YAKUSU_API_PROTO";

const sstEnv = loadSstEnv();
const devEnv = loadDevEnv();

const root = join(process.cwd());

const spawnProc = (
  cwd: string,
  cmd: string,
  args: string[],
  env: NodeJS.ProcessEnv
): ChildProcess =>
  spawn(cmd, args, {
    cwd,
    env,
    detached: true,
    shell: process.platform === "win32",
    stdio: ["ignore", "pipe", "inherit"],
  });

const killTree = (p?: ChildProcess) => {
  if (!p?.pid) return;
  const pid = p.pid;
  try {
    if (process.platform === "win32")
      spawn("taskkill", ["/pid", String(pid), "/t", "/f"]);
    else {
      process.kill(-pid, "SIGTERM");
      setTimeout(() => {
        try {
          process.kill(-pid, "SIGKILL");
        } catch {}
      }, 1000);
    }
  } catch {}
};

const waitExit = (p: ChildProcess) =>
  new Promise<number | null>((r) => p.once("exit", (c) => r(c)));

async function go() {
  let next: ChildProcess | undefined;
  const processes: ChildProcess[] = [];

  const onSig = () => {
    killTree(next);
    killTree(sst);
    processes.forEach(killTree);
    process.exit();
  };

  const webDir = join(root, "web");
  const sst = spawnProc(root, "npx", ["sst", "dev"], {
    ...process.env,
    ...sstEnv,
  });
  processes.push(sst);
  sst.stdout!.on("data", (b: Buffer) => {
    const s = b.toString();
    process.stdout.write(s);
    if (!next && /Start Next\.js|Next\.js/i.test(s)) {
      next = spawnProc(webDir, "npx", ["sst", "bind", "next", "dev"], {
        ...process.env,
        ...sstEnv,
      });
      processes.push(next);
      const env: Record<string, string> = {};
      next.stdout!.on("data", (x: Buffer) => {
        const s = x.toString();
        const urlWithoutScheme = extractNetworkDomainFromSSTString(s);
        if (urlWithoutScheme) {
          env[API_BASE_VAR] = `${urlWithoutScheme}`;
          env[API_PROTO_VAR] = `http`;
        }
        return process.stdout.write(x);
      });
      setTimeout(() => {
        if (!env[API_BASE_VAR] || !env[API_PROTO_VAR]) {
          throw new Error("API base & proto var must be defined");
        }
        setupFixtures(env, onSig);
      }, 10_000);
    }
  });

  process.on("SIGINT", onSig);
  process.on("SIGTERM", onSig);

  const race = await Promise.race([
    waitExit(sst).then((c) => (killTree(next), { name: "sst", code: c })),
    new Promise<{ name: string; code: number | null }>((resolve) => {
      const check = () =>
        next
          ? waitExit(next!).then(
              (c) => (killTree(sst), resolve({ name: "next", code: c }))
            )
          : setTimeout(check, 200);
      check();
    }),
  ]);

  process.exitCode = race.code ?? 1;
}

go();

async function setupFixtures(env: Record<string, string>, err: () => void) {
  const argv = await yargs(hideBin(process.argv))
    .parserConfiguration({
      "camel-case-expansion": true,
      "strip-aliased": true,
    })
    .help()
    .parse();

  console.info("[dev] Fetching sessions");
  const devSessions = await apiFetchDevSessions(
    `${devEnv.YAKUSU_API_PROTO}://${devEnv.YAKUSU_API_BASE}`,
    cleanSplit(devEnv.DEV_API_KEYS, ",")
  );
  if (devSessions.length < 1) {
    return err();
  }
  const { user: sessionUser, token: sessionToken } = devSessions[0];

  console.info("[dev] Writing iOS configuration");
  const iosDir = join(root, "ios");
  const configPath = join(iosDir, "YAKUSU", "Generated.xcconfig");
  await mkdir(dirname(configPath), { recursive: true }).catch(() => {});
  const lines = [
    `DEV_SESSION_TOKEN = ${safeConfigValue(sessionToken, "_")}`,
    `DEV_SESSION_USER_ID = ${safeConfigValue(sessionUser.id, "_")}`,
    `DEV_SESSION_USER_PROVIDER = ${safeConfigValue(sessionUser.provider, "_")}`,
    `DEV_SESSION_USER_EMAIL = ${safeConfigValue(sessionUser.email, "test@aisatsu.co")}`,
    `DEV_SESSION_USER_ROLES = ${safeConfigValue(sessionUser.roles?.join(","), "user")}`,
  ];
  for (const key in env) {
    lines.push(`${key} = ${safeConfigValue(env[key], "_")}`);
  }
  console.info("[dev] iOS vars", lines);
  await writeFile(configPath, lines.join("\n") + "\n", "utf8");

  console.info("[dev] Writing web session");
  const webDir = join(root, "web");
  const webConfigPath = join(webDir, ".dev-session.json");
  const webPayload = JSON.stringify({ token: sessionToken }, null, 2);
  await writeFile(webConfigPath, webPayload + "\n", "utf8");
}
