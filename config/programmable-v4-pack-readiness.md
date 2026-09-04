# Programmable V4 pack readiness

> **Preparation only.** No `programmable-launch.config.json` or `launch.json` exists in this repository. Nothing here
> is an API submission, approval, wallet signature, broadcast, deployment, audit, or public-release claim.

## Deterministic inputs already prepared

Run the credential-free build from the repository root:

```sh
npm run build:pack-artifacts
```

It uses the exact pinned `solc@0.8.26` Emscripten compiler and writes:

- `build/programmable-v4/standard-json/programmable-v4.json`
- `build/programmable-v4/artifacts/programmable-launch-initializer.json`
- `build/programmable-v4/artifacts/programmable-token.json`
- `build/programmable-v4/artifacts/programmable-launch-fee-hook.json`
- `build/programmable-v4/evidence/build-manifest.json`

The builder refuses to run when `PROGRAMMABLE_API_KEY` is present. It makes no network request and does not create a
platform config or launch payload. The build manifest records exact source, Standard JSON, artifact, creation-code,
runtime-code, settings, and compiler hashes. Regenerate all outputs after any source, dependency, compiler, or settings
change.

The Standard JSON structure follows the public V4 source-candidate contract: literal source content, optimizer 200,
Cancun EVM, `viaIR: false`, no metadata bytecode hash, no CBOR, and compiler artifacts containing ABI, metadata,
creation bytecode, deployed bytecode, link references, and immutable references.

## Why no final platform config is committed

The public V4 pack schema requires every launch-time binding. It does not permit `null` placeholders for those fields.
A final committed file would require inventing at least one security-critical or short-lived value. Local provisional
packs may be used to derive graph bindings, but they are ignored and are not submission evidence.

These inputs remain unresolved until the final source is public and the launch window is prepared:

- fresh nonzero launch nonce and short-lived `permitWindow`;
- exact public HTTPS source origin plus the immutable 40- or 64-character source revision;
- current capability-bound `chainDeployment` and integer-revision `profile` objects;
- exact external-contract evidence and constructor/initializer locators;
- dependency-topological target salts, constructor arguments, initializer arguments, and runtime-immutable values;
- public availability of the prepared commit-addressed HTTPS URI for the approved local PNG;
- launch-time Q64.96 start price, previewed token/native liquidity principals, initial-buy amount, price limit, minimum
  output, and deadline;
- exact native transaction funding value;
- final evidence files and time-bound agent attestation;
- any behavior-scenario inputs required by the then-current server policy.

The following static intent is known but is not enough to form a complete config:

- chain `4663`, CAIP-2 `eip155:4663`;
- launch wallet `0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1`;
- three targets: initializer, token, hook;
- canonical pool: native ETH / V4, dynamic fee flag `8388608`, tick spacing `60`;
- project-provided launch liquidity through the initializer;
- token metadata and social links recorded in `metadata/token-metadata.json`.

## Official packer gate

The public sources were rechecked on 2026-09-04:

- `https://programmable.market/.well-known/programmable.json` still advertises V4 as `planned-not-deployed`, with
  `publicAuthorization: false`, `publicWrites: false`, `releaseReady: false`, and CLI `4.0.0` marked source-candidate,
  unreleased, and not installable.
- `https://api.programmable.market/v4/chains/4663/capabilities` and `/readiness` currently report `ready`.

Those surfaces describe different lanes. Global discovery keeps public self-service fail-closed. A separately
authorized, internally granted chain-4663 API key may use Source CLI 4.0.0 against the live V4 backend only when the
authenticated preflight independently proves create scope, chain grant, controller binding, and simulation. Never use
a hand-written payload or the public flags as a substitute for that preflight.

Public self-service packing still requires public discovery promotion and a matching immutable CLI `4.0.0` release.
For an internally authorized launch, regenerate the final payload from the exact public source revision, fresh
capabilities, and short-lived timing values with the reviewed Source CLI; then require local reproduction and the live
authenticated preflight before any submission or wallet handoff.
