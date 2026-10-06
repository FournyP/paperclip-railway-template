import fs from "node:fs";

const owner = "paperclipai";
const repo = "paperclip";
const image = `ghcr.io/${owner}/${repo}`;
const token = process.env.GITHUB_TOKEN;

if (!token) {
  console.error("Missing GITHUB_TOKEN");
  process.exit(2);
}

async function gh(path) {
  const url = `https://api.github.com${path}`;
  const res = await fetch(url, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "user-agent": "paperclip-railway-template-bot",
    },
  });
  if (!res.ok) {
    throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  }
  return res.json();
}

// Resolve the multi-arch index digest for a tag of the official image.
async function imageDigest(tag) {
  const auth = await fetch(`https://ghcr.io/token?scope=repository:${owner}/${repo}:pull`);
  if (!auth.ok) throw new Error(`ghcr token ${auth.status}`);
  const { token: registryToken } = await auth.json();
  const res = await fetch(`https://ghcr.io/v2/${owner}/${repo}/manifests/${tag}`, {
    method: "HEAD",
    headers: {
      authorization: `Bearer ${registryToken}`,
      accept: "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
    },
  });
  const digest = res.headers.get("docker-content-digest");
  if (!res.ok || !digest) throw new Error(`No image ${image}:${tag} (HTTP ${res.status})`);
  return digest;
}

const fromRe = new RegExp(`^FROM ${image.replace(/[.]/g, "\\.")}:([^@\\s]+)@(sha256:[0-9a-f]+)$`, "m");

const latest = await gh(`/repos/${owner}/${repo}/releases/latest`);
const latestTag = latest.tag_name;
if (!latestTag) throw new Error("No tag_name in latest release response");
const latestVersion = latestTag.replace(/^v/, "");

const dockerPath = "Dockerfile";
const docker = fs.readFileSync(dockerPath, "utf8");
const m = docker.match(fromRe);
if (!m) throw new Error(`Could not find the FROM ${image} line`);
const currentVersion = m[1];

console.log(`current=${currentVersion} latest=${latestVersion}`);

if (currentVersion === latestVersion) {
  console.log("No update needed.");
  process.exit(0);
}

const digest = await imageDigest(latestVersion);
fs.writeFileSync(dockerPath, docker.replace(fromRe, `FROM ${image}:${latestVersion}@${digest}`));
console.log(`Updated ${dockerPath} to ${latestVersion} (${digest})`);
