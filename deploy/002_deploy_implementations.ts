import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  console.log({ deployer });

  const ubeAddress = '0x71e26d0E519D14591b9dE9a0fE9513A398101490';
  const ubeV3Factory = '0x67FEa58D5a5a4162cED847E13c2c81c73bf8aeC4';
  const ubeV3NftPositionManager = '0x897387c7B996485c3AAa85c94272Cd6C506f8c8F';

  await deployments.deploy('UbeStarterLaunchpadV1', {
    contract: 'UbeStarterLaunchpadV1',
    from: deployer,
    args: [
      ubeV3NftPositionManager, // address _nftPositionManager
    ],
    log: true,
    autoMine: true,
  });
};

export default func;
func.id = 'deploy_implementations';
func.tags = ['Implementations'];
