import { SSTConfig } from "sst";
import { NextjsSite, Table } from "sst/constructs";

// Whomever invokes this should export or pass these env vars!
const REQUIRED_ENV_VARS = [
  "APPLE_AUDIENCE",
  "AUTH_SECRET",
  "AWS_PROFILE",
  "DEV_API_KEYS",
  "NODE_ENV",
  "OPENROUTER_API_KEY",
  "OPENROUTER_BASE_URL",
];
const env: Record<string, string> = {};
REQUIRED_ENV_VARS.forEach((key) => {
  if (!process.env[key]) {
    throw new Error(`process.env.${key} not found`);
  }
  env[key] = process.env[key];
});
const region =
  process.env.AWS_REGION ??
  process.env.AWS_DEFAULT_REGION ??
  process.env.SST_REGION ??
  "us-east-1";
if (!process.env.AWS_REGION) process.env.AWS_REGION = region;

export default {
  config() {
    return { name: "yakusu-web", region };
  },
  stacks(app) {
    app.stack(function Site({ stack }) {
      const users = new Table(stack, "UsersTable", {
        fields: {
          id: "string",
          provider: "string",
          providerUserId: "string",
          email: "string",
          roles: "string",
          sessionVersion: "number",
          createdAt: "number",
          updatedAt: "number",
        },
        primaryIndex: { partitionKey: "id" },
      });
      const site = new NextjsSite(stack, "Site", {
        // customDomain: "",
        path: "web",
        permissions: [users],
        environment: {
          ...omit(env, "AWS_PROFILE"),
          USERS_TABLE: users.tableName,
        },
      });
      stack.addOutputs({
        SiteUrl: site.url,
        UsersTable: users.tableName,
      });
    });
  },
} satisfies SSTConfig;

function omit<T extends Record<string, any>>(obj: T, ...keys: string[]): T {
  const res = {} as T;
  Object.keys(obj).forEach((k) => {
    if (!keys.includes(k)) {
      res[k as keyof T] = obj[k];
    }
  });
  return res;
}
