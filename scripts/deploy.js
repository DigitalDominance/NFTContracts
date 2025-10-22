
// deploy.js — end-to-end deploy & wiring for Factory + Marketplace (UUPS) on Kasplex
// Requires: Hardhat, ethers v6, @openzeppelin/hardhat-upgrades
//   npm i -D hardhat @nomicfoundation/hardhat-ethers ethers @openzeppelin/hardhat-upgrades
//
// Usage examples:
//   npx hardhat run scripts/deploy.js --network kasplex
//   TREASURY_MULTISIG=0x... PLATFORM_FEE_BP=20 STAKING_FEE_BP=30 ROYALTY_CAP_BP=200 \
//   DEPLOY_SAMPLE=1 SAMPLE_NAME="Demo" SAMPLE_SYMBOL="DEMO" SAMPLE_BASE_URI="ipfs://CID/" \
//   npx hardhat run scripts/deploy.js --network kasplex

const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const net = await ethers.provider.getNetwork();
  console.log("Network:", net.name, "chainId:", net.chainId?.toString());

  // ====== CONFIG ======
  // Fees are basis points (bps). Example defaults: 0.20% platform, 0.30% staking, 2.00% royalty cap.
  const TREASURY = process.env.TREASURY_MULTISIG || deployer.address;
  const PLATFORM_FEE_BP = Number(process.env.PLATFORM_FEE_BP ?? 20);
  const STAKING_FEE_BP  = Number(process.env.STAKING_FEE_BP  ?? 30);
  const ROYALTY_CAP_BP  = Number(process.env.ROYALTY_CAP_BP  ?? 200);

  // Sanity
  if (!ethers.isAddress(TREASURY)) throw new Error("Invalid TREASURY address");
  if (PLATFORM_FEE_BP < 0 || STAKING_FEE_BP < 0 || ROYALTY_CAP_BP < 0) throw new Error("Negative BPs not allowed");
  if (PLATFORM_FEE_BP > 10000 || STAKING_FEE_BP > 10000 || ROYALTY_CAP_BP > 10000) throw new Error("BPs must be <= 10000");

  // ====== 1) Deploy CollectionFactory (owner = deployer; treasury = TREASURY) ======
  const Factory = await ethers.getContractFactory("CollectionFactory");
  const factory = await Factory.deploy(deployer.address, TREASURY);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("CollectionFactory:", factoryAddr);

  // Verify treasury set
  try {
    const t = await factory.treasury();
    console.log("Factory.treasury:", t);
  } catch (e) {
    console.warn("Could not read treasury() on factory (non-fatal):", e.message);
  }

  // ====== 2) Deploy Marketplace (UUPS proxy) & initialize ======
  const Marketplace = await ethers.getContractFactory("Marketplace");
  // initialize(owner_, treasury_, stakingPool_, platformFeeBP_, stakingFeeBP_, royaltyCapBP_)
  const marketplace = await upgrades.deployProxy(
    Marketplace,
    [
      deployer.address,
      TREASURY,
      ethers.ZeroAddress, // stakingPool_ (legacy placeholder; per-collection pools via factory)
      PLATFORM_FEE_BP,
      STAKING_FEE_BP,
      ROYALTY_CAP_BP
    ],
    {
      kind: "uups",
      initializer: "initialize"
    }
  );
  await marketplace.waitForDeployment();
  const marketplaceAddr = await marketplace.getAddress();
  console.log("Marketplace (proxy):", marketplaceAddr);

  // Confirm owner/treasury initialized
  try {
    const owner = await marketplace.owner();
    console.log("Marketplace.owner:", owner);
    const treas = await marketplace.treasury();
    console.log("Marketplace.treasury:", treas);
  } catch (e) {
    console.warn("Marketplace not exposing owner/treasury (ok if functions not public):", e.message);
  }

  // ====== 3) Wire Marketplace → Factory ======
  // This is critical: makes per-collection staking pools discoverable by Marketplace.
  {
    console.log("Setting Marketplace.factory →", factoryAddr);
    const tx = await marketplace.setFactory(factoryAddr);
    await tx.wait();
    console.log("✓ Marketplace.factory set");
  }

  // ====== 4) (Optional) Allow native KAS as payment token ======
  // If your Marketplace enforces an allowlist for payment tokens, uncomment the next block.
  // It sets address(0) (native KAS) as allowed.
  try {
    if (typeof marketplace.setPaymentToken === "function") {
      console.log("Allowing native KAS (address(0)) as payment token...");
      const tx2 = await marketplace.setPaymentToken(ethers.ZeroAddress, true);
      await tx2.wait();
      console.log("✓ Native KAS allowed");
    }
  } catch (e) {
    console.log("setPaymentToken not available or failed (continuing):", e.message);
  }

  // ====== 5) Ensure Marketplace is unpaused ======
  try {
    if (typeof marketplace.unpause === "function") {
      console.log("Unpausing Marketplace...");
      const tx3 = await marketplace.unpause();
      await tx3.wait();
      console.log("✓ Marketplace unpaused");
    }
  } catch (e) {
    console.log("Marketplace unpause skipped/failed (continuing):", e.message);
  }

  // ====== 6) (Optional) Smoke deploy a collection to validate wiring ======
  if (process.env.DEPLOY_SAMPLE === "1") {
    const name = process.env.SAMPLE_NAME || "Demo Collection";
    const symbol = process.env.SAMPLE_SYMBOL || "DEMO";
    const baseURI = process.env.SAMPLE_BASE_URI || "ipfs://CID/";
    const royaltyReceiver = process.env.SAMPLE_ROYALTY_RECEIVER || deployer.address;
    const royaltyBps = Number(process.env.SAMPLE_ROYALTY_BPS || 200);
    const mintPrice = ethers.parseEther(process.env.SAMPLE_MINT_PRICE || "0.001");
    const maxPerWallet = Number(process.env.SAMPLE_MAX_PER_WALLET || 5);
    const maxSupply = Number(process.env.SAMPLE_MAX_SUPPLY || 1000);
    const DEPLOY_FEE = ethers.parseEther("5"); // exact 5 KAS

    console.log("\n-- Smoke deploying sample collection (fee 5 KAS)...");
    // simulate (callStatic) to catch any revert reason prior to sending (if available in your stack)
    // NOTE: ethers v6 doesn't expose callStatic on Contract directly; most users use hardhat's dry-run or viem simulate.
    // We'll send directly here with clear logs.
    const dtx = await factory.deployCollection(
      name,
      symbol,
      baseURI,
      royaltyReceiver,
      royaltyBps,
      mintPrice,
      maxPerWallet,
      maxSupply,
      { value: DEPLOY_FEE }
    );
    const rcpt = await dtx.wait();
    console.log("Sample tx hash:", rcpt.hash);

    // Parse CollectionDeployed event to extract addresses
    let collectionAddr = null, poolAddr = null;
    for (const log of rcpt.logs) {
      try {
        const parsed = factory.interface.parseLog({ topics: log.topics, data: log.data });
        if (parsed && parsed.name === "CollectionDeployed") {
          collectionAddr = parsed.args.collection;
          poolAddr = parsed.args.stakingPool;
          break;
        }
      } catch { /* ignore non-factory logs */ }
    }
    console.log("Sample collection:", collectionAddr);
    console.log("Sample staking pool:", poolAddr);

    if (!collectionAddr || !poolAddr) {
      console.warn("WARNING: Could not parse CollectionDeployed event. Check event signature or topics.");
    }
  }

  console.log("\nAll set.");
  console.log("Addresses:");
  console.log("  Factory     :", factoryAddr);
  console.log("  Marketplace :", marketplaceAddr);
  console.log("  Treasury    :", TREASURY);
  console.log("  Platform BP :", PLATFORM_FEE_BP);
  console.log("  Staking  BP :", STAKING_FEE_BP);
  console.log("  Royalty Cap :", ROYALTY_CAP_BP);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
