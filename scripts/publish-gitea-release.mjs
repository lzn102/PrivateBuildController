import { openAsBlob } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { generateElectronManifest } from "./generate-electron-manifest.mjs";

function required(name, value) {
  const normalized = value?.trim();
  if (!normalized) throw new Error(`${name} is required`);
  return normalized;
}

function encodePathSegment(value) {
  return encodeURIComponent(value);
}

function parseRepository(sourceRepoUrl, repositoryApiUrl) {
  if (repositoryApiUrl?.trim()) {
    const parsed = new URL(repositoryApiUrl.trim());
    const segments = parsed.pathname.split("/").filter(Boolean);
    const apiIndex = segments.indexOf("api");
    const reposIndex = segments.indexOf("repos");
    if (apiIndex < 0 || reposIndex < 0 || segments.length < reposIndex + 3) {
      throw new Error("REPOSITORY_API_URL must contain /api/v1/repos/<owner>/<repo>");
    }
    const apiBasePath = `/${segments.slice(0, apiIndex + 2).join("/")}`;
    return {
      apiBase: `${parsed.origin}${apiBasePath}`,
      origin: parsed.origin,
      owner: segments[reposIndex + 1],
      repo: segments[reposIndex + 2],
    };
  }

  const parsed = new URL(required("SOURCE_REPO_URL", sourceRepoUrl));
  const segments = parsed.pathname.split("/").filter(Boolean);
  if (segments.length < 2) throw new Error("SOURCE_REPO_URL must contain an owner and repository");
  return {
    apiBase: `${parsed.origin}/api/v1`,
    origin: parsed.origin,
    owner: segments.at(-2),
    repo: segments.at(-1).replace(/\.git$/u, ""),
  };
}

async function readVersion(sourceDir) {
  const raw = await readFile(resolve(required("SOURCE_DIR", sourceDir), "package.json"), "utf8");
  const version = JSON.parse(raw).version;
  if (
    typeof version !== "string" ||
    !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/u.test(version)
  ) {
    throw new Error(`Invalid source package version: ${version}`);
  }
  return version;
}

function assertSourceRef(sourceRef) {
  const normalized = required("SOURCE_REF or BUILD_ID", sourceRef).toLowerCase();
  if (!/^[0-9a-f]{40}$/u.test(normalized)) {
    throw new Error("SOURCE_REF/BUILD_ID must be a 40-character commit SHA");
  }
  return normalized;
}

