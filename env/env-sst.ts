import { z } from "zod";
import { loadBaseEnv, ZBaseEnvSchema } from "./env-base";
import { loadEnvFile } from "./load-env";

loadEnvFile(import.meta.url, ".env.sst");

export const ZSstEnvSchema = z.intersection(
  ZBaseEnvSchema,
  z.object({
    APPLE_AUDIENCE: z.string(),
    AUTH_SECRET: z.string(),
    OPENROUTER_API_KEY: z.string(),
    OPENROUTER_BASE_URL: z.string(),
  })
);

export type SstEnv = z.infer<typeof ZSstEnvSchema>;

export const loadSstEnv = (): SstEnv => {
  try {
    return ZSstEnvSchema.parse({
      ...loadBaseEnv(),
      ...process.env,
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      const missingVars = error.errors
        .map((err) => err.path.join("."))
        .join(", ");
      throw new Error(
        `Missing or invalid SST environment variables: ${missingVars}`
      );
    }
    throw error;
  }
};
