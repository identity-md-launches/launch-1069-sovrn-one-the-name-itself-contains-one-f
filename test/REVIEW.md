# Contributor test review

Scope: the accepted OG implementation, without production changes. The downloaded bundle's SHA-256 is `8d918c729607f1be5c14bc1b4d2e4b162b6f121f8462e77dad3af25760b1d064`; all six `src/*.sol` files match accepted commit `607cb79244f68dd99376c4b1bbedd320570c7700` byte for byte. Existing contributor tests are preserved. No dependency or configuration changes are required.

## Added coverage

| File | Properties |
| --- | --- |
| `AdversarialFees.t.sol` | Actual native settlement and fee events for both directions and exact modes, tiny amounts, partial fills, launch timing, invalid callback inputs, pool-key binding, quote rollback against an unhooked reference pool, mixed deferred/direct fees. |
| `AdversarialLifecycle.t.sol` | Owner versus approved-operator authorization, activation/upgrade/listing/exit/sale events, exact burn allowances, lock boundaries, fee funding rejection, rational weighted reward oracle, ETH refund rollback, NFT receipt rollback, and reentrancy against a different eligible NFT/listing. |
| `AuctionProperties.t.sol` | Geometric identity of exponential decay, the exact floor boundary, real 100-entry pagination limits, empty pages and swap-and-pop enumeration. |
| `LifecycleInvariants.t.sol` | Three owners and nine NFTs; real swaps, token/ETH activation, upgrades, transfers, exits, sales, claim redemption, rejecting team recipients, OG transfers/burns and forced-ETH accounting. |
| `AdversarialMainnetFork.t.sol` | Real SPEPE mint-status reads, fee settlement at opening and after decay, and a transfer/exit/auction lifecycle using the unmodified collection. |

The two new arithmetic fuzz properties and auction-curve property each use 1,000 runs. The added invariant suite uses 256 sequences of 96 calls, with unexpected reverts treated as failures. Its deterministic lifecycle test verifies that transfers, exits, sales, ETH activation, team rejection and recovery are reachable. Each sequence ends by advancing beyond all locks and attempting every remaining active exit.

## Invariant model

These guarantees follow from the assignment's accounting and custody requirements:

- Distributor ETH plus outstanding fee claims plus measured payouts equals the sum of fee allocations plus forced donations. Pending rewards and unstreamed backlog cannot exceed backing.
- PoolManager ERC-6909 native claims equal the hook's distributor and team liabilities. Team cash paid plus credit plus deferred claims equals the cumulative team allocation. The hook's ETH backs its team credit.
- Aggregate NFT weight and per-level counts equal the sum over all tracked NFTs. Every listing has auction custody, zero level and zero pending, and appears exactly once in pagination.
- All tracked OG balances sum to the fixed billion-token supply. Activation costs, auction payments and direct burns independently accumulate into the burn oracle and must equal both `totalBurned` and the DEAD balance.
- Transfers preserve accrued rewards, level and lock; upgrades cannot erase accrued rewards; new activations earn no past fees. Checkpointing twice at the same timestamp is idempotent.

Fee allocations are observed from `FeeSplit`, independently checked against cash/claims. The fee fuzz tests separately validate those event amounts against trader, manager, team and distributor balances. `vm.recordLogs` includes events emitted in reverted quote frames; the quote-rollback test therefore compares final pool price, liquidity and both LP fee-growth accumulators against a second real PoolManager pool with the same net AMM trade.

## Source and economics review

- **OG:** fixed supply, plain transfers, allowance subtraction and ordinary DEAD transfers. The conservation campaign includes direct burns in addition to protocol burns.
- **OGHook:** manager-only entry, immutable factory and pool binding, permission bits, all four fee paths, native return deltas, reverting quote isolation, deferred claim backing and retryable team payments.
- **OGDistributor:** ownerOf authorization on every operation, cumulative upgrade costs, fractional debt preservation, weight changes, zero-weight backlog, exact-output ETH purchases, delayed exits and payment rollback.
- **OGAuction:** exclusive distributor listing, custody validation, per-NFT sale history, exponential decay and permanent floor, burned payment, recipient callbacks and pagination.
- **Interfaces/Guard/HookFlags:** caller boundaries, shared reentrancy errors, checked ETH sends and address permission masks.

The accepted implementation reschedules the remaining backlog over a fresh 30 days after a zero-weight interval or new launch surplus. It retains past accrual when doing so. Its buy-fee base includes the hook fee; the sell base precedes the hook deduction. Team share stays at 1% during launch protection. Auction history belongs to the tokenId. These interpretations are preserved rather than changed by this tests-only contribution.

This is a bounded review of another contributor's code, not an external audit or formal proof. The stateful campaign uses a local ERC-721 fixture and a real local v4 PoolManager; fork tests separately check the actual SPEPE collection. Source review and these tests did not establish a confirmed production defect.

## Reproduction

Default verification requires no network and uses the already vendored dependencies:

```sh
forge build
forge test
```

To keep local artifacts inside the disposable test directory, the equivalent commands used for this contribution pass `--out test/scratch/out --cache-path test/scratch/cache`.

Fork verification uses an explicit RPC and fixed block; it does not set environment variables or require RPC configuration files:

```sh
forge test --match-contract '^(AdversarialMainnetForkTest|MainnetForkTest)$' \
  --fork-url https://eth-mainnet.public.blastapi.io --fork-block-number 26147125
```

At block **26,147,125**, fresh RPC reads returned `symbol() = SPEPE`, `mintOpen() = true`, `totalMinted() = 1242`, and `MAX_SUPPLY() = 5000`; `totalSupply()` reverted. Mint status can change after this block. The fork suites explicitly skip in the offline default run; an offline skip is not a claim that live integration ran.

## Recorded results

- `forge build`: exit 0; existing lint warnings do not prevent compilation.
- Full offline `forge test -vv`: **62 passed, 0 failed, 2 skipped**. Foundry 1.8.3 reports each grouped invariant suite as one result; all six invariant properties (existing and new) passed.
- New lifecycle campaign: **256 runs, 24,576 calls, 0 reverts** across all ten handler actions, followed by exit-liveness checks.
- Mainnet fork at block 26,147,125: **3 passed, 0 failed, 0 skipped** across the existing and added fork suites.
- No confirmed production defects were found; no finding was suppressed or converted into an assertion blessing incorrect behavior.
