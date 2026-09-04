import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(scriptDir, "../../..");
const outputDir = scriptDir;

const sourceWorkbookRelative =
  "outputs/01a06520-7460-7db2-b9b4-5407a9c65e7d/ROBINHOOD_V4_FULL_SUPPLY_PLAN_DRAFT_1B_LP5_OVR-001_OVR-002_REST-001_2026-09-04.xlsx";
const sourceSnapshotRelative =
  "outputs/01a06520-7460-7db2-b9b4-5407a9c65e7d/V4_FINAL_ALLOCATIONS_2026-09-03T065500Z.json";
const sourceWorkbookPath = path.join(workspaceRoot, sourceWorkbookRelative);
const sourceSnapshotPath = path.join(workspaceRoot, sourceSnapshotRelative);

const expectedSourceWorkbookSha256 =
  "80db21b1271292d79fea95e8e8f833e88ad96d60420ae33e7762bef243f05257";
const expectedSourceSnapshotSha256 =
  "ef4ce7002aab6e53eb18b1d4f9abf545fdae33c333f1569b83212ead60ea3cc6";
const expectedMigrationRaw = 755738416021526951788414688n;
const expectedFullSupplyRaw = 1000000000000000000000000000n;
const expectedLpRaw = 50000000000000000000000000n;
const expectedTreasuryRaw = 194261583978473048211585312n;
const decimals = 18;
const uint256Max = (1n << 256n) - 1n;
const zeroAddress = "0x0000000000000000000000000000000000000000";
const castBin = process.env.CAST_BIN || "cast";
const digestDomain =
  "programmable-v4-migration-allocation/v1|chainId=4663|decimals=18\n";

const allocationJsonName = "migration-allocations.json";
const allocationCsvName = "migration-allocations.csv";
const manifestName = "migration-manifest.json";
const schemaName = "migration-allocations.schema.json";
const readmeName = "README.md";
const builderName = "build-migration-package.mjs";
const verifierName = "verify-package.mjs";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function sha256File(filePath) {
  return sha256(await fs.readFile(filePath));
}

function decimalFromRaw(raw) {
  const base = 10n ** BigInt(decimals);
  return `${raw / base}.${(raw % base).toString().padStart(decimals, "0")}`;
}

