import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import * as dotenv from "dotenv";
dotenv.config();

const rpcUrl = process.env.KASPLEX_RPC_URL || "https://evmrpc.kasplex.org";
const chainId = Number(process.env.KASPLEX_CHAIN_ID || 202555);
const pk = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];
const gasPriceGwei = Number(process.env.GAS_PRICE_GWEI || 2000);

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true
    }
  },
  networks: {
    kasplexTest: {
      url: rpcUrl,
      chainId,
      accounts: pk,
      gasPrice: gasPriceGwei * 1e9
    }
  },
  mocha: { timeout: 120000 }
};

export default config;
