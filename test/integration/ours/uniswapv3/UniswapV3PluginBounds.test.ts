import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import { BigNumber, BigNumberish, Wallet } from "ethers"
import hre, { ethers, waffle } from "hardhat"
import { defaultFixture, IMPLEMENTATION } from "../../../fixtures"
import { getChainId } from "../../../../common/blockchain-utils"
import { networkConfig } from "../../../../common/configuration"
import { bn, fp, pow10 } from "../../../../common/numbers"
import {
    ERC20Mock,
    ISwapRouter,
    MockV3Aggregator,
    UniswapV3WrapperMock,
    USDCMock,
} from "../../../../typechain"
import { whileImpersonating } from "../../../utils/impersonation"
import { waitForTx } from "../../utils"
import { expect } from "chai"
import { CollateralStatus, MAX_UINT256 } from "../../../../common/constants"
import { UniswapV3NonFiatCollateral__factory } from "@typechain/factories/UniswapV3NonFiatCollateral__factory"
import { UniswapV3NonFiatCollateral } from "@typechain/UniswapV3NonFiatCollateral"
import {
    closeDeadline,
    defaultMintParams,
    deployUniswapV3WrapperMock,
    holderDAI,
    holderUSDC,
    holderUSDT,
    logBalances,
    MAX_TICK,
    p999,
    TMintParams,
} from "../common"
import { anyUint, anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs"
import { getLatestBlockTimestamp } from "../../../utils/time"

const createFixtureLoader = waffle.createFixtureLoader

const swapRouterAddress = "0xE592427A0AEce92De3Edee1F18E0157C05861564"

const describeFork = process.env.FORK ? describe : describe.skip
describeFork(`UniswapV3Plugin - Integration - Mainnet Forking P${IMPLEMENTATION}`, function () {
    const initialBal = 20000
    let owner: SignerWithAddress
    let addr1: SignerWithAddress
    let addr2: SignerWithAddress

    // Tokens and Assets
    let dai: ERC20Mock
    let usdc: USDCMock
    let usdt: USDCMock

    let loadFixture: ReturnType<typeof createFixtureLoader>
    let wallet: Wallet

    let chainId: number

    describe("Assets/Collateral", () => {
        before(async () => {
            ;[wallet] = (await ethers.getSigners()) as unknown as Wallet[]
            loadFixture = createFixtureLoader([wallet])

            chainId = await getChainId(hre)
            if (!networkConfig[chainId]) {
                throw new Error(`Missing network configuration for ${hre.network.name}`)
            }
        })

        beforeEach(async () => {
            ;[owner, , addr1, addr2] = await ethers.getSigners()

            const tokens = networkConfig[chainId].tokens
            await loadFixture(defaultFixture)
            ;[dai, usdt, usdc] = await Promise.all(
                [tokens.DAI!, tokens.USDT!, tokens.USDC!].map(
                    async (address) => await ethers.getContractAt("ERC20Mock", address)
                )
            )

            await Promise.all(
                [
                    [dai, holderDAI],
                    [usdt, holderUSDT],
                    [usdc, holderUSDC],
                ].map(async ([asset, holder]) => {
                    await whileImpersonating(holder, async (signer) => {
                        const decimals = await asset.decimals()
                        const p = (value: BigNumberish) => pow10(decimals).mul(value)
                        await asset.connect(signer).transfer(addr1.address, p(initialBal))
                    })
                })
            )
            await Promise.all(
                [
                    [dai, holderDAI],
                    [usdt, holderUSDT],
                    [usdc, holderUSDC],
                ].map(async ([asset, holder]) => {
                    await whileImpersonating(holder, async (signer) => {
                        const balance = await asset.balanceOf(holder)
                        await asset.connect(signer).transfer(addr2.address, balance)
                    })
                })
            )
        })

        it("U3C can be deployed", async () => {
            const asset0 = dai
            const asset1 = usdc

            const decimals0 = await asset0.decimals()
            const decimals1 = await asset1.decimals()

            const p0 = (value: BigNumberish) => pow10(decimals0).mul(value)
            const p1 = (value: BigNumberish) => pow10(decimals1).mul(value)

            const DELAY_UNTIL_DEFAULT = bn("86400") // 24h
            const ORACLE_TIMEOUT = bn("281474976710655").div(2) // type(uint48).max / 2
            const RTOKEN_MAX_TRADE_VALUE = fp("1e6")

            const mintParams: TMintParams = await defaultMintParams(
                asset0,
                asset1,
                p0(100),
                p1(100)
            )

            mintParams.tickLower = BigNumber.from(MAX_TICK).mul(1).div(10)

            const uniswapV3WrapperMock: UniswapV3WrapperMock = await deployUniswapV3WrapperMock(
                asset0,
                asset1,
                owner,
                mintParams,
                addr1
            )

            const MockV3AggregatorFactory = await ethers.getContractFactory("MockV3Aggregator")
            const mockChainlinkFeed0 = <MockV3Aggregator>(
                await MockV3AggregatorFactory.connect(addr1).deploy(8, bn("1e8"))
            )
            const mockChainlinkFeed1 = <MockV3Aggregator>(
                await MockV3AggregatorFactory.connect(addr1).deploy(8, bn("1e8"))
            )

            const UniswapV3NonFiatCollateralContractFactory: UniswapV3NonFiatCollateral__factory =
                await ethers.getContractFactory("UniswapV3NonFiatCollateral")

            const fallbackPrice = fp("1")
            const targetName = ethers.utils.formatBytes32String("UNIV3SQRT")
            const UniswapV3NonFiatCollateral: UniswapV3NonFiatCollateral =
                await UniswapV3NonFiatCollateralContractFactory.connect(addr1).deploy(
                    fallbackPrice,
                    fallbackPrice,
                    mockChainlinkFeed0.address,
                    mockChainlinkFeed1.address,
                    uniswapV3WrapperMock.address,
                    RTOKEN_MAX_TRADE_VALUE,
                    ORACLE_TIMEOUT,
                    targetName,
                    DELAY_UNTIL_DEFAULT
                )

            console.log({ mintParams })
            console.log("strictPrice", await UniswapV3NonFiatCollateral.strictPrice())
            console.log("_fallbackPrice", await UniswapV3NonFiatCollateral._fallbackPrice())

            mintParams.amount0Desired = await asset0.balanceOf(addr2.address)

            // const uniswapV3WrapperMock2: UniswapV3WrapperMock = await deployUniswapV3WrapperMock(
            //     asset0,
            //     asset1,
            //     owner,
            //     mintParams,
            //     addr2
            // )

            console.log("strictPrice", await UniswapV3NonFiatCollateral.strictPrice())
            console.log("_fallbackPrice", await UniswapV3NonFiatCollateral._fallbackPrice())

            const swapRouter: ISwapRouter = await ethers.getContractAt(
                "ISwapRouter",
                swapRouterAddress
            )

            await waitForTx(
                await asset0
                    .connect(addr2)
                    .approve(swapRouter.address, await asset0.balanceOf(addr2.address))
            )

            await waitForTx(
                await swapRouter.connect(addr2).exactInputSingle({
                    tokenIn: asset0.address,
                    tokenOut: asset1.address,
                    fee: mintParams.fee,
                    recipient: addr2.address,
                    deadline: await closeDeadline(),
                    amountIn: await asset0.balanceOf(addr2.address),
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0,
                })
            )

            console.log("strictPrice", await UniswapV3NonFiatCollateral.strictPrice())
            console.log("_fallbackPrice", await UniswapV3NonFiatCollateral._fallbackPrice())
        })
    })
})

//TODO check that fees earned remain intact after decreaseLiquidity calls
//TODO @etsvigun cleanup helpers
//https://github.com/reserve-protocol/protocol/blob/master/test/integration/individual-collateral/CTokenFiatCollateral.test.ts
