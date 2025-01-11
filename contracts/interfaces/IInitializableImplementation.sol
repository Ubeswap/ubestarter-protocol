// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IInitializableImplementation {
    struct LaunchpadParams {
        address token;
        address quoteToken;
        address owner;
        // Token Sale Details
        uint32 startDate; // epoch seconds
        uint32 endDate; // epoch seconds
        uint32 exchangeRate; // x / 100_000 (tokenAmount = quoteTokenAmount * exchangeRate / 100_000)
        uint32 releaseDuration; // seconds
        uint32 releaseInterval; // seconds
        uint32 cliffDuration; // seconds
        uint32 initialReleaseRate; // x / 100_000
        uint32 cliffReleaseRate; // x / 100_000
        uint128 hardCapAsQuote; // hard cap amount as quote token
        uint128 softCapAsQuote; // soft cap amount as quote token
        // Liquidity Params
        uint24 liquidityRate; // x / 100_000 (percentage of raised tokens for liquidity)
        uint24 liquidityFee; // v3 pool fee
        int24 priceTick; // liquidity initial tick
        int24 tickLower; // liquidity tick lower
        int24 tickUpper; // liquidity tick upper
        uint32 lockDuration; // lock duration of liquidity
    }

    function initialize(
        LaunchpadParams memory params,
        bytes memory extraParams,
        string memory infoCID,
        string memory tokenSymbol,
        uint8 tokenDecimals
    ) external returns (uint256);

    function cancel(string memory reason) external;
}
