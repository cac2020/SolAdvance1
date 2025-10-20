## 一、反射（RFI）是什么，为什么用 rOwned / tOwned？

RFI 模型的核心就是这条关系：
对于未被排除账户：balanceOf(addr) = rOwned[addr] / currentRate
其中：
rOwned：账户的“反射余额”（反射体系中的内部单位）
currentRate = rSupply / tSupply：全局反射比例
tOwned：账户的“真实 token 余额”（人类看得懂的数量）
这样做的好处是，当合约分配反射收益（减少 _rTotal）时，
currentRate 会自动变化，所有账户的实际余额 (rOwned / currentRate) 就会被动增加。
👉 因此，不需要更新每个账户的余额，就能让所有持币人自动得到分红。

目标： 在每次交易中把一部分手续费「分配给所有持币人」，但不遍历所有地址（遍历会 gas 爆炸）。
RFI 的核心技巧是：把“增加每个持币者余额”的效果，通过调整一个全局比率来实现。

t = token 表示的“真实 token 单位”（用户看到的数量）。

r = reflected 表示“反射记账单位”（合约内部的高精度余额表示）。

每个账户维护 rOwned（反射余额）。对被排除（例如合约自身、burn 地址、LP、owner） 的账户还维护 tOwned（实际 token 余额）以便精确计算与外部交互。

通过维护 _rTotal（反射总量）和 _tTotal（真实总量）并让 currentRate = _rTotal / _tTotal，所有未被排除账户的实际余额等于 rOwned / currentRate。当合约“分配”反射奖励时，只要减少 _rTotal（r 总量），currentRate 会变化，进而隐式放大每个 rHeld 对应的 t 值——这就实现了“每个持币者自动收到分红”的效果，无需逐个加余额。

## 二、被排除账户为什么需要 tOwned

被排除账户是特殊的：
它们不参与反射收益分配（即反射时不希望它们的余额发生变化）。

常见的排除账户包括：

合约自身（address(this)，用于存手续费、流动性池操作）；

burn 地址（0xdead）；

某些运营钱包；

DEX pair（有些实现会排除 LP）。

问题是：
反射系统整体通过 rOwned 和 _rTotal 来调整持币者的实际余额。
如果一个地址被排除，它的 rOwned 不能随 _rTotal 的变化而改变。
否则它会错误地拿到分红。那该怎么办？

我们希望：
普通账户：自动分红 → 跟着 currentRate 变
排除账户：不分红 → 不受 currentRate 变化影响
解决办法：
排除账户直接以真实 token 计账（tOwned），不再依赖 currentRate。
所以设计上：
未排除账户：只需要 rOwned（因为余额 = r / rate）
被排除账户：必须有固定的 tOwned 记录（因为不能跟着 rate 自动变化）
但它仍然需要保留一个对应的 rOwned（用于计算总供给、反射比例）

为什么仍然要保留 rOwned？
虽然排除账户不用 rOwned 来算余额，但仍要保留它有两个原因：
* 保持账面一致性（供计算 currentRate 用）
_getCurrentSupply() 计算 currentRate 时会从 _rTotal、_tTotal 中减去被排除账户的份额：
rSupply -= rOwned[ex];
tSupply -= tOwned[ex];
这样反射比率只作用于未排除的部分。

* 防止错误反射
在转账时，我们依然要减少/增加 rOwned，否则全局 rBalance 会不平衡。

总结一句话
被排除账户有 rOwned + tOwned 是为了能固定它的真实余额、同时保证反射账本的完整性。未被排除账户只有 rOwned，因为它的真实余额是通过全局比率计算出来的。


## 二、关键变量与概念

常见命名（你会在实现里看到这些）：

_tTotal    = 总的 token（真实）供应量（例如 1e15）
_rTotal    = 反射总量 (通常 = MAX - (MAX % _tTotal))
rOwned[a]  = 地址 a 的反射余额（内部）
tOwned[a]  = 地址 a 的真实余额（仅对被排除账户维护）
_isExcludedFromReward[a] = 地址是否被排除在反射之外（例如合约、burn）
currentRate = _rTotal / _tTotal

重要关系：
对未排除地址 a：balanceOf(a) = rOwned[a] / currentRate
对排除地址 b：balanceOf(b) = tOwned[b]（并且 rOwned[b] 也会维护，但用于计算 rSupply）

注意：反射总量为什么要使用Max 一个很大的值？
因为要保持 除法运算的精度：
* 如果 _rTotal（rSupply） 是一个小数（比如和 tSupply 同量级），那么 rOwned / rate 的精度会很差；
* 当你计算分红时，由于 Solidity 是整数除法，会出现大量舍入误差；
* 这种误差在连续反射中会累积，导致反射币的总供应和持仓不再精确匹配。

将 _rTotal 设置为 接近 uint256 最大值，例如：
> uint256 private constant MAX = ~uint256(0);
  uint256 private _rTotal = (MAX - (MAX % _tTotal));

就能确保：
* rate = rTotal / tTotal 是一个很大的整数，⇒ 避免精度丢失；
* 所有乘除法都能在整数域内完成；
* 保证反射计算稳定、不会溢出或出现 0

但是也有一些问题：当反射分红是一个较小的数时，经过反射计算，舍入误差，余额几乎不会发生变化；

## 三、数学与行为（核心公式）

转换函数

rAmount = tAmount * currentRate

tAmount = rAmount / currentRate （整除时注意向下截断）

转账（无 fee 情况）
从 sender 减少 rAmount，接收方增加 rAmount。_rTotal 不变，所以 balances 按比例不变。

分配 reflection fee（tFee）

当收取 tFee（真实 token 单位）作为反射时，等价的 rFee = tFee * currentRate

通过 _rTotal -= rFee 来“分配”这笔 fee：r 总量变小，但 t 总量不变，因此 currentRate = _rTotal/_tTotal 变小 ⇒ 每个 rOwned 对应更多 t，从而所有持币者都以比例获得收益。

收集流动性 / marketing 税

这类税需要合约持有 token（以 t 单位）。实现时把对应的 r 值转入 rOwned[address(this)]（同时如果合约在排除列表里也更新 tOwned[address(this)]），并把 liquidityTokensAccumulated += tLiquidity 记录起来，之后触发 swapAndLiquify 等。

burn（销毁）

如果要永远销毁 tBurn tokens，常见做法是把它转入 0x000...dead（若 dead 在排除列表，就会被计入 tOwned[dead]），或者直接减少 _tTotal 并相应调整 _rTotal：如果选择减少 _tTotal，则必须同时减少 _rTotal 按比率（或直接把 r 值转移到 dead 并把 dead 排除以模拟销毁）。两种方式都可，但要一致且文档化。

## 四、优缺点总结

优点：

被动收益：持币即得分红，无需用户交互。

无需遍历持币者：gas 成本固定（除了 exclude 列表相关）。

设计相对简单，社区熟悉度高（SafeMoon/RFI 模式广泛采用）。

缺点 / 风险：

实现复杂：需要精确管理 r/t 关系与排除逻辑。

与某些外部合约（尤其直接读取内部 balances 的合约）不兼容。

_getCurrentSupply 在 exclude 列表很大时会影响 gas。

rounding/截断误差需测试覆盖。


## 五、总结
RFI 通过维护反射总量 _rTotal 与真实总量 _tTotal，并用一个全局比率把“分红”效果隐式地分配到每个持币者上。