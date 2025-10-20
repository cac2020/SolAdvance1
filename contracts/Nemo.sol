// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  Nemo.sol
  - Inherits OpenZeppelin ERC20 for interface compatibility
  - Implements Reflection (RFI) bookkeeping (rOwned / tOwned)
  - Taxes: reflection, liquidity, burn, marketing
  - Auto swapAndLiquify (UniswapV2 style)
  - Trading limits: maxTx, maxWallet, dailyTxLimit
  - Whitelist / Blacklist / Exclude-from-fee / Exclude-from-reward
  NOTE: We override ERC20 views/mutative functions to use our own bookkeeping.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "hardhat/console.sol";

/**
 * @title IUniswapV2Router02
 * @dev Uniswap V2 路由器接口，定义了与Uniswap交易所交互的核心函数
 */
interface IUniswapV2Router02 {
    /**
     * @dev 获取工厂合约地址
     * @return address 工厂合约地址
     */
    function factory() external pure returns (address);

    /**
     * @dev 获取WETH代币地址
     * @return address WETH代币地址
     */
    function WETH() external pure returns (address);

    /**
     * @dev 添加流动性到ETH交易对中
     * @param token 代币地址
     * @param amountTokenDesired 期望添加的代币数量
     * @param amountTokenMin 最小接受的代币数量
     * @param amountETHMin 最小接受的ETH数量
     * @param to 流动性代币接收者地址
     * @param deadline 交易截止时间戳
     * @return amountToken 实际添加的代币数量
     * @return amountETH 实际添加的ETH数量
     * @return liquidity 获得的流动性代币数量
     */
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);

    /**
     * @dev 从ETH交易对中移除流动性
     * @param token 代币地址
     * @param liquidity 要移除的流动性代币数量
     * @param amountTokenMin 最小接受的代币数量
     * @param amountETHMin 最小接受的ETH数量
     * @param to 代币和ETH接收者地址
     * @param deadline 交易截止时间戳
     * @return amountToken 实际获得的代币数量
     * @return amountETH 实际获得的ETH数量
     */
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);

    /**
     * @dev 使用精确数量的代币兑换最少数量的ETH，支持转账时收取费用的代币
     * @param amountIn 输入的代币数量
     * @param amountOutMin 最小输出的ETH数量
     * @param path 兑换路径数组，从输入代币到WETH
     * @param to ETH接收者地址
     * @param deadline 交易截止时间戳
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

/**
 * @title IUniswapV2Factory
 * @dev Uniswap V2工厂接口，用于获取交易对地址
 */
interface IUniswapV2Factory {
    /**
     * @dev 根据两个代币地址获取对应的交易对地址
     * @param tokenA 第一个代币的地址
     * @param tokenB 第二个代币的地址
     * @return pair 返回tokenA和tokenB组成的交易对合约地址，如果不存在则返回零地址
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    /**
     * @dev 创建一个新的交易对，并返回交易对合约地址
     * @param a 第一个代币的合约地址
     * @param b 第二个代币的合约地址
     * @return pair 创建的交易对合约地址
     */
    function createPair(address a, address b) external returns (address);
}

/**
 * @title Nemo
 * @dev A Solidity smart contract implementing an ERC20 token with reflection rewards,
 * liquidity generation, burn mechanism, and marketing fee distribution.
 * Inherits from OpenZeppelin's ERC20 and Ownable contracts.
 * Integrates with Uniswap V2 for liquidity operations.
 */
