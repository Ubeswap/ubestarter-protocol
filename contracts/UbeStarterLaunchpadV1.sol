// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import { Clones } from '@openzeppelin/contracts/proxy/Clones.sol';
import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { ERC20Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { INonfungiblePositionManager } from './interfaces/uniswap-v3/INonfungiblePositionManager.sol';
import { TickMath } from './libraries/TickMath.sol';
import { QuoteLibrary } from './libraries/QuoteLibrary.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { IERC20Metadata } from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import { IInitializableImplementation } from './interfaces/IInitializableImplementation.sol';
import { IERC721Receiver } from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import { IUniswapV3Pool } from './interfaces/uniswap-v3/IUniswapV3Pool.sol';
import { IUniswapV3Factory } from './interfaces/uniswap-v3/IUniswapV3Factory.sol';
import { Strings } from '@openzeppelin/contracts/utils/Strings.sol';

contract UbeStarterLaunchpadV1 is
    Initializable,
    IInitializableImplementation,
    ERC20Upgradeable,
    ReentrancyGuard,
    IERC721Receiver
{
    /*
       Pending --> Active --> Succeeded --> Done
                         \
                        Failed
    */
    enum LaunchpadStatus {
        Pending, // token sale is not started
        Active, // token sale is active
        Succeeded, // token sale succeeded with softCap or hardCap
        Done, // token sale succeeded and liquidity is created
        Failed, // softCap could not be reached and token sale ended
        Canceled
    }

    address public factory;
    LaunchpadParams private params;
    string public infoCID;
    uint256 public participantCount;
    uint256 public buyCount;
    uint256 public totalRaisedAsQuote;
    uint256 public liquidityTokenId;
    mapping(address => uint256) public participantToQuoteAmount;
    mapping(address => uint256) public releasedAmounts;
    uint256 public totalReleased;
    string public cancelReason;

    uint256 private constant MIN_START_DELAY = 1 hours; // 3 days
    uint256 private constant MAX_START_DELAY = 10 days;
    uint256 private constant MIN_LAUNCHPAD_DURATION = 1 hours; // 1 days
    uint256 private constant MAX_LAUNCHPAD_DURATION = 7 days;
    uint256 private constant INFO_CHANGE_DEADLINE = 1 hours; // 1 days
    uint256 private constant MAX_CLIFF = 30 days;
    int24 private constant MIN_TICK_RANGE = 9000;

    INonfungiblePositionManager public immutable nftPositionManager;
    IUniswapV3Pool public pool;

    uint8 private tokenDecimals;
    bool private isCanceled = false;

    event TokenBought(address account, uint256 quoteTokenAmount, bytes disclaimerSignature);
    event UserClaimed(address account, uint256 tokenAmount);
    event OwnerClaimed(uint256 tokenAmount, uint256 quoteTokenAmount);
    event UserRefunded(address account, uint256 quoteTokenAmount);
    event OwnerRefunded(uint256 tokenAmount);
    event Canceled(address canceler, string reason);
    event InfoCIDChanged(string newCID);
    event LiquidityCreated(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event LiquidityUnlocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _nftPositionManager) {
        _disableInitializers();
        nftPositionManager = INonfungiblePositionManager(_nftPositionManager);
    }

    function initialize(
        LaunchpadParams memory _params,
        bytes memory,
        string memory _infoCID,
        string memory _tokenSymbol,
        uint8 _tokenDecimals
    ) public initializer returns (uint256 tokenAmount) {
        _validateParams(_params);
        __ERC20_init(
            string.concat('UbeStarter Locked ', _tokenSymbol),
            string.concat('l-', _tokenSymbol)
        );
        tokenDecimals = _tokenDecimals;
        params = _params;
        infoCID = _infoCID;
        factory = msg.sender;
        pool = _createPoolIfNot();

        uint256 sellAmount = _calculateSoldAmount(params.hardCapAsQuote);
        uint256 liqQuoteAmount = (params.hardCapAsQuote * params.liquidityRate) / 100_000;
        uint256 liqTokenAmount = QuoteLibrary.getQuoteAtTick(
            params.priceTick,
            uint128(liqQuoteAmount),
            params.quoteToken,
            params.token
        );
        return sellAmount + liqTokenAmount;
    }

    function getParams() public view returns (LaunchpadParams memory) {
        return params;
    }

    function getStatus() public view returns (LaunchpadStatus) {
        if (isCanceled) {
            return LaunchpadStatus.Canceled;
        }
        if (liquidityTokenId > 0) {
            return LaunchpadStatus.Done;
        }
        if (block.timestamp < uint256(params.startDate)) {
            return LaunchpadStatus.Pending;
        }
        if (block.timestamp >= uint256(params.endDate)) {
            if (totalRaisedAsQuote >= params.softCapAsQuote) {
                return LaunchpadStatus.Succeeded;
            } else {
                return LaunchpadStatus.Failed;
            }
        }
        if (totalRaisedAsQuote >= params.hardCapAsQuote) {
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
        cancelReason = reason;
        emit Canceled(msg.sender, reason);
    }

    // User buys token when launchpad is active
    function buy(uint256 _quoteTokenAmount, bytes memory disclaimerSignature) public nonReentrant {
        require(getStatus() == LaunchpadStatus.Active, 'Token sale is not active');
        require(params.owner != msg.sender, 'owner can not buy');
        _buy(_quoteTokenAmount);
        emit TokenBought(msg.sender, _quoteTokenAmount, disclaimerSignature);
    }

    // User claim their released token after launchpad succeeded.
    // This function can be called multiple times because of vesting.
    function userClaim() public nonReentrant {
        require(getStatus() == LaunchpadStatus.Done, 'status is not done');

        uint256 releasable = getParticipantUnclaimedAmount(msg.sender);
        require(releasable > 0, 'No releasable amount');

        releasedAmounts[msg.sender] += releasable;
        totalReleased += releasable;
        SafeERC20.safeTransferFrom(IERC20(params.token), address(this), msg.sender, releasable);
        emit UserClaimed(msg.sender, releasable);
    }

    // Owner claim raised quote tokens and remaining tokens after liquidity creation.
    // This function can be called once.
    function ownerClaim() public nonReentrant {
        require(msg.sender == params.owner, 'Only owner');
        require(getStatus() == LaunchpadStatus.Done, 'status is not done');

        IERC20 quoteToken = IERC20(params.quoteToken);
        uint256 quoteTokenAmoun = quoteToken.balanceOf(address(this));
        IERC20 token = IERC20(params.token);
        uint256 tokenAmount = token.balanceOf(address(this)) - totalSupply();
        SafeERC20.safeTransferFrom(quoteToken, address(this), msg.sender, quoteTokenAmoun);
        SafeERC20.safeTransferFrom(token, address(this), msg.sender, tokenAmount);
        emit OwnerClaimed(tokenAmount, quoteTokenAmoun);
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
    function ownerRefund() public nonReentrant {
        require(msg.sender == params.owner, 'Only owner');
        LaunchpadStatus status = getStatus();
        require(
            status == LaunchpadStatus.Failed || status == LaunchpadStatus.Canceled,
            'token sale not failed'
        );

        IERC20 token = IERC20(params.token);
        uint256 amount = token.balanceOf(address(this));
        SafeERC20.safeTransferFrom(token, address(this), msg.sender, amount);
        emit OwnerRefunded(amount);
    }

    function createLiquidity() public nonReentrant {
        require(getStatus() == LaunchpadStatus.Succeeded, 'token sale not succeeded');
        require(liquidityTokenId == 0, 'liquidity already created');
        if (block.timestamp < params.endDate) {
            require(msg.sender == params.owner, 'Only owner');
        }
        _createLiquidity();
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
        return _calculateSoldAmount(participantToQuoteAmount[participant]);
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
        int24 tickSpacing = IUniswapV3Factory(nftPositionManager.factory()).feeAmountTickSpacing(
            p.liquidityFee
        );
        require(tickSpacing > 0, 'invalid liquidityFee');
        require(p.tickLower % tickSpacing == 0, 'TLS');
        require(p.tickUpper % tickSpacing == 0, 'TUS');
        require(p.priceTick % tickSpacing == 0, 'PTS');
        require(p.tickLower < p.priceTick && p.tickUpper > p.priceTick, 'TLU');
        require(p.tickLower >= TickMath.MIN_TICK, 'TLM');
        require(p.tickUpper <= TickMath.MAX_TICK, 'TUM');
        require((p.tickUpper - p.tickLower) > MIN_TICK_RANGE, 'invalid tick range');

        require(p.lockDuration > 0, 'invalid lock duration');
    }

    function _buy(uint256 _quoteTokenAmount) internal {
        if ((totalRaisedAsQuote + _quoteTokenAmount) > params.hardCapAsQuote) {
            _quoteTokenAmount = params.hardCapAsQuote - totalRaisedAsQuote;
        }
        uint256 oldBuyAmount = participantToQuoteAmount[msg.sender];
        if (oldBuyAmount == 0) {
            participantCount++;
        }
        buyCount++;
        participantToQuoteAmount[msg.sender] += _quoteTokenAmount;
        totalRaisedAsQuote += _quoteTokenAmount;
        IERC20(params.quoteToken).transferFrom(msg.sender, address(this), _quoteTokenAmount);
    }

    function _createPoolIfNot() internal returns (IUniswapV3Pool poolContract) {
        address token0 = params.token;
        address token1 = params.quoteToken;
        if (token0 >= token1) {
            (token0, token1) = (token1, token0);
        }
        poolContract = IUniswapV3Pool(
            nftPositionManager.createAndInitializePoolIfNecessary(
                token0,
                token1,
                params.liquidityFee,
                TickMath.getSqrtRatioAtTick(params.priceTick)
            )
        );
        (, int24 tick, , , , , ) = poolContract.slot0();
        require(
            tick > (params.priceTick - 100) && tick < (params.priceTick + 100),
            'invalid pool price'
        );
    }

    function _createLiquidity() internal {
        (, int24 tick, , , , , ) = pool.slot0();
        require(
            tick > (params.priceTick - 100) && tick < (params.priceTick + 100),
            'invalid pool price'
        );

        address token0 = params.token;
        address token1 = params.quoteToken;
        uint256 token1Amount = (totalRaisedAsQuote * params.liquidityRate) / 100_000;
        uint256 token0Amount = QuoteLibrary.getQuoteAtTick(
            params.priceTick,
            uint128(token1Amount),
            token1,
            token0
        );
        if (token0 >= token1) {
            (token0, token1) = (token1, token0);
            (token0Amount, token1Amount) = (token1Amount, token0Amount);
        }

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
                amount0Min: (token0Amount * 98) / 100,
                amount1Min: (token1Amount * 98) / 100,
                recipient: address(this),
                deadline: block.timestamp + 5 minutes
            });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nftPositionManager
            .mint(mintParams);

        liquidityTokenId = tokenId;

        emit LiquidityCreated(tokenId, liquidity, amount0, amount1);
    }

    function _calculateSoldAmount(uint256 quoteTokenAmount) internal view returns (uint256) {
        uint8 quoteDecimals = IERC20Metadata(params.quoteToken).decimals();
        uint256 multiplier = tokenDecimals > quoteDecimals
            ? 10 ** (tokenDecimals - quoteDecimals)
            : 1;
        uint256 divider = quoteDecimals > tokenDecimals ? 10 ** (quoteDecimals - tokenDecimals) : 1;
        return (quoteTokenAmount * params.exchangeRate * multiplier) / (100_000 * divider);
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
        if (isCanceled) {
            return 0;
        }
        return _calculateSoldAmount(totalRaisedAsQuote) - totalReleased;
    }
    function balanceOf(address account) public view override returns (uint256) {
        if (isCanceled) {
            return 0;
        }
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

    // IERC721Receiver override
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        require(msg.sender == address(nftPositionManager), 'not a ubev3 nft');
        return this.onERC721Received.selector;
    }
}
