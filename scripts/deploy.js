// Updated deploy.js — per-collection staking wiring
// - No global StakingPool is deployed anymore.
// - Marketplace is deployed (UUPS) with stakingPool = ZeroAddress (legacy arg kept for ABI compat).
// - CollectionFactory is deployed and then set on Marketplace via setFactory(factory).
// - Optional: shows how to deploy a sample collection and read back its pool address.
//
// Requires: TREASURY_MULTISIG in your .env

const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const treasuryAddress = process.env.TREASURY_MULTISIG;
  if (!treasuryAddress) throw new Error("TREASURY_MULTISIG required");

  // ---- Marketplace (UUPS proxy) ----
  const platformFeeBP = 20;   // 0.20% (example: set your real values)
  const stakingFeeBP  = 30;   // 0.30%
  const royaltyCapBP  = 20;  // 0.20% cap

  const Marketplace = await ethers.getContractFactory("Marketplace");
  const marketplace = await upgrades.deployProxy(
    Marketplace,
    [
      deployer.address,             // owner
      treasuryAddress,              // treasury
      ethers.ZeroAddress,           // stakingPool (legacy, unused now; per-collection pools)
      platformFeeBP,
      stakingFeeBP,
      royaltyCapBP
    ],
    { kind: "uups", initializer: "initialize" }
  );
  await marketplace.waitForDeployment();
  const marketplaceAddr = await marketplace.getAddress();
  console.log("Marketplace (proxy):", marketplaceAddr);

  // ---- Treasury (optional helper/vault; keep if used by your app) ----
  // If your app already uses a separate Treasury contract, leave this in.
  // Otherwise you can remove this section.
  let treasuryContractAddr = null;
  try {
    const Treasury = await ethers.getContractFactory("Treasury");
    const treasury = await Treasury.deploy(treasuryAddress);
    await treasury.waitForDeployment();
    treasuryContractAddr = await treasury.getAddress();
    console.log("Treasury:", treasuryContractAddr);
  } catch (e) {
    console.log("Treasury deployment skipped or contract not present:", e.message);
  }

  // ---- CollectionFactory (deploys collection + a dedicated pool per collection) ----
  const Factory = await ethers.getContractFactory("CollectionFactory");
  // Your constructor previously took (owner, treasury). Keep same order.
  const factory = await Factory.deploy(deployer.address, treasuryAddress);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("CollectionFactory:", factoryAddr);

  // ---- Wire factory to marketplace (enables per-collection pools) ----
  const tx = await marketplace.setFactory(factoryAddr);
  await tx.wait();
  console.log("Marketplace.factory set ->", factoryAddr);

  // ---- (Optional) Sanity: deploy one sample collection + pool, then read the pool ----
  // NOTE: Keep/adjust this section for CI smoke tests, or comment it out in production.
  // const name = "Demo Collection";
  // const symbol = "DEMO";
  // const baseURI = "ipfs://CID/";
  // const royaltyReceiver = deployer.address;
  // const royaltyBps = 200;              // 2.00% default royalty (capped by marketplace)
  // const mintPrice = ethers.parseEther("0.001"); // KAS
  // const maxPerWallet = 5;
  // const maxSupply = 1000;
  //
  // // Remember: your factory enforces an exact 5 KAS deploy fee.
  // const DEPLOY_FEE = ethers.parseEther("5");
  // const deployTx = await factory.deployCollection(
  //   name,
  //   symbol,
  //   baseURI,
  //   royaltyReceiver,
  //   royaltyBps,
  //   mintPrice,
  //   maxPerWallet,
  //   maxSupply,
  //   { value: DEPLOY_FEE }
  // );
  // const receipt = await deployTx.wait();
  // let collectionAddr = null, poolAddr = null;
  // for (const log of receipt.logs) {
  //   try {
  //     const parsed = factory.interface.parseLog(log);
  //     if (parsed && parsed.name === "CollectionDeployed") {
  //       collectionAddr = parsed.args.collection;
  //       poolAddr = parsed.args.stakingPool;
  //     }
  //   } catch (_) {}
  // }
  // console.log("Deployed collection:", collectionAddr);
  // console.log("Its staking pool:", poolAddr);
  //
  // // (Optional) Marketplace sanity: ensure listing guard calls into the correct pool
  // // and buy() routes stakingFee to that same pool (handled inside Marketplace).

  console.log("\nDONE");
  console.log("Addresses:");
  console.log("  Marketplace:", marketplaceAddr);
  console.log("  Factory    :", factoryAddr);
  if (treasuryContractAddr) console.log("  Treasury   :", treasuryContractAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
