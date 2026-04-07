import { cpSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sharedRoot = join(root, "packages/shared");
const targetDir = join(root, "api/node_modules/@tasks-app/shared");

rmSync(targetDir, { recursive: true, force: true });
mkdirSync(targetDir, { recursive: true });
cpSync(join(sharedRoot, "dist"), join(targetDir, "dist"), { recursive: true });
cpSync(join(sharedRoot, "package.json"), join(targetDir, "package.json"));
