import { createCipheriv, publicEncrypt, randomBytes, createHash, createHmac } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { readFile, appendFile, writeFile, stat } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { basename } from 'node:path';

async function digest(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

function presign(method, key) {
  const endpoint = new URL(process.env.R2_ENDPOINT);
  const now = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const day = now.slice(0, 8);
  const scope = `${day}/auto/s3/aws4_request`;
  const encode = (x) => encodeURIComponent(x).replace(/[!'()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  const path = '/' + [process.env.R2_BUCKET, ...key.split('/')].map(encode).join('/');
  const query = Object.entries({
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${process.env.R2_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': now,
    'X-Amz-Expires': '3600',
    'X-Amz-SignedHeaders': 'host',
  }).sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>`${encode(k)}=${encode(v)}`).join('&');
  const canonical = [method,path,query,`host:${endpoint.host}\n`,'host','UNSIGNED-PAYLOAD'].join('\n');
  const toSign = ['AWS4-HMAC-SHA256',now,scope,createHash('sha256').update(canonical).digest('hex')].join('\n');
  const hmac = (key, data) => createHmac('sha256',key).update(data).digest();
  let signingKey = hmac(`AWS4${process.env.R2_SECRET_ACCESS_KEY}`,day);
  for (const value of ['auto','s3','aws4_request']) signingKey = hmac(signingKey,value);
  return `${endpoint.origin}${path}?${query}&X-Amz-Signature=${hmac(signingKey,toSign).toString('hex')}`;
}

if (process.argv[2] === 'encrypt') {
  const original = process.env.PACKAGE_PATH;
  const encrypted = `${original}.bin`;
  const key = randomBytes(32), iv = randomBytes(12);
  const pem = Buffer.from(process.env.RECOVERY_PUBLIC_KEY,'base64').toString('utf8');
  const wrapped = publicEncrypt({key:pem,oaepHash:'sha256'},key);
  const header = JSON.stringify({version:1,key:wrapped.toString('base64'),iv:iv.toString('base64')})+'\n';
  await writeFile(encrypted,header,{mode:0o600});
  const cipher = createCipheriv('aes-256-gcm',key,iv);
  await pipeline(createReadStream(original),cipher,createWriteStream(encrypted,{flags:'a'}));
  await appendFile(encrypted,cipher.getAuthTag());
  const metadata = {sourceRef:process.env.BUILD_ID,plainSha256:await digest(original),encryptedSha256:await digest(encrypted),size:(await stat(encrypted)).size};
  await writeFile(`${process.env.RUNNER_TEMP}/xcode-recovery-metadata.json`,JSON.stringify(metadata));
  await writeFile(`${encrypted}.sha256`,`${metadata.encryptedSha256}  ${basename(encrypted)}\n`);
  await appendFile(process.env.GITHUB_ENV,`PACKAGE_PATH=${encrypted}\n`);
  console.log(`Encrypted recovery package prepared; bytes=${metadata.size}`);
} else if (process.argv[2] === 'pointer') {
  const metadata = JSON.parse(await readFile(`${process.env.RUNNER_TEMP}/xcode-recovery-metadata.json`,'utf8'));
  const key = `${process.env.R2_PREFIX}/${process.env.GITHUB_RUN_ID}/${basename(process.env.PACKAGE_PATH)}`;
  const pointer = {...metadata,getUrl:presign('GET',key),deleteUrl:presign('DELETE',key),deleteChecksumUrl:presign('DELETE',`${key}.sha256`)};
  // 签名 URL 只发送到既有私有仓库；GitHub 日志不输出 URL 或凭据。
  const repoBase = 'https://gitea.kudu-wall.ts.net/api/v1/repos/XCode/ZCode-CUA-Helper-Private';
  const headers = {Authorization:`token ${process.env.GITEA_RELEASE_TOKEN}`};
  const repoResponse = await fetch(repoBase,{headers});
  if(!repoResponse.ok || !(await repoResponse.json()).private) throw Error('Recovery pointer repository must be private');
  const releaseResponse = await fetch(`${repoBase}/releases/tags/v3.16.5`,{headers});
  if(!releaseResponse.ok) throw Error(`Private Helper release HTTP ${releaseResponse.status}`);
  const release = await releaseResponse.json();
  const base = `${repoBase}/releases/${release.id}/assets`;
  const name = `xcode-recovery-${process.env.GITHUB_RUN_ID}.json`;
  const form = new FormData();form.append('attachment',new Blob([JSON.stringify(pointer)]),name);
  const response = await fetch(`${base}?name=${name}`,{method:'POST',headers:{Authorization:`token ${process.env.GITEA_RELEASE_TOKEN}`},body:form,signal:AbortSignal.timeout(60000)});
  if(!response.ok)throw Error(`Private pointer upload HTTP ${response.status}`);
  const asset = await response.json();
  console.log(`Private encrypted recovery pointer ready; assetId=${asset.id}, runId=${process.env.GITHUB_RUN_ID}`);
} else throw Error('Expected encrypt or pointer');
