
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
  const ROYALTY_CAP_BP  = Number(process.env.ROYALTY_CAP_BP  ?? 200);

  // 1) Factory
  const Factory = await ethers.getContractFactory("CollectionFactory");
  const factory = await Factory.deploy(deployer.address, TREASURY);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("Factory:", factoryAddr);

  // 2) Marketplace (non-upgradeable for simplicity/robustness)
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

  // 3) Wire marketplace -> factory
  const tx = await market.setFactory(factoryAddr);
  await tx.wait();
  console.log("Marketplace.factory set");

  // 4) Ensure native KAS is allowed (constructor already allows address(0))
  // Optional: if you support ERC-20 tokens, call setPaymentToken(token, true) here.

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
