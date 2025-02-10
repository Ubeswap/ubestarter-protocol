import { getNamedAccounts, ethers, deployments } from 'hardhat';
import {
  INonfungiblePositionManager,
  IUniswapV3Pool,
  UbestarterFactory,
  UbeStarterLaunchpadV1,
  IERC20Metadata,
} from '../typechain';
import exec from '../utils/exec';
import { toReadableJson } from '../utils/helpers';

const ubeAddress = '0x71e26d0E519D14591b9dE9a0fE9513A398101490';
const celoAddress = '0x471EcE3750Da237f93B8E339c536989b8978a438';
const usdcAddress = '0xcebA9300f2b948710d2653dD7B07f33A8B32118C';
const glousdAddress = '0x4F604735c1cF31399C6E711D5962b2B3E0225AD3';
const usdtAddress = '0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e';
const cusdAddress = '0x765DE816845861e75A25fCA122bb6898B8B1282a';

async function main() {
  const { deployer } = await getNamedAccounts();

  console.log({ deployer });

  const factory: UbestarterFactory = await ethers.getContract('UbestarterFactory', deployer);
  const implV1: UbeStarterLaunchpadV1 = await ethers.getContract('UbeStarterLaunchpadV1', deployer);
  const ubeToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    ubeAddress,
    deployer
  );
  const celoToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    celoAddress,
    deployer
  );
  const usdcToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    usdcAddress,
    deployer
  );
  const gloToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    glousdAddress,
    deployer
  );
  const usdtToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    usdtAddress,
    deployer
  );
  const cusdToken: IERC20Metadata = await ethers.getContractAt(
    'IERC20Metadata',
    cusdAddress,
    deployer
  );

  await exec(
    'updateImplementation',
    factory.updateImplementation(implV1.address, ethers.utils.parseEther('10000'))
  );

  await exec(
    'add ube as quote token',
    factory.updateQuoteToken(
      ubeAddress,
      ethers.utils.parseUnits('900000', await ubeToken.decimals()),
      ethers.utils.parseUnits('100000000', await ubeToken.decimals())
    )
  );
  await exec(
    'add celo as quote token',
    factory.updateQuoteToken(
      celoAddress,
      ethers.utils.parseUnits('10000', await celoToken.decimals()),
      ethers.utils.parseUnits('1000000', await celoToken.decimals())
    )
  );
  await exec(
    'add usdc as quote token',
    factory.updateQuoteToken(
      usdcAddress,
      ethers.utils.parseUnits('5000', await usdcToken.decimals()),
      ethers.utils.parseUnits('500000', await usdcToken.decimals())
    )
  );
  await exec(
    'add glo as quote token',
    factory.updateQuoteToken(
      glousdAddress,
      ethers.utils.parseUnits('5000', await gloToken.decimals()),
      ethers.utils.parseUnits('500000', await gloToken.decimals())
    )
  );
  await exec(
    'add usdt as quote token',
    factory.updateQuoteToken(
      usdtAddress,
      ethers.utils.parseUnits('5000', await usdtToken.decimals()),
      ethers.utils.parseUnits('500000', await usdtToken.decimals())
    )
  );
  await exec(
    'add cusd as quote token',
    factory.updateQuoteToken(
      cusdAddress,
      ethers.utils.parseUnits('5000', await cusdToken.decimals()),
      ethers.utils.parseUnits('500000', await cusdToken.decimals())
    )
  );

  const disclaimerMsg = `I accept the following disclaimer:
Ubestarter provides a platform for decentralized application (DApp) developers to launch new projects and for users to participate in these projects by purchasing tokens. The information provided on Ubestarter's website and through its services is for general informational purposes only and should not be considered financial, legal, or investment advice.
Ubestarter does not guarantee the success of any project or the performance of any token issued through its platform. The success of blockchain projects and the utility of their tokens can be affected by a multitude of factors beyond our control.
Projects are responsible for ensuring that their participation in token sales and their use of Ubestarter's services comply with laws and regulations in their jurisdiction, including but not limited to securities laws, anti-money laundering (AML) and know your customer (KYC) requirements.
Ubestarter, its affiliates, and its service providers will not be liable for any loss or damage arising from your use of the platform, including, but not limited to, any losses, damages, or claims arising from: (a) user error, such as forgotten passwords or incorrectly construed smart contracts; (b) server failure or data loss; (c) unauthorized access or activities by third parties, including the use of viruses, phishing, brute-forcing, or other means of attack against the platform or cryptocurrency wallets.
This disclaimer is subject to change at any time without notice. It is the project's responsibility to review it regularly to stay informed of any changes.
By using the Ubestarter, you acknowledge that you have read this disclaimer, understand it, and agree to be bound by its terms.`;

  await exec(
    'set disclaimerMsg',
    factory.updateDisclaimerMessage(ethers.utils.hashMessage(disclaimerMsg), disclaimerMsg)
  );

  await exec(
    'set verifier',
    factory.updateVerifier('0xbC3e48303d7bb8302aDE5E4d6A3Dd6C0a4660C72', true)
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
