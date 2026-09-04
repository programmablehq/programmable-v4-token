#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import path from "node:path";

import solc from "solc";

const EXPECTED_SOLC = "0.8.26+commit.8a97fa7a.Emscripten.clang";
const MAX_STANDARD_JSON_BYTES = 5_242_880;
const MAX_STANDARD_JSON_SOURCES = 2_048;
const OUTPUT_ROOT = "build/programmable-v4";
const STANDARD_JSON_PATH = `${OUTPUT_ROOT}/standard-json/programmable-v4.json`;
const MANIFEST_PATH = `${OUTPUT_ROOT}/evidence/build-manifest.json`;
const TARGETS = Object.freeze([
    {
        sourcePath: "src/ProgrammableLaunchInitializer.sol",
        contractName: "ProgrammableLaunchInitializer",
        artifactPath: `${OUTPUT_ROOT}/artifacts/programmable-launch-initializer.json`,
    },
    {
        sourcePath: "src/ProgrammableToken.sol",
        contractName: "ProgrammableToken",
        artifactPath: `${OUTPUT_ROOT}/artifacts/programmable-token.json`,
    },
    {
        sourcePath: "src/ProgrammableLaunchFeeHook.sol",
        contractName: "ProgrammableLaunchFeeHook",
        artifactPath: `${OUTPUT_ROOT}/artifacts/programmable-launch-fee-hook.json`,
    },
]);

if (process.argv.includes("--help")) {
    process.stdout.write(
        "Build deterministic, credential-free Solidity Standard JSON and compiler artifacts.\n" +
            "This command does not create a Programmable config or launch.json.\n",
    );
    process.exit(0);
}
if (process.argv.length !== 2) throw new TypeError("build-pack-artifacts accepts only --help");
if (Object.hasOwn(process.env, "PROGRAMMABLE_API_KEY")) {
    throw new TypeError("credential-free artifact build refuses PROGRAMMABLE_API_KEY");
}

const repositoryRoot = await realpath(process.cwd());
const compilerVersion = solc.version();
if (compilerVersion !== EXPECTED_SOLC) {
    throw new TypeError(`expected exact solc ${EXPECTED_SOLC}, received ${compilerVersion}`);
}

const remappings = await loadRemappings();
const sourceMap = new Map();
for (const { sourcePath } of TARGETS) await loadSourceClosure(sourcePath);
if (sourceMap.size > MAX_STANDARD_JSON_SOURCES) {
    throw new TypeError(`source count ${sourceMap.size} exceeds ${MAX_STANDARD_JSON_SOURCES}`);
}

const sources = Object.fromEntries(
    [...sourceMap.entries()]
        .sort(([left], [right]) => compareUtf8(left, right))
        .map(([sourcePath, content]) => [sourcePath, { content }]),
);
const standardJson = {
    language: "Solidity",
    sources,
    settings: {
        optimizer: { enabled: true, runs: 200 },
        evmVersion: "cancun",
        viaIR: false,
        metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
        libraries: {},
        remappings: remappings.map(({ encoded }) => encoded),
        outputSelection: {
            "*": {
                "*": [
                    "abi",
                    "metadata",
                    "evm.bytecode.object",
                    "evm.bytecode.linkReferences",
                    "evm.deployedBytecode.object",
                    "evm.deployedBytecode.linkReferences",
                    "evm.deployedBytecode.immutableReferences",
                ],
            },
        },
    },
};
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
if (standardJsonBytes.byteLength > MAX_STANDARD_JSON_BYTES) {
    throw new TypeError(
        `Standard JSON is ${standardJsonBytes.byteLength} bytes; limit is ${MAX_STANDARD_JSON_BYTES}`,
    );
}

const compilerOutput = JSON.parse(solc.compile(JSON.stringify(standardJson)));
const errors = (compilerOutput.errors ?? []).filter(({ severity }) => severity === "error");
if (errors.length !== 0) {
    throw new TypeError(errors.map(({ formattedMessage }) => formattedMessage).join("\n"));
}

await mkdir(path.join(repositoryRoot, OUTPUT_ROOT, "standard-json"), { recursive: true });
await mkdir(path.join(repositoryRoot, OUTPUT_ROOT, "artifacts"), { recursive: true });
await mkdir(path.join(repositoryRoot, OUTPUT_ROOT, "evidence"), { recursive: true });
await writeFile(path.join(repositoryRoot, STANDARD_JSON_PATH), standardJsonBytes);

const artifactEvidence = [];
for (const target of TARGETS) {
    const compiled = compilerOutput.contracts?.[target.sourcePath]?.[target.contractName];
    assertCompleteCompilerArtifact(compiled, target);
    const metadata = JSON.parse(compiled.metadata);
    const expectedCompilationTarget = { [target.sourcePath]: target.contractName };
    if (JSON.stringify(metadata.settings?.compilationTarget) !== JSON.stringify(expectedCompilationTarget)) {
        throw new TypeError(`${target.contractName} compiler metadata has the wrong compilation target`);
    }
    const artifact = {
        abi: compiled.abi,
        bytecode: compiled.evm.bytecode,
        deployedBytecode: compiled.evm.deployedBytecode,
        metadata: compiled.metadata,
    };
    const artifactBytes = Buffer.from(`${JSON.stringify(artifact)}\n`, "utf8");
    await writeFile(path.join(repositoryRoot, target.artifactPath), artifactBytes);
    artifactEvidence.push({
        sourcePath: target.sourcePath,
        contractName: target.contractName,
        artifactPath: target.artifactPath,
        artifactSha256: sha256(artifactBytes),
        creationBytecodeSha256: sha256(Buffer.from(compiled.evm.bytecode.object, "hex")),
        runtimeBytecodeSha256: sha256(Buffer.from(compiled.evm.deployedBytecode.object, "hex")),
        runtimeImmutableReferences: compiled.evm.deployedBytecode.immutableReferences,
    });
}

