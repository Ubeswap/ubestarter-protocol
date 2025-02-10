import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  console.log({ deployer });

  const ubeAddress = '0x71e26d0E519D14591b9dE9a0fE9513A398101490';

  await deployments.deploy('UbestarterFactory', {
    contract: 'UbestarterFactory',
    from: deployer,
    args: [
      deployer, // address initialOwner
      ubeAddress, // address feeTokenAddress
    ],
    log: true,
    autoMine: true,
  });
};

export default func;
func.id = 'deploy_factory';
func.tags = ['UbestarterFactory'];
