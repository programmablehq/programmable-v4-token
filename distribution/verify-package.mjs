import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(scriptDir, "../../..");
const castBin = process.env.CAST_BIN || "cast";
const uint256Max = (1n << 256n) - 1n;
const canonicalWorkbookRelative =
  "outputs/01a06520-7460-7db2-b9b4-5407a9c65e7d/ROBINHOOD_V4_FULL_SUPPLY_PLAN_DRAFT_1B_LP5_OVR-001_OVR-002_REST-001_2026-09-04.xlsx";
const canonicalSnapshotRelative =
  "outputs/01a06520-7460-7db2-b9b4-5407a9c65e7d/V4_FINAL_ALLOCATIONS_2026-09-03T065500Z.json";
const canonicalWorkbookSha256 =
  "80db21b1271292d79fea95e8e8f833e88ad96d60420ae33e7762bef243f05257";
const canonicalSnapshotSha256 =
  "ef4ce7002aab6e53eb18b1d4f9abf545fdae33c333f1569b83212ead60ea3cc6";
const canonicalOrderedAllocationSha256 =
  "3ba2c483ccbdce333c106e4ecb7b68785f566bfec79d7d5e19c07dd9085d1f43";
const canonicalMigrationRaw = 755738416021526951788414688n;

const ovr001 = {
  sources: [
    "0x77B6E288B1e578EBBcd5708d48E4Fb929bC6A44D",
    "0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62",
  ],
  targets: [["0x20C80D578d2c387f8f32D04FDEA137F4144F27aA", "12453871913232192230249089"]],
};
const ovr002 = {
  sources: [
    "0x3865757B9086ccF3c6187DCc83604c2585a88eAc",
    "0xde6D50C7De0262Cf4b6b2B78297D68115e1a20CC",
    "0xb410720Fd7be07bBf7EFc3ff83B253890672d71c",
    "0x7d6F8189eB73DAF5d33019bf36181d1067E1BfC6",
    "0x5A8D7D5bdFEb77AeF3eFD472807d0be93B01F5fB",
    "0xA29b926c08E66a7f6df38f64E47ABa39b2132fb4",
    "0xFaf2dA5BC45E1258F0230cB35C29BB6827B24Fc3",
  ],
  targets: [
    ["0x12aF4F24c30Ae4FfF17F997b913A443a45eb5ae6", "13132139315038611763619987"],
    ["0x2da036704793d2B95d2752bAc23258A91479a1b3", "13132139315038611763619986"],
    ["0x6aE8afF5af0E07d2B32610BAaEd7536FAf1AAF76", "13132139315038611763619986"],
    ["0x73547bB64c791827d5d09B9864345De5E6e316FB", "13132139315038611763619986"],
    ["0x82A23D4f280d7fCf883A17082A6156D2CaEBb889", "13132139315038611763619986"],
    ["0xb0d8bF106d303F87073A161B6b2a0F92F3a380Ca", "13132139315038611763619986"],
  ],
};

const expectedManifestArtifactNames = [
  "README.md",
  "build-migration-package.mjs",
  "migration-allocations.csv",
  "migration-allocations.json",
  "migration-allocations.schema.json",
  "verify-package.mjs",
].sort(asciiCompare);
const expectedChecksumNames = [...expectedManifestArtifactNames, "migration-manifest.json"].sort(asciiCompare);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function sha256File(filePath) {
  return sha256(await fs.readFile(filePath));
}

function decimalFromRaw(raw, decimals = 18) {
  const base = 10n ** BigInt(decimals);
  return `${raw / base}.${(raw % base).toString().padStart(decimals, "0")}`;
}

