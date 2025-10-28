
const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const net = await ethers.provider.getNetwork();
  console.log("Network chainId:", net.chainId.toString());

  const TREASURY = process.env.TREASURY_MULTISIG || deployer.address;
  const PLATFORM_FEE_BP = Number(process.env.PLATFORM_FEE_BP ?? 20);
  const STAKING_FEE_BP  = Number(process.env.STAKING_FEE_BP  ?? 30);
  const ROYALTY_CAP_BP  = Number(process.env.ROYALTY_CAP_BP  ?? 500);

  const Factory = await ethers.getContractFactory("CollectionFactory");
  const factory = await Factory.deploy(deployer.address, TREASURY);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("Factory:", factoryAddr);

  const Market = await ethers.getContractFactory("Marketplace");
  const market = await Market.deploy(
    deployer.address,
    TREASURY,
    PLATFORM_FEE_BP,
    STAKING_FEE_BP,
    ROYALTY_CAP_BP
  );
  await market.waitForDeployment();
  const marketAddr = await market.getAddress();
  console.log("Marketplace:", marketAddr);

  const tx = await market.setFactory(factoryAddr);
  await tx.wait();
  console.log("✓ Marketplace.factory set");

  try {
    const paused = await market.paused();
    if (paused) {
      const u = await market.unpause();
      await u.wait();
      console.log("✓ Marketplace unpaused");
    } else {
      console.log("Marketplace already unpaused");
    }
  } catch (e) {
    console.log("Pause/unpause not available or failed (continuing):", e.message);
  }

  console.log("\nAddresses:");
  console.log("  Factory     :", factoryAddr);
  console.log("  Marketplace :", marketAddr);
  console.log("  Treasury    :", TREASURY);
  console.log("  Platform BP :", PLATFORM_FEE_BP);
  console.log("  Staking  BP :", STAKING_FEE_BP);
  console.log("  Royalty Cap :", ROYALTY_CAP_BP);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
