# sovrn-contracts

Base tree for the SOVRN AI token launch (Uniswap v4 hook launch via the IMD swarm).

**This commit is an unmodified import** of the accepted contract sources (`src/`, `test/`, `script/`, `lib/`, `foundry.toml`, `launch.json`) from IMD launch #1040
(`identity-md-launches/launch-1040-og-symbol-og-the-launch-s-standard-token`, commit `c1d98b5`). Sources carry `SPDX-License-Identifier: MIT`.
The website, `dist/`, ABIs and validation records of that repo were left out on purpose.

It exists so an IMD `launch.open` can name it as `repoUrl` + `baseCommit` and adapt it: remove the SPEPE NFT distributor/auction,
send the hook fee to an immutable `LifeForceVault` (created by the hook constructor), rename the token to SOVRN AI. No audit is claimed.
