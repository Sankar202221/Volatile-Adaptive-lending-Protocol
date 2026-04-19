// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Deterministic mock used in unit and fuzz tests.
contract MockVolatilityOracle {
    uint256 private _vol;
    uint256 private _price;
    bool    private _shouldRevert;

    function setVolatility(uint256 vol) external { _vol = vol; }
    function setPrice(uint256 price)   external { _price = price; }
    function setShouldRevert(bool v)   external { _shouldRevert = v; }

    function getVolatility() external view returns (uint256) {
        require(!_shouldRevert, "oracle: no data");
        return _vol;
    }

    function latestPrice() external view returns (uint256) {
        require(!_shouldRevert, "oracle: no data");
        return _price;
    }
}
