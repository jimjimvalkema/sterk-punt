import { AztecAddress, Contract, createPXEClient, waitForPXE, Fr, GrumpkinScalar, type PXE, AccountWalletWithSecretKey, AztecAddressLike } from '@aztec/aztec.js';
import { getDeployedTestAccountsWallets } from '@aztec/accounts/testing';
import { AccountBasedPrivacyContract } from '../contracts/aztec/AccountBasedPrivacy/src/artifacts/AccountBasedPrivacy';
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
        const walletBob = wallets[2] as AccountWalletWithSecretKey
        const accountBasedPrivacy = await AccountBasedPrivacyContract.deploy(walletDeployer).send().deployed()

        for (let amount = 0; amount < 3; amount++) {
            await accountBasedPrivacy.withWallet(walletAlice).methods.mint(
                walletAlice.getAddress(),
                BigInt(amount),
            ).send().wait()
        }
        const privateEvents = await PXE.getPrivateEvents(accountBasedPrivacy.address, AccountBasedPrivacyContract.events.PrivateIncomingTransfer, 0, 100000, [walletAlice.getAddress()])
        // TODO make issue getPublicEvents need to filter per contract address like getPrivateEvents does
        const publicEvents = await PXE.getPublicEvents(AccountBasedPrivacyContract.events.PublicIncomingTransfer, 0, 100000);
        //console.log({publicLenght: publicEvents.length, privateLenght: privateEvents.length})
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
        const aliceReceivedAmountData = combinedEventsAlice.reduce((p: any, c: any, i) => {
            return { receivedAmount: p.receivedAmount += c.amount, receivedAmountBlindingNonce: p.receivedAmountBlindingNonce += c.amount_blinding_nonce }
        }, { receivedAmount: 0n, receivedAmountBlindingNonce: 0n })
        console.log({aliceReceivedAmountData: aliceReceivedAmountData})

    })
});