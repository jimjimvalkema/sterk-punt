import { AztecAddress, Contract, createPXEClient, waitForPXE, Fr, GrumpkinScalar, type PXE, AccountWalletWithSecretKey, AztecAddressLike, FieldLike } from '@aztec/aztec.js';
import { getDeployedTestAccountsWallets } from '@aztec/accounts/testing';
import { AccountBasedPrivacyContract } from '../contracts/aztec/AccountBasedPrivacy/src/artifacts/AccountBasedPrivacy';
import { pedersenCommit } from '@aztec/foundation/crypto'
import { toBufferBE , toBigIntBE} from 'bigint-buffer';
import { ethers } from 'ethers';
import { Grumpkin } from '@aztec/foundation/crypto';
import { Point } from '@aztec/foundation/fields';

const MAX_FIELD_BLINDING_POINT = await pedersenOnInt([0n, Fr.MAX_FIELD_VALUE.toBigInt()])

async function pedersenOnInt(input:bigint[]) {
    const commitment = await pedersenCommit(input.map((v)=>(new Fr(v)).toBuffer()))
    const point1 = new Point(
        Fr.fromBuffer(commitment[0]),
        Fr.fromBuffer(commitment[1]),
        false
    );
    return point1
}


async function createBlindingPoint(blindingNonce: bigint) {
    return await pedersenOnInt([0n, blindingNonce % GrumpkinScalar.MODULUS])
}

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
describe("accountBasedPrivacy", () => {
    let wallets: AccountWalletWithSecretKey[]
    let PXE: PXE
    beforeAll(async () => {
        const PXE_URL = process.env.PXE_URL || 'http://localhost:8080';
        PXE = createPXEClient(PXE_URL) as PXE;
        //@ts-ignore
        wallets = await getDeployedTestAccountsWallets(PXE) as AccountWalletWithSecretKey[]
    })

    it("should spend", async () => {
        const walletDeployer = wallets[0] as AccountWalletWithSecretKey
        const walletAlice = wallets[1] as AccountWalletWithSecretKey
        const viewingKeyAlice = 1234n
        const walletBob = wallets[2] as AccountWalletWithSecretKey
        const accountBasedPrivacy = await AccountBasedPrivacyContract.deploy(walletDeployer).send().deployed()

        for (let amount = 0; amount < 10; amount++) {
            await accountBasedPrivacy.withWallet(walletAlice).methods.mint(
                walletAlice.getAddress(),
                BigInt(amount+100),
            ).send().wait()
        }
        const privateEvents = await PXE.getPrivateEvents(accountBasedPrivacy.address, AccountBasedPrivacyContract.events.PrivateIncomingTransfer, 0, 100000, [walletAlice.getAddress()])
        // TODO make issue getPublicEvents need to filter per contract address like getPrivateEvents does
        const publicEvents = await PXE.getPublicEvents(AccountBasedPrivacyContract.events.PublicIncomingTransfer, 0, 100000);
        const aliceReceivedAmountBlockNumber = await PXE.getBlockNumber()
        // because getPublicEvents doesn't filter on the contract address. Work around here assumes that the contract used to scan events is the most recent contract deployed
        const publicEventsOverShoot = publicEvents.length - privateEvents.length
        const combinedEvents = privateEvents.map((v, i) => {
            return {
                ...(privateEvents[i] as Object),
                ...(publicEvents[publicEventsOverShoot + i] as Object)
            }
        })
        // yeah no filtering indexed events in aztec.js yet grrrrr!
        // see thread issue: https://github.com/AztecProtocol/aztec-packages/issues/16245
        const combinedEventsAlice = combinedEvents.filter((v: any) => AztecAddress.fromBigInt(v.recipient).equals(walletAlice.getAddress()))

        const aliceReceivedAmountData = {receivedAmount: 0n, receivedAmountBlindingNonce: 0n }
        for (const {amount, amount_blinding_nonce} of combinedEventsAlice as any) {
            aliceReceivedAmountData.receivedAmount += amount
            aliceReceivedAmountData.receivedAmountBlindingNonce += amount_blinding_nonce
        }


        console.log({ aliceReceivedAmountData: aliceReceivedAmountData })
        console.log({combinedEventsAlice})
        const blindingPoint = await createBlindingPoint(aliceReceivedAmountData.receivedAmountBlindingNonce)//new Point(Fr.fromHexString("0x1fbe6c4566450674fe3963d1ab2b55bdf6e372abd0cabe36e0b24861e6cf8c6d"),Fr.fromHexString("0x1a5322c42fe9343da84394bad78e58254656e069b8a968b8986f488b0f9b3a63"), false)//await createBlindingPoint(aliceReceivedAmountData.receivedAmountBlindingNonce)
        const amountPoint = await pedersenOnInt([aliceReceivedAmountData.receivedAmount, 0n]) //new Point(Fr.fromHexString("0x1fbe6c4566450674fe3963d1ab2b55bdf6e372abd0cabe36e0b24861e6cf8c6d"),Fr.fromHexString("0x1a5322c42fe9343da84394bad78e58254656e069b8a968b8986f488b0f9b3a63"), false)// await pedersenOnInt([aliceReceivedAmountData.receivedAmount, 0n])
        const grumpkin = new Grumpkin()
        const receivedAmountPointBlinded = await grumpkin.add(amountPoint, blindingPoint)
        console.log({ pedersenInJs_x: ethers.toBeHex(receivedAmountPointBlinded.x.toBigInt()) })
        const current_point =  await accountBasedPrivacy.methods.get_received_amount(walletAlice.getAddress()).simulate()
        console.log({current_point_x_from_chain: ethers.toBeHex(current_point.x)} )
        const blindingPointFormatted = {
                x: blindingPoint.x.toBigInt(),
                y:  blindingPoint.y.toBigInt(),
                is_infinite: blindingPoint.isInfinite,
        }
        console.log({
            recipient: walletBob.getAddress(),
            amount:2n,
            accountNonceIsZero: true,
            viewingKeyAlice,
            receivedAmount: aliceReceivedAmountData.receivedAmount,
            blindingPointFormatted,
            aliceReceivedAmountBlockNumber
        })
        const tx = await accountBasedPrivacy.withWallet(walletAlice).methods.transfer(
            walletBob.getAddress(),
            2n,
            true,
            viewingKeyAlice,
            aliceReceivedAmountData.receivedAmount,
            blindingPointFormatted,
            aliceReceivedAmountBlockNumber
        ).send().wait()

        console.log({ tx })
    })
});