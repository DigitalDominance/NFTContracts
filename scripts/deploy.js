// deploy.js — wires Marketplace.factory automatically
// Uses Hardhat + @openzeppelin/hardhat-upgrades with ethers v6.
// Make sure you've run: npm i --save-dev @openzeppelin/hardhat-upgrades @nomicfoundation/hardhat-ethers ethers

const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // ==== ENV / CONFIG ====
  const TREASURY = process.env.TREASURY_MULTISIG || deployer.address;
  const PLATFORM_FEE_BP = Number(process.env.PLATFORM_FEE_BP || 20);   // 0.20% example
  const STAKING_FEE_BP  = Number(process.env.STAKING_FEE_BP  || 30);   // 0.30% example
  const ROYALTY_CAP_BP  = Number(process.env.ROYALTY_CAP_BP  || 20);  // 0.2% cap example

  // ==== 1) Deploy CollectionFactory (owner = deployer, treasury = TREASURY) ====
  const Factory = await ethers.getContractFactory("CollectionFactory");
  const factory = await Factory.deploy(deployer.address, TREASURY);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("CollectionFactory:", factoryAddr);

  // ==== 2) Deploy Marketplace (UUPS) ====
  const Marketplace = await ethers.getContractFactory("Marketplace");
  const marketplace = await upgrades.deployProxy(
    Marketplace,
    [
      deployer.address,         // owner
      TREASURY,                 // treasury
      ethers.ZeroAddress,       // stakingPool (legacy placeholder; per-collection pools are used)
      PLATFORM_FEE_BP,          // platform fee bp
      STAKING_FEE_BP,           // staking fee bp
      ROYALTY_CAP_BP            // royalty cap bp
    ],
    { kind: "uups", initializer: "initialize" }
  );
  await marketplace.waitForDeployment();
  const marketplaceAddr = await marketplace.getAddress();
  console.log("Marketplace (proxy):", marketplaceAddr);

  // ==== 3) Wire Marketplace → Factory (this is what makes per-collection pools active) ====
  const tx = await marketplace.setFactory(factoryAddr); // onlyOwner
  await tx.wait();
  console.log("Marketplace.factory set to:", factoryAddr);

  // ---- (Optional) Smoke deploy a collection to prove wiring works ----
  if (process.env.DEPLOY_SAMPLE === "1") {
    const name = process.env.SAMPLE_NAME || "Demo Collection";
    const symbol = process.env.SAMPLE_SYMBOL || "DEMO";
    const baseURI = process.env.SAMPLE_BASE_URI || "ipfs://CID/";
    const royaltyReceiver = process.env.SAMPLE_ROYALTY_RECEIVER || deployer.address;
    const royaltyBps = Number(process.env.SAMPLE_ROYALTY_BPS || 200);
    const mintPrice = ethers.parseEther(process.env.SAMPLE_MINT_PRICE || "0.001");
    const maxPerWallet = Number(process.env.SAMPLE_MAX_PER_WALLET || 5);
    const maxSupply = Number(process.env.SAMPLE_MAX_SUPPLY || 1000);
    const DEPLOY_FEE = ethers.parseEther("5"); // factory enforces exactly 5 KAS

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

    let collectionAddr = null, poolAddr = null;
    for (const log of rcpt.logs) {
      try {
        const parsed = factory.interface.parseLog(log);
        if (parsed.name === "CollectionDeployed") {
          collectionAddr = parsed.args.collection;
          poolAddr = parsed.args.stakingPool;
        }
      } catch {}
    }
    console.log("Sample collection:", collectionAddr);
    console.log("Sample staking pool:", poolAddr);
  }

  console.log("\nAll set.");
  console.log("Addresses:");
  console.log("  Factory     :", factoryAddr);
  console.log("  Marketplace :", marketplaceAddr);
  console.log("  Treasury    :", TREASURY);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
