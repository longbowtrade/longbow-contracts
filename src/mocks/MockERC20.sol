// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal mintable ERC-20 with configurable decimals and an optional
///         ERC-8056-style `oraclePaused()` flag so tests/demos can emulate
///         Robinhood stock tokens (mTSLA) and USDG (6 decimals) alike.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public oraclePaused;
    uint256 public uiMultiplier = 1e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function setOraclePaused(bool paused) external {
        oraclePaused = paused;
    }

    function setUiMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function balanceOfUI(address owner) external view returns (uint256) {
        return (balanceOf[owner] * uiMultiplier) / 1e18;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}
