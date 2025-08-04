import { AztecAddress, Contract,createPXEClient,waitForPXE, Fr, GrumpkinScalar, type PXE, AccountWalletWithSecretKey  } from '@aztec/aztec.js';
import { getDeployedTestAccountsWallets } from '@aztec/accounts/testing';
import { AccountBasedPrivacyContract } from '../contracts/aztec/AccountBasedPrivacy/src/artifacts/AccountBasedPrivacy';
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

describe("accountBasedPrivacy", () => {
    let wallets:AccountWalletWithSecretKey[]
    let PXE:PXE
    beforeAll(async () => {
        const PXE_URL = process.env.PXE_URL || 'http://localhost:8080';
        PXE = createPXEClient(PXE_URL) as PXE;
        //@ts-ignore
        wallets  = await getDeployedTestAccountsWallets(PXE) as AccountWalletWithSecretKey[]
    })
    it("should spend", async () => {
        const walletDeployer = wallets[0] as AccountWalletWithSecretKey
        const walletAlice = wallets[1] as AccountWalletWithSecretKey
        const walletBob = wallets[2] as AccountWalletWithSecretKey
        const accountBasedPrivacy = await AccountBasedPrivacyContract.deploy(walletDeployer).send().deployed()
        const incomingBalance = 0n
        const sum_embedded_amounts_nonces = 0n 
        const block_number = await PXE.getBlockNumber()
        const res = await accountBasedPrivacy.withWallet(walletAlice).methods.transfer(
            walletBob.getAddress(),
            1n, 
            true, 
            123n, 
            incomingBalance, 
            sum_embedded_amounts_nonces, 
            block_number
        ).send().wait()
        console.log({res})
    })
});