import hre from 'hardhat'
import '@nomiclabs/hardhat-ethers'
import { deployContract, waitTransaction } from '../cli/network'
import { setBalance } from '@nomicfoundation/hardhat-network-helpers'
import { BigNumber } from 'ethers'

const { ethers } = hre

async function getAllocations(blockNumber: BigNumber | number): Promise<BigNumber> {
  // TODO: implement
  return BigNumber.from(0)
}
async function getAllocationsPendingRewards(blockNumber: BigNumber | number): Promise<BigNumber> {
  // TODO: implement
  return BigNumber.from(0)
}

async function main() {
  // TODO: make read address.json with override chain id
  const { contracts, provider } = hre.graph({
    addressBook: 'addresses.json',
    graphConfig: 'config/graph.mainnet.yml',
  })

  // global values
  const INITIAL_ETH_BALANCE = hre.ethers.utils.parseEther('1000').toHexString()
  const L1_DEPLOYER_ADDRESS = '0xE04FcE05E9B8d21521bd1B0f069982c03BD31F76'
  const L1_COUNCIL_ADDRESS = '0x48301Fe520f72994d32eAd72E2B6A8447873CF50'
  const ISSUANCE_PER_BLOCK = 124 // TODO: estimate it better

  // roles
  const deployer = await ethers.getImpersonatedSigner(L1_DEPLOYER_ADDRESS)
  const council = await ethers.getImpersonatedSigner(L1_COUNCIL_ADDRESS)

  // fund accounts
  await setBalance(L1_DEPLOYER_ADDRESS, INITIAL_ETH_BALANCE)
  await setBalance(L1_COUNCIL_ADDRESS, INITIAL_ETH_BALANCE)

  console.log(`Deployer: ${L1_DEPLOYER_ADDRESS}`)
  console.log(`Council:  ${L1_COUNCIL_ADDRESS}`)

  // provider node config
  await provider.send('evm_setAutomine', [false])

  // ### batch 1
  // deploy L1 implementations
  const newRewardsManagerImpl = await deployContract('RewardsManager', [], deployer)
  const newL1GraphTokenGatewayImpl = await deployContract('L1GraphTokenGateway', [], deployer)

  // upgrade L1 implementations
  const batch1 = await Promise.all([
    contracts.GraphProxyAdmin.connect(council).upgrade(
      contracts.RewardsManager.address,
      newRewardsManagerImpl.contract.address,
    ),
    contracts.GraphProxyAdmin.connect(council).upgrade(
      contracts.L1GraphTokenGateway.address,
      newL1GraphTokenGatewayImpl.contract.address,
    ),
  ])
  console.log('Executing batch 1 (start upgrade)...')
  await provider.send('evm_mine', [])
  await batch1.map((tx) => waitTransaction(council, tx))

  // ### batch 2
  // << FILL WITH L2 actions >>

  const blockNumber1 = await provider.getBlockNumber()
  console.log(`Getting pending rewards at block ${blockNumber1}...`)
  const pendingRewards1 = await getAllocationsPendingRewards(blockNumber1)

  // ### batch 3
  // accept L2 implementations
  // accrue all signal and upgrade the rewards function
  // ensures the snapshot for rewards is updated right before the issuance formula changes.
  const batch3 = await Promise.all([
    contracts.GraphProxyAdmin.connect(council).acceptProxy(
      newL1GraphTokenGatewayImpl.contract.address,
      contracts.L1GraphTokenGateway.address,
    ),
    contracts.RewardsManager.connect(council).updateAccRewardsPerSignal(),
    contracts.GraphProxyAdmin.connect(council).acceptProxy(
      newRewardsManagerImpl.contract.address,
      contracts.RewardsManager.address,
    ),
    contracts.RewardsManager.connect(council).setIssuancePerBlock(ISSUANCE_PER_BLOCK),
  ])
  console.log('Executing batch 3 (upgrade implementations)...')
  await provider.send('evm_mine', [])
  await batch3.map((tx) => waitTransaction(council, tx))

  console.log(await contracts.RewardsManager.issuancePerBlock())

  const blockNumber2 = await provider.getBlockNumber()
  console.log(`Getting pending rewards at block ${blockNumber2}...`)
  const pendingRewards2 = await getAllocationsPendingRewards(blockNumber2)

  console.log(`diff is ${pendingRewards2.sub(pendingRewards1)}`)

  // ### batch 4
  // << FILL WITH L2 actions >>

  // test to move time forward and ensure that the inflation rate makes sense
  // one way to test that is to compare the pending rewards calculation before and after the upgrade

  // should be able to close active allocations and collect indexing rewards
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})