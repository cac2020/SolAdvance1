// scripts/deploy.ts
import { ethers, network } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying by:", deployer.address, "network:", network.name);

  // If running on Sepolia and you have a real Router address, set it via env
  let routerAddress: string;

  if (network.name === "sepolia") {
    //Sepolia或者Mainnet V2Router02 Contract Address
    routerAddress = "0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3";
  } else if (network.name === "mainnet") {
    routerAddress = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";
  } else if (network.name === "hardhat" || network.name === "localhost") {
    // deploy Mock Router for local testing
    const MockRouter = await ethers.deployContract("MockUniswapV2Router");
    await MockRouter.waitForDeployment();
    routerAddress = await MockRouter.getAddress();
    console.log("Mock Router deployed at:", routerAddress);
  } else {
    throw new Error("Please set ROUTER_ADDRESS env var");
  }

  // deploy the token -- assuming contract name Nemo
  const marketing = await deployer.getAddress(); // set marketing to deployer for tests; in prod use multisig
  const token = await ethers.deployContract("Nemo", [routerAddress, marketing]); //0x85317227a8A7C0a8531BB849D09d8f053431CF42
  await token.waitForDeployment();
  console.log("Token deployed at:", await token.getAddress());

  // show some useful info
  const totalSupply = await token.totalSupply();
  console.log("Total supply:", ethers.formatUnits(totalSupply, 18));
  console.log(
    "Owner token balance:",
    ethers.formatUnits(await token.balanceOf(deployer.address), 18)
  );

  console.log("Deployment complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
