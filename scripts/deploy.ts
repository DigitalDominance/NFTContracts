import { ethers, upgrades } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const treasuryAddress = process.env.TREASURY_MULTISIG;
  if (!treasuryAddress) throw new Error("TREASURY_MULTISIG required");

  // StakingPool (proxy)
  const StakingPool = await ethers.getContractFactory("StakingPool");
  const stakingPool = await upgrades.deployProxy(StakingPool, [deployer.address], { kind: "uups" });
  await stakingPool.waitForDeployment();
  console.log("StakingPool (proxy):", await stakingPool.getAddress());

  // Marketplace (proxy)
  const platformFeeBP = 20;
  const stakingFeeBP = 30;
  const royaltyCapBP = 20;
  const Marketplace = await ethers.getContractFactory("Marketplace");
  const marketplace = await upgrades.deployProxy(
    Marketplace,
    [deployer.address, treasuryAddress, await stakingPool.getAddress(), platformFeeBP, stakingFeeBP, royaltyCapBP],
    { kind: "uups" }
  );
  await marketplace.waitForDeployment();
  console.log("Marketplace (proxy):", await marketplace.getAddress());

  // Wire stakingPool.marketplace
  const setTx = await stakingPool.setMarketplace(await marketplace.getAddress());
  await setTx.wait();
  console.log("StakingPool.marketplace set");

  // Treasury (simple vault) - optional, you can point marketplace.treasury to an existing multisig instead
  const Treasury = await ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy(treasuryAddress);
  await treasury.waitForDeployment();
  console.log("Treasury:", await treasury.getAddress());

  // Factory
  const Factory = await ethers.getContractFactory("CollectionFactory");
  const factory = await Factory.deploy(deployer.address);
  await factory.waitForDeployment();
  console.log("CollectionFactory:", await factory.getAddress());

  console.log("\nDONE");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
