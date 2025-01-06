// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import { Clones } from '@openzeppelin/contracts/proxy/Clones.sol';
import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { ERC20Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { INonfungiblePositionManager } from './interfaces/uniswap-v3/INonfungiblePositionManager.sol';
import { TickMath } from './libraries/TickMath.sol';

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

enum LaunchpadStatus {
    Pending,
    Active,
    Canceled,
    Succeeded,
    Failed
}

contract UbeStarter is Initializable, ERC20Upgradeable, ReentrancyGuard {
    address public factory;
    LaunchpadParams private params;
    string private infoCID;
    uint256 public participantCount;
    uint256 public buyCount;
    uint256 public totalRaisedAsQuote;
    uint256 public liquidityTokenId;
    mapping(address => uint256) public participantToQuoteAmount;
    mapping(address => uint256) public releasedAmounts;

    uint256 private MIN_START_DELAY = 1 hours; // 3 days
    uint256 private MAX_START_DELAY = 7 days;
    uint256 private MIN_LAUNCHPAD_DURATION = 1 hours; // 1 days
    uint256 private MAX_LAUNCHPAD_DURATION = 10 days;
    uint256 private INFO_CHANGE_DEADLINE = 1 hours; // 1 days
    uint256 private MAX_CLIFF = 30 days;
    int24 private MIN_TICK_RANGE = 9000;

    INonfungiblePositionManager public nftPositionManager =
        INonfungiblePositionManager(0x897387c7B996485c3AAa85c94272Cd6C506f8c8F);

    uint8 private tokenDecimals;
    bool private isCanceled = false;
    bool private ownerPaid = false;

    event TokenBought(address account, uint256 quoteTokenAmount, bytes disclaimerSignature);
    event UserClaimed(address account, uint256 tokenAmount);
    event OwnerClaimed(uint256 quoteTokenAmount);
    event UserRefunded(address account, uint256 quoteTokenAmount);
    event OwnerRefunded(uint256 tokenAmount);
    event Canceled(address canceler, uint256 refundedTokenAmount, string reason);
    event InfoCIDChanged(string newCID);
    event LiquidityCreated(uint256 tokenId);
    event LiquidityUnlocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        LaunchpadParams memory _params,
        bytes memory,
        string memory _infoCID,
        string memory _tokenSymbol,
        uint8 _tokenDecimals
    ) public initializer {
        _validateParams(_params);
        __ERC20_init(
            string.concat('UbeStarter Locked ', _tokenSymbol),
            string.concat('l-', _tokenSymbol)
        );
        tokenDecimals = _tokenDecimals;
        params = _params;
        infoCID = _infoCID;
        factory = msg.sender;
    }

    function getParams() public view returns (LaunchpadParams memory, string memory) {
        return (params, infoCID);
    }

    function getStatus() public view returns (LaunchpadStatus) {
        if (isCanceled) {
            return LaunchpadStatus.Canceled;
        }
        if (block.timestamp < uint256(params.startDate)) {
            return LaunchpadStatus.Pending;
        }
        if (totalRaisedAsQuote >= params.hardCapAsQuote) {
            return LaunchpadStatus.Succeeded;
        }
        if (
            totalRaisedAsQuote >= params.softCapAsQuote && block.timestamp < uint256(params.endDate)
        ) {
            return LaunchpadStatus.Succeeded;
        }
        return LaunchpadStatus.Active;
    }

    function changeInfoCID(string memory _infoCID) external {
        require(msg.sender == params.owner, 'Only owner');
        require(params.startDate > (block.timestamp + INFO_CHANGE_DEADLINE));
        infoCID = _infoCID;
        emit InfoCIDChanged(_infoCID);
    }

    function cancel(string memory reason) external {
        require(msg.sender == params.owner || msg.sender == factory, 'only owner or factory');
        LaunchpadStatus status = getStatus();
        require(
            status == LaunchpadStatus.Pending ||
                (status == LaunchpadStatus.Succeeded && liquidityTokenId == 0), // in case of liquidity faliure
            'invalid status'
        );
        isCanceled = true;
        IERC20 token = IERC20(params.token);
        uint256 amount = token.balanceOf(address(this));
        ownerPaid = true;
        SafeERC20.safeTransferFrom(token, address(this), params.owner, amount);
        emit OwnerRefunded(amount);
        emit Canceled(msg.sender, amount, reason);
    }

    // User buys token when launchpad is active
    function buy(uint256 _quoteTokenAmount, bytes memory disclaimerSignature) public nonReentrant {
        require(getStatus() == LaunchpadStatus.Active, 'Token sale is not active');
        _buy(_quoteTokenAmount);
        if (getStatus() == LaunchpadStatus.Succeeded) {
            _createLiquidityIfNot();
        }
        emit TokenBought(msg.sender, _quoteTokenAmount, disclaimerSignature);
    }

    // User claim their released token after launchpad succeeded.
    // This function can be called multiple times because of vesting.
    function userClaim() public nonReentrant {
        require(getStatus() == LaunchpadStatus.Succeeded, 'token sale not succeeded');
        _createLiquidityIfNot();

        uint256 releasable = getParticipantUnclaimedAmount(msg.sender);
        require(releasable > 0, 'No releasable amount');

        releasedAmounts[msg.sender] += releasable;
        SafeERC20.safeTransferFrom(IERC20(params.token), address(this), msg.sender, releasable);
        emit UserClaimed(msg.sender, releasable);
    }

    // Owner claim total raised quote tokens after launchpad succeeded.
    // This function can be called once.
    function ownerClaim() public nonReentrant {
        require(msg.sender == params.owner, 'Only owner');
        require(ownerPaid == false, 'owner already claimed');
        require(getStatus() == LaunchpadStatus.Succeeded, 'token sale not succeeded');
        _createLiquidityIfNot();

        IERC20 quoteToken = IERC20(params.quoteToken);
        uint256 amount = quoteToken.balanceOf(address(this));
        ownerPaid = true;
        SafeERC20.safeTransferFrom(quoteToken, address(this), msg.sender, amount);
        emit OwnerClaimed(amount);
    }

    // Users get tokens back if the token sale is failed
    // This function can be called once.
    function userRefund() public nonReentrant {
        LaunchpadStatus status = getStatus();
        require(
            status == LaunchpadStatus.Failed || status == LaunchpadStatus.Canceled,
            'token sale not failed'
        );

        uint256 amount = participantToQuoteAmount[msg.sender];
        require(amount > 0, 'No refundable amount');

        participantToQuoteAmount[msg.sender] = 0;
        SafeERC20.safeTransferFrom(IERC20(params.quoteToken), address(this), msg.sender, amount);
        emit UserRefunded(msg.sender, amount);
    }

    // Owner gets tokens back if the token sale is failed
    // This function can be called once.
    function ownerRefund() public nonReentrant {
        require(msg.sender == params.owner, 'Only owner');
        require(ownerPaid == false, 'owner already refunded');
        require(getStatus() == LaunchpadStatus.Failed, 'token sale not failed');

        IERC20 token = IERC20(params.token);
        uint256 amount = token.balanceOf(address(this));
        ownerPaid = true;
        SafeERC20.safeTransferFrom(token, address(this), msg.sender, amount);
        emit OwnerRefunded(amount);
    }

    function unlockLiquidity() public nonReentrant {
        require(msg.sender == params.owner, 'Only owner');
        require(liquidityTokenId > 0, 'no liquidity');
        require(block.timestamp > (params.endDate + params.lockDuration), 'locked');
        nftPositionManager.safeTransferFrom(address(this), params.owner, liquidityTokenId);
        emit LiquidityUnlocked();
    }

    // this is the amount of tokens that the participant has bought
    function getParticipantTotalTokenAmount(address participant) public view returns (uint256) {
        return (participantToQuoteAmount[participant] * params.exchangeRate) / 100_000;
    }

    function getParticipantUnlockedAmount(
        address participant,
        uint32 timestamp
    ) public view returns (uint256) {
        uint256 totalToken = getParticipantTotalTokenAmount(participant);
        uint256 initialReleased = 0;
        if (timestamp >= params.endDate) {
            initialReleased += (totalToken * params.initialReleaseRate) / 100_000;
        }
        if (timestamp >= (params.endDate + params.cliffDuration)) {
            initialReleased += (totalToken * params.cliffReleaseRate) / 100_000;
        }
        uint256 totalLocked = totalToken - initialReleased;
        return
            _calculateUnlocked(
                totalLocked,
                timestamp,
                params.endDate + params.cliffDuration,
                params.releaseDuration,
                params.releaseInterval
            ) + initialReleased;
    }

    function getParticipantUnclaimedAmount(address participant) public view returns (uint256) {
        uint256 unlocked = getParticipantUnlockedAmount(participant, uint32(block.timestamp));
        return unlocked - releasedAmounts[participant];
    }

    // ------ Internal functions ------
    function _validateParams(LaunchpadParams memory p) internal view {
        require(p.owner != address(0), 'invalid owner');

        require(
            p.startDate >= (block.timestamp + MIN_START_DELAY) &&
                p.startDate <= (block.timestamp + MAX_START_DELAY),
            'invalid startdate'
        );

        require(
            p.endDate >= (p.startDate + MIN_LAUNCHPAD_DURATION) &&
                p.endDate <= (p.startDate + MAX_LAUNCHPAD_DURATION),
            'invalid endDate'
        );

        require(p.exchangeRate > 0, 'invalid exchangeRate');

        require(
            p.releaseInterval < p.releaseDuration &&
                p.releaseDuration % p.releaseInterval == 0 &&
                p.cliffDuration <= MAX_CLIFF &&
                p.initialReleaseRate <= 100_000 &&
                p.cliffReleaseRate <= 100_000 &&
                (p.initialReleaseRate + p.cliffReleaseRate) <= 100_000,
            'invalid release data'
        );

        require(p.liquidityRate >= 20_000 && p.liquidityRate <= 100_000, 'invalid liquidityRate');
        require(
            p.liquidityFee == 100 ||
                p.liquidityFee == 500 ||
                p.liquidityFee == 3000 ||
                p.liquidityFee == 10000,
            'invalid fee'
        );

        require(p.tickLower < p.priceTick && p.tickUpper > p.priceTick, 'TLU');
        require(p.tickLower >= TickMath.MIN_TICK, 'TLM');
        require(p.tickUpper <= TickMath.MAX_TICK, 'TUM');
        require((p.tickUpper - p.tickLower) > MIN_TICK_RANGE, 'invalid tick range');

        require(p.lockDuration > 0, 'invalid lock duration');
    }

    function _buy(uint256 _quoteTokenAmount) internal {
        require(params.owner != msg.sender, 'owner con not buy');
        uint256 oldBuyAmount = participantToQuoteAmount[msg.sender];
        uint256 totalQuoteAmount = oldBuyAmount + _quoteTokenAmount;
        if (oldBuyAmount == 0) {
            participantCount++;
        }
        participantToQuoteAmount[msg.sender] = totalQuoteAmount;
        buyCount++;
        totalRaisedAsQuote += _quoteTokenAmount;
        require(totalRaisedAsQuote <= params.hardCapAsQuote, 'hardCap exceeded');
        IERC20(params.quoteToken).transferFrom(msg.sender, address(this), _quoteTokenAmount);
    }

    function _createLiquidityIfNot() internal {
        if (liquidityTokenId == 0) {
            address token0 = params.token;
            address token1 = params.quoteToken;
            uint256 token0Amount = IERC20(params.token).balanceOf(address(this));
            uint256 token1Amount = (totalRaisedAsQuote * params.liquidityRate) / 100_000;
            if (token0 >= token1) {
                (token0, token1) = (token1, token0);
                (token0Amount, token1Amount) = (token1Amount, token0Amount);
            }
            nftPositionManager.createAndInitializePoolIfNecessary(
                token0,
                token1,
                params.liquidityFee,
                TickMath.getSqrtRatioAtTick(params.priceTick)
            );

            SafeERC20.forceApprove(IERC20(token0), address(nftPositionManager), token0Amount);
            SafeERC20.forceApprove(IERC20(token1), address(nftPositionManager), token1Amount);

            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager
                .MintParams({
                    token0: token0,
                    token1: token1,
                    fee: params.liquidityFee,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    amount0Desired: token0Amount,
                    amount1Desired: token1Amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp + 5 minutes
                });

            (uint256 tokenId, , , ) = nftPositionManager.mint(mintParams);
            liquidityTokenId = tokenId;

            emit LiquidityCreated(tokenId);
        }
    }

    function _calculateUnlocked(
        uint256 totalAllocation,
        uint32 timestamp,
        uint32 releaseStart,
        uint32 releaseDuration,
        uint32 releaseInterval
    ) internal pure returns (uint256) {
        if (timestamp < releaseStart) {
            return 0;
        } else if (timestamp > (releaseStart + releaseDuration)) {
            return totalAllocation;
        } else {
            uint256 elapsedFromStart = timestamp - releaseStart;
            uint256 vestingCount = releaseDuration / releaseInterval;
            uint256 vestingAmount = totalAllocation / vestingCount;
            uint256 passedIntervalCount = elapsedFromStart / releaseInterval;
            return passedIntervalCount * vestingAmount;
        }
    }
    // -------

    // ERC-20 overrides
    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
    function totalSupply() public view override returns (uint256) {
        return (totalRaisedAsQuote * params.exchangeRate) * 100_000;
    }
    function balanceOf(address account) public view override returns (uint256) {
        return getParticipantTotalTokenAmount(account) - releasedAmounts[account];
    }
    function transfer(address, uint256) public pure override returns (bool) {
        revert('non-transferable');
    }
    function approve(address, uint256) public pure override returns (bool) {
        revert('non-transferable');
    }
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert('non-transferable');
    }
}
