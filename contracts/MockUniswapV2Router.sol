// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function approve(address, uint256) external returns (bool);
}

contract MockUniswapV2Factory {
    mapping(bytes32 => address) public pairs;

    function getPair(address a, address b) external view returns (address) {
        return pairs[keccak256(abi.encodePacked(a, b))];
    }

    function createPair(address a, address b) external returns (address) {
        address p = address(
            uint160(uint(keccak256(abi.encodePacked(a, b, block.timestamp))))
        );
        pairs[keccak256(abi.encodePacked(a, b))] = p;
        return p;
    }
}

contract MockWETH {
    string public name = "Wrapped ETH";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    receive() external payable {}
}

contract MockUniswapV2Router {
    MockUniswapV2Factory private _factory;
    MockWETH private _weth;
    address public _factoryAddr;
    address public WETH;

    event SwapCalled(
        address indexed tokenIn,
        uint256 amountIn,
        address indexed to
    );
    event AddLiquidityCalled(
        address indexed token,
        uint256 tokenAmount,
        uint256 ethAmount,
        address indexed to
    );

    constructor() {
        _factory = new MockUniswapV2Factory();
        _weth = new MockWETH();
        _factoryAddr = address(_factory);
        WETH = address(_weth);
    }

    function factory() external view returns (address) {
        return _factoryAddr;
    }

    function WETHAddr() external view returns (address) {
        return WETH;
    }

    // supporting fee-on-transfer tokens: we'll just transfer tokens from caller to `to` or to router,
    // and forward any ETH that was sent with the call.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external {
        // path[0] = token, path[1] = WETH
        IERC20 token = IERC20(path[0]);
        // pull tokens from caller (token must approve router)
        token.transferFrom(msg.sender, address(this), amountIn);
        // For test, just emit an event and send a tiny amount of ETH to `to` to simulate swap proceeds
        uint256 fakeEth = 1e12; // tiny wei for testing
        payable(to).transfer(fakeEth);
        emit SwapCalled(path[0], amountIn, to);
    }

    // add liquidity ETH: in test we accept token approved and ETH sent, then emit event.
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address to,
        uint /*deadline*/
    )
        external
        payable
        returns (uint amountToken, uint amountETH, address liquidity)
    {
        // transfer tokens from caller (or from router caller contract)
        IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amountTokenDesired
        );
        // accept the ETH sent (msg.value)
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = address(0); // not actually minted
        emit AddLiquidityCalled(token, amountToken, amountETH, to);
    }

    // convenience functions used in tests to create pair
    function createPair(address a, address b) external returns (address) {
        return MockUniswapV2Factory(_factoryAddr).createPair(a, b);
    }

    // receive ETH for swap simulation
    receive() external payable {}
}
