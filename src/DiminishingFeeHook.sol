// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseOverrideFee, IPoolManager, PoolKey } from "@openzeppelin-uniswap-hooks/src/fee/BaseOverrideFee.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";

/**
 * @title DiminishingFeeHook
 * @notice A Uniswap V4 hook that implements a fee structure that diminishes over time.
 * @dev Fee levels change at specific time intervals after pool initialization.
 */
contract DiminishingFeeHook is BaseOverrideFee, Ownable {
    using PoolIdLibrary for PoolKey;

    error InvalidFeeStructureLengths();

    uint256[] public timeThresholds;

    uint24[] public feeTiers;

    mapping(PoolId => uint256) public poolInitTimestamps;

    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _feeTiers Array of fees in decreasing order [initialFee, tier1Fee, ..., finalFee]
     * @param _timeThresholds Array of time thresholds in minutes [0, time1, time2, ..., timeN]
     */
    constructor(
        IPoolManager _poolManager,
        uint24[] memory _feeTiers,
        uint256[] memory _timeThresholds,
        address owner
    ) BaseOverrideFee(_poolManager) Ownable(owner) {
        if (_feeTiers.length != _timeThresholds.length + 1) {
            revert InvalidFeeStructureLengths();
        }

        if (_feeTiers.length > type(uint8).max) {
            revert InvalidFeeStructureLengths();
        }

        if (_timeThresholds.length > type(uint8).max) {
            revert InvalidFeeStructureLengths();
        }

        for (uint8 i = 0; i < _feeTiers.length; i++) {
            feeTiers.push(_feeTiers[i]);
        }

        for (uint8 i = 0; i < _timeThresholds.length; i++) {
            timeThresholds.push(_timeThresholds[i] * 60);
        }
    }

    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        poolInitTimestamps[key.toId()] = block.timestamp;

        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _getPoolFee(PoolKey calldata key) internal view returns (uint24) {
        PoolId poolId = key.toId();
        uint256 initTimestamp = poolInitTimestamps[poolId];

        // Pool not initialized yet, or mapping has no record
        if (initTimestamp == 0) {
            return feeTiers[0];
        }

        uint256 timeElapsed = block.timestamp - initTimestamp;

        // Start checking from the last threshold and work backwards.
        // This is more efficient since most transactions will happen after the last threshold.
        uint256 i = timeThresholds.length;
        while (i > 0) {
            if (timeElapsed >= timeThresholds[i - 1]) {
                return feeTiers[i];
            }
            i--;
        }

        return feeTiers[0];
    }

    function _getFee(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (uint24) {
        return _getPoolFee(key);
    }

    function getFee(PoolKey calldata key) external view returns (uint256) {
        return _getPoolFee(key);
    }
}
