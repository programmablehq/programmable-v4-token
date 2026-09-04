# Programmable V4 migration allocation package

This directory contains the canonical machine-readable migration allocation set derived from the `MIGRATION` bucket of the latest full-supply workbook.

Scope:

- Exactly 310 migration recipients are included.
- The 50,000,000-token initial LP reservation is excluded.
- Both treasury-remainder rows are excluded.
- OVR-001 and OVR-002 replacement targets are included; their removed source rows are not.
- Amounts use 18 decimals. `amountRaw` is an unsigned base-10 integer string and `amountDecimal` is the corresponding fixed-18-decimal display string.

Files:

- `migration-allocations.json` — authoritative allocation set.
- `migration-allocations.csv` — deterministic tabular mirror of the JSON recipients.
- `migration-allocations.schema.json` — JSON Schema for the authoritative allocation file.
- `migration-manifest.json` — source binding, scope, override, ordering, digest, and reconciliation evidence.
- `SHA256SUMS.txt` — SHA-256 checksums for every package file except itself.
- `verify-package.mjs` — independent package verifier using Node.js built-ins and Foundry `cast` for EIP-55 checksums.
- `build-migration-package.mjs` — deterministic reconstruction from the hash-bound finalized JSON snapshot plus the explicit OVR-001/OVR-002 rules; it also verifies the bound full-supply workbook hash.

Deterministic ordering is ascending ASCII order of each target address after lowercasing. The JSON `index` is zero-based and follows that order.

The manifest's ordered-allocation digest is SHA-256 over UTF-8 bytes consisting of its documented domain-separator line followed by one record per recipient in sorted order. Each record is:

```text
<lowercase_evm_address>,<base10_uint256_amountRaw>\n
```

This digest is not a Merkle root. No Merkle root or leaf encoding is defined in this package.

Verify from this directory:

```sh
node verify-package.mjs
shasum -a 256 -c SHA256SUMS.txt
```

Set `CAST_BIN` if `cast` is not on `PATH`.
