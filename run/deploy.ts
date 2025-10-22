import { execSync } from "node:child_process";
import { join } from "node:path";
import { loadDevEnv } from "../env/env-dev";
import { loadSstEnv } from "../env/env-sst";

const sstEnv = loadSstEnv();
const devEnv = loadDevEnv();
const root = join(__dirname, "..");

async function go() {
  execSync("yarn sst deploy --stage prod", {
    stdio: "inherit",
    cwd: root,
    env: { ...sstEnv, ...devEnv },
  });
}

go();