async function giteaRequest({ apiBase, token, path, method = "GET", body, contentType, length }) {
  const headers = {
    Accept: "application/json",
    Authorization: `token ${token}`,
  };
  if (contentType) headers["Content-Type"] = contentType;
  if (length !== undefined) headers["Content-Length"] = String(length);
  const response = await fetch(`${apiBase.replace(/\/+$/u, "")}${path}`, {
    method,
    headers,
    ...(body === undefined ? {} : { body }),
    ...(body && typeof body !== "string" && typeof body.pipe === "function" ? { duplex: "half" } : {}),
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  if (!response.ok) {
    const detail = parsed?.message || text || response.statusText;
    const error = new Error(`Gitea API ${method} ${path} failed (${response.status}): ${detail}`);
    error.status = response.status;
    throw error;
  }
  return parsed;
}

function validateArtifactNames(names, version) {
  const artifacts = names.filter((name) => /\.(?:dmg|zip)$/iu.test(name));
  const dmg = artifacts.filter((name) => name.toLowerCase().endsWith(".dmg"));
  const zip = artifacts.filter((name) => name.toLowerCase().endsWith(".zip"));
  if (dmg.length !== 1 || zip.length !== 1) {
    throw new Error(`Expected exactly one DMG and one ZIP; found ${artifacts.join(", ") || "none"}`);
  }
  for (const name of artifacts) {
    if (!name.includes(`-${version}-`)) {
      throw new Error(`Artifact does not contain source version ${version}: ${name}`);
    }
  }
}

const sourceRepoUrl = process.env.SOURCE_REPO_URL?.trim() || "";
const sourceRef = assertSourceRef(process.env.SOURCE_REF || process.env.BUILD_ID);
const sourceDir = required("SOURCE_DIR", process.env.SOURCE_DIR);
const outputDir = resolve(required("OUTPUT_DIR", process.env.OUTPUT_DIR));
const token = required("GITEA_RELEASE_TOKEN", process.env.GITEA_RELEASE_TOKEN);
const repository = parseRepository(sourceRepoUrl, process.env.REPOSITORY_API_URL);
const version = await readVersion(sourceDir);
validateArtifactNames(await readdir(outputDir), version);
const requestedTag = process.env.RELEASE_TAG?.trim();
const tag = requestedTag || `v${version}`;
if (tag !== `v${version}`) {
  throw new Error(`RELEASE_TAG must be v${version}; received ${tag}`);
}

const repoPath = `/repos/${encodePathSegment(repository.owner)}/${encodePathSegment(repository.repo)}`;
const releasePath = `${repoPath}/releases/tags/${encodePathSegment(tag)}`;
let existing;
try {
  existing = await giteaRequest({ apiBase: repository.apiBase, token, path: releasePath });
} catch (error) {
  if (error?.status !== 404) throw error;
}
let release;
if (existing) {
  if (!existing.draft) {
    throw new Error(`Gitea Release already exists for ${tag}; refusing to overwrite it`);
  }
  if (existing.target_commitish !== sourceRef) {
    throw new Error(`Existing draft Release ${tag} targets ${existing.target_commitish}, expected ${sourceRef}`);
  }
  release = existing;
  for (const asset of existing.assets ?? []) {
    await giteaRequest({
      apiBase: repository.apiBase,
      token,
      path: `${repoPath}/releases/${encodePathSegment(String(release.id))}/assets/${encodePathSegment(String(asset.id))}`,
      method: "DELETE",
    });
  }
} else {
  release = await giteaRequest({
    apiBase: repository.apiBase,
    token,
    path: `${repoPath}/releases`,
    method: "POST",
    contentType: "application/json",
    body: JSON.stringify({
      tag_name: tag,
      target_commitish: sourceRef,
      name: process.env.RELEASE_NAME?.trim() || `XCode ${version}`,
      body:
        process.env.RELEASE_BODY?.trim() ||
        `XCode ${version} macOS ARM release\n\nSource commit: ${sourceRef}`,
      draft: true,
      prerelease: false,
    }),
  });
}
if (!release?.id) throw new Error("Gitea did not return a release id");

const releaseAssetBaseUrl = process.env.GITEA_PUBLIC_BASE_URL?.trim() || repository.origin;
const downloadBase = `${releaseAssetBaseUrl.replace(/\/+$/u, "")}/${encodePathSegment(repository.owner)}/${encodePathSegment(repository.repo)}/releases/download/${encodePathSegment(tag)}`;
const generated = await generateElectronManifest({
  outputDir,
  version,
  releaseAssetBaseUrl: downloadBase,
});

for (const assetName of generated.assetNames) {
  const assetPath = join(outputDir, assetName);
  const uploadPath = `${repoPath}/releases/${encodePathSegment(String(release.id))}/assets?name=${encodeURIComponent(assetName)}`;
  // Gitea 的 Release 资产接口要求 multipart 的 attachment 字段；原始二进制请求会让上传停在服务端等待表单边界。
  const form = new FormData();
  form.append("attachment", await openAsBlob(assetPath, { type: "application/octet-stream" }), assetName);
  await giteaRequest({
    apiBase: repository.apiBase,
    token,
    path: uploadPath,
    method: "POST",
    body: form,
  });
  console.log(`Uploaded ${assetName}`);
}

const uploaded = await giteaRequest({
  apiBase: repository.apiBase,
  token,
  path: `${repoPath}/releases/${encodePathSegment(String(release.id))}`,
});
const uploadedNames = new Set((uploaded?.assets ?? []).map((asset) => asset.name));
const missing = generated.assetNames.filter((assetName) => !uploadedNames.has(assetName));
if (missing.length > 0) throw new Error(`Gitea Release is missing assets: ${missing.join(", ")}`);

await giteaRequest({
  apiBase: repository.apiBase,
  token,
  path: `${repoPath}/releases/${encodePathSegment(String(release.id))}`,
  method: "PATCH",
  contentType: "application/json",
  body: JSON.stringify({ draft: false }),
});
console.log(`Published Gitea Release ${tag}: ${downloadBase}`);
