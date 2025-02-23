// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { MessageHashUtils } from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import { Clones } from '@openzeppelin/contracts/proxy/Clones.sol';
import { IERC20Metadata } from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { IInitializableImplementation } from './interfaces/IInitializableImplementation.sol';

contract UbestarterFactory is Ownable {
    struct LaunchpadDeployment {
        address creator;
        uint32 timestamp;
        uint32 blocknumber;
    }

    struct QuoteTokenInfo {
        uint128 minSoftCap; // quote token
        uint128 maxSoftCap; // quote token
    }

    // tokenAddress => QuoteTokenInfo
    mapping(address => QuoteTokenInfo) public quoteTokens;
    // hash => message
    mapping(bytes32 => string) public disclaimerMessages;
    // implementation => deploymentFee
    mapping(address => uint256) public implementations;
    // verifier => status
    mapping(address => bool) public verifiers;

    address public immutable feeToken;
    address constant burnAddress = 0x000000000000000000000000000000000000dEaD;

    address[] private launchpads;
    mapping(address => LaunchpadDeployment) public deploymentInfos;

    event LaunchpadDeployed(
        address indexed launchpadAddress,
        address indexed implementation,
        address creator,
        IInitializableImplementation.LaunchpadParams params,
        bytes extraParams,
        string infoCID,
        address verifier,
        bytes32 creatorDisclaimerHash,
        uint256 deploymentFee,
        bytes creatorDisclaimerSignature,
        bytes verifierSignature
    );
    event ImplementationUpdated(address indexed implementation, uint256 deploymentFee);
    event QuoteTokenUpdated(address indexed quoteToken, uint128 minSoftCap, uint128 maxSoftCap);
    event VerifierUpdated(address indexed verifier, bool status);
    event DisclaimerMessageUpdated(bytes32 indexed hash, string message);

    constructor(address initialOwner, address feeTokenAddress) Ownable(initialOwner) {
        feeToken = feeTokenAddress;
    }

    function updateImplementation(
        address implementation,
        uint256 deploymentFee
    ) external onlyOwner {
        implementations[implementation] = deploymentFee;
        emit ImplementationUpdated(implementation, deploymentFee);
    }

    function updateQuoteToken(
        address quoteToken,
        uint128 minAmount,
        uint128 maxAmount
    ) external onlyOwner {
        require((minAmount == 0 && maxAmount == 0) || (minAmount < maxAmount), 'invalid amounts');
        quoteTokens[quoteToken] = QuoteTokenInfo(minAmount, maxAmount);
        emit QuoteTokenUpdated(quoteToken, minAmount, maxAmount);
    }

    function updateVerifier(address verifier, bool status) external onlyOwner {
        verifiers[verifier] = status;
        emit VerifierUpdated(verifier, status);
    }

    function updateDisclaimerMessage(bytes32 hash, string memory message) external onlyOwner {
        require(
            bytes(message).length == 0 ||
                MessageHashUtils.toEthSignedMessageHash(bytes(message)) == hash,
            'invalid hash'
        );
        disclaimerMessages[hash] = message;
        emit DisclaimerMessageUpdated(hash, message);
    }

    function getLaunchpad(uint256 index) external view returns (address) {
        return launchpads[index];
    }
    function getLaunchpadsLength() external view returns (uint256) {
        return launchpads.length;
    }

    function cancelLaunchpad(address launchpad, string memory reason) external onlyOwner {
        require(deploymentInfos[launchpad].creator != address(0), 'invalid launchpad address');
        IInitializableImplementation(launchpad).cancel(reason);
    }

    function deployLaunchpad(
        address implementation,
        IInitializableImplementation.LaunchpadParams memory params,
        bytes memory extraParams,
        string memory infoCID,
        bytes32 creatorDisclaimerHash,
        bytes memory creatorDisclaimerSignature,
        bytes memory verifierSignature
    ) public {
        {
            // quoteToken, soft and hard cap controls
            QuoteTokenInfo memory quoteTokenInfo = quoteTokens[params.quoteToken];
            require(quoteTokenInfo.maxSoftCap > 0, 'invalid quote token');

            require(
                params.softCapAsQuote > 0 && params.softCapAsQuote <= params.hardCapAsQuote,
                'invalid hardCap'
            );
            require(
                params.softCapAsQuote >= quoteTokenInfo.minSoftCap &&
                    params.softCapAsQuote <= quoteTokenInfo.maxSoftCap,
                'invalid softCap'
            );
        }

        address verifier = _validateSignatures(
            MessageHashUtils.toEthSignedMessageHash(
                keccak256(abi.encode(params, extraParams, infoCID))
            ),
            verifierSignature,
            creatorDisclaimerHash,
            creatorDisclaimerSignature
        );

        uint256 deploymentFee = implementations[implementation];
        require(deploymentFee > 0, 'invalid implementation');

        address newContract = Clones.clone(implementation);
        {
            IERC20Metadata token = IERC20Metadata(params.token);
            uint8 tokenDecimals = token.decimals();
            require(tokenDecimals > 0, 'invalid token decimals');
            string memory tokenSymbol = token.symbol();
            require(bytes(tokenSymbol).length > 0, 'invalid token symbol');

            uint256 tokensToTransfer = IInitializableImplementation(newContract).initialize(
                params,
                extraParams,
                infoCID,
                tokenSymbol,
                tokenDecimals
            );

            launchpads.push(newContract);
            deploymentInfos[newContract] = LaunchpadDeployment(
                msg.sender,
                uint32(block.timestamp),
                uint32(block.number)
            );

            SafeERC20.safeTransferFrom(
                IERC20Metadata(feeToken),
                msg.sender,
                burnAddress,
                deploymentFee
            );

            SafeERC20.safeTransferFrom(token, msg.sender, newContract, tokensToTransfer);
        }

        emit LaunchpadDeployed(
            newContract,
            implementation,
            msg.sender,
            params,
            extraParams,
            infoCID,
            verifier,
            creatorDisclaimerHash,
            deploymentFee,
            creatorDisclaimerSignature,
            verifierSignature
        );
    }

    function _validateSignatures(
        bytes32 hash,
        bytes memory verifierSignature,
        bytes32 creatorDisclaimerHash,
        bytes memory creatorDisclaimerSignature
    ) internal view returns (address) {
        require(bytes(disclaimerMessages[creatorDisclaimerHash]).length > 0, 'invalid disclaimer');
        (address discSigner, ECDSA.RecoverError err1, ) = ECDSA.tryRecover(
            creatorDisclaimerHash,
            creatorDisclaimerSignature
        );
        require(err1 == ECDSA.RecoverError.NoError, 'ecrecover err1');
        require(discSigner == msg.sender, 'invalid creator signature');

        (address verifier, ECDSA.RecoverError err2, ) = ECDSA.tryRecover(hash, verifierSignature);
        require(err2 == ECDSA.RecoverError.NoError, 'ecrecover err2');
        require(verifiers[verifier] == true, 'invalid verifier');

        return verifier;
    }
}
