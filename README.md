# Kasplex NFT Marketplace Contracts (Testnet)

Upgradeable, secure ERC-721 marketplace + staking pool + factory with fee splits and ERC-2981 royalty cap — tailored for **Kasplex Network Testnet**.

**Network**
- Name: Kasplex Network Testnet
- RPC: `https://rpc.kasplextest.xyz`
- Chain ID: `167012`
- Native Token: Bridged Kas (symbol: KAS), 18 decimals
- Gas Price/Basefee: 2000 GWEI

## Modules
- `NFTCollection` (ERC721 + ERC2981)
- `Marketplace` (upgradeable, pausible, reentrancy-safe, fee split 0.7% = 0.2% royalty, 0.3% staking pool, 0.2% platform treasury, royalty capped)
- `StakingPool` (upgradeable, stake/unstake NFTs, accRewardPerShare rewards, fee notifications)
- `Treasury` (minimal vault owned by multisig)
- `Factory` (deploys `NFTCollection` with default royalty)

## Install
```bash
npm i
cp .env.example .env
# fill PRIVATE_KEY, TREASURY_MULTISIG etc.
npm run build
```

## Deploy (Kasplex Testnet)
```bash
npm run deploy:kasplextest
```

## Heroku
- Set config vars: `KASPLEX_RPC_URL`, `KASPLEX_CHAIN_ID=167012`, `PRIVATE_KEY`, `GAS_PRICE_GWEI=2000`, `TREASURY_MULTISIG`.
- On deploy, Heroku's **release phase** runs `Procfile` → `npm run release` (executes Hardhat deploy).

## Security
- OpenZeppelin upgradeable patterns (UUPS), ReentrancyGuard, Pausable, Ownable.
- Checks-Effects-Interactions. Safe fee math in basis points, royalty capped at 20 bp (0.2%).
- Prevents listing of staked NFTs via StakingPool check.

## Notes
- Marketplace supports native KAS and allow-listed ERC-20 payments.
- Adjust fees/recipients via owner-only setters.
- All constants expressed in basis points (1 bp = 0.01%).
