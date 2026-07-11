// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Constant-product AMM that mimics UniswapV2Router02's
///         `swapExactTokensForTokens` (0.3% fee) against internally held
///         pools. Used for forge tests and the testnet demo deployment where
///         no official V2 deployment/liquidity exists. On mainnet Longbow
///         talks to the real Router02.
contract MockV2Router {
    struct Pool {
        uint112 reserveA;
        uint112 reserveB;
    }

    // pair key: keccak(min(token), max(token))
    mapping(bytes32 => Pool) public pools;

    event LiquiditySeeded(address tokenA, address tokenB, uint256 amountA, uint256 amountB);

    function _key(address a, address b) internal pure returns (bytes32, bool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return (keccak256(abi.encodePacked(t0, t1)), a == t0);
    }

    /// @notice Pull tokens from caller and add them to the pool reserves.
    function seedLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        external
    {
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amountA), "pullA");
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amountB), "pullB");
        (bytes32 key, bool aIsT0) = _key(tokenA, tokenB);
        Pool storage p = pools[key];
        if (aIsT0) {
            p.reserveA += uint112(amountA);
            p.reserveB += uint112(amountB);
        } else {
            p.reserveA += uint112(amountB);
            p.reserveB += uint112(amountA);
        }
        emit LiquiditySeeded(tokenA, tokenB, amountA, amountB);
    }

    function getReserves(address tokenA, address tokenB)
        public
        view
        returns (uint112 reserveIn, uint112 reserveOut)
    {
        (bytes32 key, bool aIsT0) = _key(tokenA, tokenB);
        Pool storage p = pools[key];
        return aIsT0 ? (p.reserveA, p.reserveB) : (p.reserveB, p.reserveA);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint112 rIn, uint112 rOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(path.length >= 2, "INVALID_PATH");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        require(
            IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn),
            "pull failed"
        );

        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint112 rIn, uint112 rOut) = getReserves(path[i], path[i + 1]);
            uint256 out = getAmountOut(amounts[i], rIn, rOut);
            amounts[i + 1] = out;

            (bytes32 key, bool inIsT0) = _key(path[i], path[i + 1]);
            Pool storage p = pools[key];
            if (inIsT0) {
                p.reserveA += uint112(amounts[i]);
                p.reserveB -= uint112(out);
            } else {
                p.reserveB += uint112(amounts[i]);
                p.reserveA -= uint112(out);
            }
        }

        uint256 amountOut = amounts[amounts.length - 1];
        require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(IERC20(path[path.length - 1]).transfer(to, amountOut), "payout failed");
    }
}
