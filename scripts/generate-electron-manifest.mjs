import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { fileURLToPath } from "node:url";
import { readdir, stat, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";

function required(name, value) {
  const normalized = value?.trim();
  if (!normalized) throw new Error(`${name} is required`);
  return normalized;
}

function normalizeBaseUrl(value) {
  const url = new URL(required("RELEASE_ASSET_BASE_URL", value));
  if (url.search || url.hash) throw new Error("RELEASE_ASSET_BASE_URL must not contain query or hash");
  return `${url.toString().replace(/\/+$/u, "")}/`;
}

function hashFile(filePath) {
  return new Promise((resolveHash, rejectHash) => {
    const sha256 = createHash("sha256");
    const sha512 = createHash("sha512");
    const stream = createReadStream(filePath);
    let size = 0;
    stream.on("data", (chunk) => {
      size += chunk.length;
      sha256.update(chunk);
      sha512.update(chunk);
    });
    stream.on("error", rejectHash);
    stream.on("end", () => {
      resolveHash({
        size,
        sha2: sha256.digest("hex"),
        sha512: sha512.digest("base64"),
      });
    });
  });
}

function assetUrl(baseUrl, name) {
  return new URL(encodeURIComponent(name), baseUrl).toString();
}

export async function generateElectronManifest({ outputDir, version, releaseAssetBaseUrl }) {
  const normalizedOutputDir = resolve(required("OUTPUT_DIR", outputDir));
  const normalizedVersion = required("RELEASE_VERSION", version);
  const baseUrl = normalizeBaseUrl(releaseAssetBaseUrl);
  const names = await readdir(normalizedOutputDir);
  const artifacts = names
    .filter((name) => /\.(?:dmg|zip)$/iu.test(name))
    .sort((left, right) => left.localeCompare(right));
  const dmgArtifacts = artifacts.filter((name) => name.toLowerCase().endsWith(".dmg"));
  const zipArtifacts = artifacts.filter((name) => name.toLowerCase().endsWith(".zip"));
  if (dmgArtifacts.length !== 1 || zipArtifacts.length !== 1) {
    throw new Error(
      `Expected exactly one DMG and one ZIP for ${normalizedVersion}; found ${artifacts.join(", ") || "none"}`,
    );
  }

  const expectedVersionMarker = `-${normalizedVersion}-`;
  for (const name of artifacts) {
    if (!name.includes(expectedVersionMarker)) {
      throw new Error(`Artifact does not contain source version ${normalizedVersion}: ${name}`);
    }
  }

  const fileEntries = [];
  for (const name of [zipArtifacts[0], dmgArtifacts[0]]) {
    const filePath = join(normalizedOutputDir, name);
    const fileStats = await stat(filePath);
    if (!fileStats.isFile() || fileStats.size === 0) {
      throw new Error(`Release artifact is empty or not a file: ${name}`);
    }
    const digest = await hashFile(filePath);
    const entry = {
      url: assetUrl(baseUrl, name),
      sha512: digest.sha512,
      sha2: digest.sha2,
      size: digest.size,
    };
    fileEntries.push({ name, url: entry.url, sha512: entry.sha512, sha2: entry.sha2, size: entry.size });
    await writeFile(join(normalizedOutputDir, `${name}.sha256`), `${digest.sha2}  ${name}\n`, "utf8");
  }

  const zipEntry = fileEntries.find((entry) => entry.name.toLowerCase().endsWith(".zip"));
  const manifest = {
    version: normalizedVersion,
    releaseDate: new Date().toISOString(),
    path: zipEntry.url,
    sha2: zipEntry.sha2,
    sha512: zipEntry.sha512,
    files: fileEntries.map(({ name, url, sha512, sha2, size }) => ({ url, sha512, sha2, size })),
  };
  const manifestText = `${JSON.stringify(manifest, null, 2)}\n`;
  const manifestNames = ["latest-darwin-aarch64.yml", "latest-mac.yml"];
  for (const manifestName of manifestNames) {
    const manifestPath = join(normalizedOutputDir, manifestName);
    await writeFile(manifestPath, manifestText, "utf8");
    const manifestDigest = await hashFile(manifestPath);
    await writeFile(
      `${manifestPath}.sha256`,
      `${manifestDigest.sha2}  ${basename(manifestPath)}\n`,
      "utf8",
    );
  }

  return {
    manifest,
    assetNames: [
      ...fileEntries.map((entry) => entry.name),
      ...fileEntries.map((entry) => `${entry.name}.sha256`),
      ...manifestNames,
      ...manifestNames.map((name) => `${name}.sha256`),
    ],
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const result = await generateElectronManifest({
    outputDir: process.env.OUTPUT_DIR,
    version: process.env.RELEASE_VERSION,
    releaseAssetBaseUrl: process.env.RELEASE_ASSET_BASE_URL,
  });
  console.log(`Generated ${result.assetNames.filter((name) => name.endsWith(".yml")).join(", ")}`);
}
