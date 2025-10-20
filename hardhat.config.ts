import { HardhatUserConfig, vars } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";

const ETHERSCAN_API_KEY = vars.get("ETHERSCAN_API_KEY");
const INFURA_API_KEY = vars.get("INFURA_API_KEY");
const PRIVATE_KEY1 = vars.get("PRIVATE_KEY1");
const PRIVATE_KEY2 = vars.get("PRIVATE_KEY2");
const PRIVATE_KEY3 = vars.get("PRIVATE_KEY3");
const PRIVATE_KEY4 = vars.get("PRIVATE_KEY4");
const PRIVATE_KEY5 = vars.get("PRIVATE_KEY5");

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true, // 添加这一行
    },
  },
  networks: {
    hardhat: {},
    localhost: { url: "http://127.0.0.1:8545" },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
      accounts: [
        PRIVATE_KEY1,
        PRIVATE_KEY2,
        PRIVATE_KEY3,
        PRIVATE_KEY4,
        PRIVATE_KEY5,
      ],
      chainId: 11155111,
    },
  },
  etherscan: {
    //旧版配置为不同网络（如主网、Sepolia 测试网）分别设置 API 密钥 旧插件@nomiclabs/hardhat-etherscan
    // apiKey: {
    //   sepolia: ETHERSCAN_API_KEY,
    // },
    //新版 Etherscan v2 API使用同一个密钥即可支持所有网络（主网、测试网通用），无需按网络拆分。  需要升级插件@nomicfoundation/hardhat-verify
    apiKey: ETHERSCAN_API_KEY,
  },
  sourcify: {
    // true -- 开启 sourcify 会在Sourcify上进行验证
    // false -- 关闭 sourcify 不会在Sourcify上进行验证  而是使用上面etherscan进行验证
    enabled: false,
  },
};

export default config;
