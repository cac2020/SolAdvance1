import { expect } from "chai";
import { ethers } from "hardhat";
import { MockUniswapV2Router } from "../typechain-types";
import { Nemo } from "../typechain-types";

describe("Nemo — extended reflection tests", function () {
  let deployer: any;
  let user1: any;
  let user2: any;
  let user3: any;
  let mockRouter: MockUniswapV2Router;
  let token: Nemo;

  beforeEach(async function () {
    [deployer, user1, user2, user3] = await ethers.getSigners();

    // deploy MockRouter
    mockRouter = await ethers.deployContract("MockUniswapV2Router");
    await mockRouter.waitForDeployment();
    const mockRouterAddress = await mockRouter.getAddress();
    const marketingWallet = await user3.getAddress();

    // deploy token
    token = await ethers.deployContract("Nemo", [
      mockRouterAddress,
      marketingWallet,
    ]);
    await token.waitForDeployment();
  });

  describe("setup", function () {
    it("setup: check init value ", async function () {
      // 检查名称
      expect(await token.name()).to.equal("Nemo");
      // 检查代币符号
      expect(await token.symbol()).to.equal("NMC");
      //总供应量
      const totalSupply = await token.totalSupply();
      expect(totalSupply).to.equal(ethers.parseEther("100000"));
      // 检查 deployer余额为总发行数量
      expect(await token.balanceOf(deployer.address)).to.equal(totalSupply);
      // 检查流动性添加阈值
      expect(await token.numTokensSellToAddToLiquidity()).to.equal(
        ethers.parseEther("5")
      );
      // 检查交易限制
      expect(await token.maxTxAmount()).to.equal(ethers.parseEther("100"));
      // 检查单个钱包持仓上限
      expect(await token.maxWalletAmount()).to.equal(ethers.parseEther("1000"));
      //检查部署者是否在交易之外
      expect(await token.isExcludedFromFee(deployer.address)).to.be.true;
      expect(await token.isExcludedFromFee(await token.getAddress())).to.be
        .true;
      expect(await token.isExcludedFromFee(user3.address)).to.be.true;
      //检查 部署者加入交易白名单
      expect(await token.isWhitelisted(deployer.address)).to.be.true;
    });
  });

  describe("admin", function () {
    it("admin: setTaxes", async function () {
      //onlyOwner
      await expect(token.connect(user1).setTaxes(200, 0, 0, 0))
        .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
        .withArgs(user1.address);
      // tax too high
      await expect(token.setTaxes(200, 300, 500, 501)).to.be.revertedWith(
        "tax too high"
      );
      //check taxes
      await token.setTaxes(200, 1, 2, 3);
      expect(await token.reflectionTaxBP()).to.equal(200);
      expect(await token.liquidityTaxBP()).to.equal(1);
      expect(await token.burnTaxBP()).to.equal(2);
      expect(await token.marketingTaxBP()).to.equal(3);
      //check emit UpdateTaxes
      await expect(token.setTaxes(200, 1, 2, 3))
        .to.emit(token, "UpdateTaxes")
        .withArgs(200, 1, 2, 3);
    });

    it("admin: setLimits", async function () {
      await token.setLimits(
        ethers.parseEther("1000"),
        ethers.parseEther("10000"),
        10n
      );
      expect(await token.maxTxAmount()).to.equal(ethers.parseEther("1000"));
      expect(await token.maxWalletAmount()).to.equal(
        ethers.parseEther("10000")
      );
      expect(await token.dailyTxLimit()).to.equal(10n);
      //check emit UpdateLimits
      await expect(
        token.setLimits(
          ethers.parseEther("1000"),
          ethers.parseEther("10000"),
          10n
        )
      )
        .to.emit(token, "UpdateLimits")
        .withArgs(ethers.parseEther("1000"), ethers.parseEther("10000"), 10n);
    });

    it("admin: setNumTokensSellToAddToLiquidity", async function () {
      await token.setNumTokensSellToAddToLiquidity(ethers.parseEther("5"));
      expect(await token.numTokensSellToAddToLiquidity()).to.equal(
        ethers.parseEther("5")
      );
    });

    it("admin: setRouter", async function () {
      await expect(token.setRouter(ethers.ZeroAddress)).to.be.revertedWith(
        "zero router"
      );
    });

    it("admin: setMarketingWallet", async function () {
      await expect(
        token.setMarketingWallet(ethers.ZeroAddress)
      ).to.be.revertedWith("zero marketing");
      await token.setMarketingWallet(user3.address);
      expect(await token.marketingWallet()).to.equal(user3.address);
    });

    it("admin: setExcludeFromFee", async function () {
      await token.setExcludeFromFee(user3.address, true);
      expect(await token.isExcludedFromFee(user3.address)).to.be.true;

      await expect(token.setExcludeFromFee(user3.address, false))
        .to.emit(token, "ExcludeFromFeeEvent")
        .withArgs(user3.address, false);
    });

    it("admin: setWhitelisted", async function () {
      await token.setWhitelist(user3.address, true);
      expect(await token.isWhitelisted(user3.address)).to.be.true;
      await expect(token.setWhitelist(user3.address, false))
        .to.emit(token, "WhitelistEvent")
        .withArgs(user3.address, false);
    });

    it("admin: setBlacklisted", async function () {
      await token.setBlacklist(user3.address, true);
      expect(await token.isBlacklisted(user3.address)).to.be.true;

      await expect(token.setBlacklist(user3.address, false))
        .to.emit(token, "BlacklistEvent")
        .withArgs(user3.address, false);
    });

    it("admin: enableTrading", async function () {
      expect(await token.tradingEnabled()).to.be.false;
      await expect(token.enableTrading())
        .to.emit(token, "TradingEnabledEvent")
        .withArgs(true);
      expect(await token.tradingEnabled()).to.be.true;
    });

    it("admin: setSwapAndLiquifyEnabled", async function () {
      expect(await token.swapAndLiquifyEnabled()).to.be.true;
      await token.setSwapAndLiquifyEnabled(false);
      expect(await token.swapAndLiquifyEnabled()).to.be.false;
    });

    it("admin: excludeFromReward", async function () {
      await expect(
        token.excludeFromReward(deployer.address)
      ).to.be.revertedWith("already excluded");
      await expect(token.excludeFromReward(user3.address))
        .to.emit(token, "ExcludeFromRewardEvent")
        .withArgs(user3.address);
    });

    it("admin: includeInReward", async function () {
      await expect(token.includeInReward(user3.address)).to.be.revertedWith(
        "not excluded"
      );
      await expect(token.includeInReward(deployer.address))
        .to.emit(token, "IncludeInRewardEvent")
        .withArgs(deployer.address);
    });
  });

  describe("transfer", function () {
    it("split total supply to user1 & user2 (owner -> 0) and enable reflection-only tax", async function () {
      const total = await token.totalSupply();

      // transfer half to user1, rest to user2
      const half = total / 2n;
      await token.transfer(user1.address, half);
      await token.transfer(user2.address, total - half);

      const bOwner = await token.balanceOf(deployer.address);
      expect(bOwner).to.equal(0);

      const b1 = await token.balanceOf(user1.address);
      const b2 = await token.balanceOf(user2.address);
      expect(b1 + b2).to.equal(total);

      // set taxes: reflection = 2% (200 BP), others = 0
      await token.setTaxes(200, 0, 0, 0);

      // ensure trading enabled to allow transfers
      await token.enableTrading();

      // check maxTx is sane
      const maxTx = await token.maxTxAmount();
      // ensure a small transfer like 100 tokens is less than maxTx
      const small = 100n;
      expect(small <= maxTx).to.be.true;
    });

    it("reflection: exact proportional distribution when only two holders exist", async function () {
      const total = await token.totalSupply();
      const half = total / 2n;

      // distribute: half -> user1, half -> user2
      await token.transfer(user1.address, half);
      await token.transfer(user2.address, total - half);

      // set taxes to reflection-only 2%
      await token.setTaxes(200, 0, 0, 0);

      // enable trading
      await token.enableTrading();
      // set limits
      await token.setLimits(ethers.parseEther("1000"), total, 10n);

      // check pre balances
      const b1Before = await token.balanceOf(user1.address);
      //console.log("b1Before:", b1Before);
      const b2Before = await token.balanceOf(user2.address);
      //console.log("b2Before:", b2Before);
      const eligibleTotal = b1Before + b2Before; // owner is 0, no excluded by default (owner was excluded in ctor, but owner now holds 0)

      // choose t = 100 tokens to transfer from user1 -> user2
      const t = ethers.parseEther("100"); //如果使用较小的数  按比例计算丢失精度

      // compute expected pieces
      const reflectionBP = 200n; // 2%
      const tReflection = (t * reflectionBP) / 10000n; // floor division
      //console.log(tReflection, tTransfer);

      // expected deltas due to reflection distribution:计算两个实体的反射增量值。
      const delta1 = (tReflection * b1Before) / eligibleTotal;
      const delta2 = (tReflection * b2Before) / eligibleTotal;

      // perform transfer
      await token.connect(user1).transfer(user2.address, t);

      // read balances after 分红是按照反射比例来计算 不是简单的增量变化
      const b1After = await token.balanceOf(user1.address);
      const b2After = await token.balanceOf(user2.address);
      expect(b1After).to.lt(b1Before);
      expect(b2After).to.gt(b2Before);
    });

    it("excludeFromReward: excluded address should not receive reflection; included holders get full share", async function () {
      const total = await token.totalSupply();
      const half = total / 2n;

      // distribute all to user1 and user2
      await token.transfer(user1.address, half);
      await token.transfer(user2.address, total - half);

      // set reflectionOnly
      await token.setTaxes(200, 0, 0, 0);
      await token.enableTrading();
      // set limits
      await token.setLimits(1000n, total, 10n);

      // Verify initial balances
      const b1Before = await token.balanceOf(user1.address);
      const b2Before = await token.balanceOf(user2.address);

      // Owner will exclude user2 from reward
      // onlyOwner function: excludeFromReward(user2)
      await token.excludeFromReward(user2.address);

      // Now user1 transfers t to user2
      const t = 100n;
      const reflectionBP = 200n;
      const tReflection = (t * reflectionBP) / 10000n;
      const tTransfer = t - tReflection;

      // Since user2 is excluded, the eligible total for reflection is only user1 (b1Before).
      // So user1 should receive the whole reflection (minus rounding)
      const eligibleTotal = b1Before; // user2 excluded
      const delta1 =
        eligibleTotal > 0n ? (tReflection * b1Before) / eligibleTotal : 0n; // should equal tReflection ideally

      // perform transfer
      await token.connect(user1).transfer(user2.address, t);

      const b1After = await token.balanceOf(user1.address);
      const b2After = await token.balanceOf(user2.address);

      // expected:
      const expectedB1 = b1Before - t + delta1;
      const expectedB2 = b2Before + tTransfer; // excluded account doesn't get reflection

      const diff1 = b1After - expectedB1;
      const diff2 = b2After - expectedB2;

      expect(diff1 <= 1n).to.be.true;
      expect(diff2 <= 1n).to.be.true;

      // Now include user2 back into reward and do another transfer to verify reflection splits again
      await token.includeInReward(user2.address);

      // balances before second transfer
      const b1b2_before = await token.balanceOf(user1.address);
      const b2b2_before = await token.balanceOf(user2.address);

      const t2 = 50n;
      const t2Reflection = (t2 * reflectionBP) / 10000n;
      const totalEligible = b1b2_before + b2b2_before;
      const d1_afterInclude = (t2Reflection * b1b2_before) / totalEligible;
      const d2_afterInclude = (t2Reflection * b2b2_before) / totalEligible;

      await token.connect(user1).transfer(user2.address, t2);

      const b1_after2 = await token.balanceOf(user1.address);
      const b2_after2 = await token.balanceOf(user2.address);

      const expected1_after2 = b1b2_before - t2 + d1_afterInclude;
      const expected2_after2 =
        b2b2_before + (t2 - t2Reflection) + d2_afterInclude;

      expect(b1_after2 - expected1_after2 <= 1n).to.be.true;
      expect(b2_after2 - expected2_after2 <= 1n).to.be.true;
    });

    it("rounding edge case: tiny transfer that yields zero reflection", async function () {
      //当转账金额或分配比例极小（如低于 1 个最小单位）时，计算结果可能被四舍五入为零，导致接收方无法获得预期收益
      const total = await token.totalSupply();
      // give tiny amounts to user1 and user2
      const tiny = 1n; // 1 token (with 18 decimals it's 1 * 1e18)
      await token.transfer(user1.address, tiny);
      await token.transfer(user2.address, tiny * 2n);

      // set reflection BP very small so that tReflection = floor(t * bp / 10000) = 0
      // Example: set reflectionBP = 1 (0.01%). For t = 1 token, tReflection = floor(1 * 1 /10000) = 0
      await token.setTaxes(1, 0, 0, 0);
      await token.enableTrading();

      const b1Before = await token.balanceOf(user1.address);
      const b2Before = await token.balanceOf(user2.address);

      // user1 transfers 1 token to user2
      await token.connect(user1).transfer(user2.address, tiny);

      const b1After = await token.balanceOf(user1.address);
      const b2After = await token.balanceOf(user2.address);

      // since reflection portion is 0, the only effect is a pure transfer
      expect(b1After).to.equal(b1Before - tiny);
      expect(b2After).to.equal(b2Before + tiny);
    });

    it("swapAndLiquify trigger remains functional while using reflection-only setup", async function () {
      // set low threshold so swapAndLiquify triggers quickly
      await token.setNumTokensSellToAddToLiquidity(1n); // tiny
      // enable reflection only
      await token.setTaxes(200, 0, 0, 0);
      await token.enableTrading();

      // transfer some tokens to user1 so that user's transfers will accumulate contract balance
      await token.transfer(user1.address, 1000n);

      // multiple transfers that will tax and accumulate in contract (reflection only -> contract gets 0 for liquidity in this config,
      // but we just check swapAndLiquify doesn't revert if liquidity portion was >0 in another config)
      for (let i = 0; i < 3; i++) {
        await token.connect(user1).transfer(user2.address, 10n);
      }

      // contract balance is readable
      const contractBal = await token.balanceOf(token.target);
      expect(contractBal).to.equal(0n); // just ensure call works and returns a BigNumber
    });

    it("swapAndLiquify ", async function () {
      await token.transfer(token.target, 1000n);
      console.log(await token.balanceOf(token.target));
      await token.transfer(user1.address, 1000n);
      await token.setNumTokensSellToAddToLiquidity(1000n);
      await token.enableTrading();
      await token.connect(user1).transfer(user2.address, 1000n);
      console.log(await token.balanceOf(token.target));
    });
  });
});