function asciiCompare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function checksum(address) {
  return execFileSync(
    castBin,
    ["to-check-sum-address", address.toLowerCase()],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();
}

const allocations = JSON.parse(
  await fs.readFile(path.join(scriptDir, "migration-allocations.json"), "utf8"),
);
const manifest = JSON.parse(
  await fs.readFile(path.join(scriptDir, "migration-manifest.json"), "utf8"),
);

assert(
  manifest.source.fullSupplyWorkbook.workspaceRelativePath === canonicalWorkbookRelative,
  "Unexpected source workbook path",
);
assert(
  manifest.source.finalizedSnapshotAllocations.workspaceRelativePath === canonicalSnapshotRelative,
  "Unexpected source snapshot path",
);
assert(
  manifest.source.fullSupplyWorkbook.sha256 === canonicalWorkbookSha256,
  "Unexpected source workbook trust root",
);
assert(
  manifest.source.finalizedSnapshotAllocations.sha256 === canonicalSnapshotSha256,
  "Unexpected source snapshot trust root",
);

const canonicalWorkbookPath = path.join(workspaceRoot, canonicalWorkbookRelative);
const canonicalSnapshotPath = path.join(workspaceRoot, canonicalSnapshotRelative);
assert(
  (await sha256File(canonicalWorkbookPath)) === canonicalWorkbookSha256,
  "Canonical source workbook hash mismatch",
);
assert(
  (await sha256File(canonicalSnapshotPath)) === canonicalSnapshotSha256,
  "Canonical source snapshot hash mismatch",
);

const canonicalSnapshot = JSON.parse(await fs.readFile(canonicalSnapshotPath, "utf8"));
assert(canonicalSnapshot.schema === "v4-migration-final-allocations/v1", "Wrong canonical snapshot schema");
assert(canonicalSnapshot.allocationCount === 312, "Wrong canonical snapshot recipient count");
assert(canonicalSnapshot.allocations.length === 312, "Wrong canonical snapshot allocation length");
assert(canonicalSnapshot.totalAllocationRaw === canonicalMigrationRaw.toString(), "Wrong canonical snapshot total");

const canonicalByTarget = new Map();
for (const [index, row] of canonicalSnapshot.allocations.entries()) {
  const target = String(row.beneficiary).toLowerCase();
  assert(/^0x[0-9a-f]{40}$/.test(target), `Invalid canonical beneficiary at row ${index}`);
  assert(!canonicalByTarget.has(target), `Duplicate canonical beneficiary at row ${index}`);
  const rawText = String(row.targetRawIf18Decimals);
  assert(/^[1-9][0-9]*$/.test(rawText), `Invalid canonical amount at row ${index}`);
  assert(rawText === String(row.amountRaw), `Canonical 18-decimal amount mismatch at row ${index}`);
  canonicalByTarget.set(target, rawText);
}

function applyOverride({ sources, targets }, label) {
  let removedRaw = 0n;
  for (const source of sources) {
    const lowered = source.toLowerCase();
    const rawText = canonicalByTarget.get(lowered);
    assert(rawText !== undefined, `${label} source is absent: ${source}`);
    removedRaw += BigInt(rawText);
    canonicalByTarget.delete(lowered);
  }

  let addedRaw = 0n;
  for (const [target, rawText] of targets) {
    const lowered = target.toLowerCase();
    assert(!canonicalByTarget.has(lowered), `${label} target already exists: ${target}`);
    assert(/^[1-9][0-9]*$/.test(rawText), `${label} target amount is invalid: ${target}`);
    canonicalByTarget.set(lowered, rawText);
    addedRaw += BigInt(rawText);
  }
  assert(removedRaw === addedRaw, `${label} does not preserve its exact source total`);
}

applyOverride(ovr001, "OVR-001");
applyOverride(ovr002, "OVR-002");
assert(canonicalByTarget.size === 310, "Canonical override result does not contain 310 recipients");

assert(allocations.schema === "programmable-v4-migration-allocations/v1", "Wrong allocation schema");
assert(allocations.targetChainId === 4663, "Wrong target chain ID");
assert(allocations.targetTokenDecimals === 18, "Wrong target decimals");
assert(allocations.ordering === "targetLowercaseAsciiAscending", "Wrong ordering rule");
assert(allocations.recipientCount === 310, "Wrong recipientCount");
assert(allocations.recipients.length === 310, "Wrong recipient array length");

let totalRaw = 0n;
let previous = null;
const seen = new Set();
for (const [index, recipient] of allocations.recipients.entries()) {
  assert(recipient.index === index, `Wrong index at row ${index}`);
  assert(/^0x[0-9a-fA-F]{40}$/.test(recipient.target), `Invalid target at row ${index}`);
  assert(checksum(recipient.target) === recipient.target, `Non-checksummed target at row ${index}`);
  const lowered = recipient.target.toLowerCase();
  assert(lowered !== "0x0000000000000000000000000000000000000000", `Zero target at row ${index}`);
  assert(!seen.has(lowered), `Duplicate target at row ${index}`);
  seen.add(lowered);
  if (previous !== null) assert(asciiCompare(previous, lowered) < 0, `Unsorted target at row ${index}`);
  previous = lowered;
  assert(/^[1-9][0-9]*$/.test(recipient.amountRaw), `Invalid amountRaw at row ${index}`);
  const raw = BigInt(recipient.amountRaw);
  assert(raw > 0n && raw <= uint256Max, `Out-of-range amountRaw at row ${index}`);
  assert(decimalFromRaw(raw) === recipient.amountDecimal, `Decimal mismatch at row ${index}`);
  totalRaw += raw;
}

assert(totalRaw.toString() === allocations.totalRaw, "Allocation totalRaw mismatch");
assert(decimalFromRaw(totalRaw) === allocations.totalDecimal, "Allocation totalDecimal mismatch");
assert(totalRaw === canonicalMigrationRaw, "Unexpected canonical migration total");

const expectedRecipients = [...canonicalByTarget.entries()].sort(([left], [right]) => asciiCompare(left, right));
for (const [index, [expectedTarget, expectedRaw]] of expectedRecipients.entries()) {
  const actual = allocations.recipients[index];
  assert(actual.target.toLowerCase() === expectedTarget, `Canonical target mismatch at row ${index}`);
  assert(actual.amountRaw === expectedRaw, `Canonical amount mismatch at row ${index}`);
}

const orderedRecords = allocations.recipients
  .map((recipient) => `${recipient.target.toLowerCase()},${recipient.amountRaw}\n`)
  .join("");
const digestBytes = Buffer.from(
  manifest.orderedAllocationDigest.domainSeparator + orderedRecords,
  "utf8",
);
const orderedAllocationSha256 = sha256(digestBytes);
assert(
  orderedAllocationSha256 === allocations.orderedAllocationSha256,
  "Allocation digest mismatch in allocation file",
);
assert(
  orderedAllocationSha256 === manifest.orderedAllocationDigest.value,
  "Allocation digest mismatch in manifest",
);
assert(
  orderedAllocationSha256 === canonicalOrderedAllocationSha256,
  "Allocation digest does not match the frozen canonical allocation root",
);

const csvLines = (
  await fs.readFile(path.join(scriptDir, "migration-allocations.csv"), "utf8")
).trimEnd().split("\n");
assert(csvLines[0] === "index,target,amountRaw,amountDecimal", "Wrong CSV header");
assert(csvLines.length === 311, "Wrong CSV row count");
for (let index = 0; index < allocations.recipients.length; index += 1) {
  const expected = allocations.recipients[index];
  const actual = csvLines[index + 1].split(",");
  assert(actual.length === 4, `Wrong CSV column count at row ${index + 2}`);
  assert(
    actual.join(",") ===
      [expected.index, expected.target, expected.amountRaw, expected.amountDecimal].join(","),
    `CSV/JSON mismatch at recipient index ${index}`,
  );
}

assert(manifest.reconciliation.migrationRecipientCount === 310, "Manifest recipient count mismatch");
assert(manifest.reconciliation.uniqueMigrationRecipientCount === 310, "Manifest unique count mismatch");
assert(manifest.reconciliation.migrationTotalRaw === totalRaw.toString(), "Manifest total mismatch");
assert(manifest.reconciliation.excluded.initialLp.rowCount === 1, "LP row must be excluded");
assert(manifest.reconciliation.excluded.initialLp.totalRaw === "50000000000000000000000000", "LP total mismatch");
assert(manifest.reconciliation.excluded.treasuryRemainder.rowCount === 2, "Treasury rows must be excluded");
assert(
  manifest.reconciliation.excluded.treasuryRemainder.totalRaw ===
    "194261583978473048211585312",
  "Treasury total mismatch",
);
assert(manifest.reconciliation.fullSupplyTotalRaw === "1000000000000000000000000000", "Full supply mismatch");
assert(manifest.reconciliation.status === "PASS", "Manifest reconciliation is not PASS");
assert(manifest.merkle.generated === false, "Unexpected Merkle generation");
assert(manifest.merkle.root === null, "Unexpected Merkle root");
assert(manifest.merkle.leafEncoding === null, "Unexpected Merkle leaf encoding");

assert(
  JSON.stringify(Object.keys(manifest.artifacts).sort(asciiCompare)) === JSON.stringify(expectedManifestArtifactNames),
  "Unexpected manifest artifact set",
);
for (const [name, record] of Object.entries(manifest.artifacts)) {
  assert(
    (await sha256File(path.join(scriptDir, name))) === record.sha256,
    `Manifest artifact hash mismatch: ${name}`,
  );
}

const checksumLines = (
  await fs.readFile(path.join(scriptDir, "SHA256SUMS.txt"), "utf8")
).trimEnd().split("\n");
assert(checksumLines.length === expectedChecksumNames.length, "Wrong SHA256SUMS entry count");
const checksumNames = [];
for (const line of checksumLines) {
  const match = /^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
  assert(match, `Invalid checksum line: ${line}`);
  checksumNames.push(match[2]);
  assert(
    (await sha256File(path.join(scriptDir, match[2]))) === match[1],
    `SHA256SUMS mismatch: ${match[2]}`,
  );
}
assert(
  JSON.stringify(checksumNames.sort(asciiCompare)) === JSON.stringify(expectedChecksumNames),
  "Unexpected SHA256SUMS artifact set",
);

console.log(
  JSON.stringify(
    {
      status: "PASS",
      recipientCount: allocations.recipientCount,
      uniqueRecipientCount: seen.size,
      totalRaw: totalRaw.toString(),
      totalDecimal: decimalFromRaw(totalRaw),
      orderedAllocationSha256,
      checkedPackageFiles: checksumLines.length,
      first: allocations.recipients[0],
      last: allocations.recipients.at(-1),
    },
    null,
    2,
  ),
);