const sourceEvidence = Object.entries(sources).map(([sourcePath, { content }]) => ({
    sourcePath,
    contentSha256: sha256(Buffer.from(content, "utf8")),
}));
const manifest = {
    schemaVersion: "programmable-v4-pack-artifact-build.v1",
    status: "NON_CANONICAL_PREPARATION_ONLY",
    compiler: {
        package: "solc",
        version: compilerVersion,
    },
    settings: standardJson.settings,
    standardJson: {
        path: STANDARD_JSON_PATH,
        byteLength: standardJsonBytes.byteLength,
        sha256: sha256(standardJsonBytes),
        sourceCount: sourceEvidence.length,
    },
    sources: sourceEvidence,
    targets: artifactEvidence,
    boundaries: {
        officialV4CliReleaseRequired: true,
        programmableConfigCreated: false,
        launchJsonCreated: false,
        apiKeyRead: false,
        networkAccess: false,
        signing: false,
        broadcast: false,
    },
};
await writeFile(
    path.join(repositoryRoot, MANIFEST_PATH),
    `${JSON.stringify(manifest, null, 2)}\n`,
    "utf8",
);

process.stdout.write(
    `Wrote ${STANDARD_JSON_PATH}, ${TARGETS.length} artifacts and ${MANIFEST_PATH}; ` +
        "no config, launch.json, network request, signing or broadcast performed.\n",
);

async function loadRemappings() {
    const source = await readFile(path.join(repositoryRoot, "remappings.txt"), "utf8");
    const parsed = source
        .split(/\r?\n/u)
        .filter((line) => line.length !== 0)
        .map((line) => {
            const separator = line.indexOf("=");
            if (separator <= 0 || separator === line.length - 1) {
                throw new TypeError(`invalid remapping: ${line}`);
            }
            const from = line.slice(0, separator);
            const to = line.slice(separator + 1);
            for (const value of [from, to]) assertCanonicalRelativeFragment(value, "remapping");
            return { from, to, encoded: `${from}=${to}` };
        })
        .sort((left, right) => compareUtf8(left.encoded, right.encoded));
    if (new Set(parsed.map(({ from }) => from)).size !== parsed.length) {
        throw new TypeError("remapping prefixes must be unique");
    }
    return parsed;
}

async function loadSourceClosure(sourcePath) {
    const canonicalPath = canonicalRelativePath(sourcePath);
    if (sourceMap.has(canonicalPath)) return;
    const absolutePath = path.join(repositoryRoot, ...canonicalPath.split("/"));
    const resolvedPath = await realpath(absolutePath);
    if (resolvedPath !== repositoryRoot && !resolvedPath.startsWith(`${repositoryRoot}${path.sep}`)) {
        throw new TypeError(`source escapes repository root: ${canonicalPath}`);
    }
    const content = await readFile(resolvedPath, "utf8");
    sourceMap.set(canonicalPath, content);
    const imports = parseImports(content).sort(compareUtf8);
    for (const imported of imports) {
        await loadSourceClosure(resolveImport(canonicalPath, imported));
    }
}

function parseImports(source) {
    const imports = [];
    const pattern = /\bimport\s+(?:(?:[^"']*?)\s+from\s+)?["']([^"']+)["']\s*;/gsu;
    for (const match of source.matchAll(pattern)) imports.push(match[1]);
    return [...new Set(imports)];
}

function resolveImport(importer, imported) {
    if (imported.startsWith(".")) {
        return canonicalRelativePath(path.posix.normalize(path.posix.join(path.posix.dirname(importer), imported)));
    }
    const matches = remappings
        .filter(({ from }) => imported.startsWith(from))
        .sort((left, right) => right.from.length - left.from.length || compareUtf8(left.encoded, right.encoded));
    if (matches.length === 0) return canonicalRelativePath(imported);
    const selected = matches[0];
    return canonicalRelativePath(`${selected.to}${imported.slice(selected.from.length)}`);
}

function canonicalRelativePath(value) {
    assertCanonicalRelativeFragment(value, "source path");
    const normalized = path.posix.normalize(value);
    if (normalized !== value) throw new TypeError(`source path is not canonical: ${value}`);
    return normalized;
}

function assertCanonicalRelativeFragment(value, label) {
    if (
        typeof value !== "string" ||
        value.length === 0 ||
        path.isAbsolute(value) ||
        value.includes("\\") ||
        value.includes("\0") ||
        value.split("/").some((segment) => segment === "." || segment === "..")
    ) {
        throw new TypeError(`${label} must remain inside the repository: ${value}`);
    }
}

function assertCompleteCompilerArtifact(compiled, { sourcePath, contractName }) {
    if (
        !Array.isArray(compiled?.abi) ||
        typeof compiled?.metadata !== "string" ||
        typeof compiled?.evm?.bytecode?.object !== "string" ||
        compiled.evm.bytecode.object.length === 0 ||
        typeof compiled?.evm?.deployedBytecode?.object !== "string" ||
        compiled.evm.deployedBytecode.object.length === 0 ||
        typeof compiled.evm.bytecode.linkReferences !== "object" ||
        typeof compiled.evm.deployedBytecode.linkReferences !== "object" ||
        typeof compiled.evm.deployedBytecode.immutableReferences !== "object"
    ) {
        throw new TypeError(`incomplete compiler output for ${sourcePath}:${contractName}`);
    }
}

function compareUtf8(left, right) {
    return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
}

function sha256(bytes) {
    return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}
