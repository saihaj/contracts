import { expect } from 'chai'
import hre from 'hardhat'
import { chainIdIsL2 } from '../../../../cli/utils'

describe('[L1] L1Reservoir initialization', () => {
  const {
    contracts: { L1Reservoir, GraphToken, RewardsManager },
  } = hre.graph()

  before(async function () {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId
    if (chainIdIsL2(chainId)) this.skip()
  })

  it('should allow RewardsManager contract to spend MAX_UINT256 tokens on L1Reservoirs behalf', async function () {
    const allowance = await GraphToken.allowance(L1Reservoir.address, RewardsManager.address)
    expect(allowance).eq(hre.ethers.constants.MaxUint256)
  })
})