contract Nemo is ERC20, Ownable {
    using Address for address;

    // -------------------------
    // Reflection bookkeeping 反射机制的账本记录功能
    // -------------------------
    //uint256类型的最大值 ~uint256(0) 表示对0进行按位取反操作 得到了uint256类型能表示的最大数值（即2^256 - 1）
    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal; //总代币供应量
    uint256 private _rTotal; //总反射金额

    mapping(address => uint256) private _rOwned; //每个地址持有的反射金额
    mapping(address => uint256) private _tOwned; // 被排除账户持有的代币数量
    mapping(address => mapping(address => uint256)) private _allowancesCustom; // 自定义授权映射

    mapping(address => bool) private isExcludedFromReward; //标记是否排除奖励的地址
    address[] private _excluded; //被排除在奖励分配机制之外地址的数组

    // -------------------------
    // Taxes 交易税功能(单位为基点BP：basis points = 10000，1个基点等于0.01%，100个基点等于1%)
    // -------------------------
    uint16 public reflectionTaxBP = 200; // 反射税税率，单位为基点(BP) 默认 2%
    uint16 public liquidityTaxBP = 200; // 流动性税税率，单位为基点(BP) 2%
    uint16 public burnTaxBP = 100; // 燃烧税税率，单位为基点(BP) 1%
    uint16 public marketingTaxBP = 200; // 营销税税率，单位为基点(BP) 2%
    uint16 public constant MAX_TOTAL_TAX_BP = 1500; // 最大总税税率，单位为基点(BP) 15%

    uint256 private liquidityTokensAccumulated; //累计的流动性代币数量 用于跟踪通过交易税费收集到的流动性代币总额
    uint256 private marketingTokensAccumulated; //累计的营销代币数量 用于跟踪通过交易税费收集到的营销代币总额

    // -------------------------
    // Limits and controls 交易限制功能
    // -------------------------
    uint256 public maxTxAmount; //单笔交易限额，单位为代币数量 默认 0.1%
    uint256 public maxWalletAmount; //单个钱包持仓上限，单位为代币数量 默认 1%
    uint16 public dailyTxLimit = 10; //每日交易次数上限 默认 10次
    mapping(address => mapping(uint256 => uint16)) public dailyTxCount; //每个地址在每个时间点的交易次数记录

    bool public tradingEnabled = false; //交易状态控制变量，表示当前合约是否允许交易
    mapping(address => bool) public isWhitelisted; //白名单映射，用于存储被授权的地址
    mapping(address => bool) public isBlacklisted; //黑名单映射，用于存储被禁止的地址
    mapping(address => bool) public isExcludedFromFee; //免费用户映射，用于存储免除交易费用的地址

    // -------------------------
    // Uniswap
    // -------------------------
    IUniswapV2Router02 public uniswapRouter; //Uniswap V2 路由器接口实例，用于执行代币交换和流动性操作
    address public uniswapPair; //Uniswap V2 交易对地址，用于存储该代币与其它代币的交易对合约地址
    bool private inSwapAndLiquify; //防重入标志，用于防止在交换和添加流动性过程中发生重入攻击  当前是否正在执行交换和流动性添加操作
    bool public swapAndLiquifyEnabled = true; //交换并添加到流动性功能控制变量，用于启用或禁用该功能
    uint256 public numTokensSellToAddToLiquidity; //触发流动性和交换操作的代币数量阈值  当合约中累积的代币数量达到此值时，将执行swapAndLiquify操作

    address public marketingWallet; //营销钱包地址，用于接收部分代币或ETH用于营销推广
    address public constant BURN_ADDRESS = address(0xdead); //销毁地址常量，用于永久销毁代币

    // events (ERC20 Transfer/Approval already defined in ERC20)
    /**
     * @dev 事件：兑换和提供流动性完成
     * @param tokensSwapped 兑换的代币数量
     * @param ethReceived 获得的ETH数量
     * @param tokensIntoLiquidity 添加到流动性的代币数量
     */
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiquidity
    );

    /**
     * @dev 事件：税收分配完成
     * @param reflectionPortion 反射税部分
     * @param liquidityPortion 流动性税部分
     * @param burnPortion 销毁税部分
     * @param marketingPortion 营销税部分
     */
    event TaxesTaken(
        uint256 reflectionPortion,
        uint256 liquidityPortion,
        uint256 burnPortion,
        uint256 marketingPortion
    );

    /**
     * @dev 事件：税收比例更新
     * @param reflectionBP 反射税基点
     * @param liquidityBP 流动性税基点
     * @param burnBP 销毁税基点
     * @param marketingBP 营销税基点
     */
    event UpdateTaxes(
        uint16 reflectionBP,
        uint16 liquidityBP,
        uint16 burnBP,
        uint16 marketingBP
    );

    /**
     * @dev 事件：交易限制更新
     * @param maxTx 最大交易限额
     * @param maxWallet 最大钱包持有量
     * @param dailyLimit 每日交易限制基点
     */
    event UpdateLimits(uint256 maxTx, uint256 maxWallet, uint16 dailyLimit);

    /**
     * @dev 事件：账户从奖励中排除
     * @param account 被排除的账户地址
     */
    event ExcludeFromRewardEvent(address account);

    /**
     * @dev 事件：账户重新包含进奖励
     * @param account 被包含的账户地址
     */
    event IncludeInRewardEvent(address account);

    /**
     * @dev 事件：账户手续费豁免状态更新
     * @param account 相关账户地址
     * @param excluded 是否被排除在手续费之外
     */
    event ExcludeFromFeeEvent(address account, bool excluded);

    /**
     * @dev 事件：账户白名单状态更新
     * @param account 相关账户地址
     * @param whitelisted 是否加入白名单
     */
    event WhitelistEvent(address account, bool whitelisted);

    /**
     * @dev 事件：账户黑名单状态更新
     * @param account 相关账户地址
     * @param blacklisted 是否加入黑名单
     */
    event BlacklistEvent(address account, bool blacklisted);

    /**
     * @dev 事件：交易启用状态更新
     * @param enabled 交易是否启用
     */
    event TradingEnabledEvent(bool enabled);

    /**
     * @dev 合约构造函数，初始化Nemo代币合约
     * @param router_ Uniswap路由合约地址
     * @param marketingWallet_ 营销钱包地址
     */
    constructor(
        address router_,
        address marketingWallet_
    ) ERC20("Nemo", "NMC") Ownable(msg.sender) {
        require(router_ != address(0), "zero router");
        require(marketingWallet_ != address(0), "zero marketing");

        uniswapRouter = IUniswapV2Router02(router_);
        address weth = uniswapRouter.WETH();
        // 通过工厂合约获取当前合约与WETH的交易对地址
        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).getPair(
            address(this),
            weth
        );
        if (uniswapPair == address(0)) {
            uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).createPair(
                    address(this),
                    weth
                );
        }

        marketingWallet = marketingWallet_;

        // 初始化代币总供应量和反射总量 10万枚
        _tTotal = 100000 * (10 ** decimals()); // 示例初始供应量
        /**
         * @dev 计算总反射金额
         *
         * 此函数通过从最大值中减去最大值对总代币数取模的结果，
         * 来计算反射机制中的总反射金额。这样可以确保_rTotal
         * 是_tTotal的整数倍，避免精度损失。
         *
         * @param _tTotal 总代币供应量
         * @param MAX 最大值常量
         * @return _rTotal 计算后的总反射金额
         */
        _rTotal = (MAX - (MAX % _tTotal));
        _rOwned[msg.sender] = _rTotal; // 初始所有者拥有全部反射代币

        // 设置默认参数
        //设置流动性添加阈值为总供应量的0.005%
        numTokensSellToAddToLiquidity = _tTotal / 20000; // 0.005% -5
        //设置单笔交易限额为总供应量的0.1%
        maxTxAmount = _tTotal / 1000; // 0.1% -100
        //设置单个钱包持仓上限为总供应量的1%
        maxWalletAmount = _tTotal / 100; // 1%  - 1000

        //将部署者、合约自身和营销钱包排除在交易费用之外
        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[marketingWallet] = true;

        //将部署者排除在奖励分配机制之外
        isExcludedFromReward[msg.sender] = true;
        _tOwned[msg.sender] = tokenFromReflection(_rOwned[msg.sender]);
        _excluded.push(msg.sender);

        //将部署者加入交易白名单
        isWhitelisted[msg.sender] = true;

        emit Transfer(address(0), msg.sender, _tTotal);
    }

    /**
     * @dev 修饰符，用于锁定流动性添加和代币兑换操作，防止重入攻击
     * 该修饰符通过设置标志位来确保在执行关键操作时不会被其他调用中断
     */
    modifier lockTheSwap() {
        // 设置交换和流动性添加状态为true，锁定操作
        inSwapAndLiquify = true;
        _;
        // 操作完成后，将状态重置为false，解锁操作
        inSwapAndLiquify = false;
    }

    // -------------------------
    // ERC20-compatible views/mutative (override OZ) using our bookkeeping
    // -------------------------
    /**
     * @dev 获取代币的总供应量 （重写了ERC20的totalSupply函数）
     * @return uint256 返回代币的总供应量
     */
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    /**
     * @dev 查询指定账户的代币余额
     * @param account 要查询余额的账户地址
     * @return 返回该账户持有的代币数量
     */
    function balanceOf(address account) public view override returns (uint256) {
        //如果账户被排除在奖励机制外，直接返回其持有的代币数量_tOwned[account]
        if (isExcludedFromReward[account]) return _tOwned[account];
        //否则通过tokenFromReflection函数将反射余额_rOwned[account]转换为实际代币余额返回
        return tokenFromReflection(_rOwned[account]);
    }

    /**
     * @dev 查询指定所有者对指定使用者的代币授权额度 （重写了ERC20的allowance函数）
     * @param owner_ 授权额度的所有者地址
     * @param spender 被授权使用的地址
     * @return 返回授权额度数量
     */
    function allowance(
        address owner_,
        address spender
    ) public view override returns (uint256) {
        return _allowancesCustom[owner_][spender];
    }

    /**
     * @dev 授权 spender 能够代表调用者花费指定数量的代币
     * @param spender 被授权的地址，可以代表调用者花费代币
     * @param amount 授权花费的代币数量
     * @return 始终返回 true，表示授权操作成功
     */
    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        // 执行自定义授权逻辑，设置 spender 对 msg.sender 代币的授权额度
        _approveCustom(msg.sender, spender, amount);
        return true;
    }

    /**
     * @dev 转账代币给指定地址 （重写了ERC20的transfer函数）
     * @param to 接收代币的地址
     * @param amount 要转账的代币数量
     * @return 始终返回 true，表示转账操作成功
     */
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        // 执行自定义转账逻辑，将 amount 数量的代币从 msg.sender 转账到 to 地址
        _transferCustom(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev 从指定地址转移代币到目标地址
     * @param from 发送代币的地址
     * @param to 接收代币的地址
     * @param amount 转移的代币数量
     * @return bool 转移是否成功
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        // 检查调用者是否有足够的授权额度
        uint256 currentAllowance = _allowancesCustom[from][msg.sender];
        require(
            currentAllowance >= amount,
            "ERC20: transfer amount exceeds allowance"
        );
        // 更新授权额度，扣除已使用的额度
        _approveCustom(from, msg.sender, currentAllowance - amount);
        // 执行代币转移操作
        _transferCustom(from, to, amount);
        return true;
    }

    /**
     * @dev 批准spender从owner_账户中提取指定数量的代币
     * @param owner_ 授权方地址，不能为零地址
     * @param spender 被授权方地址，不能为零地址
     * @param amount 授权的代币数量
     */
    function _approveCustom(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        require(owner_ != address(0) && spender != address(0), "approve zero");
        _allowancesCustom[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // -------------------------
    // Reflection helpers
    // -------------------------
    /**
     * @dev 将反射代币数量转换为实际代币数量
     * @param rAmount 反射代币数量
     * @return 实际代币数量
     */
    function tokenFromReflection(
        uint256 rAmount
    ) public view returns (uint256) {
        require(rAmount <= _rTotal, "rAmount > rTotal");
        uint256 rate = _getRate();
        return rAmount / rate;
    }

    /**
     * @dev 获取当前汇率（反射代币与实际代币的比率）
     * @return 汇率值
     */
    function _getRate() internal view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    /**
     * @dev 计算当前的代币供应量，排除特定地址的余额
     * @return rSupply 当前反射代币供应量
     * @return tSupply 当前实际代币供应量
     */
    function _getCurrentSupply()
        internal
        view
        returns (uint256 rSupply, uint256 tSupply)
    {
        // 初始化供应量为总供应量
        rSupply = _rTotal;
        tSupply = _tTotal;

        // 遍历所有被排除的地址，从总供应量中减去这些地址的余额
        for (uint256 i = 0; i < _excluded.length; i++) {
            address ex = _excluded[i];
            uint256 r = _rOwned[ex];
            uint256 t = _tOwned[ex];
            // 如果某个地址的余额异常，则返回总供应量
            if (r > rSupply || t > tSupply) return (_rTotal, _tTotal);
            rSupply -= r;
            tSupply -= t;
        }

        // 检查供应量是否合理，如果不合理则返回总供应量
        if (rSupply < _rTotal / _tTotal) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    // -------------------------
    // Admin controls
    // -------------------------
    /**
     * @dev 设置各种税收比例
     * @param reflectionBP 反射税基点
     * @param liquidityBP 流动性税基点
     * @param burnBP 销毁税基点
     * @param marketingBP 营销税基点
     */
    function setTaxes(
        uint16 reflectionBP,
        uint16 liquidityBP,
        uint16 burnBP,
        uint16 marketingBP
    ) external onlyOwner {
        // 计算总税率并验证是否超过最大限制
        uint16 total = reflectionBP + liquidityBP + burnBP + marketingBP;
        require(total <= MAX_TOTAL_TAX_BP, "tax too high");
        reflectionTaxBP = reflectionBP;
        liquidityTaxBP = liquidityBP;
        burnTaxBP = burnBP;
        marketingTaxBP = marketingBP;
        emit UpdateTaxes(reflectionBP, liquidityBP, burnBP, marketingBP);
    }

    /**
     * @dev 设置交易限制参数
     * @param maxTx_ 单笔最大交易数量限制
     * @param maxWallet_ 单个钱包最大持有数量限制
     * @param dailyLimit_ 每日交易次数限制
     */
    function setLimits(
        uint256 maxTx_,
        uint256 maxWallet_,
        uint16 dailyLimit_
    ) external onlyOwner {
        // 更新最大交易数量限制
        maxTxAmount = maxTx_;
        // 更新最大钱包持有量限制
        maxWalletAmount = maxWallet_;
        // 更新每日交易限制
        dailyTxLimit = dailyLimit_;
        // 触发限制更新事件
        emit UpdateLimits(maxTx_, maxWallet_, dailyLimit_);
    }

    /**
     * @dev 设置添加到流动性池的代币销售数量
     * @param numTokens 要添加到流动性的代币数量
     */
    function setNumTokensSellToAddToLiquidity(
        uint256 numTokens
    ) external onlyOwner {
        numTokensSellToAddToLiquidity = numTokens;
    }

    /**
     * @dev 设置Uniswap路由器地址
     * @param router_ Uniswap路由器合约地址
     */
    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "zero router");
        uniswapRouter = IUniswapV2Router02(router_);
    }

    /**
     * @dev 设置营销钱包地址
     * @param wallet 营销钱包地址
     */
    function setMarketingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "zero marketing");
        marketingWallet = wallet;
    }

    /**
     * @dev 设置账户是否免除手续费
     * @param account 目标账户地址
     * @param excluded 是否免除手续费(true为免除，false为不免除)
     */
    function setExcludeFromFee(
        address account,
        bool excluded
    ) external onlyOwner {
        // 更新账户的手续费免除状态
        isExcludedFromFee[account] = excluded;
        emit ExcludeFromFeeEvent(account, excluded);
    }

    /**
     * @dev 设置账户是否加入白名单
     * @param account 目标账户地址
     * @param whitelisted 是否加入白名单(true为加入，false为移除)
     */
    function setWhitelist(
        address account,
        bool whitelisted
    ) external onlyOwner {
        // 更新账户的白名单状态
        isWhitelisted[account] = whitelisted;
        emit WhitelistEvent(account, whitelisted);
    }

    /**
     * @dev 设置账户是否加入黑名单
     * @param account 目标账户地址
     * @param blacklisted 是否加入黑名单(true为加入，false为移除)
     */
    function setBlacklist(
        address account,
        bool blacklisted
    ) external onlyOwner {
        // 更新账户的黑名单状态
        isBlacklisted[account] = blacklisted;
        emit BlacklistEvent(account, blacklisted);
    }

    /**
     * @dev 启用交易功能
     */
    function enableTrading() external onlyOwner {
        // 设置交易启用标志为true并触发事件
        tradingEnabled = true;
        emit TradingEnabledEvent(true);
    }

    /**
     * @dev 设置是否启用swap和流动性添加功能
     * @param enabled 是否启用(true为启用，false为禁用)
     */
    function setSwapAndLiquifyEnabled(bool enabled) external onlyOwner {
        swapAndLiquifyEnabled = enabled;
    }

    // Exclude/include from reflection rewards
    /**
     * @dev 将指定账户从奖励分配中排除
     * @param account 需要被排除的账户地址
     */
    function excludeFromReward(address account) external onlyOwner {
        require(!isExcludedFromReward[account], "already excluded");
        // 如果账户持有代币，则将其反射余额转换为实际代币余额
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        // 标记账户为已排除状态，并加入排除列表
        isExcludedFromReward[account] = true;
        _excluded.push(account);
        emit ExcludeFromRewardEvent(account);
    }

    /**
     * @dev 将账户重新包含到奖励分配中
     * @param account 要包含的账户地址
     *
     * 此函数只能由合约所有者调用，用于将之前被排除奖励的账户重新加入奖励分配机制。
     * 函数会从排除列表中移除该账户，并更新相关状态变量。
     */
    function includeInReward(address account) external onlyOwner {
        require(isExcludedFromReward[account], "not excluded");
        // 从排除数组中移除指定账户
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _excluded.pop();
                break;
            }
        }
        // 重置账户的代币余额并更新排除状态
        _tOwned[account] = 0;
        isExcludedFromReward[account] = false;
        emit IncludeInRewardEvent(account);
    }

    // -------------------------
    // Core transfer logic (uses reflection bookkeeping)
    // -------------------------
    /**
     * @dev 内部转账函数，处理代币的自定义转账逻辑
     * @param from 转出地址
     * @param to 转入地址
     * @param tAmount 转账金额
     */
    function _transferCustom(
        address from,
        address to,
        uint256 tAmount
    ) internal {
        // 基本验证：检查地址和金额
        require(from != address(0) && to != address(0), "zero addr");
        require(tAmount > 0, "zero amount");
        require(!isBlacklisted[from] && !isBlacklisted[to], "blacklisted");

        // 如果交易未启用，只有白名单地址可以进行交易
        if (!tradingEnabled) {
            require(
                isWhitelisted[from] || isWhitelisted[to],
                "trading disabled"
            );
        }

        // limits
        // 交易限制检查：非免手续费地址需要遵守交易限额
        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            require(tAmount <= maxTxAmount, "exceeds maxTx"); //单笔交易额度限制
            if (to != uniswapPair) {
                //交易后账户最大持币量限制
                require(
                    balanceOf(to) + tAmount <= maxWalletAmount,
                    "exceeds max wallet"
                );
            }
            //获取当前天数，用于交易限额统计
            uint256 day = block.timestamp / 1 days;
            //检查交易限制：验证发送方当日交易次数是否超过限制
            require(dailyTxCount[from][day] < dailyTxLimit, "daily tx limit");
            //更新计数器：如果未超限，则增加当日交易计数
            dailyTxCount[from][day] += 1;
        }

        // auto swap and liquify if threshold reached (not during buy)
        // 获取合约自身的代币余额
        uint256 contractTokenBalance = balanceOf(address(this));
        // 检查合约余额是否超过最低销售阈值
        bool overMin = contractTokenBalance >= numTokensSellToAddToLiquidity;
        // 当满足以下条件时执行流动性和交换操作：
        // 1. 合约代币余额超过最低销售阈值
        // 2. 当前不在交换和流动性添加过程中
        // 3. 交换和流动性功能已启用
        // 4. 交易发起方不是Uniswap交易对合约
        if (
            overMin &&
            !inSwapAndLiquify &&
            swapAndLiquifyEnabled &&
            from != uniswapPair
        ) {
            swapAndLiquify(numTokensSellToAddToLiquidity);
        }
        // 根据发送方和接收方是否被免除费用来确定是否收取交易费用，并执行代币转账
        // takeFee: 是否收取手续费的标志位
        bool takeFee = !(isExcludedFromFee[from] || isExcludedFromFee[to]);
        _tokenTransfer(from, to, tAmount, takeFee);
    }

    /**
     * @dev 内部函数，用于执行代币转账操作，并根据税率计算并分配各种税费（如反射、流动性、销毁、营销）
     * @param sender 发送方地址
     * @param recipient 接收方地址
     * @param tAmount 转账的代币数量（税前）
     * @param takeFee 是否收取税费
     */
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee
    ) internal {
        // compute tax partitions
        uint256 tReflection = 0;
        uint256 tLiquidity = 0;
        uint256 tBurn = 0;
        uint256 tMarketing = 0;

        uint256 totalTaxBP = reflectionTaxBP +
            liquidityTaxBP +
            burnTaxBP +
            marketingTaxBP;
        if (takeFee && totalTaxBP > 0) {
            tReflection = (tAmount * reflectionTaxBP) / 10000;
            tLiquidity = (tAmount * liquidityTaxBP) / 10000;
            tBurn = (tAmount * burnTaxBP) / 10000;
            tMarketing = (tAmount * marketingTaxBP) / 10000;
        }

        uint256 tTransferAmount = tAmount -
            (tReflection + tLiquidity + tBurn + tMarketing);
        //获取转换汇率
        uint256 rate = _getRate();
        //将各项金额从交易单位转换为反射单位
        uint256 rAmount = tAmount * rate;
        uint256 rTransferAmount = tTransferAmount * rate;
        uint256 rReflection = tReflection * rate;
        uint256 rLiquidity = tLiquidity * rate;
        uint256 rBurn = tBurn * rate;
        uint256 rMarketing = tMarketing * rate;

        // update sender r/t balances
        // 更新发送方的反射/税务余额
        // 对于排除在奖励之外的账户，同时更新tOwned和rOwned余额
        // 对于普通账户，只更新rOwned余额
        if (isExcludedFromReward[sender]) {
            _tOwned[sender] -= tAmount;
            _rOwned[sender] -= rAmount;
        } else {
            _rOwned[sender] -= rAmount;
        }

        // update recipient r/t balances
        // 更新接收方的反射/税务余额
        // 对于排除在奖励之外的账户，同时更新tOwned和rOwned余额
        // 对于普通账户，只更新rOwned余额
        if (isExcludedFromReward[recipient]) {
            _tOwned[recipient] += tTransferAmount;
            _rOwned[recipient] += rTransferAmount;
        } else {
            _rOwned[recipient] += rTransferAmount;
        }

        // apply reflection // 应用反射机制，将交易费用分配给所有持币者
        if (tReflection > 0) {
            _reflectFee(rReflection);
        }

        // take liquidity & marketing into contract
        // 如果流动性费用与营销费用之和大于0，则处理费用分配
        if (tLiquidity + tMarketing > 0) {
            // 检查当前合约地址是否被排除在奖励机制之外
            if (isExcludedFromReward[address(this)]) {
                // 如果被排除，则直接增加合约地址的代币余额
                _tOwned[address(this)] += (tLiquidity + tMarketing);
            }
            // 增加合约地址的反射代币余额
            _rOwned[address(this)] += (rLiquidity + rMarketing);
            // 累计已收集的流动性代币数量
            liquidityTokensAccumulated += tLiquidity;
            // 累计已收集的营销代币数量
            marketingTokensAccumulated += tMarketing;
        }

        // burn
        // 处理代币销毁逻辑
        // 如果销毁代币数量大于0
        if (tBurn > 0) {
            // 检查销毁地址是否被排除在奖励机制之外
            if (isExcludedFromReward[BURN_ADDRESS]) {
                // 如果被排除，则直接增加销毁地址的代币余额
                _tOwned[BURN_ADDRESS] += tBurn;
            }
            // 增加销毁地址的反射代币余额
            _rOwned[BURN_ADDRESS] += rBurn;
        }

        emit Transfer(sender, recipient, tTransferAmount);
        emit TaxesTaken(tReflection, tLiquidity, tBurn, tMarketing);
    }

    /**
     * @dev 反射费用处理函数
     * @param rFee 反射费用金额
     */
    function _reflectFee(uint256 rFee /*, uint256 tFee*/) internal {
        _rTotal -= rFee;
        // Note: tFee is informational; totalSupply view remains _tTotal.
    }

    // -------------------------
    // swap and liquify
    // -------------------------
    /**
     * @dev 将代币兑换为ETH并添加流动性，同时处理营销代币的兑换
     * @param tokens 需要用于流动性的代币数量
     *
     * 函数执行流程：
     * 1. 将传入的代币数量分为两半
     * 2. 将第一半代币兑换为ETH
     * 3. 使用兑换得到的ETH和第二半代币添加流动性
     * 4. 如果有累积的营销代币，则将其兑换为ETH并发送到营销钱包
     * 5. 更新流动性代币累积计数器
     *
     * 注意：此函数只能在获得lockTheSwap锁的情况下调用
     */
    function swapAndLiquify(uint256 tokens) private lockTheSwap {
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;
        uint256 initialBalance = address(this).balance;
        //授权代币给Uniswap路由器合约
        _approveToken(address(this), address(uniswapRouter), half);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        /**
         * @dev 通过Uniswap路由器将精确数量的代币兑换为ETH，支持在转账时收取费用的代币
         * @param amountIn 要兑换的代币数量
         * @param amountOutMin 最小期望获得的ETH数量，设置为0表示无最小限制
         * @param path 兑换路径数组，指定代币兑换的路径
         * @param to 接收ETH的地址
         * @param deadline 交易截止时间戳，超过此时间交易将被拒绝
         */
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half,
            0,
            path,
            address(this),
            block.timestamp
        );
        //计算合约当前余额与初始余额的差值，得到新增的余额数量。
        uint256 newBalance = address(this).balance - initialBalance;

        //将当前合约(address(this))持有的代币授权给Uniswap路由器合约使用 为后续在Uniswap上进行代币交换或添加流动性做准备
        _approveToken(address(this), address(uniswapRouter), otherHalf);
        /**
         * @dev 向Uniswap路由器添加流动性，将当前合约的代币与ETH配对添加到流动性池中
         * @param address(this) 流动性提供者的地址（当前合约地址）
         * @param otherHalf 添加到流动性的代币数量
         * @param 0 最小期望获得的代币数量（滑点保护，设为0表示无限制）
         * @param 0 最小期望获得的ETH数量（滑点保护，设为0表示无限制）
         * @param owner() 流动性代币接收者的地址，建议发送到时间锁或多签钱包以提高安全性
         * @param block.timestamp 交易截止时间戳，超过此时间交易将被撤销（立即执行 确保交易尽快完成 避免价格滑点）
         */
        uniswapRouter.addLiquidityETH{value: newBalance}(
            address(this),
            otherHalf,
            0,
            0,
            owner(), // recommend to send to timelock/multisig
            block.timestamp
        );
        // marketing swap
        /**
         * @dev 将累积的营销代币兑换为ETH并发送到营销钱包
         * 此函数会检查是否有累积的营销代币，如果有则通过Uniswap路由进行代币到ETH的兑换
         */
        if (marketingTokensAccumulated > 0) {
            uint256 m = marketingTokensAccumulated;
            marketingTokensAccumulated = 0;
            _approveToken(address(this), address(uniswapRouter), m);
            uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                m,
                0,
                path,
                marketingWallet,
                block.timestamp
            );
        }
        /**
         * @dev 从累积的流动性代币中扣除指定数量的代币
         * @param tokens 需要扣除的代币数量
         *
         * 该函数块用于处理流动性代币的扣减逻辑：
         * - 当累积的代币数量足够时，直接扣减相应数量
         * - 当累积的代币数量不足时，将累积数量清零
         */
        if (liquidityTokensAccumulated >= tokens) {
            liquidityTokensAccumulated -= tokens;
        } else {
            liquidityTokensAccumulated = 0;
        }

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    // approve helper for router: uses our internal allowance mapping and emits Approval for compatibility
    /**
     * @dev 批准代币授权额度
     * @param owner_ 授权人地址
     * @param spender 被授权人地址
     * @param amount 授权额度
     */
    function _approveToken(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        // 更新授权额度映射表
        _allowancesCustom[owner_][spender] = amount;
        // 触发授权事件
        emit Approval(owner_, spender, amount);
    }

    // -------------------------
    // Rescue & receive
    // -------------------------
    /**
     * @dev 提取合约中的ETH资金
     * @param amount 提取的ETH数量
     */
    function rescueETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    /**
     * @dev 提取合约中的ERC20代币资金
     * @param token ERC20代币合约地址
     * @param amount 提取的代币数量
     */
    function rescueERC20(address token, uint256 amount) external onlyOwner {
        //调用代币合约的transfer方法转移代币
        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                msg.sender,
                amount
            )
        );
        require(success, "transfer failed");
    }

    // 接收ETH转账的回调函数
    receive() external payable {}
}