function toChecksumAddress(address) {
  assert(/^0x[0-9a-fA-F]{40}$/.test(address), `Invalid EVM address: ${address}`);
  const normalized = address.toLowerCase();
  const checksummed = execFileSync(
    castBin,
    ["to-check-sum-address", normalized],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();
  assert(
    /^0x[0-9a-fA-F]{40}$/.test(checksummed) &&
      checksummed.toLowerCase() === normalized,
    `Checksum conversion failed: ${address}`,
  );
  return checksummed;
}

function asciiCompare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function sumBy(items, valueFn) {
  return items.reduce((total, item) => total + valueFn(item), 0n);
}

function jsonText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

const sourceWorkbookSha256 = await sha256File(sourceWorkbookPath);
const sourceSnapshotSha256 = await sha256File(sourceSnapshotPath);
assert(
  sourceWorkbookSha256 === expectedSourceWorkbookSha256,
  `Source workbook hash drift: ${sourceWorkbookSha256}`,
);
assert(
  sourceSnapshotSha256 === expectedSourceSnapshotSha256,
  `Source snapshot hash drift: ${sourceSnapshotSha256}`,
);

const sourceSnapshot = JSON.parse(await fs.readFile(sourceSnapshotPath, "utf8"));
assert(sourceSnapshot.schema === "v4-migration-final-allocations/v1", "Unexpected canonical snapshot schema");
assert(sourceSnapshot.allocationCount === 312, "Unexpected canonical snapshot count");
assert(sourceSnapshot.allocations.length === 312, "Unexpected canonical snapshot allocation length");
assert(
  sourceSnapshot.totalAllocationRaw === expectedMigrationRaw.toString(),
  "Canonical snapshot total does not match the migration total",
);

const ovr001Target = "0x20C80D578d2c387f8f32D04FDEA137F4144F27aA";
const ovr001Sources = [
  "0x77B6E288B1e578EBBcd5708d48E4Fb929bC6A44D",
  "0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62",
];
const ovr001Raw = "12453871913232192230249089";
const ovr002Sources = [
  "0x3865757B9086ccF3c6187DCc83604c2585a88eAc",
  "0xde6D50C7De0262Cf4b6b2B78297D68115e1a20CC",
  "0xb410720Fd7be07bBf7EFc3ff83B253890672d71c",
  "0x7d6F8189eB73DAF5d33019bf36181d1067E1BfC6",
  "0x5A8D7D5bdFEb77AeF3eFD472807d0be93B01F5fB",
  "0xA29b926c08E66a7f6df38f64E47ABa39b2132fb4",
  "0xFaf2dA5BC45E1258F0230cB35C29BB6827B24Fc3",
];
const ovr002Targets = [
  ["0x12aF4F24c30Ae4FfF17F997b913A443a45eb5ae6", "13132139315038611763619987"],
  ["0x2da036704793d2B95d2752bAc23258A91479a1b3", "13132139315038611763619986"],
  ["0x6aE8afF5af0E07d2B32610BAaEd7536FAf1AAF76", "13132139315038611763619986"],
  ["0x73547bB64c791827d5d09B9864345De5E6e316FB", "13132139315038611763619986"],
  ["0x82A23D4f280d7fCf883A17082A6156D2CaEBb889", "13132139315038611763619986"],
  ["0xb0d8bF106d303F87073A161B6b2a0F92F3a380Ca", "13132139315038611763619986"],
];

const recipientByTarget = new Map();
for (const [index, row] of sourceSnapshot.allocations.entries()) {
  assert(typeof row.beneficiary === "string", `Missing beneficiary at canonical snapshot row ${index}`);
  const target = toChecksumAddress(row.beneficiary);
  const lowered = target.toLowerCase();
  assert(lowered !== zeroAddress, `Zero beneficiary at canonical snapshot row ${index}`);
  assert(!recipientByTarget.has(lowered), `Duplicate beneficiary at canonical snapshot row ${index}`);

  const rawText = String(row.targetRawIf18Decimals);
  assert(/^[1-9][0-9]*$/.test(rawText), `Invalid raw amount at canonical snapshot row ${index}`);
  const raw = BigInt(rawText);
  assert(raw > 0n && raw <= uint256Max, `Out-of-range amount at canonical snapshot row ${index}`);
  assert(rawText === String(row.amountRaw), `18-decimal raw mismatch at canonical snapshot row ${index}`);
  const amountDecimal = decimalFromRaw(raw);
  assert(amountDecimal === String(row.amountV4Exact), `Decimal mismatch at canonical snapshot row ${index}`);

  recipientByTarget.set(lowered, { target, amountRaw: rawText, amountDecimal });
}
assert(
  sumBy([...recipientByTarget.values()], (recipient) => BigInt(recipient.amountRaw)) === expectedMigrationRaw,
  "Canonical snapshot rows do not sum to the migration total",
);

function applyOverride(sources, targets, label) {
  let removedRaw = 0n;
  for (const source of sources) {
    const lowered = source.toLowerCase();
    const recipient = recipientByTarget.get(lowered);
    assert(recipient, `${label} source is absent: ${source}`);
    removedRaw += BigInt(recipient.amountRaw);
    recipientByTarget.delete(lowered);
  }

  let addedRaw = 0n;
  for (const [targetInput, amountRaw] of targets) {
    const target = toChecksumAddress(targetInput);
    const lowered = target.toLowerCase();
    assert(!recipientByTarget.has(lowered), `${label} target already exists: ${target}`);
    assert(/^[1-9][0-9]*$/.test(amountRaw), `${label} target amount is invalid: ${target}`);
    const raw = BigInt(amountRaw);
    recipientByTarget.set(lowered, { target, amountRaw, amountDecimal: decimalFromRaw(raw) });
    addedRaw += raw;
  }
  assert(removedRaw === addedRaw, `${label} does not preserve its exact source total`);
}

applyOverride(ovr001Sources, [[ovr001Target, ovr001Raw]], "OVR-001");
applyOverride(ovr002Sources, ovr002Targets, "OVR-002");

const recipients = [...recipientByTarget.values()].sort((left, right) =>
  asciiCompare(left.target.toLowerCase(), right.target.toLowerCase()),
);
const loweredTargets = recipients.map((recipient) => recipient.target.toLowerCase());
assert(recipients.length === 310, "Final migration recipient count is not 310");
assert(new Set(loweredTargets).size === 310, "Duplicate migration target");
for (let index = 1; index < loweredTargets.length; index += 1) {
  assert(loweredTargets[index - 1] < loweredTargets[index], `Non-deterministic ordering at index ${index}`);
}

const outputRecipients = recipients.map((recipient, index) => ({ index, ...recipient }));
const outputTotalRaw = sumBy(outputRecipients, (recipient) => BigInt(recipient.amountRaw));
assert(outputTotalRaw === expectedMigrationRaw, "Output migration total mismatch");

const byTarget = new Map(
  outputRecipients.map((recipient) => [recipient.target.toLowerCase(), recipient]),
);

assert(byTarget.get(ovr001Target.toLowerCase())?.amountRaw === ovr001Raw, "OVR-001 target mismatch");
for (const source of [...ovr001Sources, ...ovr002Sources]) {
  assert(!byTarget.has(source.toLowerCase()), `Removed override source remains: ${source}`);
}
for (const [target, amountRaw] of ovr002Targets) {
  assert(byTarget.get(target.toLowerCase())?.amountRaw === amountRaw, `OVR-002 target mismatch: ${target}`);
}

const treasuryTargets = [
  "0x3646c0e2A0238834F2b1FdbEa082a2Da5813a487",
  "0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62",
];
for (const target of treasuryTargets) {
  assert(!byTarget.has(target.toLowerCase()), `Treasury target leaked into migration set: ${target}`);
}

const orderedRecords = outputRecipients
  .map((recipient) => `${recipient.target.toLowerCase()},${recipient.amountRaw}\n`)
  .join("");
const orderedAllocationSha256 = sha256(Buffer.from(digestDomain + orderedRecords, "utf8"));

const allocations = {
  schema: "programmable-v4-migration-allocations/v1",
  targetChainId: 4663,
  targetTokenDecimals: decimals,
  ordering: "targetLowercaseAsciiAscending",
  recipientCount: outputRecipients.length,
  totalRaw: outputTotalRaw.toString(),
  totalDecimal: decimalFromRaw(outputTotalRaw),
  orderedAllocationSha256,
  recipients: outputRecipients,
};

const allocationJsonText = jsonText(allocations);
const allocationCsvText = [
  "index,target,amountRaw,amountDecimal",
  ...outputRecipients.map((recipient) =>
    [recipient.index, recipient.target, recipient.amountRaw, recipient.amountDecimal].join(","),
  ),
].join("\n") + "\n";

await fs.writeFile(path.join(outputDir, allocationJsonName), allocationJsonText, "utf8");
await fs.writeFile(path.join(outputDir, allocationCsvName), allocationCsvText, "utf8");

const artifactNamesBeforeManifest = [
  allocationJsonName,
  allocationCsvName,
  schemaName,
  readmeName,
  builderName,
  verifierName,
];
const artifactHashes = Object.fromEntries(
  await Promise.all(
    artifactNamesBeforeManifest.map(async (name) => [
      name,
      await sha256File(path.join(outputDir, name)),
    ]),
  ),
);

const manifest = {
  schema: "programmable-v4-migration-manifest/v1",
  packageScope: "MIGRATION recipients only",
  source: {
    fullSupplyWorkbook: {
      workspaceRelativePath: sourceWorkbookRelative,
      sha256: sourceWorkbookSha256,
      sheet: "Full Supply Distribution",
      range: "A2:Q314",
      selectedBucket: "MIGRATION",
    },
    finalizedSnapshotAllocations: {
      workspaceRelativePath: sourceSnapshotRelative,
      sha256: sourceSnapshotSha256,
      originalRecipientCount: sourceSnapshot.allocationCount,
      originalTotalRaw: sourceSnapshot.totalAllocationRaw,
    },
    cutoff: sourceSnapshot.cutoff,
  },
  target: {
    chainName: "Robinhood Chain Mainnet",
    chainId: 4663,
    tokenName: "Programmable",
    tokenSymbol: "V4",
    tokenDecimals: decimals,
    tokenAddress: null,
    tokenAddressStatus: "not deployed or source-verified in the bound workbook",
  },
  ordering: {
    rule: "targetLowercaseAsciiAscending",
    indexBase: 0,
    uniquenessKey: "lowercase EVM target address",
  },
  amountEncoding: {
    amountRaw: "unsigned base-10 uint256 string in 18-decimal token units",
    amountDecimal: "fixed 18-decimal base-10 display string",
  },
  orderedAllocationDigest: {
    algorithm: "SHA-256",
    encoding: "UTF-8",
    domainSeparator: digestDomain,
    recordFormat: "<lowercase_evm_address>,<base10_uint256_amountRaw>\\n",
    value: orderedAllocationSha256,
    note: "This is a flat ordered-record digest, not a Merkle root.",
  },
  reconciliation: {
    sourceFullSupplyRowCount: 313,
    sourceSnapshotRecipientCount: sourceSnapshot.allocations.length,
    migrationRecipientCount: outputRecipients.length,
    uniqueMigrationRecipientCount: new Set(loweredTargets).size,
    migrationTotalRaw: outputTotalRaw.toString(),
    migrationTotalDecimal: decimalFromRaw(outputTotalRaw),
    excluded: {
      initialLp: {
        rowCount: 1,
        totalRaw: expectedLpRaw.toString(),
        totalDecimal: decimalFromRaw(expectedLpRaw),
      },
      treasuryRemainder: {
        rowCount: 2,
        totalRaw: expectedTreasuryRaw.toString(),
        totalDecimal: decimalFromRaw(expectedTreasuryRaw),
        targets: treasuryTargets.map(toChecksumAddress),
      },
    },
    excludedTotalRaw: (expectedLpRaw + expectedTreasuryRaw).toString(),
    fullSupplyTotalRaw: expectedFullSupplyRaw.toString(),
    fullSupplyTotalDecimal: decimalFromRaw(expectedFullSupplyRaw),
    exactEquation:
      "migrationTotalRaw + initialLp.totalRaw + treasuryRemainder.totalRaw = fullSupplyTotalRaw",
    status: "PASS",
  },
  overrides: {
    OVR_001: {
      removedSources: ovr001Sources.map(toChecksumAddress),
      finalTargets: [
        {
          target: toChecksumAddress(ovr001Target),
          amountRaw: ovr001Raw,
          amountDecimal: decimalFromRaw(BigInt(ovr001Raw)),
        },
      ],
      status: "included in canonical migration allocation set",
    },
    OVR_002: {
      removedSources: ovr002Sources.map(toChecksumAddress),
      finalTargets: ovr002Targets
        .map(([target, amountRaw]) => ({
          target: toChecksumAddress(target),
          amountRaw,
          amountDecimal: decimalFromRaw(BigInt(amountRaw)),
        }))
        .sort((left, right) =>
          asciiCompare(left.target.toLowerCase(), right.target.toLowerCase()),
        ),
      status: "included in canonical migration allocation set",
    },
  },
  merkle: {
    generated: false,
    root: null,
    leafEncoding: null,
    reason: "No Merkle root was requested; no leaf encoding is defined in this package.",
  },
  artifacts: Object.fromEntries(
    Object.entries(artifactHashes)
      .sort(([left], [right]) => asciiCompare(left, right))
      .map(([name, hash]) => [name, { sha256: hash }]),
  ),
};

await fs.writeFile(path.join(outputDir, manifestName), jsonText(manifest), "utf8");

const checksumNames = [...artifactNamesBeforeManifest, manifestName].sort(asciiCompare);
const checksumLines = await Promise.all(
  checksumNames.map(async (name) =>
    `${await sha256File(path.join(outputDir, name))}  ${name}`,
  ),
);
await fs.writeFile(
  path.join(outputDir, "SHA256SUMS.txt"),
  `${checksumLines.join("\n")}\n`,
  "utf8",
);

console.log(
  JSON.stringify(
    {
      status: "PASS",
      recipientCount: outputRecipients.length,
      totalRaw: outputTotalRaw.toString(),
      totalDecimal: decimalFromRaw(outputTotalRaw),
      orderedAllocationSha256,
      sourceWorkbookSha256,
      sourceSnapshotSha256,
      first: outputRecipients[0],
      last: outputRecipients.at(-1),
    },
    null,
    2,
  ),
);
