## 理解Uniswap V2 主要组件之间的关系
    Uniswap V2 组件	       通俗角色	                                        核心功能
    Token 合约	          菜市场里的「商品」（ETH、USDC 等）	              可交易、可转账，是兑换和流动性的核心标的。
    Factory 合约	      菜市场管理处	                                     开摊位（创建 Pair 合约）、记录摊位地址。
    Pair 合约	          具体交易摊位	                                     存两种 Token 存货、定价格、执行兑换、收手续费；发行 LP Share。
    Router 合约	          交易中介 / 导航员	                                 帮用户找摊位、算兑换比例；帮流动性提供者 “批量供货”（存入两种 Token）。
    LP Share	         「供货凭证 + 分红权」	                            1. 证明你在 Pair 摊位里有多少 “存货份额”；
                                                                           2. 凭它分摊位的手续费；
                                                                           3. 凭它赎回你存的 Token 本金 + 分红。
    用户（钱包）	       买菜的人 / 供货商	                            要么换币（买菜），要么存 Token 到 Pair （供货）拿 LP Share，后续分手续费或赎回。

总结：
* Factory 开摊位（Pair）
* Router 帮你给摊位供货（存 Token）
* Pair 给你发 LP Share 当凭证，你凭 LP Share 分摊位的手续费或赎回 Token—。
* LP Share 是 Pair 摊位发给 “供货商”（流动性提供者）的「权益凭证」，本质是特殊的 ERC20 Token，核心作用是 “证明份额、分手续费、赎回本金”。


## 测试网部署
* UniswapV2Router02	提供 swap / addLiquidity / removeLiquidity 外部接口	❌ 一般直接用官方测试网已部署的
* UniswapV2Factory	创建 Pair（交易对）	    ❌ Router 会自动调用现成 Factory
* WETH	包装 ETH，用作 ETH 交易对的 ERC20	 ❌ Router 会内置已知地址
* 最后使用 测试网已部署的UniswapV2Router02地址 部署Meme Token 合约

> 查阅UniswapV2Router02在各个网络上的部署地址：https://docs.uniswap.org/contracts/v2/reference/smart-contracts/v2-deployments